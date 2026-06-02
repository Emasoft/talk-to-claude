#!/usr/bin/env ruby
# Generates TalkToClaude.xcodeproj from the sources in ./TalkToClaude using the
# `xcodeproj` gem (already installed system-wide). Re-runnable: it removes any
# existing project first, so the .xcodeproj is a build artifact, not a
# hand-edited file. Run with:  ruby ios/project.rb
require 'xcodeproj'
require 'fileutils'

dir = __dir__
project_path = File.join(dir, 'TalkToClaude.xcodeproj')
src_dir = File.join(dir, 'TalkToClaude')

FileUtils.rm_rf(project_path)

project = Xcodeproj::Project.new(project_path)
target = project.new_target(:application, 'TalkToClaude', :ios, '17.0')

group = project.main_group.new_group('TalkToClaude', 'TalkToClaude')

# Swift sources -> compile sources phase
Dir.glob(File.join(src_dir, '*.swift')).sort.each do |path|
  ref = group.new_reference(path)
  target.add_file_references([ref])
end

# Asset catalog -> resources phase
assets = File.join(src_dir, 'Assets.xcassets')
target.add_resources([group.new_reference(assets)]) if File.exist?(assets)

# Info.plist -> visible in the navigator, but consumed via INFOPLIST_FILE (not a
# build file).
group.new_reference(File.join(src_dir, 'Info.plist'))

target.build_configurations.each do |config|
  bs = config.build_settings
  bs['PRODUCT_BUNDLE_IDENTIFIER'] = 'com.emasoft.talktoclaude'
  bs['PRODUCT_NAME'] = '$(TARGET_NAME)'
  bs['INFOPLIST_FILE'] = 'TalkToClaude/Info.plist'
  bs['GENERATE_INFOPLIST_FILE'] = 'NO'
  bs['IPHONEOS_DEPLOYMENT_TARGET'] = '17.0'
  bs['SWIFT_VERSION'] = '5.0'
  bs['TARGETED_DEVICE_FAMILY'] = '1,2'
  bs['CODE_SIGN_STYLE'] = 'Automatic'
  bs['ASSETCATALOG_COMPILER_APPICON_NAME'] = 'AppIcon'
  bs['ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME'] = 'AccentColor'
  bs['MARKETING_VERSION'] = '1.0'
  bs['CURRENT_PROJECT_VERSION'] = '1'
  bs['ENABLE_PREVIEWS'] = 'YES'
  bs['SWIFT_EMIT_LOC_STRINGS'] = 'YES'
end

project.save

# A scheme so both Xcode and `xcodebuild -scheme TalkToClaude` work. Prefer a
# shared scheme; fall back to a user scheme if the API differs.
begin
  scheme = Xcodeproj::XCScheme.new
  scheme.add_build_target(target)
  scheme.set_launch_target(target)
  scheme.save_as(project_path, 'TalkToClaude', true)
rescue StandardError => e
  warn "Shared scheme creation failed (#{e.class}: #{e.message}); using user scheme."
  project.recreate_user_schemes
end

puts "Generated #{project_path}"
