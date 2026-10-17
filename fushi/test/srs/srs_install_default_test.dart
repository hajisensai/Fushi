// 「挖词目标」与复习模块的出厂默认（所有者 2026-10-16）：
//
// - 「默认就是 fushi srs」：全新安装（含跳过引导）挖词目标 = Fushi 复习、复习模块开；
// - 「老用户继续发 Anki」+「老用户不提醒」：升级上来的存量安装（有任一老用户信号）
//   一次性判成 Anki，复习模块从没设过就显式写成关；
// - 幂等、只跑一次；显式选过的值一概不改；
// - Profile 快照没有该键（切 Profile 时 live 键被删）/ 整层恢复一份老备份时，老用户
//   不会被新默认误切成复习。
//
// 判定本体是 PreferencesRepository.settleSrsMiningTargetInstallDefault，AppModel
// .initialise() 在偏好装载后调它一次。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/profile/profile_keys.dart';
import 'package:fushi/src/srs/srs_mining_target.dart';
import 'package:fushi_core/fushi_core.dart';

const String _target = PreferencesRepository.srsMiningTargetKey;
const String _marker = PreferencesRepository.srsMiningTargetInstallDefaultKey;

void main() {
  late FushiDatabase db;
  late PreferencesRepository repo;

  setUp(() async {
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    repo = PreferencesRepository(db);
    await repo.loadFromDb();
  });

  tearDown(() async {
    repo.dispose();
    await db.close();
  });

  SrsMiningTarget target() => SrsMiningTarget.fromWire(repo.srsMiningTarget);
  bool srsModule() => repo.moduleEnabled(ModuleId.srs);

  /// 重新从库里装载（模拟下次启动 / 另一个进程读同一个库）。
  Future<void> reload() async {
    repo.dispose();
    repo = PreferencesRepository(db);
    await repo.loadFromDb();
  }

  group('全新安装', () {
    test('判定前按老用户处理：Anki、复习关', () {
      expect(target(), SrsMiningTarget.anki);
      expect(srsModule(), isFalse);
    });

    test('无任何信号 → Fushi 复习 + 模块开；不写挖词目标本身，只记出厂默认', () async {
      await repo.settleSrsMiningTargetInstallDefault();
      expect(target(), SrsMiningTarget.srs);
      expect(srsModule(), isTrue);
      expect(repo.getPref(_marker), 'srs');
      expect(repo.getPref(_target), isNull, reason: '没选过就保持没选过');
      expect(
        repo.getPref(ModuleId.srs.prefKey),
        isNull,
        reason: '模块按出厂默认（开），不显式写',
      );
      await reload();
      expect(target(), SrsMiningTarget.srs, reason: '重启后同样');
      expect(srsModule(), isTrue);
    });

    test('只跑一次：首页随后写下 first_time_setup，下次启动不会被改判成老用户', () async {
      await repo.settleSrsMiningTargetInstallDefault();
      // 首启首帧（HomePage）与引导结束写的两个键——下次启动时就是「老用户信号」。
      await repo.setPref('first_time_setup', false);
      await repo.setOnboardingCompleted(value: true);
      await reload();
      await repo.settleSrsMiningTargetInstallDefault();
      expect(target(), SrsMiningTarget.srs);
      expect(srsModule(), isTrue);
      expect(repo.getPref(_marker), 'srs');
    });

    test('新手引导里导入了推荐包（设置随包整层替换）：包带来的设置信号不算数', () async {
      await repo.setPref('first_time_setup', false);
      await repo.setOnboardingCompleted(value: true);
      await repo.setPref('last_selected_deck', 'Pack deck');
      await repo.settleSrsMiningTargetInstallDefault(
        freshOnboardingPackImport: true,
      );
      expect(target(), SrsMiningTarget.srs);
      expect(srsModule(), isTrue);
    });
  });

  group('老用户（升级上来）', () {
    final Map<
      String,
      Future<void> Function(FushiDatabase, PreferencesRepository)
    >
    signals =
        <String, Future<void> Function(FushiDatabase, PreferencesRepository)>{
          'first_time_setup 已落盘': (_, PreferencesRepository r) =>
              r.setPref('first_time_setup', false),
          'onboarding_completed 已落盘': (_, PreferencesRepository r) =>
              r.setOnboardingCompleted(value: true),
          '选过 Anki 牌组': (_, PreferencesRepository r) =>
              r.setPref('last_selected_deck', 'Mining'),
          '选过 Anki 笔记类型': (_, PreferencesRepository r) =>
              r.setPref('last_selected_model', 'Lapis'),
          '有制卡历史': (FushiDatabase d, _) => d.customStatement(
            'INSERT INTO mined_sentences (source, date_key, created_at) '
            "VALUES ('book', '2026-10-01', 0)",
          ),
          '有待发 Anki 的卡': (FushiDatabase d, _) => d.customStatement(
            'INSERT INTO pending_mine_queue (id, created_at, expression) '
            "VALUES ('a1', 0, '猫')",
          ),
        };

    for (final MapEntry<
          String,
          Future<void> Function(FushiDatabase, PreferencesRepository)
        >
        e
        in signals.entries) {
      test('信号「${e.key}」→ Anki，复习模块显式写成关', () async {
        await e.value(db, repo);
        await repo.settleSrsMiningTargetInstallDefault();
        expect(target(), SrsMiningTarget.anki);
        expect(srsModule(), isFalse);
        expect(repo.getPref(_marker), 'anki');
        expect(repo.getPref(ModuleId.srs.prefKey), isFalse);
      });
    }

    test('推荐包回执也挡不住真实的制卡数据', () async {
      await signals['有制卡历史']!(db, repo);
      await repo.settleSrsMiningTargetInstallDefault(
        freshOnboardingPackImport: true,
      );
      expect(target(), SrsMiningTarget.anki);
      expect(srsModule(), isFalse);
    });

    test('幂等、只迁一次：之后自己打开复习 / 改选目标都不会被改回', () async {
      await repo.setPref('first_time_setup', false);
      await repo.settleSrsMiningTargetInstallDefault();
      expect(target(), SrsMiningTarget.anki);
      await repo.setModuleEnabled(ModuleId.srs, true);
      await repo.setSrsMiningTarget(SrsMiningTarget.srs.wire);
      await reload();
      await repo.settleSrsMiningTargetInstallDefault();
      expect(srsModule(), isTrue);
      expect(target(), SrsMiningTarget.srs);
      expect(repo.getPref(_marker), 'anki');
    });

    test('「老用户不提醒」：判定不碰引导 / 首启标记', () async {
      await repo.setPref('first_time_setup', false);
      await repo.setOnboardingCompleted(value: true);
      await repo.settleSrsMiningTargetInstallDefault();
      expect(repo.onboardingCompleted, isTrue);
      expect(repo.isFirstTimeSetup, isFalse);
    });
  });

  group('显式选过的值不被迁移改动', () {
    test('显式 srs + 老用户信号：目标仍是 srs', () async {
      await repo.setSrsMiningTarget('srs');
      await repo.setModuleEnabled(ModuleId.srs, true);
      await repo.setPref('first_time_setup', false);
      await repo.settleSrsMiningTargetInstallDefault();
      expect(target(), SrsMiningTarget.srs);
      expect(srsModule(), isTrue);
      expect(repo.getPref(_target), 'srs');
    });

    test('显式 anki + 无信号：目标仍是 anki', () async {
      await repo.setSrsMiningTarget('anki');
      await repo.settleSrsMiningTargetInstallDefault();
      expect(target(), SrsMiningTarget.anki);
      expect(repo.getPref(_target), 'anki');
    });

    test('存量退役值 both 读成 anki，迁移不改写它', () async {
      await repo.setSrsMiningTarget('both');
      await repo.settleSrsMiningTargetInstallDefault();
      expect(target(), SrsMiningTarget.anki);
      expect(repo.getPref(_target), 'both');
    });

    test('老用户显式关过 / 开过复习：模块开关原样保留', () async {
      await repo.setModuleEnabled(ModuleId.srs, true);
      await repo.setPref('first_time_setup', false);
      await repo.settleSrsMiningTargetInstallDefault();
      expect(srsModule(), isTrue);
    });
  });

  group('Profile 快照 / 备份恢复不被新默认误切', () {
    test('出厂默认标记不随 Profile 走，挖词目标随 Profile 走', () {
      expect(ProfileKeys.isExcludedPref(_marker), isTrue);
      expect(ProfileKeys.isExcludedPref(_target), isFalse);
    });

    test('老用户切到没有该键的老快照（live 键被删）→ 回落 Anki', () async {
      await repo.setPref('first_time_setup', false);
      await repo.settleSrsMiningTargetInstallDefault();
      await repo.setSrsMiningTarget('anki');
      // ProfileRepository.applyProfile 对「快照里没有的键」执行 deletePref。
      await db.deletePref(_target);
      await reload();
      expect(target(), SrsMiningTarget.anki);
    });

    test('新用户切到没有该键的快照 → 回落 Fushi 复习', () async {
      await repo.settleSrsMiningTargetInstallDefault();
      await repo.setSrsMiningTarget('anki');
      await db.deletePref(_target);
      await reload();
      expect(target(), SrsMiningTarget.srs);
    });

    test('整层恢复一份老备份（标记随之消失）：判定前读 Anki，重判仍是 Anki', () async {
      await repo.settleSrsMiningTargetInstallDefault();
      expect(target(), SrsMiningTarget.srs);
      // 老备份的 preferences 整层换进来：没有标记、没有挖词目标，带着老用户信号。
      await db.deletePref(_marker);
      await repo.setPref('first_time_setup', false);
      await reload();
      expect(target(), SrsMiningTarget.anki, reason: '重启前（:popup / 当前进程）');
      await repo.settleSrsMiningTargetInstallDefault();
      expect(target(), SrsMiningTarget.anki);
    });
  });

  test('fromWire：null = 新默认 srs；认不出的显式值 = anki', () {
    expect(SrsMiningTarget.fromWire(null), SrsMiningTarget.srs);
    expect(SrsMiningTarget.fromWire('both'), SrsMiningTarget.anki);
    expect(SrsMiningTarget.fromWire('garbage'), SrsMiningTarget.anki);
  });
}
