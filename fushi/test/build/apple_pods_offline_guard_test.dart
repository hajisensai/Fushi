import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Guard: no Apple pod pulls its source from a third-party host at `pod install`
/// time (2026-11-27).
///
/// `pod install` downloads every CocoaPods trunk pod from the `source` of its podspec.
/// Two of ours did not come from GitHub (which runs the build anyway, so it is not an
/// extra dependency): onnxruntime (download.onnxruntime.ai, gone 2026-11-21) and
/// UniversalDetector2, whose `submodules: true` source clones uchardet from
/// gitlab.freedesktop.org — a 503 there failed the iOS release build on 2026-11-27.
/// Both are now local (`third_party/onnxruntime_pods`, `third_party/universal_detector2_pod`).
///
/// The class guard: every remaining trunk pod in either Podfile.lock is on [_auditedTrunk]
/// with the source host recorded when it was audited (all github.com, no submodules).
/// A new trunk pod fails here until someone checks its podspec `source` and either adds
/// it (GitHub-hosted, no submodules) or localizes it like the two above.
///
/// Text only, so it runs in ci-config-gate.

/// pod -> source audited 2026-11-27 (cdn.cocoapods.org podspec.json `source`).
const Map<String, String> _auditedTrunk = <String, String>{
  'AppAuth': 'git github.com/openid/AppAuth-iOS',
  'AppCheckCore': 'git github.com/google/app-check',
  'DKImagePickerController':
      'git github.com/zhangao0086/DKImagePickerController',
  'DKPhotoGallery': 'git github.com/zhangao0086/DKPhotoGallery',
  'GoogleSignIn': 'git github.com/google/GoogleSignIn-iOS',
  'GoogleUtilities': 'git github.com/google/GoogleUtilities',
  'GTMAppAuth': 'git github.com/google/GTMAppAuth',
  'GTMSessionFetcher': 'git github.com/google/gtm-session-fetcher',
  'HotKey': 'git github.com/soffes/HotKey',
  'OrderedSet': 'git github.com/Weebly/OrderedSet',
  'PromisesObjC': 'git github.com/google/promises',
  'SDWebImage': 'git github.com/SDWebImage/SDWebImage',
  'SwiftyGif': 'git github.com/kirualex/SwiftyGif',
  'Toast': 'git github.com/scalessec/Toast',
  'ZIPFoundation': 'git github.com/weichsel/ZIPFoundation',
};

/// Pods the Podfiles override with a local podspec / path; a stale lock may still list
/// them under trunk until the next `pod install` rewrites it.
const Map<String, String> _localized = <String, String>{
  'onnxruntime-c': 'third_party/onnxruntime_pods',
  'onnxruntime-objc': 'third_party/onnxruntime_pods',
  'UniversalDetector2': 'third_party/universal_detector2_pod',
};

void main() {
  const String repo = '..';

  List<String> trunkPods(String lock) {
    final RegExpMatch? block = RegExp(
      r'SPEC REPOS:\n  trunk:\n((?:    - .*\n)+)',
    ).firstMatch(lock);
    if (block == null) return <String>[];
    return block
        .group(1)!
        .split('\n')
        .where((String l) => l.trim().isNotEmpty)
        .map((String l) => l.trim().substring(2).trim())
        .toList();
  }

  for (final String platform in <String>['ios', 'macos']) {
    test('$platform: every trunk pod is audited GitHub-hosted or localized', () {
      final String lock = File(
        '$repo/fushi/$platform/Podfile.lock',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      final String podfile = File(
        '$repo/fushi/$platform/Podfile',
      ).readAsStringSync();
      final List<String> pods = trunkPods(lock);
      expect(pods, isNotEmpty, reason: 'trunk block parse collapsed');
      final List<String> problems = <String>[];
      for (final String pod in pods) {
        if (_auditedTrunk.containsKey(pod)) continue;
        final String? local = _localized[pod];
        if (local != null) {
          if (!podfile.contains("pod '$pod'")) {
            problems.add(
              '$pod is listed under trunk but fushi/$platform/Podfile does not override it',
            );
          }
          continue;
        }
        problems.add(
          '$pod: new CocoaPods trunk pod. Check its podspec `source`: GitHub-hosted without '
          'submodules -> add it to _auditedTrunk; anything else -> localize it '
          '(see third_party/universal_detector2_pod/README.md)',
        );
      }
      expect(problems, isEmpty, reason: problems.join('\n'));
    });
  }

  test('iOS Podfile builds UniversalDetector2 from the vendored source', () {
    final String podfile = File('$repo/fushi/ios/Podfile').readAsStringSync();
    expect(
      podfile,
      contains(
        "pod 'UniversalDetector2', :path => File.join(File.dirname(File.realpath(__FILE__)), '..', '..', 'third_party', 'universal_detector2_pod')",
      ),
    );
    const String dir = '$repo/third_party/universal_detector2_pod';
    final Map<String, dynamic> spec =
        jsonDecode(
              File('$dir/UniversalDetector2.podspec.json').readAsStringSync(),
            )
            as Map<String, dynamic>;
    expect(spec['name'], 'UniversalDetector2');
    // flutter_charset_detector_ios pins `UniversalDetector2 (= <version>)`.
    final String lock = File('$repo/fushi/ios/Podfile.lock').readAsStringSync();
    final RegExpMatch? required = RegExp(
      r'^    - UniversalDetector2 \(= ([^)]+)\)',
      multiLine: true,
    ).firstMatch(lock);
    expect(
      required,
      isNotNull,
      reason: 'flutter_charset_detector_ios requirement',
    );
    expect(spec['version'], required!.group(1));

    // Every source / header / preserved path the podspec names is really vendored.
    int sources = 0;
    for (final String sub in <String>[
      'UniversalDetector',
      'external/uchardet/src',
    ]) {
      final List<File> files = Directory('$dir/$sub')
          .listSync(recursive: true)
          .whereType<File>()
          .where((File f) => RegExp(r'\.(m|cpp)$').hasMatch(f.path))
          .toList();
      expect(files, isNotEmpty, reason: '$sub has no sources');
      sources += files.length;
    }
    expect(sources, greaterThan(30), reason: 'uchardet sources went missing');
    for (final String header
        in (spec['public_header_files'] as List<dynamic>).cast<String>()) {
      final String path = header.replaceAll('*.h', '');
      if (path.endsWith('.h')) {
        expect(File('$dir/$path').existsSync(), isTrue, reason: header);
      } else {
        expect(
          Directory(
            '$dir/$path',
          ).listSync().any((FileSystemEntity e) => e.path.endsWith('.h')),
          isTrue,
          reason: header,
        );
      }
    }
    expect(
      Directory(
        '$dir/external/uchardet/src',
      ).listSync().any((FileSystemEntity e) => e.path.endsWith('.tab')),
      isTrue,
      reason: 'preserve_paths *.tab',
    );
    expect(File('$dir/LICENSE').existsSync(), isTrue);
    expect(File('$dir/external/uchardet/COPYING').existsSync(), isTrue);
  });
}
