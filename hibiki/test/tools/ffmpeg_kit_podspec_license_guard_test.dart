// 守卫：vendored podspec 的 `s.license` 必须能过 CocoaPods 的校验，且许可结论不许被降级。
//
// 背景（BUG-1373）：`third_party/ffmpeg_kit_flutter/ios/ffmpeg_kit_flutter.podspec`
// 曾写 `s.license = { :file => '../LICENSE.GPLv3' }`。文件真实存在（35KB GPLv3 正文），
// 但 cocoapods-core 的 `Specification::Linter#_validate_license` 是**按扩展名**判定
// 许可文件类型的：
//
//     if file && Pathname.new(file).extname !~ /^(\.(txt|md|markdown|))?$/i
//       results.add_error('license', 'Invalid file type')
//     end
//
// `.GPLv3` 不在白名单里，于是 `pod install` 在校验阶段就断：
//
//     [!] The `ffmpeg_kit_flutter` pod failed to validate due to 1 error:
//         - ERROR | license: Invalid file type
//
// 结果是 develop 上的 iOS job 每次都在 "Build iOS (debug, no codesign)" 红掉，
// iOS 发布与真机验证全部受阻。这条错误只在 macOS runner 上才暴露，本地 Windows /
// Linux 单测跑不出来——所以这里用源码扫描把它前移到人人都能跑的层面。
//
// 本守卫做三件事：
//   1. 扫全部 vendored podspec 的 `:file =>`，照抄上面那条正则判扩展名；
//   2. 确认被指向的许可文件真的存在（防「改名过了校验但忘了 git mv」）；
//   3. 钉住 ffmpeg_kit_flutter iOS 侧的许可结论仍是 **GPL-3.0**——本仓自编产物启用了
//      `--enable-gpl --enable-x264`，有效许可就是 GPLv3，任何「为了过校验顺手改回
//      LGPLv3」都是合规倒退，不是修 bug。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// cocoapods-core `Specification::Linter#_validate_license` 里那条正则的等价实现。
///
/// 上游源码（lib/cocoapods-core/specification/linter.rb）：
/// `Pathname.new(file).extname !~ /^(\.(txt|md|markdown|))?$/i`
/// 也就是只放行「无扩展名」「.txt」「.md」「.markdown」，且大小写不敏感。
final RegExp _cocoaPodsLicenseExtname = RegExp(
  r'^(\.(txt|md|markdown|))?$',
  caseSensitive: false,
);

/// 取 CocoaPods 意义上的 extname：最后一个 `.` 起的后缀；无点则空串。
///
/// 与 Ruby `Pathname#extname` 对齐——开头即点的隐藏文件（`.gitignore`）没有扩展名。
String _extname(String path) {
  final String base = path.split(RegExp(r'[/\\]')).last;
  final int dot = base.lastIndexOf('.');
  if (dot <= 0) return '';
  return base.substring(dot);
}

/// 从当前 cwd 向上找含 `third_party/ffmpeg_kit_flutter/pubspec.yaml` 的仓库根。
Directory _repoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 6; i++) {
    if (File('${dir.path}/third_party/ffmpeg_kit_flutter/pubspec.yaml')
        .existsSync()) {
      return dir;
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail(
    '找不到含 third_party/ffmpeg_kit_flutter/pubspec.yaml 的仓库根'
    '（从 ${Directory.current.path} 向上）',
  );
}

/// 递归收集 `third_party/` 下所有 `.podspec`。
List<File> _vendoredPodspecs(Directory root) {
  final Directory thirdParty = Directory('${root.path}/third_party');
  expect(thirdParty.existsSync(), isTrue, reason: '仓库根下没有 third_party/');
  return thirdParty
      .listSync(recursive: true, followLinks: false)
      .whereType<File>()
      .where((File f) => f.path.endsWith('.podspec'))
      .toList()
    ..sort((File a, File b) => a.path.compareTo(b.path));
}

/// 抠出 podspec 里 `:file => '<路径>'` / `:file => "<路径>"` 的值。
List<String> _licenseFileRefs(String source) {
  return RegExp(':file\\s*=>\\s*[\'"]([^\'"]+)[\'"]')
      .allMatches(source)
      .map((RegExpMatch m) => m.group(1)!)
      .toList();
}

void main() {
  group('vendored podspec 的 license 必须过 CocoaPods 校验（BUG-1373）', () {
    final Directory root = _repoRoot();

    test('所有 :file 许可路径的扩展名都在 CocoaPods 白名单内', () {
      final List<File> podspecs = _vendoredPodspecs(root);
      expect(podspecs, isNotEmpty,
          reason: 'third_party/ 下一个 podspec 都没扫到，守卫失效');

      for (final File podspec in podspecs) {
        for (final String ref in _licenseFileRefs(podspec.readAsStringSync())) {
          expect(
            _cocoaPodsLicenseExtname.hasMatch(_extname(ref)),
            isTrue,
            reason: '${podspec.path} 的 s.license :file 指向 "$ref"，'
                '扩展名 "${_extname(ref)}" 不被 cocoapods-core 接受'
                '（只放行 无扩展名 / .txt / .md / .markdown）。'
                'pod install 会直接报 "ERROR | license: Invalid file type" 并整个断掉，'
                'iOS CI 全红。修法：git mv 成 .txt 结尾（或去掉扩展名）并同步 podspec，'
                '**不要改许可证本身**',
          );
        }
      }
    });

    test('所有 :file 许可路径指向的文件真实存在', () {
      for (final File podspec in _vendoredPodspecs(root)) {
        for (final String ref in _licenseFileRefs(podspec.readAsStringSync())) {
          // podspec 里的路径相对于 podspec 所在目录（Flutter 插件惯例 `../LICENSE`）。
          final File target = File('${podspec.parent.path}/$ref');
          expect(
            target.existsSync(),
            isTrue,
            reason: '${podspec.path} 的 s.license :file 指向 "$ref"，'
                '但 ${target.path} 不存在——改名时漏了 git mv，或 vendor 时漏拷许可文件',
          );
        }
      }
    });

    test('ffmpeg_kit_flutter iOS 侧许可结论仍是 GPL-3.0（--enable-gpl 的合规义务）', () {
      final File podspec = File(
        '${root.path}/third_party/ffmpeg_kit_flutter/ios/ffmpeg_kit_flutter.podspec',
      );
      expect(podspec.existsSync(), isTrue, reason: '找不到 iOS podspec');
      final String source = podspec.readAsStringSync();

      final List<String> refs = _licenseFileRefs(source);
      expect(
        refs.length,
        1,
        reason: 'iOS podspec 应恰好声明一个许可文件，实测 $refs',
      );
      expect(
        refs.single.contains('GPLv3'),
        isTrue,
        reason: 'iOS podspec 的许可文件从 GPLv3 改成了 "${refs.single}"。'
            '本仓自编 ffmpeg-kit 启用了 --enable-gpl --enable-x264，'
            '产物有效许可就是 GPLv3；降回 LGPLv3 是合规倒退，不是修构建',
      );
      expect(
        RegExp(":type\\s*=>\\s*['\"]GPL-3\\.0['\"]").hasMatch(source),
        isTrue,
        reason: 'iOS podspec 的 s.license 必须显式写 :type => \'GPL-3.0\'，'
            '让许可结论机器可读、也免掉 CocoaPods 的 "Missing license type." 警告',
      );

      // 指向的正文必须真是 GPL（不是 LGPL）。只看抬头——GPLv3 正文后段（第 13 节附近）
      // 本来就会提到 "GNU Lesser General Public License"，全文搜 LESSER 会假阳。
      final File license = File('${podspec.parent.path}/${refs.single}');
      final String heading =
          license.readAsStringSync().split('\n').first.trim();
      expect(
        heading,
        'GNU GENERAL PUBLIC LICENSE',
        reason: '${license.path} 抬头是 "$heading"，不是 GPL 正文。'
            '若指到了 LGPL——包根的 LICENSE（LGPLv3 原件）是给 macOS podspec 用的'
            '（macOS 走上游非 GPL 预编译包），iOS 侧自编产物是 GPLv3，别指错',
      );
    });
  });
}
