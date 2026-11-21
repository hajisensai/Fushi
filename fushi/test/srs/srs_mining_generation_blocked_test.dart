// BUG-5085：挖词目标是 Fushi 复习、复习库在换代途中（要升级 / 别的窗口在升级 / 上次没升级完 / 要人处理）时，
// 制卡器解析不再把代际异常吞成 null：制卡失败带分类码，提示说「去复习页完成升级」并带「打开复习」，互联主机替
// 对端制卡把码回给对端，而不是笼统的「Fushi review is not available.」。
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/srs/srs_generation_kind.dart';
import 'package:fushi/src/srs/srs_mining.dart';
import 'package:fushi/src/sync/host_remote_mining_targets.dart';
import 'package:fushi/src/utils/components/fushi_mine_notice_card.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_engine/srs/srs_storage.dart'
    show SrsLegacyMainDatabasePending;
import 'package:fushi_engine/sync/remote_mining_target.dart';
import 'package:fushi_srs/fushi_srs.dart';

/// 内层 Anki 替身：记录落卡次数。
class _Anki extends BaseAnkiRepository {
  int mined = 0;

  @override
  Future<AnkiSettings> loadSettings() async => const AnkiSettings(
    availableDecks: <AnkiDeck>[AnkiDeck(id: 1, name: 'Mining')],
  );

  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      throw UnimplementedError();

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    mined++;
    return const MineOutcome.success(deckName: 'Mining');
  }

  @override
  Future<bool> isDuplicate(String expression, String reading) async => true;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;

  @override
  Future<bool> createDeck(String name) async => false;
}

String _payload() => jsonEncode(<String, Object?>{
  'expression': '雪',
  'reading': 'ゆき',
  'glossary': '<ol><li>snow</li></ol>',
});

const AnkiMiningContext _ctx = AnkiMiningContext(sentence: '雪が降る。');

const SrsStoreNotMigrated _needsMigration = SrsStoreNotMigrated(
  'not migrated',
  SrsGenState.needsMigration,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  LocaleSettings.setLocaleRaw('en');

  group('代际异常 → 制卡失败码（与代际状态页同一个分类）', () {
    test('四类按用户下一步分；非代际异常不算', () {
      expect(
        srsGenerationMineErrorCode(_needsMigration),
        AnkiErrorCode.srsNeedsMigration,
      );
      expect(
        srsGenerationMineErrorCode(
          const SrsStoreNotMigrated('x', SrsGenState.migrationFailed),
        ),
        AnkiErrorCode.srsMigrationFailed,
      );
      expect(
        srsGenerationMineErrorCode(
          const SrsStoreNotMigrated('x', SrsGenState.migratingElsewhere),
        ),
        AnkiErrorCode.srsMigrating,
      );
      expect(
        srsGenerationMineErrorCode(const SrsStoreMigrating('x')),
        AnkiErrorCode.srsMigrating,
      );
      expect(
        srsGenerationMineErrorCode(
          const SrsStoreNotMigrated('x', SrsGenState.sealedOldOnly),
        ),
        AnkiErrorCode.srsNeedsAttention,
      );
      expect(
        srsGenerationMineErrorCode(const SrsStoreLegacyUnmigrated('x')),
        AnkiErrorCode.srsNeedsAttention,
      );
      expect(
        srsGenerationMineErrorCode(const SrsLegacyMainDatabasePending()),
        AnkiErrorCode.srsNeedsAttention,
      );
      expect(srsGenerationMineErrorCode(StateError('broken')), isNull);
      expect(isSrsGenerationBlocked(StateError('broken')), isFalse);
      for (final String code in <String>[
        AnkiErrorCode.srsNeedsMigration,
        AnkiErrorCode.srsMigrationFailed,
        AnkiErrorCode.srsMigrating,
        AnkiErrorCode.srsNeedsAttention,
      ]) {
        expect(isSrsGenerationErrorCode(code), isTrue, reason: code);
      }
      expect(isSrsGenerationErrorCode(AnkiErrorCode.httpError), isFalse);
    });
  });

  group('SrsMiningAnkiRepository：解析器抛代际异常', () {
    SrsMiningAnkiRepository repoThrowing(
      Exception error, {
      _Anki? inner,
      bool background = false,
    }) => SrsMiningAnkiRepository(
      inner: inner ?? _Anki(),
      miner: () async => throw error,
      backgroundMining: background ? () => true : null,
    );

    test('制卡回带分类码的失败，提示说去复习页升级（不再是「复习不可用」），不落回 Anki', () async {
      final _Anki inner = _Anki();
      final MineOutcome out = await repoThrowing(
        _needsMigration,
        inner: inner,
      ).mineEntry(rawPayloadJson: _payload(), context: _ctx);
      expect(out.result, MineResult.error);
      expect(out.errorCode, AnkiErrorCode.srsNeedsMigration);
      expect(out.error, same(_needsMigration));
      expect(mineFailureMessage(out), t.srs_mining_error_needs_migration);
      expect(
        mineFailureMessage(out),
        isNot(contains('Fushi review is not available')),
      );
      expect(inner.mined, 0);
    });

    test('后台制卡开着也当场报失败，不回「已入队」', () async {
      final MineOutcome out = await repoThrowing(
        const SrsStoreMigrating('busy'),
        background: true,
      ).mineEntry(rawPayloadJson: _payload(), context: _ctx);
      expect(out.result, MineResult.error);
      expect(out.errorCode, AnkiErrorCode.srsMigrating);
      expect(mineFailureMessage(out), t.srs_mining_error_migrating);
    });

    test('覆写同样回分类码', () async {
      final MineOutcome out = await repoThrowing(
        const SrsStoreNotMigrated('x', SrsGenState.migrationFailed),
      ).updateMinedNote(noteId: 1, rawPayloadJson: _payload(), context: _ctx);
      expect(out.errorCode, AnkiErrorCode.srsMigrationFailed);
      expect(mineFailureMessage(out), t.srs_mining_error_migration_failed);
    });

    test('每次查词跑的探测与复习不可用同一个答案（不重复 / 没有），不抛', () async {
      final SrsMiningAnkiRepository repo = repoThrowing(_needsMigration);
      expect(await repo.isDuplicate('雪', 'ゆき'), isFalse);
      expect(await repo.findMatchingNotes('雪', 'ゆき'), isEmpty);
      expect(await repo.noteFields(1), isNull);
      expect(await repo.findDeletedNotes(<int>{1}), isEmpty);
      expect(await repo.openNoteInAnki(1), isFalse);
    });

    test('一定要读写复习的操作把代际异常原样抛给调用方（看得到真正的原因）', () async {
      final SrsMiningAnkiRepository repo = repoThrowing(_needsMigration);
      await expectLater(
        repo.deleteMinedNote(1),
        throwsA(same(_needsMigration)),
      );
      await expectLater(
        repo.listNewCards('Default'),
        throwsA(same(_needsMigration)),
      );
    });

    test('非代际的失败照旧：解析器回 null = 复习不可用（不带分类码）', () async {
      final SrsMiningAnkiRepository repo = SrsMiningAnkiRepository(
        inner: _Anki(),
        miner: () async => null,
      );
      final MineOutcome out = await repo.mineEntry(
        rawPayloadJson: _payload(),
        context: _ctx,
      );
      expect(out.result, MineResult.error);
      expect(out.errorCode, isNull);
    });
  });

  group('提示上的「打开复习」', () {
    tearDown(() => mineFailureOpenReview = null);

    MineOutcome failureFor(Object error) =>
        srsGenerationMineFailure(error, StackTrace.current);

    test('要升级 / 上次没升级完 / 要人处理：带「打开复习」，点下去走装上的入口', () {
      int opened = 0;
      mineFailureOpenReview = () => opened++;
      for (final Object e in <Object>[
        _needsMigration,
        const SrsStoreNotMigrated('x', SrsGenState.migrationFailed),
        const SrsLegacyMainDatabasePending(),
      ]) {
        final MineNoticeAction? action = mineFailureToastAction(failureFor(e));
        expect(action, isNotNull, reason: '$e');
        expect(action!.label, t.srs_mining_open_review);
        action.onPressed();
      }
      expect(opened, 3);
    });

    test('正在升级（等它完成就行）、其它失败、成功：不带', () {
      mineFailureOpenReview = () {};
      expect(
        mineFailureToastAction(failureFor(const SrsStoreMigrating('x'))),
        isNull,
      );
      expect(mineFailureToastAction(MineOutcome.failure('boom')), isNull);
      expect(mineFailureToastAction(const MineOutcome.success()), isNull);
    });

    test('没装入口（弹窗 / 查词窗进程）：不带', () {
      expect(mineFailureToastAction(failureFor(_needsMigration)), isNull);
    });
  });

  group('互联主机替对端制卡（HostRemoteMiningTargets）', () {
    HostRemoteMiningTargets targetsBlockedBy(Exception error, _Anki anki) =>
        HostRemoteMiningTargets(
          defaultKind: () => kRemoteMiningKindReview,
          defaultRepository: () => SrsMiningAnkiRepository(
            inner: anki,
            miner: () async => throw error,
          ),
          ankiRepository: () => anki,
          reviewCatalog: () async => throw error,
          reviewRepository: (String uid) async => null,
          reviewMiner: (String uid) async => throw error,
          toResult: remoteMineResultFromOutcome,
        );

    test('点名复习：回机读分类码，不悄悄退回 Anki', () async {
      final _Anki anki = _Anki();
      final RemoteMineLanding landing =
          await targetsBlockedBy(_needsMigration, anki).mine(
            const RemoteMiningTarget(kind: kRemoteMiningKindReview),
            rawPayloadJson: _payload(),
            context: _ctx,
          );
      expect(landing.result.result, MineResult.error.name);
      expect(landing.result.errorCode, AnkiErrorCode.srsNeedsMigration);
      expect(landing.result.message, t.srs_mining_error_needs_migration);
      expect(anki.mined, 0);
    });

    test('不带 target（老客户端）走主机默认那条链：同样回分类码', () async {
      final _Anki anki = _Anki();
      final RemoteMineLanding landing = await targetsBlockedBy(
        const SrsStoreMigrating('busy'),
        anki,
      ).mine(null, rawPayloadJson: _payload(), context: _ctx);
      expect(landing.result.errorCode, AnkiErrorCode.srsMigrating);
      expect(anki.mined, 0);
    });

    test('点名 Anki：复习库在换代途中不挡 Anki', () async {
      final _Anki anki = _Anki();
      final RemoteMineLanding landing =
          await targetsBlockedBy(_needsMigration, anki).mine(
            const RemoteMiningTarget(
              kind: kRemoteMiningKindAnki,
              deck: 'Mining',
            ),
            rawPayloadJson: _payload(),
            context: _ctx,
          );
      expect(landing.result.result, MineResult.success.name);
      expect(anki.mined, 1);
    });

    test('列「保存到」与查重不因代际异常失败', () async {
      final HostRemoteMiningTargets targets = targetsBlockedBy(
        _needsMigration,
        _Anki(),
      );
      final Map<String, Object?> listed = await targets.targets();
      expect(listed['review'], isEmpty);
      expect(
        await targets.isDuplicate(
          const RemoteMiningTarget(kind: kRemoteMiningKindReview),
          expression: '雪',
          reading: 'ゆき',
        ),
        isFalse,
      );
    });
  });
}
