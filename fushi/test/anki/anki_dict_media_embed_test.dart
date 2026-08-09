import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_anki/fushi_anki.dart';

/// 制卡词典媒体（gaiji 外字）嵌入守卫：导出的义项 HTML 已经是
/// `<img class="gloss-image" src="fushi_dict_N.ext">`，制卡时必须把占位符
/// `fushi_dict_N.ext` 替换成**裸文件名**。若替换值是完整 `<img src="real.svg">`
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
  filename: 'fushi_dict_0.svg', // popup.js getMediaFilename 注入的占位符
);

// 导出义项 HTML：占位符在已有 <img> 的 src 属性里（见 popup.js createDefinitionImage）。
const String _glossaryHtml = '<img class="gloss-image" src="fushi_dict_0.svg">';

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
      expect(back, isNot(contains('fushi_dict_0.svg'))); // 占位符已替换
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
        '../packages/fushi_anki/lib/src/ankiconnect/ankiconnect_repository.dart',
      ).readAsStringSync().replaceAll('\r\n', '\n');
      // 锚定方法定义（而非调用点 `_storeDictionaryMedia(service, media)`）。
      // BUG-1265：返回类型是 `Future<String?>`——null = 这条词典媒体嵌不进去，
      // 只降级它一条，与 AnkiDroid/AnkiMobile 及 buildDictionaryMediaTags 同契约。
      final int start = src.indexOf('Future<String?> _storeDictionaryMedia(');
      expect(start, greaterThan(0),
          reason: '_storeDictionaryMedia 必须返回 Future<String?>（BUG-1265 降级契约）');
      // This is the final method in the repository class. Match its closing
      // brace plus the class brace so an inner guard block cannot truncate the
      // extracted method body.
      final int end = src.indexOf('\n  }\n}', start);
      expect(end, greaterThan(start));
      final String body = src.substring(start, end);
      expect(body, contains('ankiInlineMediaReference('));
      // 不允许把完整 <img>/[sound:] 标签直接塞进 dictionaryMediaTags。
      expect(body, isNot(contains("return '<img")));
      expect(body, isNot(contains("return '[sound:")));
      // BUG-1265：缓存缺失只能 return null 降级这一条，绝不能抛异常拖垮整次制卡
      // （封面/句子音频的「缺媒体就别建卡」策略在 _storeLocalMedia，两者不是一回事）。
      expect(body, isNot(contains('throw ')),
          reason: '词典媒体缺失必须降级返回 null，不得抛异常中止 mineEntry（BUG-1265）');
      expect(body, contains('return null;'),
          reason: '缺失分支必须显式 return null，交给 buildDictionaryMediaTags 跳过');
    });
  });

  // TODO-843：{video-clip} 是 {book-cover} 的语义别名，两者读同一 context.coverPath。
  // 在**同一 backend**（基类 buildMinedFields）内，把 image 字段映射 {video-clip} 与
  // 映射 {book-cover}（给同一已嵌入的 coverPath 媒体引用）必须产出**相同**字段值——
  // 证明无运行时分叉、媒体嵌入零改动。（跨 backend 包装格式本就不同，故只在同 backend 内比。）
  group('{video-clip} == {book-cover} within one backend (TODO-843)', () {
    // 模拟 backend 落盘后回填的 context：coverPath 已是 <img src="ref"> 媒体引用。
    const AnkiMiningContext mediaContext = AnkiMiningContext(
      sentence: '',
      coverPath: '<img src="hibiki_cover_x.gif">',
    );
    const AnkiMiningPayload payload = AnkiMiningPayload(expression: '一');

    test('mapping {video-clip} yields the same field value as {book-cover}',
        () {
      final Map<String, String> clipFields = repo.fieldsFor(
        fieldMappings: const <String, String>{'Image': '{video-clip}'},
        payload: payload,
        context: mediaContext,
        tags: const <String, String>{},
      );
      final Map<String, String> coverFields = repo.fieldsFor(
        fieldMappings: const <String, String>{'Image': '{book-cover}'},
        payload: payload,
        context: mediaContext,
        tags: const <String, String>{},
      );
      expect(clipFields['Image'], '<img src="hibiki_cover_x.gif">');
      expect(clipFields['Image'], coverFields['Image']);
    });

    test('null coverPath → both render empty image field', () {
      final Map<String, String> clipFields = repo.fieldsFor(
        fieldMappings: const <String, String>{'Image': '{video-clip}'},
        payload: payload,
        context: const AnkiMiningContext(sentence: ''),
        tags: const <String, String>{},
      );
      final Map<String, String> coverFields = repo.fieldsFor(
        fieldMappings: const <String, String>{'Image': '{book-cover}'},
        payload: payload,
        context: const AnkiMiningContext(sentence: ''),
        tags: const <String, String>{},
      );
      // buildMinedFields 对空值字段一视同仁（两者都不写入该字段）；关键是行为一致。
      expect(clipFields['Image'], coverFields['Image']);
      expect(clipFields['Image'] ?? '', '');
    });
  });
}
