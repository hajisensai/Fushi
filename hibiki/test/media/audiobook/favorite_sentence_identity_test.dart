import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';

/// BUG-494 (TODO-1053 Bug C) 守卫：收藏身份键坍缩。
///
/// 收藏存单 JSON blob，旧身份键 = (text, bookKey, sectionIndex, normCharOffset)。
/// 日文重复短句无前置查词/选区时 normCharOffset 均为 null → 键坍缩：两条不同收藏
/// (text/section 相同、offset 均 null) 内容键完全相同 → isFavorited 对「未收藏那条」
/// 误报 true（幻影收藏点亮★），removeByContent 误把两条一起删（连坐）。
///
/// 根因修复：每条 FavoriteSentence 自带唯一 id；add 只按 id 去重（不再按内容键
/// collapse），removeById 按精确 id 删单条，matchedFavoriteId 返回命中条目 id 供
/// reader 精确删除。本测试断言两条 offset 均 null 的同内容记录能被 id 精确区分。
void main() {
  late HibikiDatabase db;
  late FavoriteSentenceRepository repo;

  setUp(() {
    db = HibikiDatabase.forTesting(NativeDatabase.memory());
    repo = FavoriteSentenceRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  FavoriteSentence make() => FavoriteSentence(
        text: 'そうか',
        bookTitle: '本',
        createdAt: DateTime.utc(2026, 6, 30),
        bookKey: 'Book',
        sectionIndex: 3,
        // 无前置查词/选区 → offset/length 均 null（身份键坍缩风险区）。
        normCharOffset: null,
        normCharLength: null,
      );

  test('两条同 text/同 section、normCharOffset 均 null 的收藏被当作两条独立记录', () async {
    final FavoriteSentence a = make();
    final FavoriteSentence b = make();
    expect(a.id, isNot(equals(b.id)), reason: '每条 FavoriteSentence 自带唯一 id');

    await repo.add(a);
    await repo.add(b);

    final List<FavoriteSentence> all = await repo.getAll();
    expect(all, hasLength(2),
        reason: 'add 只按 id 去重，两条内容相同 offset 均 null 的记录不被内容键 collapse');
  });

  test('removeById 只删指定 id 那一条，不连坐删掉另一条同内容记录', () async {
    final FavoriteSentence a = make();
    final FavoriteSentence b = make();
    await repo.add(a);
    await repo.add(b);

    await repo.removeById(a.id);

    final List<FavoriteSentence> all = await repo.getAll();
    expect(all, hasLength(1), reason: 'removeById 精确删单条，不因内容键相同连坐删掉 b');
    expect(all.single.id, equals(b.id), reason: '留下的是未删的那一条 b');
  });

  test('matchedFavoriteId 命中某一条并返回其 id；删该 id 后仍剩另一条', () async {
    final FavoriteSentence a = make();
    final FavoriteSentence b = make();
    await repo.add(a);
    await repo.add(b);

    final String? matched = await repo.matchedFavoriteId(
      text: 'そうか',
      bookKey: 'Book',
      sectionIndex: 3,
      normCharOffset: null,
    );
    expect(matched, isNotNull, reason: '内容键命中 → 返回某条已收藏记录的精确 id');
    expect(<String>{a.id, b.id}, contains(matched), reason: '命中的 id 必是已存两条之一');

    await repo.removeById(matched!);
    final List<FavoriteSentence> all = await repo.getAll();
    expect(all, hasLength(1),
        reason: '按命中 id 删后只剩另一条（reader toggle 走 removeById 的行为）');
  });

  test('isFavorited 对真正已收藏内容返 true、对未收藏内容返 false（未破坏既有查询）', () async {
    await repo.add(make());

    expect(
        await repo.isFavorited(
          text: 'そうか',
          bookKey: 'Book',
          sectionIndex: 3,
          normCharOffset: null,
        ),
        isTrue,
        reason: '已收藏该 (text,section,null) → true');
    expect(
        await repo.isFavorited(
          text: 'ちがう',
          bookKey: 'Book',
          sectionIndex: 3,
          normCharOffset: null,
        ),
        isFalse,
        reason: '不同 text 未收藏 → false，无幻影');
  });
}
