// 守卫：每个产出桌面发布物的 job 都必须装配 ffmpeg-min（BUG-1420 / BUG-1421）。
//
// 背景——这一类 bug 的共同根因是「配方 / 产物 / 装配 / 消费四处各写各的，没有单一
// 真相源」：
//   - 配方   tool/ffmpeg-min/build-ffmpeg-min.sh 决定编出哪些 exe、含哪些组件；
//   - 产物   third_party/ffmpeg-min/<平台>/ 是手工 vendor 回来的二进制；
//   - 装配   .github/workflows/release-desktop.yml 把产物拷进各平台 bundle；
//   - 消费   fushi/lib/src/media/video/ffmpeg_backend.dart 的 resolve*Executable()
//            按「覆盖 > 程序旁捆绑 > PATH」找它们。
// 四者之间没有任何自动关联，于是：
//   - BUG-1058：改了配方忘了重新 vendor（已由 ffmpeg_min_vendored_recipe_guard 堵住）；
//   - BUG-1420：配方压根没编 ffprobe，消费方却一直按「已捆绑」设计，两个功能静默失效；
//   - BUG-1421：macOS job 从来没有装配步，整条桌面制卡链在没装 Homebrew ffmpeg 的
//               Mac 上全挂——而这**只是漏写了一个 step**，仓库里没有任何东西会红。
//
// 本守卫补的正是「装配」这一环的不变量，且**不硬编码平台清单**：
//   凡是在 release-desktop.yml 里跑了 `flutter build <桌面平台> --release` 的 job，
//   就必须在同一个 job 里装配 ffmpeg-min，且必须同时装 ffmpeg 与 ffprobe。
// 这样将来新增 Linux 发布 job（当前没有）时，漏装配会当场红，而不是等用户报。
//
// iOS/Android 不在此列：移动端走 KitFfmpegBackend（进程内 ffmpeg-kit），不找程序旁
// 的 CLI，见 ffmpeg_backend.dart 的 _selectBackend()。

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// 走 CLI 后端、因此必须捆绑 ffmpeg/ffprobe 的桌面平台。值是 vendored 目录名。
const Map<String, String> _desktopPlatforms = <String, String>{
  'windows': 'windows',
  'macos': 'macos',
  'linux': 'linux',
};

/// 每个平台 vendored 目录下必须存在的可执行文件名。
const Map<String, List<String>> _requiredBinaries = <String, List<String>>{
  'windows': <String>['ffmpeg.exe', 'ffprobe.exe'],
  'macos': <String>['ffmpeg', 'ffprobe'],
  'linux': <String>['ffmpeg', 'ffprobe'],
};

Directory _repoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 6; i++) {
    if (File('${dir.path}/tool/ffmpeg-min/build-ffmpeg-min.sh').existsSync()) {
      return dir;
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail('找不到含 tool/ffmpeg-min/build-ffmpeg-min.sh 的仓库根'
      '（从 ${Directory.current.path} 向上）');
}

/// 把 workflow 切成 `job 名 -> 该 job 的正文行`。
///
/// job 头是 `jobs:` 之下缩进 2 空格的 `<名>:`；下一个同级头即上一个 job 的结束。
/// 用行扫描而非 YAML 解析，与仓库里其它源码扫描守卫一致（零额外依赖，且改动
/// 意图在 diff 里一眼可见）。
Map<String, List<String>> _splitJobs(List<String> lines) {
  final RegExp jobHeader = RegExp(r'^  ([A-Za-z][A-Za-z0-9_-]*):\s*$');
  final Map<String, List<String>> jobs = <String, List<String>>{};
  int jobsAt = lines.indexWhere((String l) => l.trimRight() == 'jobs:');
  if (jobsAt < 0) fail('release-desktop.yml 里找不到顶层 `jobs:`');

  String? current;
  for (int i = jobsAt + 1; i < lines.length; i++) {
    final RegExpMatch? m = jobHeader.firstMatch(lines[i]);
    if (m != null) {
      current = m.group(1)!;
      jobs[current] = <String>[];
      continue;
    }
    if (current != null) jobs[current]!.add(lines[i]);
  }
  return jobs;
}

void main() {
  final Directory root = _repoRoot();
  final File workflow =
      File('${root.path}/.github/workflows/release-desktop.yml');

  group('桌面发布装配 ffmpeg-min 守卫（BUG-1420 / BUG-1421）', () {
    test('release-desktop.yml 在', () {
      expect(workflow.existsSync(), isTrue, reason: '缺 ${workflow.path}');
    });

    test('每个构建桌面 release 的 job 都装配了 ffmpeg-min，且 ffmpeg/ffprobe 齐全', () {
      final List<String> lines = workflow.readAsLinesSync();
      final Map<String, List<String>> jobs = _splitJobs(lines);

      final List<String> problems = <String>[];
      int desktopJobsSeen = 0;

      jobs.forEach((String jobName, List<String> body) {
        final String text = body.join('\n');
        for (final MapEntry<String, String> entry in _desktopPlatforms.entries)  {
          final String platform = entry.key;
          final String vendorDir = entry.value;
          // `flutter build <平台> --release` 是「这个 job 产出该平台发布物」的判据。
          if (!RegExp('flutter build $platform --release').hasMatch(text)) {
            continue;
          }
          desktopJobsSeen++;

          // 装配步必须引用该平台的 vendored 目录。
          if (!text.contains('third_party/ffmpeg-min/$vendorDir') &&
              !text.contains(r'third_party\ffmpeg-min\' + vendorDir)) {
            problems.add(
              'job `$jobName` 构建了 $platform 发布物，却没有任何一步引用 '
              'third_party/ffmpeg-min/$vendorDir —— 该平台的 bundle 里不会有 '
              'ffmpeg，桌面制卡链在没装系统 ffmpeg 的机器上全挂（BUG-1421）。',
            );
            continue;
          }

          // 光引用目录不够：ffmpeg 与 ffprobe 必须都被装进去（BUG-1420）。
          for (final String binary in _requiredBinaries[platform]!) {
            if (!text.contains(binary)) {
              problems.add(
                'job `$jobName` 的 ffmpeg-min 装配步没提到 `$binary`。'
                'ffprobe 与 ffmpeg 是两个独立可执行，各有各的消费方'
                '（内封字幕字体 / 音频容器元数据），漏一个就静默降级（BUG-1420）。',
              );
            }
          }
        }
      });

      expect(
        desktopJobsSeen,
        greaterThan(0),
        reason: '在 release-desktop.yml 里没找到任何 `flutter build <桌面平台> --release`。'
            '若构建命令改了写法，请同步更新本守卫的判据，'
            '否则它会退化成永远通过的空壳。',
      );
      expect(problems, isEmpty, reason: problems.join('\n'));
    });

    test('被装配步引用的 vendored 二进制真的在库里', () {
      final String text = workflow.readAsStringSync();
      final List<String> problems = <String>[];

      _desktopPlatforms.forEach((String platform, String vendorDir) {
        final bool referenced =
            text.contains('third_party/ffmpeg-min/$vendorDir') ||
                text.contains(r'third_party\ffmpeg-min\' + vendorDir);
        if (!referenced) return;

        for (final String binary in _requiredBinaries[platform]!) {
          final File f =
              File('${root.path}/third_party/ffmpeg-min/$vendorDir/$binary');
          if (!f.existsSync()) {
            problems.add(
              '${f.path} 不存在，但 release-desktop.yml 会去拷它 —— 发布当场失败。'
              '跑 .github/workflows/ffmpeg-min.yml 取 artifact 后 vendor 回来。',
            );
            continue;
          }
          // 真二进制（~9-15MB），不是 LFS 指针或占位符。
          if (f.lengthSync() <= (1 << 20)) {
            problems.add('${f.path} 只有 ${f.lengthSync()} 字节，疑似占位文件或 LFS 指针。');
          }
        }
      });

      expect(problems, isEmpty, reason: problems.join('\n'));
    });
  });
}
