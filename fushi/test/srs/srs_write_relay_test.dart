// BUG-5542：Android `:popup` 查词窗 / 第二块屏面板按 Secondary 只读打开复习库（拍板 D10），制卡直接在本进程写
// 报 SrsCoreReadOnlyException。修法补上 D10 的另一半——写入转交主进程：辅助进程的 SrsMiningAnkiRepository 用
// RelaySrsNoteWriter 把请求（冻结的载荷 + 配置副本 + 落点 + 设置）交给主进程的 SrsWriteRelayHost，在 Primary 上写、
// 原样带回结果。这里在同一个测试进程里对同一个库目录开 Primary（主进程）与 Secondary（辅助进程），传输换成
// 同进程的 JSON 往返（与 MethodChannel / Binder 一样只传 JSON）。
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart'
    show DatabaseConnectionUser, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/srs/srs_mining.dart';
import 'package:fushi/src/srs/srs_storage_host.dart';
import 'package:fushi/src/srs/srs_write_relay.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_engine/srs/srs_media_store.dart';
import 'package:fushi_engine/srs/srs_miner.dart';
import 'package:fushi_engine/srs/srs_mining_target.dart';
import 'package:fushi_engine/srs/srs_storage.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'srs_test_support.dart';

/// 内层 Anki 仓库：只提供设置；复习模式下写入不该落到这里。
class _SettingsOnlyAnki extends BaseAnkiRepository {
  int mined = 0;

  @override
  Future<AnkiSettings> loadSettings() async => const AnkiSettings();

  @override
  Future<AnkiFetchResult> fetchConfiguration() async =>
      throw UnimplementedError();

  @override
  Future<MineOutcome> mineEntry({
    required String rawPayloadJson,
    required AnkiMiningContext context,
  }) async {
    mined++;
    return const MineOutcome.success();
  }

  @override
  Future<bool> isDuplicate(String expression, String reading) async => false;

  @override
  Future<bool> createNoteType(AnkiNoteTypeTemplate template) async => false;

  @override
  Future<bool> createDeck(String name) async => false;
}

/// 辅助进程取定的落点（内置笔记类型不读字段映射，这里只用来认出「主进程按的是这一份」）。
const SrsMiningDestination _popupDestination = SrsMiningDestination(
  fieldMappingsByType: <String, Map<String, String>>{
    'probe': <String, String>{'f': '{expression}'},
  },
);

String _payload(String expression, String reading, {String gloss = 'snow'}) =>
    jsonEncode(<String, Object?>{
      'expression': expression,
      'reading': reading,
      'glossary': '<ol><li>$gloss</li></ol>',
      'glossaryFirst': '<ol><li>$gloss</li></ol>',
      'audio': '',
    });

/// 同进程的「跨进程」传输：请求与回包都过一遍 JSON（与 MethodChannel / Binder 上传的东西一样）。
SrsWriteRelayTransport _jsonTransport(SrsWriteRelayHost host) =>
    (Map<String, Object?> request) async {
      final Map<String, Object?> decoded =
          (jsonDecode(jsonEncode(request)) as Map<Object?, Object?>)
              .cast<String, Object?>();
      final Map<String, Object?> reply = await host.handle(decoded);
      return (jsonDecode(jsonEncode(reply)) as Map<Object?, Object?>)
          .cast<String, Object?>();
    };

void main() {
  late Directory tmp;
  late FushiDatabase db;
  late SrsStorage primaryStorage;
  late SrsStorage secondaryStorage;
  late SrsDbStore primary;
  late SrsDbStore secondary;
  late SrsMediaStore media;
  late _SettingsOnlyAnki inner;
  late List<(String, SrsMiningDestination)> resolved;
  late int written;

  String fid(String key) => srsFushiCardFieldId(kSrsTestProfile, key);

  setUp(() async {
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    tmp = Directory.systemTemp.createTempSync('fushi_srs_relay_');
    db = FushiDatabase.forTesting(NativeDatabase.memory());
    // 主进程：Primary，建库、建身份。
    primaryStorage = await SrsStorage.open(directory: tmp.path);
    primary = await SrsDbStore.open(
      core: primaryStorage.core,
      profileUid: kSrsTestProfile,
      deviceId: 'dev',
      engine: const SrsTestEngine(),
    );
    // 辅助进程：同一个目录按 Secondary 只读打开。
    secondaryStorage = await SrsStorage.open(
      directory: tmp.path,
      mode: SrsOpenMode.secondary,
    );
    secondary = await SrsDbStore.open(
      core: secondaryStorage.core,
      profileUid: kSrsTestProfile,
      deviceId: 'dev',
      engine: const SrsTestEngine(),
    );
    media = SrsMediaStore(Directory('${tmp.path}/srs_media/$kSrsTestProfile'));
    inner = _SettingsOnlyAnki();
    resolved = <(String, SrsMiningDestination)>[];
    written = 0;
  });

  tearDown(() async {
    await secondaryStorage.close();
    await primaryStorage.close();
    await db.close();
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // 句柄尚未释放；临时目录留给系统清理。
    }
  });

  SrsWriteRelayHost host() => SrsWriteRelayHost(
    resolveMiner: (String uid, SrsMiningDestination destination) async {
      resolved.add((uid, destination));
      return SrsMiner(store: primary, media: media, destination: destination);
    },
    onWritten: () => written++,
  );

  /// 辅助进程的制卡链：读在 Secondary 上，写经 [writer]。
  SrsMiningAnkiRepository popupRepo(SrsNoteWriter writer) =>
      SrsMiningAnkiRepository(
        inner: inner,
        miner: () async => SrsMiner(
          store: secondary,
          media: media,
          destination: _popupDestination,
        ),
        writer: writer,
      );

  RelaySrsNoteWriter relay(SrsWriteRelayHost h) => RelaySrsNoteWriter(
    transport: _jsonTransport(h),
    spoolDirectory: () async => Directory('${tmp.path}/spool'),
  );

  Future<Map<String, SrsTermStatus>> statusIn(
    SrsDbStore store,
    String expression,
  ) => store.lookupTermStatus(<SrsTermQuery>[SrsTermQuery(expression)]);

  test('复现：辅助进程在只读库上本地写，制卡失败报只读（修前 :popup 的行为）', () async {
    final MineOutcome out = await popupRepo(const LocalSrsNoteWriter())
        .mineEntry(
          rawPayloadJson: _payload('雪', 'ゆき'),
          context: const AnkiMiningContext(sentence: '雪が降る。'),
        );
    expect(out.result, MineResult.error);
    expect(out.errorDetail, contains('read-only'));
    expect(await statusIn(primary, '雪'), isEmpty);
  });

  test('转交：辅助进程的制卡在主进程的 Primary 上写成，结果原样带回；辅助进程随即读得到、查重为真', () async {
    final File cover = File('${tmp.path}/shot.png')
      ..writeAsBytesSync(<int>[1, 2, 3, 4]);
    final SrsWriteRelayHost h = host();
    final SrsMiningAnkiRepository repo = popupRepo(relay(h));

    final MineOutcome out = await repo.mineEntry(
      rawPayloadJson: _payload('雪', 'ゆき'),
      context: AnkiMiningContext(sentence: '雪が降る。', coverPath: cover.path),
    );

    expect(out.result, MineResult.success, reason: '${out.errorDetail}');
    expect(out.noteId, isNotNull, reason: '带回句柄：覆写 / 撤回要用');
    expect(out.deckName, isNotNull, reason: '成功提示「已添加到『…』」要牌组名');
    expect(written, 1, reason: '主进程写完要刷新它的牌组列表 / 计数');
    expect(resolved.single.$1, kSrsTestProfile, reason: '按辅助进程取定的配置副本写');
    expect(
      resolved.single.$2,
      _popupDestination,
      reason: '按辅助进程取定的落点写（它按自己的作品会话 / 激活配置算好）',
    );
    final Map<String, SrsTermStatus> hit = await statusIn(primary, '雪');
    expect(hit, contains('雪'));
    final SrsNoteView note = (await primary.note(hit['雪']!.noteId))!;
    expect(note.field(fid('Sentence')), contains('降る'));
    final String coverName = SrsMediaStore.contentName('x.png', <int>[
      1,
      2,
      3,
      4,
    ]);
    expect(
      note.field(fid('Picture')),
      contains('src="$coverName"'),
      reason: '媒体经冻结的载荷带过去',
    );
    expect(
      await repo.isDuplicate('雪', 'ゆき'),
      isTrue,
      reason: '辅助进程的只读库看得到主进程的提交',
    );
    expect(inner.mined, 0, reason: '目标是 Fushi 复习，不碰 Anki');
    expect(
      Directory('${tmp.path}/spool').listSync(),
      isEmpty,
      reason: '转交用的载荷文件用完即删',
    );

    // 重复：主进程判重复，辅助进程收到的就是重复（提示与以前一致）。
    final MineOutcome again = await repo.mineEntry(
      rawPayloadJson: _payload('雪', 'ゆき'),
      context: const AnkiMiningContext(sentence: '雪が降る。'),
    );
    expect(again.result, MineResult.duplicate);
  });

  test('转交：覆写已有卡、撤回制卡都在主进程上执行', () async {
    final SrsWriteRelayHost h = host();
    final SrsMiningAnkiRepository repo = popupRepo(relay(h));
    final MineOutcome mined = await repo.mineEntry(
      rawPayloadJson: _payload('雪', 'ゆき'),
      context: const AnkiMiningContext(sentence: '雪が降る。'),
    );
    expect(mined.result, MineResult.success, reason: '${mined.errorDetail}');
    final String id = (await statusIn(primary, '雪'))['雪']!.noteId;

    final MineOutcome overwritten = await repo.updateMinedNote(
      noteId: mined.noteId!,
      rawPayloadJson: _payload('雪', 'ゆき', gloss: 'snowfall'),
      context: const AnkiMiningContext(sentence: '雪が積もる。'),
    );
    expect(
      overwritten.result,
      MineResult.success,
      reason: '${overwritten.errorDetail}',
    );
    expect(overwritten.noteId, mined.noteId);
    final SrsNoteView after = (await primary.note(id))!;
    expect(after.field(fid('Sentence')), contains('積もる'));
    expect(after.field(fid('Glossary')), contains('snowfall'));
    expect(await repo.findMatchingNotes('雪', 'ゆき'), hasLength(1));

    expect(await repo.deleteMinedNote(mined.noteId!), isTrue);
    expect((await primary.note(id))?.deletedAt, isNotNull);
    expect(await repo.isDuplicate('雪', 'ゆき'), isFalse);
  });

  test('主进程的库在换代途中：带回带分类码的失败（提示去复习页升级），不报笼统错误', () async {
    final SrsWriteRelayHost h = SrsWriteRelayHost(
      resolveMiner: (String uid, SrsMiningDestination d) async =>
          throw const SrsStoreNotMigrated('x', SrsGenState.needsMigration),
    );
    final MineOutcome out = await popupRepo(relay(h)).mineEntry(
      rawPayloadJson: _payload('雪', 'ゆき'),
      context: const AnkiMiningContext(sentence: ''),
    );
    expect(out.result, MineResult.error);
    expect(out.errorCode, AnkiErrorCode.srsNeedsMigration);
  });

  test('主进程不可达（传输失败）：明确失败，不静默', () async {
    final RelaySrsNoteWriter writer = RelaySrsNoteWriter(
      transport: (Map<String, Object?> request) async =>
          throw StateError('main process unreachable'),
      spoolDirectory: () async => Directory('${tmp.path}/spool'),
    );
    final MineOutcome out = await popupRepo(writer).mineEntry(
      rawPayloadJson: _payload('雪', 'ゆき'),
      context: const AnkiMiningContext(sentence: ''),
    );
    expect(out.result, MineResult.error);
    expect(out.errorDetail, contains('main process unreachable'));
    expect(Directory('${tmp.path}/spool').listSync(), isEmpty);
  });

  test('MineOutcome 往返：结果、句柄、牌组名、警告、分类码都保留', () {
    final MineOutcome s = decodeMineOutcome(
      encodeMineOutcome(
        const MineOutcome.success(
          noteId: 42,
          deckName: 'D',
          audioWarning: 'w',
          notice: 'n',
        ),
      ),
    );
    expect(s.result, MineResult.success);
    expect(s.noteId, 42);
    expect(s.deckName, 'D');
    expect(s.audioWarning, 'w');
    expect(s.notice, 'n');
    final MineOutcome f = decodeMineOutcome(
      encodeMineOutcome(
        MineOutcome.failure(
          'detail',
          errorCode: AnkiErrorCode.srsMigrating,
          error: StateError('boom'),
        ),
      ),
    );
    expect(f.result, MineResult.error);
    expect(f.errorDetail, 'detail');
    expect(f.errorCode, AnkiErrorCode.srsMigrating);
    expect('${f.error}', contains('boom'));
    expect(
      decodeMineOutcome(
        encodeMineOutcome(const MineOutcome.duplicate()),
      ).result,
      MineResult.duplicate,
    );
  });

  test('落点往返', () {
    const SrsMiningDestination d = SrsMiningDestination(
      deckId: 'deck',
      noteTypeId: 'type',
      fieldMappingsByType: <String, Map<String, String>>{
        'type': <String, String>{'f1': '{expression}'},
      },
    );
    expect(
      decodeSrsMiningDestination(
        jsonDecode(jsonEncode(encodeSrsMiningDestination(d))),
      ),
      d,
    );
  });

  test(
    'SrsStorageHost：主进程每次按 Primary 开库之前先等 beforePrimaryOpen；辅助进程不等；它失败则这次打开失败、不缓存',
    () async {
      final List<String> events = <String>[];
      int claims = 0;
      SrsStorageHost hostFor(bool mainProcess) => SrsStorageHost(
        dbDirectory: 'D:/data/db',
        isMainProcess: mainProcess,
        legacyDatabase: () => db,
        beforePrimaryOpen: () async {
          claims++;
          events.add('claim');
          if (claims == 1) throw StateError('claim failed');
        },
        opener:
            ({
              required String directory,
              required SrsOpenMode mode,
              DatabaseConnectionUser? legacy,
            }) async {
              events.add('open:${mode.name}');
              throw const SrsStoreNotMigrated('x', SrsGenState.needsMigration);
            },
      );
      final SrsStorageHost mainHost = hostFor(true);
      await expectLater(mainHost.acquire(), throwsA(isA<StateError>()));
      expect(events, <String>['claim'], reason: '交接没完成就不开库');
      await expectLater(
        mainHost.acquire(),
        throwsA(isA<SrsStoreNotMigrated>()),
      );
      expect(events, <String>['claim', 'claim', 'open:primary']);

      events.clear();
      final SrsStorageHost popupHost = SrsStorageHost(
        dbDirectory: 'D:/data/db',
        isMainProcess: false,
        legacyDatabase: () => db,
        beforePrimaryOpen: () async => events.add('claim'),
        opener:
            ({
              required String directory,
              required SrsOpenMode mode,
              DatabaseConnectionUser? legacy,
            }) async {
              events.add('open:${mode.name}');
              throw const SrsStoreNotMigrated('x', SrsGenState.ready);
            },
      );
      expect(await popupHost.acquire(), isNull);
      expect(events, <String>['open:secondary']);
    },
  );
}
