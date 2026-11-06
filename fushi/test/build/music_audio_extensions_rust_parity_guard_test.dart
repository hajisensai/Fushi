import 'dart:io';

import 'package:test/test.dart';
import 'package:fushi_engine/media/media_extensions.dart';

/// 守卫：Dart 侧「是不是纯音频」的唯一判据 [kAudioExtensions]（media_extensions.dart）=
/// 音乐扫描器 `native/fushi_music/src/tags.rs` 的 `AUDIO_EXTENSIONS` 去掉 `mp4` 再加点号。
///
/// 洞的形状（反馈 QAondMh4M5）：视频来源扫到 [isAudioOnlyMediaPath] 判为纯音频的文件就
/// 不进视频库、交给音乐库；两表一漂移，Dart 认、Rust 不认的格式（曾经的 `.m4b` /
/// `.ac3` / `.eac3`）在两个库里都消失；Rust 认、Dart 不认的（`.ape` / `.dsf` / `.tta`
/// ...）视频来源和视频页拖放静默丢弃。`mp4` 是唯一允许的差异：它首先是视频容器，视频
/// 来源里的归视频库；音乐来源目录里的 mp4 照收。
void main() {
  // 测试 cwd 是 `fushi/`。
  test('kAudioExtensions == Rust AUDIO_EXTENSIONS minus mp4', () {
    final File file = File('../native/fushi_music/src/tags.rs');
    expect(file.existsSync(), isTrue, reason: '${file.absolute.path} 不存在');
    final String src = file.readAsStringSync();
    final RegExpMatch? table = RegExp(
      r'pub const AUDIO_EXTENSIONS: &\[&str\] = &\[([^\]]*)\];',
    ).firstMatch(src);
    expect(table, isNotNull, reason: 'tags.rs 里找不到 AUDIO_EXTENSIONS 表');
    final List<String> rust = <String>[
      for (final RegExpMatch m in RegExp(
        r'"([a-z0-9]+)"',
      ).allMatches(table!.group(1)!))
        m.group(1)!,
    ];
    expect(rust, contains('mp4'), reason: '音乐来源目录里的 mp4 音频要收');
    expect(rust.toSet().length, rust.length, reason: 'Rust 表有重复项');
    expect(
      kAudioExtensions,
      equals(<String>{
        for (final String e in rust)
          if (e != 'mp4') '.$e',
      }),
      reason:
          '纯音频扩展名漂移：media_extensions.dart 的 kAudioExtensions 与 '
          'native/fushi_music/src/tags.rs 的 AUDIO_EXTENSIONS（去掉 mp4）必须一致',
    );
  });

  test('kAudioExtensions stays disjoint from kVideoExtensions', () {
    expect(kAudioExtensions.intersection(kVideoExtensions), isEmpty);
  });
}
