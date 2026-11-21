import 'dart:io';

import 'package:test/test.dart';

import '../../helpers/source_guard.dart';

/// 守卫：生产代码里 SRT 块（`序号 / 起 --> 止 / 正文 / 空行`）只由
/// `packages/fushi_engine/lib/media/video/subtitle/srt_writer.dart` 写出。
///
/// 起因（#3722 video-36o）：片段导出、有声书对齐、图形字幕 OCR、Lua 字幕镜像、
/// 双语拆轨各抄了一份时间戳格式化与块拼接，五份已经漂开——图形字幕那份不 clamp
/// 负值（Dart 的 `%` 取正模，`-50` 会写成 `00:00:00,950`）。收成一份后，再有人
/// 在 lib 里手拼 `--> ` 就等于把漂移放回来。
///
/// 只扫 `lib/`：测试夹具、集成测试素材与 `tool/` 里的造数脚本不在范围内。
void main() {
  const String writerPath =
      'packages/fushi_engine/lib/media/video/subtitle/srt_writer.dart';
  // 字符串里手拼的 SRT 时间轴箭头：`} --> `（插值后接箭头）、`--> ${`、行尾
  // `--> '`（跨行字符串拼接）。HTML 注释的 `-->` 不带两侧空格 + 插值，不会误中。
  final RegExp handBuiltArrow = RegExp(
    r"\}\s*-->\s|-->\s\$\{|-->\s'\s*$",
    multiLine: true,
  );

  test('lib 里只有 srt_writer.dart 手拼 SRT 时间轴', () {
    final Directory repoRoot = Directory('..');
    final List<Directory> libDirs = <Directory>[
      Directory('${repoRoot.path}/fushi/lib'),
      for (final FileSystemEntity e in Directory(
        '${repoRoot.path}/packages',
      ).listSync())
        if (e is Directory && Directory('${e.path}/lib').existsSync())
          Directory('${e.path}/lib'),
    ];
    expect(libDirs.length, greaterThan(3));

    final List<String> offenders = <String>[];
    bool writerSeen = false;
    for (final Directory dir in libDirs) {
      for (final FileSystemEntity e in dir.listSync(recursive: true)) {
        if (e is! File || !e.path.endsWith('.dart')) continue;
        final String rel = e.path
            .replaceAll(r'\', '/')
            .replaceFirst('${repoRoot.path}/', '');
        if (rel.endsWith('.g.dart')) continue;
        final String code = maskComments(e.readAsStringSync());
        if (!handBuiltArrow.hasMatch(code)) continue;
        if (rel == writerPath) {
          writerSeen = true;
        } else {
          offenders.add(rel);
        }
      }
    }
    expect(writerSeen, isTrue, reason: '守卫自身失效：没在 $writerPath 里认出箭头');
    expect(
      offenders,
      isEmpty,
      reason: '这些文件手拼了 SRT 时间轴，改用 srt_writer.dart 的 writeSrtBlocks',
    );
  });
}
