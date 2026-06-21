import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

import '../pages/reader_hibiki_page_source_corpus.dart';
import '../pages/video_hibiki_page_source_corpus.dart';

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
      if (p.endsWith('reader_hibiki_page.dart')) return readReaderPageSource();
      if (p.endsWith('video_hibiki_page.dart')) return readVideoHibikiSource();
      return File(p).readAsStringSync();
    }

    final sites = <String>[
      'lib/src/pages/implementations/dictionary_page_mixin.dart',
      'lib/src/pages/implementations/reader_hibiki_page.dart',
      'lib/src/pages/implementations/video_hibiki_page.dart',
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
