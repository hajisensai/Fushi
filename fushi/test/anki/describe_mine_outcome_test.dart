import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_anki/fushi_anki.dart';

import '../pages/reader_fushi_page_source_corpus.dart';
import '../pages/video_fushi_page_source_corpus.dart';

/// describeMineOutcome 是制卡结果→(用户消息, 是否成功, 是否记账) 的单一真相。
/// 此前该四分支 switch 在 5 个调用点（mixin/reader/video/app_model/floating）各
/// 复制一份；本测试钉死映射，并用源码守卫确认各调用点都转调它、不再保留本地 switch。
void main() {
  group('describeMineOutcome 单一真相', () {
    test('success: 带牌组名消息 + success=true + record=true', () {
      final r = describeMineOutcome(
        const MineOutcome(MineResult.success),
        deckName: 'Deck1',
      );
      expect(r.message, t.card_exported(deck: 'Deck1'));
      expect(r.success, isTrue);
      expect(r.record, isTrue);
    });

    test('TODO-779 success + audioWarning: 成功文案后追加音频失败提示', () {
      const reason = 'HTTP 404 for https://dict.example/a.mp3';
      final r = describeMineOutcome(
        const MineOutcome.success(audioWarning: reason),
        deckName: 'Deck1',
      );
      // 卡片仍算成功、仍记账（音频缺失不撤销制卡）。
      expect(r.success, isTrue);
      expect(r.record, isTrue);
      // 成功文案保留，并追加可见的音频失败原因（含 HTTP 码/URL）。
      expect(r.message, contains(t.card_exported(deck: 'Deck1')));
      expect(r.message, contains('404'));
      expect(r.message, contains('https://dict.example/a.mp3'));
      expect(r.message, isNot(t.card_exported(deck: 'Deck1')));
    });

    test('TODO-779 overwrite + audioWarning: 覆盖文案后追加音频失败提示', () {
      const reason = 'HTTP 500 for https://dict.example/a.mp3';
      final r = describeMineOutcome(
        const MineOutcome.success(noteId: 7, audioWarning: reason),
        deckName: 'Deck1',
        overwrite: true,
      );
      expect(r.success, isTrue);
      // 覆盖不记账（与既有行为一致）。
      expect(r.record, isFalse);
      expect(r.message, contains(t.card_overwritten(deck: 'Deck1')));
      expect(r.message, contains('500'));
    });

    test('duplicate: 重复文案 + 不成功不记账', () {
      final r = describeMineOutcome(const MineOutcome(MineResult.duplicate));
      expect(r.message, t.card_duplicate);
      expect(r.success, isFalse);
      expect(r.record, isFalse);
    });

    test('notConfigured: 未配置文案 + 不成功不记账', () {
      final r =
          describeMineOutcome(const MineOutcome(MineResult.notConfigured));
      expect(r.message, t.card_export_not_configured);
      expect(r.success, isFalse);
      expect(r.record, isFalse);
    });

    test('error: 走 logMineFailure 通用文案 + 不成功不记账', () {
      final r = describeMineOutcome(const MineOutcome(MineResult.error));
      // 无 errorDetail → logMineFailure 降级到通用文案。
      expect(r.message, t.card_export_failed);
      expect(r.success, isFalse);
      expect(r.record, isFalse);
    });
  });

  group('调用点都转调 describeMineOutcome（不再本地 switch 复制）', () {
    // TODO-589/590: reader 与 video 的制卡方法已搬进各自的 `*.part.dart`，读合并
    // 语料（主壳 + 全部 part）才能命中搬出去的 describeMineOutcome。
    String read(String p) {
      if (p.endsWith('reader_fushi_page.dart')) return readReaderPageSource();
      if (p.endsWith('video_fushi_page.dart')) return readVideoFushiSource();
      final String src = File(p).readAsStringSync();
      // TODO-1303：app_model 的 remoteMineResultFromOutcome 是「outcome → RemoteMineResult
      // 远端契约」的单一真相（与 describeMineOutcome「outcome → 用户消息」正交），它合法地
      // switch MineResult（含 case MineResult.duplicate）。它不是被 describeMineOutcome 取代
      // 的本地消息 switch，故把该函数体排除出「不得残留本地 MineResult switch」的扫描范围。
      if (p.endsWith('app_model.dart')) {
        return _withoutRemoteMineResultSwitch(src);
      }
      return src;
    }

    final sites = <String>[
      'lib/src/pages/implementations/dictionary_page_mixin.dart',
      'lib/src/pages/implementations/reader_fushi_page.dart',
      'lib/src/pages/implementations/video_fushi_page.dart',
      'lib/src/pages/implementations/floating_dict_page.dart',
      'lib/src/models/app_model.dart',
    ];
    for (final site in sites) {
      test('$site 转调 describeMineOutcome', () {
        final src = read(site);
        expect(src, contains('describeMineOutcome('),
            reason: '$site 应转调 describeMineOutcome');
        expect(src.contains('case MineResult.duplicate:'), isFalse,
            reason: '$site 不应再保留本地 MineResult switch');
      });
    }
  });
}

/// 从 app_model 源码里剔除 `remoteMineResultFromOutcome` 函数（TODO-1303：它是
/// outcome→RemoteMineResult 的远端契约单一真相，合法 switch MineResult；不属于被
/// describeMineOutcome 取代的本地消息 switch）。用其后紧邻的顶层声明 `remoteMineError`
/// 夹住函数体并整段移除，避免其中的 `case MineResult.duplicate:` 误触发过广守卫。
String _withoutRemoteMineResultSwitch(String source) {
  const String start = 'RemoteMineResult remoteMineResultFromOutcome(';
  const String end = 'RemoteMineResult remoteMineError(';
  final int startIdx = source.indexOf(start);
  if (startIdx < 0) return source;
  final int endIdx = source.indexOf(end, startIdx);
  if (endIdx < 0) return source;
  return source.substring(0, startIdx) + source.substring(endIdx);
}
