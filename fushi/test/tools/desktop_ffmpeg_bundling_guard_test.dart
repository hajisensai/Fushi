// 守卫：每个产出桌面发布物的 job 都必须让随包的统一 FFmpeg（tool/ffmpeg-unified）
// 的 ffmpeg 与 ffprobe 真的在 bundle 里、真的能跑（BUG-1420 / BUG-1421）。
//
// 背景——这一类 bug 的共同根因是「配方 / 产物 / 装配 / 消费四处各写各的，没有单一
// 真相源」：
//   - BUG-1420：配方压根没编 ffprobe，消费方（ffmpeg_backend.dart 的
//     resolveFfprobeExecutable，内封字幕字体 / 音频容器元数据）却一直按「已捆绑」设计；
//   - BUG-1421：macOS job 从来没有装配步，整条桌面制卡链在没装 Homebrew ffmpeg 的
//     Mac 上全挂——而这**只是漏写了一个 step**，仓库里没有任何东西会红。
//
// 统一 FFmpeg 后两个桌面平台的装配方式不同，但不变式相同：
//   - Windows：ffmpeg.exe / ffprobe.exe 随 libmpv 运行时归档（runtime-files.cmake）
//     装到 fushi.exe 旁边，与播放器共用 fbd*.dll；
//   - macOS：程序从 media_kit_libs_macos_video 的统一布局包装进 Contents/MacOS，
//     rpath 指向同一套 Contents/Frameworks。
// 判据不硬编码平台清单：凡是跑了 `flutter build <桌面平台> --release` 的 job，同一个
// job 里就必须对随包的 ffmpeg 与 ffprobe 跑能力下限检查 + 行为冒烟。
//
// iOS/Android 不在此列：移动端走 KitFfmpegBackend（进程内 FFmpegKitNext）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const List<String> _desktopPlatforms = <String>['windows', 'macos', 'linux'];

Directory _repoRoot() {
  Directory dir = Directory.current;
  for (int i = 0; i < 6; i++) {
    if (File('${dir.path}/tool/ffmpeg-unified/recipe.env').existsSync()) {
      return dir;
    }
    final Directory parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  fail(
    '找不到含 tool/ffmpeg-unified/recipe.env 的仓库根'
    '（从 ${Directory.current.path} 向上）',
  );
}

/// 把 workflow 切成 `job 名 -> 该 job 的正文行`。
///
/// job 头是 `jobs:` 之下缩进 2 空格的 `<名>:`；下一个同级头即上一个 job 的结束。
/// 用行扫描而非 YAML 解析，与仓库里其它源码扫描守卫一致。
Map<String, List<String>> _splitJobs(List<String> lines) {
  final RegExp jobHeader = RegExp(r'^  ([A-Za-z][A-Za-z0-9_-]*):\s*$');
  final Map<String, List<String>> jobs = <String, List<String>>{};
  final int jobsAt = lines.indexWhere((String l) => l.trimRight() == 'jobs:');
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
  final File workflow = File(
    '${root.path}/.github/workflows/release-desktop.yml',
  );

  group('桌面发布随包统一 FFmpeg 守卫（BUG-1420 / BUG-1421）', () {
    test('每个构建桌面 release 的 job 都验证随包的 ffmpeg 与 ffprobe', () {
      final Map<String, List<String>> jobs = _splitJobs(
        workflow.readAsLinesSync(),
      );
      final List<String> problems = <String>[];
      int desktopJobsSeen = 0;

      jobs.forEach((String jobName, List<String> body) {
        final String text = body.join('\n');
        for (final String platform in _desktopPlatforms) {
          if (!RegExp('flutter build $platform --release').hasMatch(text)) {
            continue;
          }
          desktopJobsSeen++;
          for (final String needle in <String>[
            'tool/ffmpeg-unified/verify_ffmpeg_capabilities.py',
            'tool/ffmpeg-unified/smoke-test.sh',
            'ffprobe',
          ]) {
            if (!text.contains(needle)) {
              problems.add(
                'job `$jobName` 构建了 $platform 发布物，却没有 `$needle`：'
                '随包的 ffmpeg/ffprobe 缺失或残缺会静默降级整条桌面制卡链'
                '（BUG-1420 / BUG-1421）。',
              );
            }
          }
          if (platform == 'macos' &&
              !text.contains('ffmpeg-unified-macos.tar.gz')) {
            problems.add(
              'job `$jobName` 没有从统一布局包安装 ffmpeg/ffprobe 到 '
              'Contents/MacOS（BUG-1421）。',
            );
          }
        }
      });

      expect(
        desktopJobsSeen,
        greaterThan(0),
        reason:
            '在 release-desktop.yml 里没找到任何 `flutter build <桌面平台> --release`；'
            '若构建命令改了写法，请同步更新本守卫的判据，否则它会退化成空壳。',
      );
      expect(problems, isEmpty, reason: problems.join('\n'));
    });

    test('macOS 布局包与 Makefile 钉的哈希一致，且确实带 ffmpeg / ffprobe', () {
      final File layout = File(
        '${root.path}/third_party/media_kit_libs_macos_video/'
        'native/ffmpeg-unified-macos.tar.gz',
      );
      expect(layout.existsSync(), isTrue, reason: '缺 ${layout.path}');
      expect(
        layout.lengthSync(),
        greaterThan(1 << 20),
        reason: '布局包太小，疑似 LFS 指针或占位文件',
      );
      final String makefile = File(
        '${root.path}/third_party/'
        'media_kit_libs_macos_video/macos/Makefile',
      ).readAsStringSync();
      expect(
        makefile,
        contains('UNIFIED_FFMPEG_SHA256SUM='),
        reason: 'Makefile 必须钉住布局包的 SHA-256',
      );
    });
  });
}
