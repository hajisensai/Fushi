import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';

/// 词典改名（v95）的行为契约。
///
/// 这套改名的全部风险都压在一句话上：**真名冻结，只加显示层覆盖**。
/// `dictionary_metadata.name` 同时是主键、磁盘目录名、C++ 引擎装载路径、查词
/// 结果里的 dictName，还被每词典 CSS map、样式规则、弹窗 `data-dictionary`
/// 选择器、词典媒体 URL、Anki `{single-glossary-<名>}` token、存储占用条目 id
/// 和同步资产名当键用。所以这里逐条钉住「改名不改身份」。
Future<FushiDatabase> _openDb() async {
  final FushiDatabase db = FushiDatabase.forTesting(NativeDatabase.memory());
  addTearDown(db.close);
  return db;
}

DictionaryMetadataCompanion _meta({
  String name = 'JMdict [2026-05-17]',
  String? displayName,
}) =>
    DictionaryMetadataCompanion.insert(
      name: name,
      formatKey: 'yomitan',
      order: 0,
      displayName: Value<String?>(displayName),
    );

void main() {
  group('dictionary_metadata.display_name (v95)', () {
    test('缺省为 null——旧库既有行 = 没改过名', () async {
      final FushiDatabase db = await _openDb();
      await db.upsertDictionaryMeta(_meta());

      final List<DictionaryMetaRow> rows = await db.getAllDictionaryMetadata();
      expect(rows, hasLength(1));
      expect(rows.single.name, 'JMdict [2026-05-17]');
      expect(
        rows.single.displayName,
        isNull,
        reason: 'nullable 无 default：不写就是 NULL，等价于改名前的行为',
      );
    });

    test('写入后往返一致，且真名一个字节都没动', () async {
      final FushiDatabase db = await _openDb();
      await db.upsertDictionaryMeta(_meta(displayName: '日汉大辞典'));

      final DictionaryMetaRow row =
          (await db.getAllDictionaryMetadata()).single;
      expect(row.displayName, '日汉大辞典');
      expect(
        row.name,
        'JMdict [2026-05-17]',
        reason: '改名只写 display_name；name 是主键+目录名+引擎键，必须原样',
      );
    });

    test('改名不新增行——按主键 upsert，不会留下孤儿', () async {
      final FushiDatabase db = await _openDb();
      await db.upsertDictionaryMeta(_meta());
      await db.upsertDictionaryMeta(_meta(displayName: '改过的名'));

      final List<DictionaryMetaRow> rows = await db.getAllDictionaryMetadata();
      expect(
        rows,
        hasLength(1),
        reason: '真名是主键，改显示名走同一行 upsert；若改的是 name 这里会变成 2 行',
      );
      expect(rows.single.displayName, '改过的名');
    });
  });

  group('Dictionary.effectiveDisplayName', () {
    Dictionary make({String? displayName}) => Dictionary(
          name: 'JMdict [2026-05-17]',
          formatKey: 'yomitan',
          order: 0,
          displayName: displayName,
        );

    test('没改过名 → 显示真名', () {
      expect(make().effectiveDisplayName, 'JMdict [2026-05-17]');
    });

    test('改过名 → 显示改的名', () {
      expect(make(displayName: '日汉大辞典').effectiveDisplayName, '日汉大辞典');
    });

    test('空串 / 纯空白 → 回落真名，不显示一个空标题', () {
      expect(make(displayName: '').effectiveDisplayName, 'JMdict [2026-05-17]');
      expect(
        make(displayName: '   ').effectiveDisplayName,
        'JMdict [2026-05-17]',
      );
    });

    test('显示名两端空白被裁掉', () {
      expect(make(displayName: '  日汉  ').effectiveDisplayName, '日汉');
    });
  });

  group('改名不改身份', () {
    test('== / hashCode 仍只看真名', () {
      final Dictionary a = Dictionary(
        name: 'JMdict',
        formatKey: 'yomitan',
        order: 0,
      );
      final Dictionary b = Dictionary(
        name: 'JMdict',
        formatKey: 'yomitan',
        order: 3,
        displayName: '完全不同的显示名',
      );
      expect(
        a == b,
        isTrue,
        reason: '同一本词典改了显示名后必须仍等于自己——一堆集合运算（hidden / '
            'collapsed / 排序）按 Dictionary 相等性去重',
      );
      expect(a.hashCode, b.hashCode);
    });

    test('toJson / fromJson 往返保住显示名', () {
      final Dictionary d = Dictionary(
        name: 'JMdict',
        formatKey: 'yomitan',
        order: 0,
        displayName: '日汉',
      );
      final Dictionary back = Dictionary.fromJson(d.toJson());
      expect(back.name, 'JMdict');
      expect(back.displayName, '日汉');
      expect(back.effectiveDisplayName, '日汉');
    });

    test('copyWith 只换指定字段，用户设置列原样带过', () {
      // 防真数据丢失：构造器把 languageOverride / displayName 设成可选默认 null，
      // 而 _dictionaryToCompanion 对每列都写 Value(...)（不是 absent）——「new 一个
      // Dictionary 再 persist」漏填一个参数就是显式往 DB 写 NULL。类型自愈迁移
      // （AppModel._migrateDictionaryTypes）曾这么把用户的改名和内容语言一起抹掉。
      final Dictionary original = Dictionary(
        name: 'JMdict',
        formatKey: 'yomitan',
        order: 5,
        type: DictionaryType.kanji,
        metadata: const <String, String>{'revision': '1'},
        hiddenLanguages: <String>['en'],
        collapsedLanguages: <String>['ja'],
        languageOverride: 'ja',
        displayName: '日汉大辞典',
      );

      final Dictionary migrated = original.copyWith(
        type: DictionaryType.term,
        metadata: const <String, String>{'revision': '2'},
      );

      // 换掉的
      expect(migrated.type, DictionaryType.term);
      expect(migrated.metadata, const <String, String>{'revision': '2'});
      // 必须原样带过的——这两条是丢数据的那两列
      expect(
        migrated.displayName,
        '日汉大辞典',
        reason: '类型自愈只想换 type，不能顺手抹掉用户的改名',
      );
      expect(
        migrated.languageOverride,
        'ja',
        reason: '手动指定的内容语言同理（v87 起的既有丢数据路径）',
      );
      // 其余字段也不许掉
      expect(migrated.name, 'JMdict');
      expect(migrated.formatKey, 'yomitan');
      expect(migrated.order, 5);
      expect(migrated.hiddenLanguages, <String>['en']);
      expect(migrated.collapsedLanguages, <String>['ja']);
    });

    test('fromJson 读旧 JSON（没有 displayName 字段）不炸，退化成没改过名', () {
      final Dictionary old = Dictionary(
        name: 'JMdict',
        formatKey: 'yomitan',
        order: 0,
      );
      final Dictionary back = Dictionary.fromJson(old.toJson());
      expect(back.displayName, isNull);
      expect(back.effectiveDisplayName, 'JMdict');
    });
  });
}
