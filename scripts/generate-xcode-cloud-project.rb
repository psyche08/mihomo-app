#!/usr/bin/env ruby
# frozen_string_literal: true

require "digest"
require "fileutils"
require "pathname"
require "securerandom"
require "xcodeproj"

# xcodeproj normally assigns random object IDs. Stable IDs keep regeneration
# reviewable and make the committed Cloud project reproducible.
module SecureRandom
  class << self
    alias mihomobox_original_hex hex

    def hex(length = nil)
      @mihomobox_xcode_counter ||= 0
      @mihomobox_xcode_counter += 1
      Digest::SHA256.hexdigest("mihomobox-xcode-cloud-#{@mihomobox_xcode_counter}")[0, (length || 16) * 2]
    end
  end
end

ROOT = Pathname.new(__dir__).parent.expand_path
PROJECT_DIR = ROOT.join("XcodeCloud")
PROJECT_PATH = PROJECT_DIR.join("MihomoBox.xcodeproj")
TEAM_ID = "89LGY6BD53"

if ARGV == ["--check"]
  abort "missing #{PROJECT_PATH}" unless PROJECT_PATH.directory?
  project = Xcodeproj::Project.open(PROJECT_PATH.to_s)
  expected_sources = {
    "MihomoBox" => ROOT.join("Sources/MihomoBoxApp"),
    "MihomoDaemon" => ROOT.join("Sources/MihomoDaemon"),
    "MihomoAgent" => ROOT.join("Sources/MihomoAgent"),
    "MihomoBoxCLI" => ROOT.join("Sources/MihomoBoxCLI"),
  }
  abort "unexpected Xcode Cloud targets" unless project.targets.map(&:name).sort == expected_sources.keys.sort

  expected_sources.each do |target_name, directory|
    target = project.targets.find { |candidate| candidate.name == target_name }
    actual = target.source_build_phase.files_references.map { |reference| reference.real_path.to_s }.sort
    expected = directory.glob("**/*.swift").map { |source| source.expand_path.to_s }.sort
    abort "source membership drift for #{target_name}; regenerate the project" unless actual == expected
  end

  app = project.targets.find { |target| target.name == "MihomoBox" }
  expected_phases = [
    "Sources",
    "Frameworks",
    "Resources",
    "Prepare pinned Mihomo and icon inputs",
    "Embed signed helper executables",
    "Embed signed pinned Mihomo",
    "Assemble audited application resources",
  ]
  abort "MihomoBox archive phases drifted" unless app.build_phases.map(&:display_name) == expected_phases
  abort "MihomoBox must be the only installed target" unless app.resolved_build_setting("SKIP_INSTALL").values.uniq == ["NO"]

  resolved = PROJECT_PATH.join("project.xcworkspace/xcshareddata/swiftpm/Package.resolved")
  abort "Xcode Cloud Package.resolved drifted" unless FileUtils.compare_file(ROOT.join("Package.resolved"), resolved)
  scheme = PROJECT_PATH.join("xcshareddata/xcschemes/MihomoBox.xcscheme")
  abort "shared MihomoBox scheme is missing" unless scheme.file? && scheme.read.include?("<ArchiveAction")

  version = ROOT.join("VERSION").read.strip
  configured_version = ROOT.join("Config/XcodeCloud.xcconfig").read[/^MARKETING_VERSION = (.+)$/, 1]
  abort "Xcode Cloud version does not match VERSION" unless version == configured_version

  puts "Xcode Cloud project static checks passed"
  exit 0
elsif !ARGV.empty?
  abort "usage: #{$PROGRAM_NAME} [--check]"
end

FileUtils.rm_rf(PROJECT_PATH)
FileUtils.mkdir_p(PROJECT_DIR)

project = Xcodeproj::Project.new(PROJECT_PATH.to_s)
project.root_object.attributes["LastSwiftUpdateCheck"] = "2660"
project.root_object.attributes["LastUpgradeCheck"] = "2660"
project.root_object.attributes["BuildIndependentTargetsInParallel"] = "YES"

config_group = project.main_group.new_group("Configuration", "../Config")
xcconfig = config_group.new_file("XcodeCloud.xcconfig")
config_group.new_file("XcodeCloud-Info.plist")

project.build_configurations.each do |configuration|
  configuration.base_configuration_reference = xcconfig
  configuration.build_settings.merge!(
    "ALWAYS_SEARCH_USER_PATHS" => "NO",
    "CLANG_ENABLE_MODULES" => "YES",
    "MACOSX_DEPLOYMENT_TARGET" => "14.0",
    "SWIFT_VERSION" => "5.0"
  )
end

local_package = project.new(Xcodeproj::Project::Object::XCLocalSwiftPackageReference)
local_package.relative_path = ".."
project.root_object.package_references << local_package

sparkle_package = project.new(Xcodeproj::Project::Object::XCRemoteSwiftPackageReference)
sparkle_package.repositoryURL = "https://github.com/sparkle-project/Sparkle.git"
sparkle_package.requirement = { "kind" => "exactVersion", "version" => "2.9.4" }
project.root_object.package_references << sparkle_package

def add_package_product(project, target, package, product_name)
  dependency = project.new(Xcodeproj::Project::Object::XCSwiftPackageProductDependency)
  dependency.package = package
  dependency.product_name = product_name
  target.package_product_dependencies << dependency

  build_file = project.new(Xcodeproj::Project::Object::PBXBuildFile)
  build_file.product_ref = dependency
  target.frameworks_build_phase.files << build_file
end

def add_sources(project, target, display_name, source_directory)
  relative_directory = source_directory.relative_path_from(PROJECT_DIR)
  group = project.main_group.new_group(display_name, relative_directory.to_s)
  source_directory.glob("**/*.swift").sort.each do |source|
    reference = group.new_file(source.relative_path_from(source_directory).to_s)
    target.source_build_phase.add_file_reference(reference)
  end
end

def configure_target(target, product_name)
  target.build_configurations.each do |configuration|
    configuration.build_settings.merge!(
      "CODE_SIGN_STYLE" => "Automatic",
      "DEVELOPMENT_TEAM" => TEAM_ID,
      "ENABLE_HARDENED_RUNTIME" => "YES",
      "PRODUCT_NAME" => product_name,
      "SWIFT_VERSION" => "5.0"
    )
  end
end

daemon = project.new_target(
  :command_line_tool, "MihomoDaemon", :osx, "14.0", nil, :swift, "mihomo-daemon"
)
configure_target(daemon, "mihomo-daemon")
daemon.build_configurations.each { |configuration| configuration.build_settings["SKIP_INSTALL"] = "YES" }
add_sources(project, daemon, "Daemon Sources", ROOT.join("Sources/MihomoDaemon"))
add_package_product(project, daemon, local_package, "MihomoControl")
add_package_product(project, daemon, local_package, "MihomoDNSCore")
daemon.add_system_framework(["Security", "SystemConfiguration"])

agent = project.new_target(
  :command_line_tool, "MihomoAgent", :osx, "14.0", nil, :swift, "mihomo-agent"
)
configure_target(agent, "mihomo-agent")
agent.build_configurations.each { |configuration| configuration.build_settings["SKIP_INSTALL"] = "YES" }
add_sources(project, agent, "Agent Sources", ROOT.join("Sources/MihomoAgent"))
add_package_product(project, agent, local_package, "MihomoDNSCore")
agent.add_system_framework(["IOKit", "SystemConfiguration"])

cli = project.new_target(
  :command_line_tool, "MihomoBoxCLI", :osx, "14.0", nil, :swift, "mihomoboxctl"
)
configure_target(cli, "mihomoboxctl")
cli.build_configurations.each { |configuration| configuration.build_settings["SKIP_INSTALL"] = "YES" }
add_sources(project, cli, "CLI Sources", ROOT.join("Sources/MihomoBoxCLI"))
add_package_product(project, cli, local_package, "MihomoControl")
cli.add_system_framework("Security")

app = project.new_target(:application, "MihomoBox", :osx, "14.0", nil, :swift, "MihomoBox")
configure_target(app, "MihomoBox")
app.build_configurations.each do |configuration|
  configuration.build_settings.merge!(
    "EXECUTABLE_NAME" => "mihomo-app",
    "GENERATE_INFOPLIST_FILE" => "NO",
    "INFOPLIST_FILE" => "../Config/XcodeCloud-Info.plist",
    "LD_RUNPATH_SEARCH_PATHS" => "$(inherited) @executable_path/../Frameworks",
    "PRODUCT_BUNDLE_IDENTIFIER" => "dev.linsheng.mihomo-app",
    "SKIP_INSTALL" => "NO"
  )
end
add_sources(project, app, "App Sources", ROOT.join("Sources/MihomoBoxApp"))
add_package_product(project, app, local_package, "MihomoControl")
add_package_product(project, app, local_package, "MihomoDNSCore")
add_package_product(project, app, local_package, "MihomoBoxUI")
add_package_product(project, app, sparkle_package, "Sparkle")
app.add_system_framework(["AppKit", "Security", "UniformTypeIdentifiers"])

[daemon, agent, cli].each { |helper| app.add_dependency(helper) }

prepare_phase = app.new_shell_script_build_phase("Prepare pinned Mihomo and icon inputs")
prepare_phase.shell_path = "/bin/bash"
prepare_phase.shell_script = <<~'SCRIPT'
  set -euo pipefail
  TARGET_TRIPLE=aarch64-apple-darwin "$SRCROOT/../scripts/fetch-mihomo.sh"
  "$SRCROOT/../scripts/prepare-icons.sh"
SCRIPT
prepare_phase.input_paths = [
  "$(SRCROOT)/../scripts/fetch-mihomo.sh",
  "$(SRCROOT)/../scripts/prepare-icons.sh",
  "$(SRCROOT)/../Resources/AppIcon/icon.icns"
]
prepare_phase.output_paths = ["$(SRCROOT)/../.build/staging/mihomo-aarch64-apple-darwin"]
prepare_phase.always_out_of_date = "1"

executables_phase = app.new_copy_files_build_phase("Embed signed helper executables")
executables_phase.symbol_dst_subfolder_spec = :executables
[daemon, agent, cli].each do |helper|
  build_file = executables_phase.add_file_reference(helper.product_reference)
  build_file.settings = { "ATTRIBUTES" => ["CodeSignOnCopy"] }
end

pinned_group = project.main_group.new_group("Pinned Build Inputs", "..")
mihomo = pinned_group.new_file(".build/staging/mihomo-aarch64-apple-darwin")
mihomo.name = "mihomo"
mihomo.last_known_file_type = "compiled.mach-o.executable"
mihomo.include_in_index = "0"
mihomo_phase = app.new_copy_files_build_phase("Embed signed pinned Mihomo")
mihomo_phase.symbol_dst_subfolder_spec = :executables
mihomo_build_file = mihomo_phase.add_file_reference(mihomo)
mihomo_build_file.settings = { "ATTRIBUTES" => ["CodeSignOnCopy"] }

resources_phase = app.new_shell_script_build_phase("Assemble audited application resources")
resources_phase.shell_path = "/bin/bash"
resources_phase.shell_script = '"$SRCROOT/../scripts/assemble-xcode-cloud-resources.sh"'
resources_phase.always_out_of_date = "1"

project.save

scheme = Xcodeproj::XCScheme.new
scheme.add_build_target(app)
scheme.set_launch_target(app)
scheme.archive_action.build_configuration = "Release"
scheme.archive_action.custom_archive_name = "MihomoBox"
scheme.save_as(PROJECT_PATH.to_s, "MihomoBox", true)

resolved_directory = PROJECT_PATH.join("project.xcworkspace/xcshareddata/swiftpm")
FileUtils.mkdir_p(resolved_directory)
FileUtils.cp(ROOT.join("Package.resolved"), resolved_directory.join("Package.resolved"))

puts "generated #{PROJECT_PATH.relative_path_from(ROOT)}"
