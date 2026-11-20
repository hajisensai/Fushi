import 'dart:async';

import 'package:drift/native.dart';
import 'package:test/test.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';

/// 收藏句变更流（#3722 c51 遗留）：视频播放页的收藏镜像只在打开面板 / 本页增删时刷新，
/// 收藏夹页、同步合并、备份恢复改了收藏，播放页星标一直是旧的。仓库给出
/// [FavoriteSentenceRepository.watchChanges]：任何写入者改了收藏偏好键都发一次，
/// 别的偏好写入不发。
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

  /// 订阅并等基线读完（`getPref` 一次往返）。
  Future<(List<void>, StreamSubscription<void>)> listen() async {
    final List<void> events = <void>[];
    final StreamSubscription<void> sub = repo.watchChanges().listen(events.add);
    await db.getPref('favorite_sentences');
    await Future<void>.delayed(const Duration(milliseconds: 20));
    return (events, sub);
  }

  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 50));

  test('本仓库的增删各发一次', () async {
    final (List<void> events, StreamSubscription<void> sub) = await listen();
    addTearDown(sub.cancel);
    final FavoriteSentence a = make('そうか');
    await repo.add(a);
    await settle();
    expect(events, hasLength(1));
    await repo.removeById(a.id);
    await settle();
    expect(events, hasLength(2));
  });

  test('绕过仓库直接写同一偏好键（同步合并 / 备份恢复）也发', () async {
    final (List<void> events, StreamSubscription<void> sub) = await listen();
    addTearDown(sub.cancel);
    await db.setPref('favorite_sentences', '[]');
    await settle();
    expect(events, hasLength(1));
  });

  test('别的偏好写入、值没变的重写都不发', () async {
    await repo.add(make('いいね'));
    final (List<void> events, StreamSubscription<void> sub) = await listen();
    addTearDown(sub.cancel);
    await db.setPref('some_other_pref', 'x');
    final String? same = await db.getPref('favorite_sentences');
    await db.setPref('favorite_sentences', same!);
    await settle();
    expect(events, isEmpty);
  });
}
