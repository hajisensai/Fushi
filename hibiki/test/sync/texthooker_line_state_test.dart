// gal-hook-ux-overhaul：捕获工作台行状态（已制卡 / 已收藏）与筛选 predicate 的纯逻辑测试。
// 这些逻辑不依赖 i18n key，故与页面层新增 key 解耦，可独立编译运行。

import 'package:characters/characters.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/src/sync/texthooker_service.dart';

void main() {
  setUp(() => TexthookerService.instance.clear());
  tearDown(() => TexthookerService.instance.clear());

  group('markLineMined（制卡成功回写，幂等）', () {
    test('首次标记置 mined=true 并通知一次', () {
      final TexthookerLineEntry line =
          TexthookerService.instance.appendLine('制卡对象')!;
      expect(line.mined, isFalse, reason: '新行默认未制卡');

      int notifications = 0;
      TexthookerService.instance.addListener(() => notifications++);

      expect(TexthookerService.instance.markLineMined(line.id), isTrue);
      expect(TexthookerService.instance.entryById(line.id)!.mined, isTrue);
      expect(notifications, 1);
    });

    test('重复标记幂等：返回 false 且不再通知', () {
      final TexthookerLineEntry line =
          TexthookerService.instance.appendLine('已制卡')!;
      TexthookerService.instance.markLineMined(line.id);

      int notifications = 0;
      TexthookerService.instance.addListener(() => notifications++);
      expect(TexthookerService.instance.markLineMined(line.id), isFalse);
      expect(notifications, 0, reason: '已是 mined 不重复通知');
    });

    test('行不存在返回 false', () {
      expect(TexthookerService.instance.markLineMined('missing-id'), isFalse);
    });
  });

  group('收藏（会话内存态，不落 DB）', () {
    test('setLineFavorite 设置并通知，同值不通知', () {
      final TexthookerLineEntry line =
          TexthookerService.instance.appendLine('收藏对象')!;
      expect(line.favorited, isFalse);

      int notifications = 0;
      TexthookerService.instance.addListener(() => notifications++);

      expect(TexthookerService.instance.setLineFavorite(line.id, true), isTrue);
      expect(TexthookerService.instance.entryById(line.id)!.favorited, isTrue);
      expect(notifications, 1);

      // 相同值再设置：无变化不通知。
      expect(
          TexthookerService.instance.setLineFavorite(line.id, true), isFalse);
      expect(notifications, 1);
    });

    test('toggleLineFavorite 翻转并返回新状态', () {
      final TexthookerLineEntry line =
          TexthookerService.instance.appendLine('翻转对象')!;
      expect(TexthookerService.instance.toggleLineFavorite(line.id), isTrue);
      expect(TexthookerService.instance.entryById(line.id)!.favorited, isTrue);
      expect(TexthookerService.instance.toggleLineFavorite(line.id), isFalse);
      expect(TexthookerService.instance.entryById(line.id)!.favorited, isFalse);
    });

    test('翻转不存在的行返回 false', () {
      expect(TexthookerService.instance.toggleLineFavorite('missing'), isFalse);
    });

    test('制卡态与收藏态互不干扰', () {
      final TexthookerLineEntry line =
          TexthookerService.instance.appendLine('双态')!;
      TexthookerService.instance.markLineMined(line.id);
      TexthookerService.instance.setLineFavorite(line.id, true);
      final TexthookerLineEntry updated =
          TexthookerService.instance.entryById(line.id)!;
      expect(updated.mined, isTrue);
      expect(updated.favorited, isTrue);
    });
  });

  group('hasAudio 派生（有音频判据单一真相源）', () {
    TexthookerLineEntry entryWith(TexthookerLineAudioStatus status) =>
        TexthookerLineEntry(
          id: 'x',
          text: 't',
          source: TexthookerLineSource.engineHook,
          receivedAt: DateTime(2026),
          audioStatus: status,
        );

    test('matched / encoded / fallback 视作有音频', () {
      expect(entryWith(TexthookerLineAudioStatus.matched).hasAudio, isTrue);
      expect(entryWith(TexthookerLineAudioStatus.encoded).hasAudio, isTrue);
      expect(entryWith(TexthookerLineAudioStatus.fallback).hasAudio, isTrue);
    });

    test('pending / missing / unavailable 视作无音频', () {
      expect(entryWith(TexthookerLineAudioStatus.pending).hasAudio, isFalse);
      expect(entryWith(TexthookerLineAudioStatus.missing).hasAudio, isFalse);
      expect(
          entryWith(TexthookerLineAudioStatus.unavailable).hasAudio, isFalse);
    });
  });

  group('lineMatchesFilter（枚举驱动，无特殊分支）', () {
    final TexthookerLineEntry plain = TexthookerLineEntry(
      id: '1',
      text: '普通',
      source: TexthookerLineSource.engineHook,
      receivedAt: DateTime(2026),
    );
    final TexthookerLineEntry withAudio = TexthookerLineEntry(
      id: '2',
      text: '有声',
      source: TexthookerLineSource.engineHook,
      receivedAt: DateTime(2026),
      audioStatus: TexthookerLineAudioStatus.matched,
    );
    final TexthookerLineEntry mined = TexthookerLineEntry(
      id: '3',
      text: '已制卡',
      source: TexthookerLineSource.engineHook,
      receivedAt: DateTime(2026),
      mined: true,
    );
    final TexthookerLineEntry favorited = TexthookerLineEntry(
      id: '4',
      text: '已收藏',
      source: TexthookerLineSource.engineHook,
      receivedAt: DateTime(2026),
      favorited: true,
    );

    test('all 恒真', () {
      for (final TexthookerLineEntry e in <TexthookerLineEntry>[
        plain,
        withAudio,
        mined,
        favorited,
      ]) {
        expect(lineMatchesFilter(e, TexthookerLineFilter.all), isTrue);
      }
    });

    test('withAudio 仅命中有音频行', () {
      expect(
          lineMatchesFilter(withAudio, TexthookerLineFilter.withAudio), isTrue);
      expect(lineMatchesFilter(plain, TexthookerLineFilter.withAudio), isFalse);
    });

    test('mined 仅命中已制卡行', () {
      expect(lineMatchesFilter(mined, TexthookerLineFilter.mined), isTrue);
      expect(lineMatchesFilter(plain, TexthookerLineFilter.mined), isFalse);
    });

    test('favorited 仅命中已收藏行', () {
      expect(
          lineMatchesFilter(favorited, TexthookerLineFilter.favorited), isTrue);
      expect(lineMatchesFilter(plain, TexthookerLineFilter.favorited), isFalse);
    });
  });

  group('textThreads 聚合预览（latestText / audioLineCount）', () {
    test('latestText 取该线程最新一条，audioLineCount 只数 hasAudio 行', () {
      final TexthookerService s = TexthookerService.instance;
      s.appendLine(
        '第一句',
        textThreadKey: 'k1',
        textThreadLabel: 'KiriKiriZ',
        audioStatus: TexthookerLineAudioStatus.matched,
      );
      s.appendLine(
        '第二句',
        textThreadKey: 'k1',
        textThreadLabel: 'KiriKiriZ',
        audioStatus: TexthookerLineAudioStatus.missing,
      );
      s.appendLine(
        'UI 文本',
        textThreadKey: 'k2',
        textThreadLabel: 'TextRender',
      );
      final Map<String, TexthookerTextThread> byKey =
          <String, TexthookerTextThread>{
        for (final TexthookerTextThread t in s.textThreads) t.key: t,
      };
      expect(byKey['k1']!.latestText, '第二句');
      expect(byKey['k1']!.audioLineCount, 1, reason: 'missing 不算有音频');
      expect(byKey['k1']!.lineCount, 2);
      expect(byKey['k2']!.latestText, 'UI 文本');
      expect(byKey['k2']!.audioLineCount, 0);
    });
  });

  group('texthookerThreadSubtitle / collapseTexthookerPreview', () {
    test('音频段仅在 audioLineCount>0 时出现，两段用 · 连接', () {
      expect(
        texthookerThreadSubtitle(
          audioLineCount: 3,
          latestText: '「こんにちは」',
          audioLabel: '3 行有音频',
        ),
        '3 行有音频 · 「こんにちは」',
      );
      expect(
        texthookerThreadSubtitle(
          audioLineCount: 0,
          latestText: '台词',
          audioLabel: '0 行有音频',
        ),
        '台词',
      );
      expect(
        texthookerThreadSubtitle(
          audioLineCount: 0,
          latestText: null,
          audioLabel: '0 行有音频',
        ),
        isNull,
      );
    });

    test('预览折叠空白并按字素簇截断', () {
      expect(collapseTexthookerPreview('  多行\n台词\t文本  '), '多行 台词 文本');
      final String long = 'あ' * 50;
      final String out = collapseTexthookerPreview(long);
      expect(out.characters.length, 41, reason: '40 字素 + 省略号');
      expect(out.endsWith('…'), isTrue);
      // 截断不劈开代理对（emoji 是双 code unit）。
      final String emoji = '😀' * 45;
      final String cut = collapseTexthookerPreview(emoji);
      expect(cut.characters.take(40).every((String c) => c == '😀'), isTrue);
    });
  });
}
