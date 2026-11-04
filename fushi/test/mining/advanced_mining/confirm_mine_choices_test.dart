import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi_anki/fushi_anki_core.dart';

/// 「高级制卡」确认往返回点出来的制卡 fields 在交宿主前的合并（[applyConfirmMineChoices]）：
/// 单词音频改写 `audio`（null 不改 / 空串不要 / 其余替换），其余调整经
/// [MiningRequestOverrides.attach] 附上。四个制卡桥 handler 共用这一处。
void main() {
  const Map<String, String> fields = <String, String>{
    'expression': '諦める',
    'audio': 'https://default.test/a.mp3',
  };

  test('wordAudioUrl 为 null：audio 原样保留', () {
    expect(applyConfirmMineChoices(fields), fields);
  });

  test('wordAudioUrl 为空串：清空 audio（不要单词音频）', () {
    final Map<String, String> out = applyConfirmMineChoices(
      fields,
      wordAudioUrl: '',
    );
    expect(out['audio'], '');
    expect(out['expression'], '諦める');
    expect(fields['audio'], 'https://default.test/a.mp3', reason: '不改入参');
  });

  test('wordAudioUrl 为 URL：替换 audio', () {
    expect(
      applyConfirmMineChoices(
        fields,
        wordAudioUrl: 'https://peer.test/b.mp3?token=2',
      )['audio'],
      'https://peer.test/b.mp3?token=2',
    );
  });

  test('与覆盖项一起：audio 被替换，覆盖项也附上', () {
    final Map<String, String> out = applyConfirmMineChoices(
      fields,
      overrides: const MiningRequestOverrides(deckName: '日语::动画'),
      wordAudioUrl: 'https://peer.test/b.mp3',
    );
    expect(out['audio'], 'https://peer.test/b.mp3');
    final Object? raw = out[MiningRequestOverrides.wireKey];
    expect(raw, isA<String>());
    expect(
      MiningRequestOverrides.readFrom(<String, dynamic>{
        MiningRequestOverrides.wireKey: raw,
      })?.deckName,
      '日语::动画',
    );
    expect(jsonDecode(raw! as String), isA<Map<String, dynamic>>());
  });

  test('空覆盖项不附 wire key', () {
    expect(
      applyConfirmMineChoices(
        fields,
        overrides: const MiningRequestOverrides(),
      ).containsKey(MiningRequestOverrides.wireKey),
      isFalse,
    );
  });

  // 往返状态只活一次往返：finally 不清干净，下一次普通「+」会继续带上次选的音源 /
  // 「不要」/ 覆盖项。State 里的往返无法脱离 WebView 驱动，守住源码契约。
  test('mineEntryByIndex 的 finally 同时清空覆盖项与单词音频', () {
    final String src = File(
      'lib/src/pages/implementations/dictionary_popup_webview.dart',
    ).readAsStringSync();
    final int start = src.indexOf('Future<bool> mineEntryByIndex(');
    expect(start, greaterThan(0));
    final int fin = src.indexOf('} finally {', start);
    expect(fin, greaterThan(start));
    final String finallyBlock = src.substring(fin, src.indexOf('\n  }\n', fin));
    expect(finallyBlock, contains('_confirmMineOverrides = null;'));
    expect(finallyBlock, contains('_confirmMineWordAudioUrl = null;'));
    // 四个制卡桥 handler 都必须经同一个合并入口。
    expect(
      RegExp(r'_withConfirmMineOverrides\(').allMatches(src).length,
      greaterThanOrEqualTo(5),
      reason:
          '定义 1 处 + mineEntry / updateEntry / queueOverwrite / '
          'minedCardAction 四处调用',
    );
    expect(src, contains('applyConfirmMineChoices('));
  });
}
