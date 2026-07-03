#
# To learn more about a Podspec see http://guides.cocoapods.org/syntax/podspec.html
#
# HIBIKI PATCH (TODO-1107): upstream fluttertoast 8.2.1 excludes the iOS
# simulator arm64 slice via EXCLUDED_ARCHS[sdk=iphonesimulator*] = i386, arm64
# (and arm64 on the user target). On Apple Silicon that removes the only slice
# the simulator can run, so `flutter build ios --simulator` fails with
# "Module 'fluttertoast' not found". We keep i386 excluded (long dead) but drop
# arm64 from the simulator exclusion so the arm64 simulator slice is built.
# Applied post `flutter pub get` by ci/apply-patches.sh into the pub cache.
#
Pod::Spec.new do |s|
  s.name             = 'fluttertoast'
  s.version          = '0.0.2'
  s.summary          = 'Toast Library for Flutter'
  s.description      = <<-DESC
Toast Library for FLutter
                       DESC
  s.homepage         = 'http://example.com'
  s.license          = { :file => '../LICENSE' }
  s.author           = { 'Karthik Ponnam' => 'ponnamkarthik3@gmail.com' }
  s.source           = { :path => '.' }
  s.source_files = 'Classes/**/*'
  s.public_header_files = 'Classes/**/*.h'
  s.dependency 'Flutter'
  s.dependency 'Toast'
  s.pod_target_xcconfig = { 'DEFINES_MODULE' => 'YES', 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
  s.user_target_xcconfig = { 'EXCLUDED_ARCHS[sdk=iphonesimulator*]' => 'i386' }
end
