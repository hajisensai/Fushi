/// 复习远程刷卡的 host 侧（docs/specs/2026-11-01-srs-remote-review-design.md）。
///
/// 已配对的互联客户端不下载卡组，直接在本机复习上刷卡：排队、排程、模板渲染都在这里经 [SrsDbStore] 做，
/// 客户端只显示推过去的卡面、把评分交回来。路由在 `FushiSyncServer`（`/api/srs/review/*`），这里只管语义：
/// 出卡、作答（幂等 + 陈旧判定）、撤销、卡的线格式。
library;

import 'dart:collection';
import 'dart:typed_data';

import 'package:fushi_core/fushi_core.dart' show SrsCardCacheRow;
import 'package:fushi_engine/srs/srs_db_store.dart';
import 'package:fushi_srs/fushi_srs.dart';

/// host 在 `GET /api/capabilities` 声明的能力位。
const String kSrsRemoteReviewCapability = 'srsRemoteReviewV1';

/// 端点前缀（`POST <前缀>decks|next|answer|undo`、`GET <前缀>media/<名字>`）。
const String kSrsRemoteReviewPathPrefix = '/api/srs/review/';

/// 远程刷卡的失败：[code] 是给客户端的机读码，[status] 是 HTTP 状态。
class SrsRemoteReviewError implements Exception {
  const SrsRemoteReviewError(this.status, this.code);

  final int status;
  final String code;

  /// 出卡之后这张卡变了（别的设备 / host 自己复习过、被删、被挂起）。
  static const String stale = 'stale';

  /// host 期间切换了配置：答案不能记进另一份配置。
  static const String profileChanged = 'profile_changed';

  /// 复习模块没开 / 排程内核不可用。
  static const String unavailable = 'unavailable';

  /// 请求体不合契约。
  static const String badRequest = 'bad_request';

  /// 牌组不存在。
  static const String noDeck = 'no_deck';

  @override
  String toString() => 'SrsRemoteReviewError($status, $code)';
}

/// host 侧服务：每个请求现取当前配置的 [SrsDbStore]（配置切换 / 模块开关即时生效）。
class SrsRemoteReviewService {
  SrsRemoteReviewService({
    required Future<SrsDbStore?> Function() readStore,
    required Future<Uint8List?> Function(String name) readMedia,
    int idempotencyCapacity = 256,
  }) : _readStore = readStore,
       _readMedia = readMedia,
       _capacity = idempotencyCapacity;

  final Future<SrsDbStore?> Function() _readStore;
  final Future<Uint8List?> Function(String name) _readMedia;
  final int _capacity;

  /// 作答幂等缓存：客户端请求 id → 回包（最近 [_capacity] 次，按插入顺序淘汰）。
  final LinkedHashMap<String, Map<String, Object?>> _answered =
      LinkedHashMap<String, Map<String, Object?>>();

  /// 同一请求 id 并发重发时等第一次的结果，不各写一条日志。
  final Map<String, Future<Map<String, Object?>>> _inFlight =
      <String, Future<Map<String, Object?>>>{};

  Future<SrsDbStore> _store({String? expectedProfile}) async {
    final SrsDbStore? store = await _readStore();
    if (store == null || !store.canSchedule) {
      throw const SrsRemoteReviewError(503, SrsRemoteReviewError.unavailable);
    }
    if (expectedProfile != null && expectedProfile != store.profileUid) {
      throw const SrsRemoteReviewError(
        409,
        SrsRemoteReviewError.profileChanged,
      );
    }
    return store;
  }

  /// 牌组列表（含子树计数）。
  Future<Map<String, Object?>> decks() async {
    final SrsDbStore store = await _store();
    final List<SrsDeckSummary> decks = await store.deckSummaries();
    return <String, Object?>{
      'profile': store.profileUid,
      'decks': <Map<String, Object?>>[
        for (final SrsDeckSummary d in decks)
          <String, Object?>{
            'id': d.deck.id,
            'name': d.fullName,
            'depth': d.depth,
            ..._countsOf(d),
          },
      ],
    };
  }

  /// [deck] 的下一张与再下一张（客户端预取）；[exclude] 是客户端已经拿着的卡。
  Future<Map<String, Object?>> next({
    required String? profile,
    required String deck,
    Set<String> exclude = const <String>{},
  }) async {
    final SrsDbStore store = await _store(expectedProfile: profile);
    final SrsStudyState? study = await store.studyState(deck, exclude: exclude);
    if (study == null) {
      throw const SrsRemoteReviewError(404, SrsRemoteReviewError.noDeck);
    }
    return <String, Object?>{
      'profile': store.profileUid,
      ...await _studyPayload(store, study),
    };
  }

  /// 评分一张卡并排出之后的卡。[request] 由客户端生成，重发不变：同一 id 只记一次。
  Future<Map<String, Object?>> answer({
    required String? profile,
    required String request,
    required String deck,
    required String card,
    required String? base,
    required int rating,
    required int durationMs,
  }) {
    final Map<String, Object?>? done = _answered[request];
    if (done != null) return Future<Map<String, Object?>>.value(done);
    final Future<Map<String, Object?>>? running = _inFlight[request];
    if (running != null) return running;
    final Future<Map<String, Object?>> future = _answer(
      profile: profile,
      deck: deck,
      card: card,
      base: base,
      rating: rating,
      durationMs: durationMs,
    );
    _inFlight[request] = future;
    return future
        .then((Map<String, Object?> out) {
          _answered[request] = out;
          while (_answered.length > _capacity) {
            _answered.remove(_answered.keys.first);
          }
          return out;
        })
        .whenComplete(() => _inFlight.remove(request));
  }

  Future<Map<String, Object?>> _answer({
    required String? profile,
    required String deck,
    required String card,
    required String? base,
    required int rating,
    required int durationMs,
  }) async {
    if (rating < 1 || rating > 4) {
      throw const SrsRemoteReviewError(400, SrsRemoteReviewError.badRequest);
    }
    final SrsDbStore store = await _store(expectedProfile: profile);
    final SrsCardCacheRow? row = await store.cardRow(card);
    if (row == null || row.hidden || row.suspended || row.lastLogId != base) {
      throw const SrsRemoteReviewError(409, SrsRemoteReviewError.stale);
    }
    final SrsAnswerOutcome out = await store.answerAndStudy(
      card,
      rating,
      durationMs: durationMs.clamp(0, kSrsMaxAnswerDurationMs),
      studyDeckId: deck,
    );
    final SrsStudyState? study = out.study;
    return <String, Object?>{
      'profile': store.profileUid,
      'logId': out.log.id,
      if (study != null)
        ...await _studyPayload(store, study)
      else
        'cards': const <Object?>[],
    };
  }

  /// 撤销本会话记下的一条评分；它已不是该卡最后一条有效日志时 `ok: false`。成功时带回这张卡（重新出题）。
  Future<Map<String, Object?>> undo({
    required String? profile,
    required String card,
    required String log,
  }) async {
    final SrsDbStore store = await _store(expectedProfile: profile);
    final bool ok = await store.undo(card, log);
    final Map<String, Object?>? payload = ok
        ? await _cardPayload(store, card)
        : null;
    return <String, Object?>{
      'profile': store.profileUid,
      'ok': ok && payload != null,
      'card': ?payload,
    };
  }

  /// 卡面引用的媒体字节；名字不合法 / 不存在时 null。
  Future<Uint8List?> media(String name) => _readMedia(name);

  Map<String, Object?> _countsOf(SrsDeckSummary s) => <String, Object?>{
    'new': s.newCount,
    'learn': s.learnCount,
    'review': s.reviewCount,
  };

  Future<Map<String, Object?>> _studyPayload(
    SrsDbStore store,
    SrsStudyState study,
  ) async {
    final List<Map<String, Object?>> cards = <Map<String, Object?>>[];
    for (final String? id in <String?>[study.next, study.after]) {
      if (id == null) continue;
      final Map<String, Object?>? c = await _cardPayload(store, id);
      if (c != null) cards.add(c);
    }
    return <String, Object?>{
      'counts': _countsOf(study.summary),
      'rwkvPending': study.rwkvPending,
      'cards': cards,
    };
  }

  /// 一张卡的线格式（设计 §2）。卡已不在（同步删掉 / 空卡）时 null。
  Future<Map<String, Object?>?> _cardPayload(
    SrsDbStore store,
    String cardId,
  ) async {
    final SrsCardDetail? detail = await store.cardDetail(cardId);
    if (detail == null) return null;
    final SrsRenderedCard? rendered = await store.renderCard(
      cardId,
      detail: detail,
    );
    if (rendered == null) return null;
    final SrsAnswerPreview preview = await store.preview(cardId);
    final SrsDayContext day = await store.dayContext();
    // 牌组的「自动播放音频」（与本机复习页同一取法：卡所在牌组不在了按默认牌组）。
    final SrsDeckTree tree = await store.deckTree();
    final String deckId = tree[detail.card.deckId] != null
        ? detail.card.deckId
        : store.defaultDeckId;
    final bool autoplay = tree[deckId] == null
        ? true
        : tree.paramsOwner(deckId).autoplayAudio;
    return <String, Object?>{
      'id': cardId,
      'base': detail.card.lastLogId,
      'question': rendered.question,
      'answer': rendered.answer,
      'css': rendered.css,
      'isEmpty': rendered.isEmpty,
      'fields': rendered.fields,
      'definitions': ?rendered.fushiCardDefinitions,
      'builtinKey': ?detail.noteType.builtinKey,
      'deckName': detail.deckName,
      'plan': <Map<String, Object?>>[
        for (int r = 1; r <= 4; r++) preview.plan[r].toJson(),
      ],
      'nowMs': preview.nowMs,
      'today': day.dayIndexOf(preview.nowMs),
      'rwkv': preview.algorithm == SrsAlgorithm.rwkv,
      'autoplay': autoplay,
    };
  }
}
