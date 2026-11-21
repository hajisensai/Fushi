import 'dart:async';

import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// 收藏句变更流（#3722 c51 遗留）：视频播放页的收藏镜像只在打开面板 / 本页增删时刷新，
/// 收藏夹页、同步合并、备份恢复改了收藏，播放页星标一直是旧的。仓库给出
/// [FavoriteSentenceRepository.watchChanges]：任何写入者改了收藏句表都发一次（v166 起
/// 收藏句是表），别的表 / 偏好写入、内容相同的整表重写都不发。
void main() {
  late FushiDatabase db;
  late FavoriteSentenceRepository repo;

  setUp(() {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = FavoriteSentenceRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  FavoriteSentence make(String text) => FavoriteSentence(
    text: text,
    bookTitle: '本',
    createdAt: DateTime.utc(2026, 11, 20),
    bookKey: 'video/a',
    sectionIndex: 0,
    normCharOffset: 1200,
    normCharLength: null,
    source: kFavoriteSentenceSourceVideo,
  );

  /// 订阅（测试结束时取消）。
  Future<List<void>> listen() async {
    final List<void> events = <void>[];
    final StreamSubscription<void> sub = repo.watchChanges().listen(events.add);
    addTearDown(sub.cancel);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return events;
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  test('本仓库的增删各发一次', () async {
    final List<void> events = await listen();
    final FavoriteSentence a = make('そうか');
    await repo.add(a);
    await settle();
    expect(events, hasLength(1));
    await repo.removeById(a.id);
    await settle();
    expect(events, hasLength(2));
  });

  test('同步 / 备份合并的整表重写也发', () async {
    final List<void> events = await listen();
    await repo.replaceAll(<FavoriteSentence>[make('すごい')]);
    await settle();
    expect(events, hasLength(1));
  });

  test('别的偏好写入、内容相同的整表重写都不发', () async {
    final FavoriteSentence a = make('いいね');
    await repo.add(a);
    final List<void> events = await listen();
    await db.setPref('some_other_pref', 'x');
    await repo.replaceAll(await repo.getAll());
    await settle();
    expect(events, isEmpty);
  });
}
