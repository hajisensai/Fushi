import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:fushi/src/models/dictionary_repository.dart';

/// BUG-1492：**覆盖导入 / 在线更新一本词典之后，那本词典查不到词了**（重新导入才好）。
///
/// 根因是「词典集合变了」与「查词缓存失效 + 引擎重载」不是同一件事：
/// * `persistDictionary` 只重载引擎、不清查词缓存；
/// * `deleteDictionaryMeta` 两件都不做。
///
/// 而覆盖导入的替换分支正是「删旧目录 + 删旧 meta → 把新包整包 publish 到位 →
/// persist 新 meta」，中间那段（大词典包要几十秒到几分钟）引擎的 in-memory 索引还指着
/// **已被删掉的目录**。那段窗口里任何一次查词都会拿到「缺这本词典」的结果并写进缓存，
/// 导入结束后缓存没人清 → 同一个查询串永远重放缺词典的旧结果。
///
/// 用户侧表现完全对得上：视频字幕弹窗（查询串是「点中字位→句尾」的长尾串）一直查不到，
/// 而「查词」页手打精确词能查到——两条路径共用同一个 `AppModel.searchDictionary` 与
/// 同一组缓存，只是**缓存 key 不同**，被污染的只有弹窗那个 key。所谓「重新导入就好了」
/// 也不是重导修好了词典，而是 `importFromFile` 在**开头**清了一次缓存。
///
/// 本测试钉住修复后的不变式：**写和删词典元数据，都必须同时重载引擎并清空查词缓存。**
void main() {
  FushiDatabase makeDb() =>
      FushiDatabase.forTesting(DatabaseConnection(NativeDatabase.memory()));

  Dictionary dict({String name = 'Pixiv Light [2026-02-01]', int order = 0}) {
    return Dictionary(
      name: name,
      formatKey: 'yomichan',
      order: order,
      type: DictionaryType.term,
      metadata: const <String, String>{},
      hiddenLanguages: const <String>[],
      collapsedLanguages: const <String>[],
    );
  }

  /// 模拟「更新前用户在视频字幕上点过词」——查询串是从被点字位取到句尾的长尾串，
  /// 这正是被污染后再也刷不掉的那个缓存 key。
  const String subtitleTailTerm = 'アケコンなどという謎に重いだけの箱';

  DictionarySearchResult staleResult() => DictionarySearchResult(
        searchTerm: subtitleTailTerm,
        entries: <DictionaryEntry>[
          DictionaryEntry(word: 'アケ', meaning: 'あけ'),
        ],
        bestLength: 2,
      );

  late FushiDatabase db;
  late int rebuildCount;
  late DictionaryRepository repo;

  setUp(() {
    db = makeDb();
    rebuildCount = 0;
    repo = DictionaryRepository(db, onCacheRebuild: () => rebuildCount++);
  });

  tearDown(() async {
    await db.close();
  });

  test('persistDictionary 重载引擎并清空查词缓存（导入收尾）', () async {
    repo.cacheSearchResult(subtitleTailTerm, staleResult());
    expect(repo.getCachedSearch(subtitleTailTerm), isNotNull,
        reason: '前置条件：缓存里确实有一条陈旧结果');
    final int before = rebuildCount;

    await repo.persistDictionary(dict());

    expect(rebuildCount, greaterThan(before),
        reason: '新词典进库必须重载 native 引擎，否则查询打不到它');
    expect(repo.getCachedSearch(subtitleTailTerm), isNull,
        reason: '词典集合变了，旧查询结果必须失效——否则重导完仍重放「查不到」的旧结果');
  });

  test('deleteDictionaryMeta 重载引擎并清空查词缓存（替换的删旧半程）', () async {
    await repo.persistDictionary(dict());
    repo.cacheSearchResult(subtitleTailTerm, staleResult());
    final int before = rebuildCount;

    await repo.deleteDictionaryMeta('Pixiv Light [2026-02-01]');

    expect(rebuildCount, greaterThan(before),
        reason: '旧词典目录已被删，引擎必须立刻重载，不能继续指着不存在的目录');
    expect(repo.getCachedSearch(subtitleTailTerm), isNull);
    expect(repo.dictionaries, isEmpty);
  });

  test('覆盖导入全程（删旧→发布→persist 新）结束时缓存必空、引擎已重载', () async {
    // 更新前：词典在库，且用户查过一次，结果进了缓存。
    await repo.persistDictionary(dict());
    repo.cacheSearchResult(subtitleTailTerm, staleResult());
    final int rebuildsBeforeUpdate = rebuildCount;

    // 替换的删旧半程（importFromFile 的 replaceExact / replaceOldVersion 分支）。
    await repo.deleteDictionaryMeta('Pixiv Light [2026-02-01]');

    // 窗口期：此时哪怕有一次查词把「缺这本词典」的结果写进缓存……
    repo.cacheSearchResult(subtitleTailTerm, staleResult());

    // ……收尾 persist 新 meta 也必须把它清掉。
    await repo.persistDictionary(dict());

    expect(repo.getCachedSearch(subtitleTailTerm), isNull,
        reason: '这是 BUG-1492 的核心：更新窗口内被污染的缓存不能活过导入收尾');
    expect(rebuildCount, greaterThan(rebuildsBeforeUpdate + 1),
        reason: '删旧与装新各要一次引擎重载');
    expect(repo.dictionaries.map((Dictionary d) => d.name),
        contains('Pixiv Light [2026-02-01]'));
  });

  test('换名更新（日期后缀变了）后新名在库、缓存已清', () async {
    await repo.persistDictionary(dict(name: 'Pixiv Light [2026-02-01]'));
    repo.cacheSearchResult(subtitleTailTerm, staleResult());

    // replaceOldVersion 分支：base 名同、全名不同 → 删旧名、装新名。
    await repo.deleteDictionaryMeta('Pixiv Light [2026-02-01]');
    await repo.persistDictionary(dict(name: 'Pixiv Light [2026-08-01]'));

    expect(repo.getCachedSearch(subtitleTailTerm), isNull);
    expect(repo.dictionaries.map((Dictionary d) => d.name),
        <String>['Pixiv Light [2026-08-01]']);
  });
}
