import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_core/fushi_core.dart';

import 'package:fushi/src/mining/galgame_library.dart';
import 'package:fushi/src/mining/galgame_repository.dart';
import 'package:fushi/src/pages/implementations/games/galgame_item_menu.dart'
    show galgameNsfwToggleAction;
import 'package:fushi/src/pages/implementations/media_item_dialog_page.dart'
    show DialogToggleAction, ItemMenuSlot;

/// 游戏卡菜单的 NSFW 开关行（#3803：与书 / 视频 / 合集保持一致）。写游戏自己的
/// 「成人向」覆盖，状态并入通用 `media_nsfw_flags` 表；关掉时两处都清。
void main() {
  late FushiDatabase db;
  late GalgameRepository repo;
  late int changed;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = GalgameRepository(db);
    changed = 0;
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

  DialogToggleAction toggle() => galgameNsfwToggleAction(
    repo: repo,
    db: db,
    gameId: 'g1',
    onPressed: () {},
    onChanged: () => changed++,
  );

  test('是开关行（toggle 槽），初始关', () async {
    final DialogToggleAction action = toggle();
    expect(action.slot, ItemMenuSlot.toggle);
    expect(await action.loadState(), (value: false, locked: false));
  });

  test('拨开写「成人向」覆盖；拨关两处都清（表里同步来的标记也清）', () async {
    final DialogToggleAction action = toggle();
    await action.onChanged(true);
    expect(repo.byId('g1')!.isNsfw, isTrue);
    expect(await action.loadState(), (value: true, locked: false));
    expect(changed, 1);

    // 互联同步 / 旧数据把表里也标了：开关显示开，关掉后表里那行一并清掉。
    await db.setMediaNsfw(TagHostKind.game, 'g1', true);
    await action.onChanged(false);
    expect(repo.byId('g1')!.isNsfw, isFalse);
    expect(await db.isMediaNsfw(TagHostKind.game, 'g1'), isFalse);
    expect(await action.loadState(), (value: false, locked: false));
    expect(changed, 2);
  });

  test('只有表里的标记时开关也显示开', () async {
    await db.setMediaNsfw(TagHostKind.game, 'g1', true);
    expect(await toggle().loadState(), (value: true, locked: false));
  });
}
