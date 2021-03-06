require 'puppet/resource_api/simple_provider'
require 'puppet_x/puppetlabs/dsc_api/dsc_template_helper'
require 'ruby-pwsh'
require 'pathname'
require 'json'

class Puppet::Provider::DscBaseProvider < Puppet::ResourceApi::SimpleProvider

  def get(context, names = nil)
    # Relies on the get_simple_filter feature to pass the namevars
    # as an array containing the namevar parameters as a hash.
    # This hash is functionally the same as a should hash as
    # passed to the should_to_resource method.
    context.debug('Returning pre-canned example data')
    names.collect { |name_hash| invoke_get_method(context,name_hash) }
  end

  def invoke_get_method(context, name_hash)
    context.debug("retrieving '#{name_hash}'")
    resource = should_to_resource(name_hash, context, 'get')
    script_content = ps_script_content(resource)
    context.debug("Script:\n #{script_content}")
    output = ps_manager.execute(script_content)[:stdout]
    context.err('Nothing returned') if output.nil?

    data   = JSON.parse(output)
    # DSC gives back information we don't care about; filter down to only
    # those properties exposed in the type definition.
    valid_attributes = context.type.attributes.keys.collect{ |k| k.to_s }
    data.reject! { |key,value| !valid_attributes.include?("dsc_#{key.downcase}") }
    # Canonicalize the results to match the type definition representation;
    # failure to do so will prevent the resource_api from comparing the result
    # to the should hash retrieved from the resource definition in the manifest.
    data.keys.each do |key|
      type_key = "dsc_#{key.downcase}".to_sym
      data[type_key] = data.delete(key)
      if context.type.attributes[type_key][:type] =~ /Enum/
        data[type_key] = data[type_key].downcase if data[type_key].is_a?(String)
      end
    end
    data.merge!({ensure: 'present', name: name_hash[:name]})

    context.debug(data)

    data
  end

  def invoke_set_method(context, name, should)
    context.debug("Ivoking Set Method for '#{name}' with #{should.inspect}")
    resource = should_to_resource(should, context, 'set')
    script_content = ps_script_content(resource)
    context.debug("Script:\n #{script_content}")

    output = ps_manager.execute(script_content)[:stdout]
    context.err('Nothing returned') if output.nil?

    data   = JSON.parse(output)
    context.debug(data)

    context.err(data['errormessage']) if !data['errormessage'].empty?
    # notify_reboot_pending if data['rebootrequired'] == true
    data
  end

  def create(context, name, should)
    context.debug("Creating '#{name}' with #{should.inspect}")
    invoke_set_method(context, name, should)
  end

  def update(context, name, should)
    context.debug("Updating '#{name}' with #{should.inspect}")
    invoke_set_method(context, name, should)
  end

  def delete(context, name)
    context.debug("Deleting '#{name}'")
    invoke_set_method(context, name, should)
  end

  def should_to_resource(should, context, dsc_invoke_method)
    resource = {}
    resource[:parameters] = {}
    [:name, :dscmeta_resource_friendly_name, :dscmeta_resource_name, :dscmeta_module_name, :dscmeta_module_version].each do |k|
      resource[k] = context.type.definition[k]
    end
    should.each do |k,v|
      next if k == :name
      next if k == :ensure
      resource[:parameters][k] = {}
      resource[:parameters][k][:value] = v
      [:mof_type, :mof_is_embedded].each do |ky|
        resource[:parameters][k][ky] = context.type.definition[:attributes][k][ky]
      end
    end
    resource[:dsc_invoke_method] = dsc_invoke_method
    resource[:vendored_modules_path] = File.expand_path(Pathname.new(__FILE__).dirname + '../../../' + 'puppet_x/dsc_resources')
    resource[:attributes] = nil
    resource
  end

  def ps_script_content(resource)
    template_path = File.expand_path('../', __FILE__)
    preamble      = File.new(template_path + "/invoke_dsc_resource_preamble.ps1.erb").read
    template      = File.new(template_path + "/invoke_dsc_resource.ps1.erb").read
    postscript    = File.new(template_path + "/invoke_dsc_resource_postscript.ps1.erb").read
    content = preamble + template + postscript
    PuppetX::DscApi::TemplateHelpers.ps_script_content(resource, content)
  end

  def ps_manager
    debug_output = Puppet::Util::Log.level == :debug
    Pwsh::Manager.instance(Pwsh::Manager.powershell_path, Pwsh::Manager.powershell_args, debug: debug_output)
  end
end
