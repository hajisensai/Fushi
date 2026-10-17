#
# Fushi: vendored FFmpegKitNext v9.0.0 plugin with the unified FFmpeg
# (tool/ffmpeg-unified; built by .github/workflows/ffmpeg-unified-mobile.yml).
# The libav*/libsw* xcframeworks shipped here are the ONE FFmpeg of the iOS app:
# the libmpv player (media_kit_libs_ios_video, Mpv.framework) links them through
# @rpath at runtime instead of carrying its own copy.
#
# The build enables --enable-gpl (x264), so the effective license is GPLv3,
# matching Fushi itself. BUG-1373: CocoaPods only accepts license files with
# no extension or .txt/.md/.markdown, hence LICENSE-GPLv3.txt.
#
Pod::Spec.new do |s|
  s.name             = 'ffmpeg_kit_next_flutter'
  s.version          = '9.0.0'
  s.summary          = 'FFmpeg Kit Next for Flutter (Fushi unified FFmpeg)'
  s.description      = 'FFmpegKitNext plugin running the unified FFmpeg in-process for Fushi.'
  s.homepage         = 'https://github.com/arthenica/ffmpeg-kit-next'
  s.license          = { :type => 'GPL-3.0', :file => '../LICENSE-GPLv3.txt' }
  s.author           = { 'ARTHENICA' => 'open-source@arthenica.com' }

  s.platform              = :ios
  s.requires_arc          = true
  s.static_framework      = true
  s.ios.deployment_target = '12.1'

  s.source              = { :path => '.' }
  s.source_files        = 'ffmpeg_kit_next_flutter/Sources/ffmpeg_kit_next_flutter/**/*.{h,m}'
  s.public_header_files = 'ffmpeg_kit_next_flutter/Sources/ffmpeg_kit_next_flutter/include/**/*.h'

  s.dependency          'Flutter'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES' }

  s.vendored_frameworks = [
    'ffmpeg_kit_next_flutter/Frameworks/ffmpegkit.xcframework',
    'ffmpeg_kit_next_flutter/Frameworks/libavcodec.xcframework',
    'ffmpeg_kit_next_flutter/Frameworks/libavdevice.xcframework',
    'ffmpeg_kit_next_flutter/Frameworks/libavfilter.xcframework',
    'ffmpeg_kit_next_flutter/Frameworks/libavformat.xcframework',
    'ffmpeg_kit_next_flutter/Frameworks/libavutil.xcframework',
    'ffmpeg_kit_next_flutter/Frameworks/libswresample.xcframework',
    'ffmpeg_kit_next_flutter/Frameworks/libswscale.xcframework',
  ]
  # System frameworks / libraries FFmpeg links (VideoToolbox decode,
  # AudioToolbox, zlib, bzip2, iconv).
  s.frameworks = 'Foundation', 'CoreFoundation', 'CoreMedia', 'CoreVideo', 'AudioToolbox', 'VideoToolbox'
  s.libraries  = 'c++', 'z', 'bz2', 'iconv'
end
