import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/media/privacy/media_privacy_dialog.dart'
    show MediaNsfwBinding;
import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:fushi/src/pages/implementations/games/galgame_item_menu.dart'
    show galgameNsfwBinding;

/// 游戏「隐私」对话框里的 NSFW 开关（#3803；拍板台 qiqSbvdxrk 起与私密 / 上锁合进
/// 同一个「隐私」入口）。写游戏自己的「成人向」覆盖，状态并入通用 `media_nsfw_flags`
/// 表；关掉时两处都清。
void main() {
  late FushiDatabase db;
  late GalgameRepository repo;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = GalgameRepository(db);
    await repo.addAll(<GalgameEntry>[
      GalgameEntry(
        id: 'g1',
        name: 'game',
        exePath: r'Z:\g1\game.exe',
        workdir: r'Z:\g1',
        addedAt: DateTime(2026),
      ),
    ]);
  });

  tearDown(() => db.close());

  MediaNsfwBinding binding() =>
      galgameNsfwBinding(repo: repo, db: db, gameId: 'g1');

  test('初始关、无继承', () async {
    final ({bool own, List<MediaCollectionRow> collections}) state =
        await binding().load();
    expect(state.own, isFalse);
    expect(state.collections, isEmpty);
  });

  test('打开写「成人向」覆盖；关掉两处都清（表里同步来的标记也清）', () async {
    await binding().write(true);
    expect(repo.byId('g1')!.isNsfw, isTrue);
    expect((await binding().load()).own, isTrue);

    // 互联同步 / 旧数据把表里也标了：显示开，关掉后表里那行一并清掉。
    await db.setMediaNsfw(TagHostKind.game, 'g1', true);
    await binding().write(false);
    expect(repo.byId('g1')!.isNsfw, isFalse);
    expect(await db.isMediaNsfw(TagHostKind.game, 'g1'), isFalse);
    expect((await binding().load()).own, isFalse);
  });

  test('只有表里的标记时也显示开', () async {
    await db.setMediaNsfw(TagHostKind.game, 'g1', true);
    expect((await binding().load()).own, isTrue);
  });
}
