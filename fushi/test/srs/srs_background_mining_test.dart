// 反馈 Rl00Di264R：挖词目标 = Fushi 复习时的「后台制卡」。制卡请求冻结进进程级
// 后台队列、立即回 queued；卡片随后在后台按入队顺序依次写进复习；后台的失败 / 重复
// 经结果出口交出去（不静默丢）；开关关着时行为与以前逐字一致（同步写、回句柄）。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fushi_engine/srs/srs_miner.dart';
import 'package:fushi_engine/srs/srs_media_store.dart';
import 'package:fushi/src/srs/srs_mining.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/srs/srs_builtin.dart';
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

import 'srs_test_support.dart';

/// 内层 Anki 仓库：只提供设置；复习模式下制卡不该落到这里。
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

String _payload(String expression, String reading) =>
    jsonEncode(<String, Object?>{
      'expression': expression,
      'reading': reading,
      'glossary': '<ol><li>snow</li></ol>',
      'glossaryFirst': '<ol><li>snow</li></ol>',
      'audio': '',
    });

void main() {
  late Directory tmp;
  late FushiDatabase db;
  late SrsDbStore store;
  late SrsMediaStore media;
  late _SettingsOnlyAnki inner;
  late List<(String, MineOutcome)> reported;
  late bool background;

  String fid(String key) => srsFushiCardFieldId(kSrsTestProfile, key);

  setUp(() async {
    SrsMiningAnkiRepository.debugResetBackgroundQueue();
    tmp = Directory.systemTemp.createTempSync('fushi_srs_bg_mining_');
    (db, store) = await openSrsTestStore();
    media = SrsMediaStore(Directory('${tmp.path}/srs_media/$kSrsTestProfile'));
    inner = _SettingsOnlyAnki();
    reported = <(String, MineOutcome)>[];
    background = true;
  });

  tearDown(() async {
    await SrsMiningAnkiRepository.debugBackgroundIdle();
    await db.close();
    tmp.deleteSync(recursive: true);
  });

  SrsMiningAnkiRepository repo() => SrsMiningAnkiRepository(
    inner: inner,
    miner: () async => SrsMiner(store: store, media: media),
    backgroundMining: () => background,
    onBackgroundOutcome: (String expression, MineOutcome outcome) =>
        reported.add((expression, outcome)),
  );

  Future<Map<String, SrsTermStatus>> statusOf(String expression) =>
      store.lookupTermStatus(<SrsTermQuery>[SrsTermQuery(expression)]);

  test('入队即返回：后台还没轮到时 mineEntry 已回 queued（带落点牌组），调用方随即删掉临时封面'
      '也不影响后台写进复习', () async {
    // 挂住后台队列：前面有一个没做完的任务（上一张卡还在写）。
    final Completer<void> gate = Completer<void>();
    unawaited(
      SrsMiningAnkiRepository.debugBackgroundQueue.enqueue<void>(
        () => gate.future,
        buildFailure: (Object error, StackTrace stack) {},
      ),
    );
    final File cover = File('${tmp.path}/shot.png')
      ..writeAsBytesSync(<int>[1, 2, 3, 4]);

    final MineOutcome out = await repo().mineEntry(
      rawPayloadJson: _payload('雪', 'ゆき'),
      context: AnkiMiningContext(sentence: '雪が降る。', coverPath: cover.path),
    );

    expect(out.result, MineResult.queued, reason: '后台队列被挂住时制卡也必须立即返回');
    expect(
      out.deckName,
      isNotNull,
      reason: 'queued 带落点牌组 = 本机后台写入，不是 Anki 待发卡片',
    );
    expect(await statusOf('雪'), isEmpty, reason: '还没轮到，复习里不该已有这张卡');
    expect(reported, isEmpty);
    // 调用方在 mineEntry 返回后就清理临时媒体（ImmersionMiningEngine / gal 协调器都这样做）。
    cover.deleteSync();

    gate.complete();
    await SrsMiningAnkiRepository.debugBackgroundIdle();

    final Map<String, SrsTermStatus> hit = await statusOf('雪');
    expect(hit, contains('雪'));
    final SrsNoteView note = (await store.note(hit['雪']!.noteId))!;
    expect(note.field(fid('Expression')), '雪');
    final String coverName = SrsMediaStore.contentName('x.png', <int>[
      1,
      2,
      3,
      4,
    ]);
    expect(note.field(fid('Picture')), contains('src="$coverName"'));
    expect(await media.load(coverName), <int>[
      1,
      2,
      3,
      4,
    ], reason: '封面在入队时已冻结成字节，临时文件删了照样落盘');
    expect(reported, hasLength(1));
    expect(reported.single.$1, '雪');
    expect(reported.single.$2.result, MineResult.success);
    expect(inner.mined, 0, reason: '目标是 Fushi 复习，不碰 Anki');
  });

  test('后台串行、按入队顺序写；同一个词连挖两次，第二张在后台判重复并经结果出口交出', () async {
    final SrsMiningAnkiRepository r = repo();
    final List<MineOutcome> immediate = <MineOutcome>[
      await r.mineEntry(
        rawPayloadJson: _payload('上手', 'じょうず'),
        context: const AnkiMiningContext(sentence: ''),
      ),
      await r.mineEntry(
        rawPayloadJson: _payload('上手', 'じょうず'),
        context: const AnkiMiningContext(sentence: ''),
      ),
      await r.mineEntry(
        rawPayloadJson: _payload('下手', 'へた'),
        context: const AnkiMiningContext(sentence: ''),
      ),
    ];
    expect(
      immediate.map((MineOutcome o) => o.result),
      everyElement(MineResult.queued),
    );
    await SrsMiningAnkiRepository.debugBackgroundIdle();

    expect(reported.map(((String, MineOutcome) e) => e.$1), <String>[
      '上手',
      '上手',
      '下手',
    ], reason: '后台按入队顺序逐张写');
    expect(reported.map(((String, MineOutcome) e) => e.$2.result), <MineResult>[
      MineResult.success,
      MineResult.duplicate,
      MineResult.success,
    ], reason: '第二张在后台查重命中：必须交出来提示，不能静默丢');
    expect((await statusOf('上手'))['上手']!.cardCount, 1);
    expect(await statusOf('下手'), contains('下手'));
  });

  test('后台写入失败可见：失败结果经出口交出，队列不被毒化，下一张照常写', () async {
    final SrsMiningAnkiRepository r = repo();
    // 第一字段为空：复习拒建（与同步制卡同一条规则），只能在后台那一步发现。
    final MineOutcome bad = await r.mineEntry(
      rawPayloadJson: _payload('', ''),
      context: const AnkiMiningContext(sentence: '句子'),
    );
    final MineOutcome good = await r.mineEntry(
      rawPayloadJson: _payload('雨', 'あめ'),
      context: const AnkiMiningContext(sentence: ''),
    );
    expect(bad.result, MineResult.queued);
    expect(good.result, MineResult.queued);
    await SrsMiningAnkiRepository.debugBackgroundIdle();

    expect(reported, hasLength(2));
    expect(reported[0].$1, '句子', reason: '词条取不到时用句子提示是哪一张');
    expect(reported[0].$2.result, MineResult.error);
    expect(reported[0].$2.errorCode, AnkiErrorCode.firstFieldEmpty);
    expect(reported[1].$2.result, MineResult.success);
    expect(await statusOf('雨'), contains('雨'));
  });

  test('开关关着：同步写进复习、回笔记句柄，不经后台队列', () async {
    background = false;
    final MineOutcome out = await repo().mineEntry(
      rawPayloadJson: _payload('雪', 'ゆき'),
      context: const AnkiMiningContext(sentence: ''),
    );
    expect(out.result, MineResult.success);
    expect(out.noteId, isNotNull, reason: '同步路径照旧回句柄（弹窗可立即覆写 / 撤销）');
    expect(await statusOf('雪'), contains('雪'));
    expect(reported, isEmpty, reason: '同步结果直接回给调用方，不走后台出口');
  });

  test('没接开关（互联主机替对端制卡 / 浏览器扩展）：恒同步', () async {
    final SrsMiningAnkiRepository r = SrsMiningAnkiRepository(
      inner: inner,
      miner: () async => SrsMiner(store: store, media: media),
    );
    final MineOutcome out = await r.mineEntry(
      rawPayloadJson: _payload('雪', 'ゆき'),
      context: const AnkiMiningContext(sentence: ''),
    );
    expect(out.result, MineResult.success);
  });

  test('复习不可用：入队前就报失败，不回假的 queued', () async {
    final SrsMiningAnkiRepository r = SrsMiningAnkiRepository(
      inner: inner,
      miner: () async => null,
      backgroundMining: () => true,
      onBackgroundOutcome: (String e, MineOutcome o) => reported.add((e, o)),
    );
    final MineOutcome out = await r.mineEntry(
      rawPayloadJson: _payload('雪', 'ゆき'),
      context: const AnkiMiningContext(sentence: ''),
    );
    expect(out.result, MineResult.error);
    expect(reported, isEmpty);
  });
}
