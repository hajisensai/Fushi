import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_anki/hibiki_anki.dart';

/// 制卡词典媒体（gaiji 外字）嵌入守卫：导出的义项 HTML 已经是
/// `<img class="gloss-image" src="hoshi_dict_N.ext">`，制卡时必须把占位符
/// `hoshi_dict_N.ext` 替换成**裸文件名**。若替换值是完整 `<img src="real.svg">`
/// 标签，会嵌进 `src="..."` 成 `<img src="<img src="real.svg">">` 的嵌套坏图，
/// Anki 卡片上外字不显示。
///
/// AnkiConnect 旧实现（桌面端，用户报「视频查词制卡外字图没有」的路径）返回完整
/// `<img>` 标签 → 丢图；AnkiDroid 经 [ankiInlineMediaReference] 裸化故正常。本守卫
/// 锁定两端经基类 [BaseAnkiRepository] 共用同一裸化契约。
class _TestRepo extends BaseAnkiRepository {
  @override
  Future<AnkiFetchResult> fetchConfiguration() => throw UnimplementedError();

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) =>
      throw UnimplementedError();

  @override
  Future<bool> isDuplicate(String expression, String reading) =>
      throw UnimplementedError();

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) =>
      throw UnimplementedError();

  @override
  Future<bool> createDeck(String name) => throw UnimplementedError();

  Future<Map<String, String>> tagsFor(
    List<DictionaryMedia> media,
    Future<String?> Function(DictionaryMedia media) store,
  ) =>
      buildDictionaryMediaTags(media, store);

  Map<String, String> fieldsFor({
    required Map<String, String> fieldMappings,
    required AnkiMiningPayload payload,
    required AnkiMiningContext context,
    required Map<String, String> tags,
  }) =>
      buildMinedFields(
        fieldMappings: fieldMappings,
        payload: payload,
        context: context,
        dictionaryMediaTags: tags,
      );
}

const DictionaryMedia _gaijiMedia = DictionaryMedia(
  dictionary: '明鏡',
  path: 'gaiji/bs一.svg',
  filename: 'hoshi_dict_0.svg', // popup.js getMediaFilename 注入的占位符
);

// 导出义项 HTML：占位符在已有 <img> 的 src 属性里（见 popup.js createDefinitionImage）。
const String _glossaryHtml = '<img class="gloss-image" src="hoshi_dict_0.svg">';

void main() {
  final _TestRepo repo = _TestRepo();

  group('dictionary media embed — bare filename contract', () {
    test('bare ref replaces placeholder → valid single <img>, no nesting',
        () async {
      final Map<String, String> tags = await repo.tagsFor(
        const <DictionaryMedia>[_gaijiMedia],
        // 修复后两端的契约：返回裸文件名。
        (DictionaryMedia m) async => 'real_stored.svg',
      );
      final Map<String, String> fields = repo.fieldsFor(
        fieldMappings: const <String, String>{'Back': '{glossary}'},
        payload: const AnkiMiningPayload(
          expression: '一',
          glossary: _glossaryHtml,
        ),
        context: const AnkiMiningContext(sentence: ''),
        tags: tags,
      );
      final String back = fields['Back'] ?? '';
      expect(back, contains('src="real_stored.svg"'));
      expect(back, isNot(contains('src="<img'))); // 不嵌套
      expect(back, isNot(contains('hoshi_dict_0.svg'))); // 占位符已替换
    });

    test('full <img> tag ref nests (reproduces the AnkiConnect BUG)', () async {
      // 这正是 AnkiConnect 旧实现（返回完整 <img> 标签）会产生的坏图。
      final Map<String, String> tags = await repo.tagsFor(
        const <DictionaryMedia>[_gaijiMedia],
        (DictionaryMedia m) async => '<img src="real_stored.svg">',
      );
      final Map<String, String> fields = repo.fieldsFor(
        fieldMappings: const <String, String>{'Back': '{glossary}'},
        payload: const AnkiMiningPayload(
          expression: '一',
          glossary: _glossaryHtml,
        ),
        context: const AnkiMiningContext(sentence: ''),
        tags: tags,
      );
      expect(fields['Back'], contains('src="<img')); // 嵌套坏图（被修复杜绝）
    });

    test('null store ref (cache miss / store failure) drops the entry',
        () async {
      final Map<String, String> tags = await repo.tagsFor(
        const <DictionaryMedia>[_gaijiMedia],
        (DictionaryMedia m) async => null,
      );
      expect(tags, isEmpty);
    });
  });

  group('ankiInlineMediaReference — single source of bare ref (both backends)',
      () {
    test('bares an <img> tag to its src', () {
      expect(ankiInlineMediaReference('<img src="x.svg">'), 'x.svg');
    });
    test('bares a [sound:] tag to its filename', () {
      expect(ankiInlineMediaReference('[sound:y.mp3]'), 'y.mp3');
    });
  });

  group('source guard — AnkiConnect _storeDictionaryMedia returns bare ref',
      () {
    test('routes through ankiInlineMediaReference, never returns a raw tag',
        () {
      final String src = File(
        '../packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_repository.dart',
      ).readAsStringSync();
      // 锚定方法定义（而非调用点 `_storeDictionaryMedia(service, media)`）。
      final int start = src.indexOf('Future<String?> _storeDictionaryMedia(');
      expect(start, greaterThan(0));
      final int end = src.indexOf('\n  }', start);
      expect(end, greaterThan(start));
      final String body = src.substring(start, end);
      expect(body, contains('ankiInlineMediaReference('));
      // 不允许把完整 <img>/[sound:] 标签直接塞进 dictionaryMediaTags。
      expect(body, isNot(contains("return '<img")));
      expect(body, isNot(contains("return '[sound:")));
    });
  });
}
