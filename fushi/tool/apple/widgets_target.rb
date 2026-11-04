#!/usr/bin/env ruby
# frozen_string_literal: true

# 主屏小组件扩展（FushiWidgets.appex）在 Runner.xcodeproj 里的唯一定义。
#
#   ruby tool/apple/widgets_target.rb add   ios|macos   # 建 / 重建 target（幂等）
#   ruby tool/apple/widgets_target.rb strip ios|macos   # CI：签不了扩展时整个摘掉
#
# 源码在 fushi/apple/HomeWidgets/（两端共用），工程只引用它们：
#   Extension/*.swift + Shared/*.swift + Extension/Localizable.xcstrings → FushiWidgets
#   Shared/*.swift + FushiHomeWidgets.swift (+ macOS 的菜单栏) → Runner
#
# `add` 的结果入库（project.pbxproj）。`strip` 只在 CI 的 runner 上执行、不入库：描述
# 文件里没有扩展的 App ID / App Group 时，带着扩展签名会让 TestFlight 整条失败，摘掉后
# 主 app 照旧上传（见 .github/workflows/release-desktop.yml「Home screen widgets」）。
#
# 依赖 xcodeproj gem（CocoaPods 自带）。Mac 上可用：
#   GEM_HOME=$(ls -d /opt/homebrew/Cellar/cocoapods/*/libexec | head -1) ruby tool/apple/widgets_target.rb …

require 'xcodeproj'

TARGET = 'FushiWidgets'
BUNDLE_ID = 'app.fushi.reader.widgets'
EMBED_PHASE = 'Embed Foundation Extensions'
SHARED_GROUP = 'HomeWidgets'

mode, platform = ARGV
unless %w[add strip].include?(mode) && %w[ios macos].include?(platform)
  warn 'usage: widgets_target.rb add|strip ios|macos'
  exit 64
end

fushi_root = File.expand_path('../..', __dir__)
project_path = File.join(fushi_root, platform, 'Runner.xcodeproj')
project = Xcodeproj::Project.open(project_path)
runner = project.targets.find { |t| t.name == 'Runner' } or abort('Runner target not found')

def remove_target(project, runner)
  target = project.targets.find { |t| t.name == TARGET }
  if target
    runner.dependencies.select { |d| d.target == target }.each(&:remove_from_project)
    product = target.product_reference
    runner.copy_files_build_phases.each do |phase|
      phase.files.select { |f| f.file_ref == product }.each(&:remove_from_project)
    end
    target.build_configurations.each { |c| c.base_configuration_reference = nil }
    target.remove_from_project
    product&.remove_from_project
  end
  runner.copy_files_build_phases.select { |p| p.name == EMBED_PHASE && p.files.empty? }
        .each(&:remove_from_project)
  project.root_object.attributes['TargetAttributes']&.delete_if { |k, _| !project.objects_by_uuid[k] }
end

def shared_group(project)
  project.main_group.children.find { |g| g.display_name == SHARED_GROUP } ||
    project.main_group.new_group(SHARED_GROUP, '../apple/HomeWidgets')
end

def file_ref(group, relative)
  parts = relative.split('/')
  name = parts.pop
  parts.each do |dir|
    group = group.children.find { |c| c.display_name == dir && c.isa == 'PBXGroup' } ||
            group.new_group(dir, dir)
  end
  group.files.find { |f| f.display_name == name } || group.new_file(name)
end

def runner_shared_sources(platform)
  base = %w[Shared/FushiWidgetSnapshot.swift Shared/FushiActivityAttributes.swift
            Shared/FushiWidgetIntents.swift Shared/FushiOpenLinkIntent.swift FushiHomeWidgets.swift]
  platform == 'macos' ? base + %w[FushiMenuBarActivities.swift] : base
end

if mode == 'strip'
  remove_target(project, runner)
  # Runner 里的共用源码保留：它们不依赖扩展，App Group 不可用时 Dart 整段不写快照。
  project.save
  puts "stripped #{TARGET} from #{platform}"
  exit 0
end

remove_target(project, runner)
apple_dir = File.join(fushi_root, 'apple', 'HomeWidgets')
group = shared_group(project)

# Runner：共用源码（重复执行不重复加）。
runner_files = runner.source_build_phase.files_references
runner_shared_sources(platform).each do |rel|
  ref = file_ref(group, rel)
  runner.add_file_references([ref]) unless runner_files.include?(ref)
end

deployment = platform == 'ios' ? '17.0' : '14.0'
target = project.new_target(:app_extension, TARGET,
                            platform == 'ios' ? :ios : :osx, deployment, nil, :swift)

ext_sources = Dir.children(File.join(apple_dir, 'Extension')).select { |f| f.end_with?('.swift') }.sort
              .map { |f| "Extension/#{f}" }
shared = Dir.children(File.join(apple_dir, 'Shared')).select { |f| f.end_with?('.swift') }.sort
           .map { |f| "Shared/#{f}" }
target.add_file_references((ext_sources + shared).map { |rel| file_ref(group, rel) })
target.add_resources([file_ref(group, 'Extension/Localizable.xcstrings')])

config_dir = platform == 'ios' ? 'Flutter' : 'Runner/Configs'
xcconfig_name = 'FushiWidgets.xcconfig'
config_group = project.main_group.find_subpath(config_dir, false) or abort("#{config_dir} group missing")
xcconfig_abs = File.join(fushi_root, platform, config_dir, xcconfig_name)
# 组本身可能没有 path（文件各自带「Flutter/Debug.xcconfig」这样的路径），按绝对路径建引用，
# 让 xcodeproj 自己算相对路径。
xcconfig = config_group.files.find { |f| f.real_path.to_s == xcconfig_abs } ||
           config_group.new_reference(xcconfig_abs)

plist_dir = 'FushiWidgets'
plist_group = project.main_group.children.find { |g| g.display_name == plist_dir } ||
              project.main_group.new_group(plist_dir, plist_dir)
%w[Info.plist FushiWidgets.entitlements].each do |f|
  plist_group.files.find { |x| x.display_name == f } || plist_group.new_file(f)
end

# Runner 的每个配置名（Debug / Release / Profile）都要有一份，否则 flutter build 选到的
# 配置在扩展上不存在会回落到默认值。
target.build_configurations.each(&:remove_from_project)
target.build_configuration_list.build_configurations.clear
runner.build_configurations.each do |runner_config|
  config = project.new(Xcodeproj::Project::Object::XCBuildConfiguration)
  config.name = runner_config.name
  config.base_configuration_reference = xcconfig
  settings = {
    'PRODUCT_BUNDLE_IDENTIFIER' => BUNDLE_ID,
    'PRODUCT_NAME' => '$(TARGET_NAME)',
    'INFOPLIST_FILE' => "#{plist_dir}/Info.plist",
    'GENERATE_INFOPLIST_FILE' => 'NO',
    'SWIFT_VERSION' => '5.0',
    'SWIFT_EMIT_LOC_STRINGS' => 'YES',
    'SKIP_INSTALL' => 'YES',
    'ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS' => 'NO',
    'SWIFT_OPTIMIZATION_LEVEL' => runner_config.name == 'Debug' ? '-Onone' : '-O',
    'DEBUG_INFORMATION_FORMAT' => runner_config.name == 'Debug' ? 'dwarf' : 'dwarf-with-dsym'
  }
  if platform == 'ios'
    settings.merge!(
      'IPHONEOS_DEPLOYMENT_TARGET' => deployment,
      'SDKROOT' => 'iphoneos',
      'TARGETED_DEVICE_FAMILY' => '1,2',
      'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/Frameworks @executable_path/../../Frameworks'
    )
    # entitlements 只在 FushiWidgets.xcconfig 里按 sdk 条件接入（模拟器）；真机签名由 CI
    # 按描述文件是否带 App Group 决定（ios/Runner.xcodeproj 不得出现 CODE_SIGN_ENTITLEMENTS）。
    #
    # iOS 扩展的 target 级**不写 CODE_SIGN_STYLE**（与 Runner 一样）：target 级设置优先于
    # base configuration（FushiWidgets.xcconfig），写了 Automatic，CI 往 xcconfig 追加的
    # `CODE_SIGN_STYLE = Manual` + PROVISIONING_PROFILE_SPECIFIER 就被盖掉，Xcode 报
    # 「FushiWidgets is automatically signed, but provisioning profile … has been manually
    # specified」。不写时本地走 Xcode 默认（自动签名），CI 的手动签名照常生效。
  else
    settings.merge!(
      'CODE_SIGN_STYLE' => 'Automatic',
      'MACOSX_DEPLOYMENT_TARGET' => deployment,
      'SDKROOT' => 'macosx',
      'CODE_SIGN_ENTITLEMENTS' => "#{plist_dir}/FushiWidgets.entitlements",
      'ENABLE_HARDENED_RUNTIME' => 'YES',
      'LD_RUNPATH_SEARCH_PATHS' => '$(inherited) @executable_path/../Frameworks @executable_path/../../../../Frameworks'
    )
  end
  config.build_settings = settings
  target.build_configuration_list.build_configurations << config
end
target.build_configuration_list.default_configuration_name = 'Release'

# Runner 依赖扩展，并把它嵌进 PlugIns。嵌入阶段必须排在 Flutter 的 Thin Binary 之前，
# 否则 Xcode 报「Cycle inside Runner」。
runner.add_dependency(target)
embed = runner.copy_files_build_phases.find { |p| p.name == EMBED_PHASE } ||
        runner.new_copy_files_build_phase(EMBED_PHASE)
embed.symbol_dst_subfolder_spec = :plug_ins
embed.dst_path = ''
build_file = embed.add_file_reference(target.product_reference, true)
build_file.settings = { 'ATTRIBUTES' => %w[RemoveHeadersOnCopy] }
phases = runner.build_phases
phases.delete(embed)
thin = phases.index { |p| p.respond_to?(:name) && p.name.to_s.include?('Thin Binary') }
anchor = thin || phases.index { |p| p.isa == 'PBXResourcesBuildPhase' }&.+(1) || phases.length
phases.insert(anchor, embed)

project.save
puts "added #{TARGET} to #{platform} (#{ext_sources.size + shared.size} sources)"
