#
# Hibiki: 自编 min ffmpeg-kit（arthenica 源码 Xcode 重编）的 iOS podspec。
# 用本地 vendored xcframeworks 替代已停服的 cocoapods pod（ffmpeg-kit-ios-min 等），
# 修复 BUG-122（旧预编译在新系统不可用）。xcframeworks 放在 ios/Frameworks/，含
# device(arm64/arm64e) + simulator(arm64/x86_64) 两组切片（maccatalyst 切片不随包
# 分发——macOS 走独立构建，留着只增体积）。
#
# TODO-2357：本仓构建启用 `--enable-gpl --enable-x264`（片段导出全平台 H.264），
# 产物有效许可因此是 **GPLv3** 而非 ffmpeg-kit 默认的 LGPLv3，故 license 指向
# LICENSE.GPLv3。Hibiki 自身即 GPL-3.0，两者一致。重编流程见 patches/README.md。
#
Pod::Spec.new do |s|
  s.name             = 'ffmpeg_kit_flutter'
  s.version          = '6.0.3'
  s.summary          = 'FFmpeg Kit for Flutter (Hibiki self-built min)'
  s.description      = 'Self-built minimal ffmpeg-kit (arthenica source rebuilt) for Hibiki.'
  s.homepage         = 'https://github.com/arthenica/ffmpeg-kit'
  s.license          = { :file => '../LICENSE.GPLv3' }
  s.author           = { 'ARTHENICA' => 'open-source@arthenica.com' }

  s.platform              = :ios
  s.requires_arc          = true
  s.ios.deployment_target = '12.1'

  s.source               = { :path => '.' }
  s.source_files         = 'Classes/**/*'
  s.public_header_files   = 'Classes/**/*.h'

  s.dependency           'Flutter'
  s.pod_target_xcconfig  = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }

  # 自编 ffmpeg-kit 动态 xcframeworks（vendored，本地 Frameworks/）。
  s.vendored_frameworks = [
    'Frameworks/ffmpegkit.xcframework',
    'Frameworks/libavcodec.xcframework',
    'Frameworks/libavformat.xcframework',
    'Frameworks/libavfilter.xcframework',
    'Frameworks/libavutil.xcframework',
    'Frameworks/libavdevice.xcframework',
    'Frameworks/libswscale.xcframework',
    'Frameworks/libswresample.xcframework',
  ]
  # ffmpeg/ffmpeg-kit 链接的系统 framework / 库（otool -L 实测 + 常见项；多声明无害）。
  s.frameworks = 'Foundation', 'CoreFoundation', 'CoreMedia', 'CoreVideo', 'AudioToolbox', 'VideoToolbox'
  s.libraries  = 'c++', 'z', 'bz2', 'iconv'
end
