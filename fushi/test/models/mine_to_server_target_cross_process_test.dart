// BUG-4241：查词弹窗（`:popup` 进程）把某台主机的「保存到」退回主机默认后，主进程的偏好缓存
// 仍是旧值——设置页照旧显示已失效的牌组，下一张卡还发旧目标。两个 PreferencesRepository
// 共用一个库，就是两个进程各自的缓存。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/sync/remote_mining_target.dart';

void main() {
  late FushiDatabase db;
  late PreferencesRepository mainProcess;
  late PreferencesRepository popupProcess;

  const RemoteMiningTarget mining = RemoteMiningTarget(
    kind: 'review',
    profile: 'uid-1',
    deck: 'Mining',
  );
  const RemoteMiningTarget anki = RemoteMiningTarget(kind: 'anki', deck: 'X');

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    mainProcess = PreferencesRepository(db);
    await mainProcess.loadFromDb();
    await mainProcess.setMineToServerTarget('host-a', mining, label: 'Mining');
    popupProcess = PreferencesRepository(db);
    await popupProcess.loadFromDb();
  });

  tearDown(() => db.close());

  test('the popup resets a host; the main process sees it after reloading '
      'the popup-written prefs', () async {
    await popupProcess.setMineToServerTarget('host-a', null);
    // 主进程缓存是启动时装的，还没对账前看到的就是旧值（这正是 bug 的现场）。
    expect(mainProcess.mineToServerTargets['host-a'], mining);

    bool notified = false;
    mainProcess.addListener(() => notified = true);
    expect(await mainProcess.reloadPopupWrittenPrefs(), isTrue);
    expect(notified, isTrue);
    expect(mainProcess.mineToServerTargets, isEmpty);
    expect(mainProcess.mineToServerTargetLabels, isEmpty);

    // 没变化时不通知、不算变过。
    notified = false;
    expect(await mainProcess.reloadPopupWrittenPrefs(), isFalse);
    expect(notified, isFalse);
  });

  test('a stale main process choosing for another host does not bring back '
      'the entry the popup cleared', () async {
    await popupProcess.setMineToServerTarget('host-a', null);
    await mainProcess.setMineToServerTarget('host-b', anki, label: 'Anki');

    final PreferencesRepository fresh = PreferencesRepository(db);
    await fresh.loadFromDb();
    expect(fresh.mineToServerTargets.keys, <String>['host-b']);
    expect(fresh.mineToServerTargets['host-b'], anki);
    expect(mainProcess.mineToServerTargets.keys, <String>['host-b']);
  });

  test('the target key is declared as popup-written', () {
    expect(
      PreferencesRepository.popupWrittenKeys,
      contains(PreferencesRepository.mineToServerTargetsKey),
    );
  });
}
