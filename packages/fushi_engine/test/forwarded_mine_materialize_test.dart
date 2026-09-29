import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_anki/fushi_anki_core.dart';
import 'package:fushi_engine/sync/forwarded_mine_materialize.dart';
import 'package:fushi_engine/sync/forwarded_mine_payload.dart';
import 'package:test/test.dart';

/// BUG-2773：跨设备中转的载荷来自任何能写同步后端的一方。凡不是本载荷随附字节的
/// 媒体引用都要剥掉，绝不把对端给的本地路径 / URL 交给下游（下游会读本地文件、
/// 对任意 URL 发 GET）。
void main() {
  Future<Map<String, dynamic>> materializedFields(
    ForwardedMinePayload payload, {
    required bool bundledMediaOnly,
    void Function(Map<String, dynamic> fields)? whileAlive,
  }) => withMaterializedMiningContext<Map<String, dynamic>>(payload, (
    String raw,
    AnkiMiningContext context,
  ) async {
    final Map<String, dynamic> fields =
        jsonDecode(raw) as Map<String, dynamic>;
    whileAlive?.call(fields);
    return fields;
  }, bundledMediaOnly: bundledMediaOnly);

  test('中转载荷：非随附的单词音频（本地路径 / URL）一律剥掉', () async {
    for (final String ref in <String>[
      '/etc/passwd',
      r'C:\Windows\win.ini',
      'file:///etc/hosts',
      'http://169.254.169.254/latest/meta-data/',
      'https://example.com/a.mp3',
    ]) {
      final Map<String, dynamic> fields = await materializedFields(
        ForwardedMinePayload(
          rawPayloadJson: jsonEncode(<String, Object?>{
            'expression': '猫',
            'audio': ref,
          }),
          sentence: 's',
        ),
        bundledMediaOnly: true,
      );
      expect(fields['audio'], '', reason: ref);
      expect(fields['expression'], '猫');
    }
  });

  test('中转载荷：随附了单词音频字节时 audio 指向本次写出的临时文件', () async {
    late String audioPath;
    late List<int> audioBytes;
    await materializedFields(
      ForwardedMinePayload(
        rawPayloadJson: jsonEncode(<String, Object?>{
          'expression': '猫',
          'audio': '/etc/passwd',
        }),
        sentence: 's',
        wordAudioBytes: Uint8List.fromList(<int>[1, 2, 3]),
        wordAudioExt: '../../evil',
      ),
      bundledMediaOnly: true,
      whileAlive: (Map<String, dynamic> fields) {
        audioPath = fields['audio'] as String;
        audioBytes = File(audioPath).readAsBytesSync();
      },
    );
    expect(audioPath, isNot('/etc/passwd'));
    expect(audioPath, contains('fushi_fwd_mine_'));
    expect(audioPath, endsWith('word_audio.evil'), reason: '扩展名只留字母数字');
    expect(audioBytes, <int>[1, 2, 3]);
  });

  test('中转载荷：词典外字只留随附了字节的条目', () async {
    final Map<String, dynamic> fields = await materializedFields(
      ForwardedMinePayload(
        rawPayloadJson: jsonEncode(<String, Object?>{
          'expression': '猫',
          'dictionaryMedia': jsonEncode(<Map<String, String>>[
            <String, String>{'dictionary': 'A', 'path': 'gaiji/a.png'},
            <String, String>{'dictionary': 'B', 'path': 'gaiji/b.png'},
          ]),
        }),
        sentence: 's',
        dictionaryMedia: <ForwardedDictMedia>[
          ForwardedDictMedia(
            dictionary: 'A',
            path: 'gaiji/a.png',
            bytes: Uint8List.fromList(<int>[9]),
          ),
        ],
      ),
      bundledMediaOnly: true,
    );
    final List<Object?> kept =
        jsonDecode(fields['dictionaryMedia'] as String) as List<Object?>;
    expect(kept, hasLength(1));
    expect((kept.single as Map<String, Object?>)['dictionary'], 'A');
  });

  test('中转载荷：fields 不是 JSON 对象时拒绝（剥不了就不落）', () async {
    await expectLater(
      materializedFields(
        const ForwardedMinePayload(rawPayloadJson: '[1]', sentence: 's'),
        bundledMediaOnly: true,
      ),
      throwsA(isA<FormatException>()),
    );
  });

  test('非中转（本机 / 已配对主机）载荷：URL 单词音频照旧透传', () async {
    final Map<String, dynamic> fields = await materializedFields(
      ForwardedMinePayload(
        rawPayloadJson: jsonEncode(<String, Object?>{
          'expression': '猫',
          'audio': 'https://example.com/a.mp3',
        }),
        sentence: 's',
      ),
      bundledMediaOnly: false,
    );
    expect(fields['audio'], 'https://example.com/a.mp3');
  });
}
