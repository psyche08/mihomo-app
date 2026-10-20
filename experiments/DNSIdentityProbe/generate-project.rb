#!/usr/bin/env ruby
require 'xcodeproj'
require 'digest'
require 'fileutils'
module SecureRandom
  def self.hex(length = nil)
    @probe_counter = (@probe_counter || 0) + 1
    Digest::SHA256.hexdigest("dns-probe-#{@probe_counter}")[0, (length || 16)*2]
  end
end
root = File.expand_path(__dir__)
path = File.join(root, 'DNSIdentityProbe.xcodeproj')
FileUtils.rm_rf(path)
p = Xcodeproj::Project.new(path)
p.root_object.attributes['LastUpgradeCheck'] = '2700'
def target(p, root, name, id, source, kind = :application)
  t = p.new_target(:application, name, :osx, '14.0', nil, :swift)
  if kind == :extension
    t.product_type = 'com.apple.product-type.system-extension'
    t.product_reference.path = "#{id}.systemextension"
    t.product_reference.explicit_file_type = 'wrapper.system-extension'
  end
  group = p.main_group.new_group(name, source)
  Dir[File.join(root, source, '*.swift')].sort.each { |f| t.source_build_phase.add_file_reference(group.new_file(File.basename(f))) }
  t.build_configurations.each do |c|
    c.build_settings.merge!({
      'PRODUCT_NAME' => kind == :extension ? id : name,
      'EXECUTABLE_NAME' => name, 'PRODUCT_MODULE_NAME' => name,
      'PRODUCT_BUNDLE_IDENTIFIER' => id, 'DEVELOPMENT_TEAM' => '89LGY6BD53',
      'CODE_SIGN_STYLE' => 'Automatic', 'CODE_SIGN_INJECT_BASE_ENTITLEMENTS' => 'NO',
      'ENABLE_HARDENED_RUNTIME' => 'YES', 'SWIFT_VERSION' => '5.0',
      'MACOSX_DEPLOYMENT_TARGET' => '14.0', 'ARCHS' => 'arm64',
      'ONLY_ACTIVE_ARCH' => 'NO', 'MARKETING_VERSION' => '0.1.0',
      'CURRENT_PROJECT_VERSION' => '1', 'SKIP_INSTALL' => name == 'MihomoDNSProbe' ? 'NO' : 'YES',
      'INFOPLIST_FILE' => "Config/#{kind == :extension ? 'Extension' : 'App'}-Info.plist",
      'GENERATE_INFOPLIST_FILE' => 'NO', 'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/../Frameworks',
      'SWIFT_EMIT_LOC_STRINGS' => 'NO'
    })
    c.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Config/Extension.entitlements' if kind == :extension
    c.build_settings['CODE_SIGN_ENTITLEMENTS'] = 'Config/Host.entitlements' if name == 'MihomoDNSProbe'
  end
  t
end
def embed(parent, child, path)
  parent.add_dependency(child)
  phase = parent.new_copy_files_build_phase("Embed #{child.name}")
  phase.dst_subfolder_spec = '1'; phase.dst_path = path
  phase.add_file_reference(child.product_reference).settings = {'ATTRIBUTES'=>['CodeSignOnCopy', 'RemoveHeadersOnCopy']}
end
ext = target(p, root, 'MihomoDNSProbeExtension', 'dev.linsheng.mihomo-dns-probe.extension', 'Extension', :extension)
helper = target(p, root, 'MihomoDNSHelper', 'dev.linsheng.mihomo-dns-probe.selected.helper', 'Client')
selected = target(p, root, 'MihomoDNSSelected', 'dev.linsheng.mihomo-dns-probe.selected', 'Client')
control = target(p, root, 'MihomoDNSControl', 'dev.linsheng.mihomo-dns-probe.control', 'Client')
host = target(p, root, 'MihomoDNSProbe', 'dev.linsheng.mihomo-dns-probe', 'Host')
embed(selected, helper, 'Contents/Library/LoginItems')
embed(host, ext, 'Contents/Library/SystemExtensions')
embed(host, selected, 'Contents/Resources/Clients')
embed(host, control, 'Contents/Resources/Clients')
p.save
scheme = Xcodeproj::XCScheme.new
scheme.configure_with_targets(host, nil)
scheme.archive_action.build_configuration = 'Release'
scheme.save_as(path, 'MihomoDNSProbe', true)
puts path
