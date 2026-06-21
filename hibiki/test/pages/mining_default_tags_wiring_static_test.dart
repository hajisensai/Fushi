import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki/i18n/strings.g.dart';

import 'reader_hibiki_page_source_corpus.dart';
import 'video_hibiki_page_source_corpus.dart';

/// 源码守卫（TODO-115）：制卡默认标签接线。
///
/// 行为本体（`hibiki` + `book`/`video` 分类标签的拼装、两后端对称、去重保序）由
/// `packages/hibiki_anki/test/mining_tag_and_parallel_test.dart` 的真制卡行为测试咬住。
/// 本守卫补两块行为测试照不到的接线：
///   1. AnkiDroid 原生 `addNote` 不再硬编码注入旧 fork 的 `"Yuuna"` 默认 tag
///      （那是 Android 原生 Java，Dart 行为测试到不了的层）。
///   2. reader / video 两条覆写制卡路径，以及共享 mixin，确实把来源透传进
///      `AnkiMiningContext.source`（这两条路径的页面在 headless 无法实例化，真制卡又
///      依赖真 Anki，端到端不可落地，故用结构化源码守卫）。
void main() {
  test('AnkiDroid native addNote 不再硬编码注入 Yuuna 默认 tag', () {
    final String src = File(
      'android/app/src/main/java/app/hibiki/reader/AnkiChannelHandler.java',
    ).readAsStringSync();
    // 旧 fork 曾 `new HashSet<>(Arrays.asList("Yuuna"))`，给每张卡硬塞 Yuuna。
    expect(src.contains('"Yuuna"'), isFalse,
        reason: 'AnkiDroid 不得再注入旧 Yuuna 默认 tag；标签统一由 Dart buildNoteTags 计算');
    // addNote 仍透传 Dart 传入的 tags（含 hibiki + 分类标签）。
    expect(src, contains('allTags.addAll(tags)'),
        reason: 'AnkiDroid 必须透传 Dart 传入的 tags');
  });

  test('buildNoteTags 把来源映射成 book/video 分类标签（追加不覆盖）', () {
    final String src = File(
      '../packages/hibiki_anki/lib/src/base_anki_repository.dart',
    ).readAsStringSync();
    expect(
        src,
        allOf(
          contains('List<String> buildNoteTags('),
          contains('AnkiMiningSource? source'),
        ),
        reason: 'buildNoteTags 必须接受来源参数');
    expect(src, contains("static const String bookTag = 'book';"));
    expect(src, contains("static const String videoTag = 'video';"));
    expect(src, contains("static const String hibikiTag = 'hibiki';"),
        reason: 'hibiki 固定标签不得丢（TODO-062）');
  });

  test('两后端 mineEntry 都把 context.source 传给 buildNoteTags', () {
    for (final String path in <String>[
      '../packages/hibiki_anki/lib/src/ankidroid/anki_repository.dart',
      '../packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_repository.dart',
    ]) {
      final String src = File(path).readAsStringSync();
      expect(src,
          allOf(contains('buildNoteTags('), contains('source: context.source')),
          reason: '$path 必须把来源透传给 buildNoteTags（否则分类标签不生效）');
    }
  });

  test('reader 制卡入口指定 book 来源', () {
    final String src = readReaderPageSource();
    expect(src, contains('source: AnkiMiningSource.book'),
        reason: 'reader 制卡应标记书籍来源 → book 分类标签');
  });

  test('video 制卡入口指定 video 来源', () {
    // TODO-590 batch14: `_mineVideoCard`（含 source: AnkiMiningSource.video）已搬进
    // lookup_mining.part.dart，读合并语料才能命中。
    final String src = readVideoHibikiSource();
    expect(src, contains('source: AnkiMiningSource.video'),
        reason: 'video 制卡应标记视频来源 → video 分类标签');
  });

  test('mixin 把 dictionarySourceType 映射进 AnkiMiningContext.source', () {
    final String src =
        File('lib/src/pages/implementations/dictionary_page_mixin.dart')
            .readAsStringSync();
    expect(src, contains('AnkiMiningSource get _miningSource'),
        reason: 'mixin 应把统计来源映射成制卡来源');
    expect(src, contains('source: _miningSource'),
        reason: 'mixin 的 onMineEntry 必须把来源传进 context');
    expect(src, contains('AnkiMiningSource.video'));
    expect(src, contains('AnkiMiningSource.book'));
  });

  // TODO-295 / BUG-242：设置页「添加来源分类标签」开关的提示文案，必须如实描述
  // 视频卡片得到的标签字面量是 `video`（见 base_anki_repository.dart 的
  // `videoTag = 'video'`），不得再写成 `anime`/「动漫」误导用户。
  // 行为本体（写进 Anki 的 tag 确实是 video）由 hibiki_anki 的真制卡行为测试咬住；
  // 本守卫只盯用户可见的提示文案别再漂回旧名。
  test('分类标签提示文案描述视频标签为 video，而非 anime/动漫', () {
    final String enHint =
        AppLocale.en.translations.anki_tag_include_category_hint;
    final String zhHint =
        AppLocale.zhCn.translations.anki_tag_include_category_hint;

    expect(enHint.contains('video'), isTrue,
        reason: 'EN 提示应说明视频卡片得到 "video" 标签');
    expect(enHint.toLowerCase().contains('anime'), isFalse,
        reason: 'EN 提示不得再把视频标签写成 "anime"（实际写入的是 video）');

    expect(zhHint.contains('video'), isTrue,
        reason: 'zh-CN 提示应说明视频卡片得到「video」标签');
    expect(zhHint.contains('anime'), isFalse, reason: 'zh-CN 提示不得再出现 "anime"');
    expect(zhHint.contains('动漫'), isFalse,
        reason: 'zh-CN 提示不得把视频写成「动漫」（视频≠动画）');
  });
}
