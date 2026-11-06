import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/mining/web_mine_clip.dart';
import 'package:fushi/src/mining/web_mine_replay.dart';

WebMineReplayFrame _f(int atMs) =>
    WebMineReplayFrame(bytes: Uint8List.fromList(<int>[1]), atMs: atMs);

void main() {
  test('concat 清单：帧按 atMs + lead 落位，首帧顶住 0、末帧撑到片段末尾并重复一次', () {
    final String list = buildWebMineFrameConcat(
      frames: <WebMineReplayFrame>[_f(0), _f(125), _f(250)],
      audioLeadMs: 150,
      clipDurationMs: 1000,
    );
    expect(
      list,
      'ffconcat version 1.0\n'
      "file 'frame_0000.jpg'\n"
      'duration 0.275\n'
      "file 'frame_0001.jpg'\n"
      'duration 0.125\n'
      "file 'frame_0002.jpg'\n"
      'duration 0.600\n'
      "file 'frame_0002.jpg'\n",
    );
  });

  test('concat 清单：时长不足一帧时不写出 0 / 负数', () {
    final String list = buildWebMineFrameConcat(
      frames: <WebMineReplayFrame>[_f(0), _f(500)],
      audioLeadMs: 0,
      clipDurationMs: 400,
    );
    expect(list, contains('duration 0.500'));
    expect(list, contains('duration 0.040'));
    expect(list, isNot(contains('duration -')));
  });

  test('ffmpeg 参数：有音频时映射并原样拷贝，无音频时只出画面', () {
    final List<String> withAudio = buildWebMineClipArgs(
      concatPath: 'l.ffconcat',
      audioPath: 'a.m4a',
      outputPath: 'o.mkv',
    );
    expect(withAudio, containsAllInOrder(<String>['-f', 'concat', '-i']));
    expect(withAudio, containsAllInOrder(<String>['-map', '1:a:0']));
    expect(withAudio, containsAllInOrder(<String>['-c:a', 'copy']));
    expect(withAudio.last, 'o.mkv');

    final List<String> silent = buildWebMineClipArgs(
      concatPath: 'l.ffconcat',
      audioPath: null,
      outputPath: 'o.mkv',
    );
    expect(silent, isNot(contains('1:a:0')));
    expect(silent, isNot(contains('copy')));
  });
}
