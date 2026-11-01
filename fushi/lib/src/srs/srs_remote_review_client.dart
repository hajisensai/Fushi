/// 复习远程刷卡的客户端（docs/specs/2026-11-01-srs-remote-review-design.md）：在已配对电脑的复习上
/// 出卡 / 作答 / 撤销，卡面媒体按名字拉进本机缓存（[SrsRemoteMediaStore]）。
library;

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_engine/srs/srs_db_store.dart' show SrsRenderedCard;
import 'package:fushi_engine/srs/srs_remote_review.dart'
    show kSrsRemoteReviewCapability, kSrsRemoteReviewPathPrefix;
import 'package:fushi_srs/fushi_srs.dart'
    show
        SrsAnswerPlan,
        SrsIntervalUnit,
        SrsQueue,
        SrsScheduleResult,
        srsIntervalParts;
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

import 'package:fushi/src/srs/srs_card_media.dart' show srsCardReferencedMedia;
import 'package:fushi/src/srs/srs_media_store.dart';
import 'package:fushi/src/sync/interconnect_host_client.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/sync/video_remote_targets.dart';

export 'package:fushi_engine/srs/srs_remote_review.dart'
    show SrsRemoteReviewError;

/// 一个牌组（含子树计数）。
class SrsRemoteDeck {
  const SrsRemoteDeck({
    required this.id,
    required this.name,
    required this.depth,
    required this.counts,
  });

  final String id;
  final String name;
  final int depth;
  final SrsRemoteCounts counts;

  static SrsRemoteDeck fromJson(Map<String, dynamic> json) => SrsRemoteDeck(
    id: json['id'] as String,
    name: json['name'] as String,
    depth: (json['depth'] as num?)?.toInt() ?? 0,
    counts: SrsRemoteCounts.fromJson(json),
  );
}

/// 新卡 / 学习 / 到期数。
class SrsRemoteCounts {
  const SrsRemoteCounts({
    required this.newCount,
    required this.learnCount,
    required this.reviewCount,
  });

  final int newCount;
  final int learnCount;
  final int reviewCount;

  int get total => newCount + learnCount + reviewCount;

  static SrsRemoteCounts fromJson(Map<String, dynamic>? json) =>
      SrsRemoteCounts(
        newCount: (json?['new'] as num?)?.toInt() ?? 0,
        learnCount: (json?['learn'] as num?)?.toInt() ?? 0,
        reviewCount: (json?['review'] as num?)?.toInt() ?? 0,
      );
}

/// host 推来的一张卡：渲染好的两面 + 四个评分的排程结果（间隔文案由本机按界面语言出）。
class SrsRemoteCard {
  const SrsRemoteCard({
    required this.id,
    required this.base,
    required this.rendered,
    required this.builtinKey,
    required this.deckName,
    required this.plan,
    required this.nowMs,
    required this.today,
    required this.rwkv,
    required this.autoplay,
  });

  final String id;

  /// 出卡时该卡的最后一条日志：作答时交回，host 据此判断卡在此期间变没变。
  final String? base;
  final SrsRenderedCard rendered;
  final String? builtinKey;
  final String deckName;
  final SrsAnswerPlan plan;
  final int nowMs;
  final int today;

  /// 牌组按 RWKV-Instant 排程：进复习队列的评分不显示天数（与本机复习页同一规则）。
  final bool rwkv;

  /// 卡所在牌组的「自动播放音频」（host 的牌组设置）。
  final bool autoplay;

  static SrsRemoteCard fromJson(Map<String, dynamic> json) {
    final List<dynamic> plan = json['plan'] as List<dynamic>;
    return SrsRemoteCard(
      id: json['id'] as String,
      base: json['base'] as String?,
      rendered: SrsRenderedCard(
        question: json['question'] as String? ?? '',
        answer: json['answer'] as String? ?? '',
        css: json['css'] as String? ?? '',
        isEmpty: json['isEmpty'] == true,
        fields: <String, String>{
          for (final MapEntry<String, dynamic> e
              in ((json['fields'] as Map?) ?? const <String, dynamic>{})
                  .cast<String, dynamic>()
                  .entries)
            e.key: '${e.value}',
        },
        fushiCardDefinitions: json['definitions'] as String?,
      ),
      builtinKey: json['builtinKey'] as String?,
      deckName: json['deckName'] as String? ?? '',
      plan: SrsAnswerPlan(<int, SrsScheduleResult>{
        for (int i = 0; i < 4; i++)
          i + 1: SrsScheduleResult.fromJson(
            (plan[i] as Map).cast<String, Object?>(),
          ),
      }),
      nowMs: (json['nowMs'] as num).toInt(),
      today: (json['today'] as num).toInt(),
      rwkv: json['rwkv'] == true,
      autoplay: json['autoplay'] != false,
    );
  }

  /// 评分 [rating] 的下次间隔；RWKV 牌组进复习队列时 null（不显示）。
  ({String amount, SrsIntervalUnit unit})? intervalOf(int rating) {
    final SrsScheduleResult next = plan[rating];
    if (rwkv && next.queue == SrsQueue.review) return null;
    return srsIntervalParts(next, nowMs: nowMs, today: today);
  }

  /// 两面、样式、字段与释义区引用的媒体名。
  Set<String> get mediaNames => <String>{
    ...srsCardReferencedMedia(rendered.question),
    ...srsCardReferencedMedia(rendered.answer),
    ...srsCardReferencedMedia(rendered.css),
    for (final String v in rendered.fields.values) ...srsCardReferencedMedia(v),
    if (rendered.fushiCardDefinitions != null)
      ...srsCardReferencedMedia(rendered.fushiCardDefinitions!),
  };
}

/// 一次排队的结果：计数与下一张 / 再下一张。
class SrsRemoteStudy {
  const SrsRemoteStudy({
    required this.profile,
    required this.counts,
    required this.cards,
    required this.rwkvPending,
  });

  final String profile;
  final SrsRemoteCounts counts;
  final List<SrsRemoteCard> cards;
  final bool rwkvPending;

  static SrsRemoteStudy fromJson(Map<String, dynamic> json) => SrsRemoteStudy(
    profile: json['profile'] as String,
    counts: SrsRemoteCounts.fromJson(
      (json['counts'] as Map?)?.cast<String, dynamic>(),
    ),
    cards: <SrsRemoteCard>[
      for (final dynamic c in (json['cards'] as List?) ?? const <dynamic>[])
        SrsRemoteCard.fromJson((c as Map).cast<String, dynamic>()),
    ],
    rwkvPending: json['rwkvPending'] == true,
  );
}

/// 一台电脑的远程刷卡协议。失败抛 [InterconnectHostError]，`message` 是 host 的机读码
/// （[SrsRemoteReviewError] 的常量）或连接层的码（[InterconnectHostError.unreachableCode] 等）。
class SrsRemoteReviewClient extends InterconnectHostClient {
  SrsRemoteReviewClient({
    required super.repository,
    required super.peer,
    super.httpClient,
    super.pinnedClientFactory,
  });

  Future<Map<String, dynamic>> _call(
    String op, [
    Map<String, dynamic> body = const <String, dynamic>{},
  ]) => postJson(
    '$kSrsRemoteReviewPathPrefix$op',
    body: body,
    timeout: const Duration(seconds: 20),
    authErrorMessage: 'SRS remote review authentication rejected',
  );

  /// host 是否声明了远程刷卡。null = 没有应答。
  Future<bool?> supportsRemoteReview() =>
      declaresCapability(kSrsRemoteReviewCapability);

  Future<({String profile, List<SrsRemoteDeck> decks})> decks() async {
    final Map<String, dynamic> json = await _call('decks');
    return (
      profile: json['profile'] as String,
      decks: <SrsRemoteDeck>[
        for (final dynamic d in (json['decks'] as List?) ?? const <dynamic>[])
          SrsRemoteDeck.fromJson((d as Map).cast<String, dynamic>()),
      ],
    );
  }

  Future<SrsRemoteStudy> next({
    required String profile,
    required String deck,
    Iterable<String> exclude = const <String>[],
  }) async => SrsRemoteStudy.fromJson(
    await _call('next', <String, dynamic>{
      'profile': profile,
      'deck': deck,
      'exclude': exclude.toList(),
    }),
  );

  /// [request] 每次作答生成一次，重发时不变（host 按它去重）。
  Future<({String logId, SrsRemoteStudy study})> answer({
    required String profile,
    required String request,
    required String deck,
    required SrsRemoteCard card,
    required int rating,
    required int durationMs,
  }) async {
    final Map<String, dynamic> json = await _call('answer', <String, dynamic>{
      'profile': profile,
      'request': request,
      'deck': deck,
      'card': card.id,
      'base': card.base,
      'rating': rating,
      'durationMs': durationMs,
    });
    return (
      logId: json['logId'] as String,
      study: SrsRemoteStudy.fromJson(json),
    );
  }

  Future<({bool ok, SrsRemoteCard? card})> undo({
    required String profile,
    required String cardId,
    required String logId,
  }) async {
    final Map<String, dynamic> json = await _call('undo', <String, dynamic>{
      'profile': profile,
      'card': cardId,
      'log': logId,
    });
    final Object? card = json['card'];
    return (
      ok: json['ok'] == true,
      card: card is Map
          ? SrsRemoteCard.fromJson(card.cast<String, dynamic>())
          : null,
    );
  }

  /// 一个媒体文件的字节；host 没有时 null。
  Future<Uint8List?> media(String name) async {
    final http.Response? r = await getFromHost(
      '${kSrsRemoteReviewPathPrefix}media/${Uri.encodeComponent(name)}',
      timeout: const Duration(seconds: 30),
    );
    return r?.bodyBytes;
  }
}

/// 列出此刻提供远程刷卡的电脑。
Future<List<InterconnectHostTarget>> probeSrsRemoteReviewTargets(
  SyncRepository repository,
) => probeInterconnectHostTargets(
  repository: repository,
  probe: (SyncRepository repo, FushiClientUrl peer) => SrsRemoteReviewClient(
    repository: repo,
    peer: peer,
  ).supportsRemoteReview(),
);

/// 远程刷卡的卡面媒体缓存：卡面照旧经 [SrsMediaStore] 读本地文件，缺的从 host 按名字补拉。
///
/// 媒体名是内容哈希（[SrsMediaStore.contentName]），同名即同内容、永不变，所以按名字缓存不会读到旧内容；
/// 缓存放在临时目录，系统可随时清。
class SrsRemoteMediaStore extends SrsMediaStore {
  SrsRemoteMediaStore(super.root, this._client);

  final SrsRemoteReviewClient _client;
  final Map<String, Future<bool>> _fetching = <String, Future<bool>>{};

  /// [hostId] 那台电脑的缓存目录。
  static Directory directoryFor(Directory tempRoot, String hostId) => Directory(
    p.join(
      tempRoot.path,
      'srs_remote_media',
      hostId.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_'),
    ),
  );

  @override
  Future<Uint8List?> load(String name) async {
    final Uint8List? hit = await super.load(name);
    if (hit != null) return hit;
    if (!await fetch(name)) return null;
    return super.load(name);
  }

  /// 把 [names] 里还没缓存的拉下来（显示卡之前调，`[sound:]` 播放要读本地文件）。失败的跳过：
  /// 卡面照常显示，缺的媒体在卡面里显示为缺失。
  Future<void> prefetch(Iterable<String> names) async {
    await Future.wait(<Future<bool>>[for (final String n in names) fetch(n)]);
  }

  /// 缓存里有或拉成功返回 true。同名并发只拉一次。
  Future<bool> fetch(String name) {
    final File? file = resolve(name);
    if (file == null) return Future<bool>.value(false);
    return _fetching.putIfAbsent(name, () async {
      try {
        if (await file.exists()) return true;
        final Uint8List? bytes = await _client.media(name);
        if (bytes == null) return false;
        await root.create(recursive: true);
        // 先写临时文件再改名：被杀时不留下半截文件（名字即内容，半截文件会一直错）。
        final File tmp = File('${file.path}.part');
        await tmp.writeAsBytes(bytes, flush: true);
        await tmp.rename(file.path);
        return true;
      } catch (_) {
        return false;
      } finally {
        unawaited(Future<void>(() => _fetching.remove(name)));
      }
    });
  }
}
