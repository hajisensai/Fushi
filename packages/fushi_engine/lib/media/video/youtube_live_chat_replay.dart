/// YouTube 直播回放的「聊天回放」（live chat replay）数据源（拍板台 zTedU_pOQF，方案 b）。
///
/// YouTube 没有聊天回放的官方接口，youtube_explode_dart 也不支持；这里走 YouTube 网页
/// 自己用的 innertube 接口（与 yt-dlp / chat-downloader 同一条路）：
///
/// 1. `POST /youtubei/v1/next {videoId}`：响应里
///    `contents.twoColumnWatchNextResults.conversationBar.liveChatRenderer` 带
///    `isReplay: true` 与一条 `reloadContinuationData.continuation`——这就是「这个视频有
///    聊天回放」的判据与入口（[parseYoutubeChatReplayEntry]）。不取 watch 页 HTML：同一份
///    数据，JSON 约 0.4 MB，HTML 约 1.4 MB 还得正则抠。
/// 2. `POST /youtubei/v1/live_chat/get_live_chat_replay {continuation, playerOffsetMs}`：
///    回一页消息（`replayChatItemAction`，每条带 `videoOffsetTimeMsec`）与下一页 /
///    跳转用的 continuation（[parseYoutubeChatReplayPage]）。带入口或 seek continuation
///    与任意 `playerOffsetMs` 就从那一刻附近开始（实测会带一段起点前的消息）。
///
/// 接口是网页内部协议，YouTube 改版就会失效——失败一律落 [YoutubeChatReplayStatus.failed]
/// 由 UI 显示并给「重试」，绝不影响播放本身。
///
/// 为什么在 Dart 而不在 Rust 胖核心：这是纯 IO 适配（两个 HTTP 接口 + 分页游标），出站
/// 必须走应用代理与 YouTube 出口（[createAppHttpIoClient] + youtube_explode 的
/// [yt.YoutubeHttpClient]，与同目录 `youtube_source_resolver.dart` 同一条），没有计算
/// 热点；JSON 解析放后台 isolate（[Isolate.run]），不占 UI 线程。状态只有
/// [YoutubeChatReplaySession] 一份，UI 不另存镜像。
library;

import 'dart:async';
import 'dart:collection' show UnmodifiableListView;
import 'dart:convert' show jsonDecode;
import 'dart:isolate' show Isolate;

import 'package:fushi_engine/media/video/youtube_source_resolver.dart'
    show kYoutubeConnectTimeout;
import 'package:fushi_engine/utils/net/app_http.dart'
    show createAppHttpIoClient;
import 'package:meta/meta.dart';
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt;

/// innertube WEB client 版本号（2026-11 网页实测值）。接口对旧版本号长期兼容；真被拒时
/// 换成 watch 页 `INNERTUBE_CLIENT_VERSION` 的当前值即可。
const String kYoutubeChatWebClientVersion = '2.20261119.07.00';

/// 单次请求上限：连上后被 tarpit 时不让聊天栏永远停在「加载中」。
const Duration kYoutubeChatRequestTimeout = Duration(seconds: 20);

/// 一条聊天回放消息。[offsetMs] 是它在视频时间轴上的位置（`videoOffsetTimeMsec`）。
@immutable
class YoutubeChatMessage {
  const YoutubeChatMessage({
    required this.id,
    required this.offsetMs,
    required this.author,
    required this.text,
    this.paidAmount,
  });

  final String id;
  final int offsetMs;
  final String author;

  /// 正文：文字段原样拼接；Unicode 表情是字符本身；频道自定义表情用它的短码
  /// （`:_shukkin:`，与 YouTube 图片的替代文本一致）。
  final String text;

  /// Super Chat 金额（`¥1,000`）；普通消息为 null。
  final String? paidAmount;

  @override
  bool operator ==(Object other) =>
      other is YoutubeChatMessage &&
      other.id == id &&
      other.offsetMs == offsetMs &&
      other.author == author &&
      other.text == text &&
      other.paidAmount == paidAmount;

  @override
  int get hashCode => Object.hash(id, offsetMs, author, text, paidAmount);

  @override
  String toString() => 'YoutubeChatMessage($offsetMs, $author: $text)';
}

/// `get_live_chat_replay` 的一页。
@immutable
class YoutubeChatReplayPage {
  const YoutubeChatReplayPage({
    required this.messages,
    required this.nextContinuation,
    required this.seekContinuation,
  });

  /// 按 [YoutubeChatMessage.offsetMs] 升序。
  final List<YoutubeChatMessage> messages;

  /// 往后接着取的 continuation；null = 聊天回放到头了。
  final String? nextContinuation;

  /// 跳到任意时刻用的 continuation（`playerSeekContinuationData`）；没给时为 null。
  final String? seekContinuation;
}

Map<String, Object?>? _map(Object? v) =>
    v is Map ? v.cast<String, Object?>() : null;

List<Object?> _list(Object? v) => v is List ? v : const <Object?>[];

String? _str(Object? v) => v is String ? v : null;

/// `{simpleText}` 或 `{runs:[{text}]}` 形态的文本字段。
String _plainText(Object? field) {
  final Map<String, Object?>? m = _map(field);
  if (m == null) return '';
  final String? simple = _str(m['simpleText']);
  if (simple != null) return simple;
  return _runsText(m['runs']);
}

String _runsText(Object? runs) {
  final StringBuffer out = StringBuffer();
  for (final Object? raw in _list(runs)) {
    final Map<String, Object?>? run = _map(raw);
    if (run == null) continue;
    final String? text = _str(run['text']);
    if (text != null) {
      out.write(text);
      continue;
    }
    final Map<String, Object?>? emoji = _map(run['emoji']);
    if (emoji == null) continue;
    if (emoji['isCustomEmoji'] == true) {
      final List<Object?> shortcuts = _list(emoji['shortcuts']);
      final String? shortcut = shortcuts.isEmpty ? null : _str(shortcuts.first);
      if (shortcut != null) out.write(shortcut);
    } else {
      // 标准表情的 emojiId 就是字符本身。
      final String? id = _str(emoji['emojiId']);
      if (id != null) out.write(id);
    }
  }
  return out.toString();
}

/// 从 `/youtubei/v1/next` 响应里取聊天回放入口 continuation。只认
/// `isReplay: true`（直播中 / 预约中的视频也有 liveChatRenderer，但那是实时聊天，不是
/// 回放）；没有聊天回放返回 null。
String? parseYoutubeChatReplayEntry(Map<String, Object?> nextResponse) {
  final Map<String, Object?>? renderer = _map(
    _map(
      _map(
        _map(nextResponse['contents'])?['twoColumnWatchNextResults'],
      )?['conversationBar'],
    )?['liveChatRenderer'],
  );
  if (renderer == null || renderer['isReplay'] != true) return null;
  for (final Object? raw in _list(renderer['continuations'])) {
    final String? c = _str(
      _map(_map(raw)?['reloadContinuationData'])?['continuation'],
    );
    if (c != null && c.isNotEmpty) return c;
  }
  return null;
}

/// 解析 `get_live_chat_replay` 的一页。只收文字消息与 Super Chat（会员加入、置顶横幅、
/// 占位项、系统提示都不是「聊天内容」）；空正文的消息丢掉（Super Chat 允许只有金额）。
/// 结构不认识时返回空页（无 continuation），交给调用方当「到头」处理。
YoutubeChatReplayPage parseYoutubeChatReplayPage(Map<String, Object?> json) {
  final Map<String, Object?>? cont = _map(
    _map(json['continuationContents'])?['liveChatContinuation'],
  );
  if (cont == null) {
    return const YoutubeChatReplayPage(
      messages: <YoutubeChatMessage>[],
      nextContinuation: null,
      seekContinuation: null,
    );
  }
  final List<YoutubeChatMessage> messages = <YoutubeChatMessage>[];
  for (final Object? rawAction in _list(cont['actions'])) {
    final Map<String, Object?>? replay = _map(
      _map(rawAction)?['replayChatItemAction'],
    );
    if (replay == null) continue;
    final int? offset = int.tryParse(_str(replay['videoOffsetTimeMsec']) ?? '');
    if (offset == null) continue;
    for (final Object? rawInner in _list(replay['actions'])) {
      final Map<String, Object?>? item = _map(
        _map(_map(rawInner)?['addChatItemAction'])?['item'],
      );
      if (item == null) continue;
      final YoutubeChatMessage? message = _messageFromItem(item, offset);
      if (message != null) messages.add(message);
    }
  }
  // YouTube 按时间给，这里稳定排序兜底（同一时刻保持原序）。
  final List<YoutubeChatMessage> sorted = _stableSortByOffset(messages);
  String? next;
  String? seek;
  for (final Object? raw in _list(cont['continuations'])) {
    final Map<String, Object?>? c = _map(raw);
    if (c == null) continue;
    next ??= _str(_map(c['liveChatReplayContinuationData'])?['continuation']);
    seek ??= _str(_map(c['playerSeekContinuationData'])?['continuation']);
  }
  return YoutubeChatReplayPage(
    messages: sorted,
    nextContinuation: next,
    seekContinuation: seek,
  );
}

YoutubeChatMessage? _messageFromItem(Map<String, Object?> item, int offset) {
  final Map<String, Object?>? text = _map(item['liveChatTextMessageRenderer']);
  final Map<String, Object?>? paid = _map(item['liveChatPaidMessageRenderer']);
  final Map<String, Object?>? r = text ?? paid;
  if (r == null) return null;
  final String id = _str(r['id']) ?? '';
  final String body = _runsText(_map(r['message'])?['runs']).trim();
  final String? amount = paid == null
      ? null
      : _plainText(paid['purchaseAmountText']).trim();
  if (id.isEmpty) return null;
  if (body.isEmpty && (amount == null || amount.isEmpty)) return null;
  return YoutubeChatMessage(
    id: id,
    offsetMs: offset,
    author: _plainText(r['authorName']).trim(),
    text: body,
    paidAmount: amount == null || amount.isEmpty ? null : amount,
  );
}

List<YoutubeChatMessage> _stableSortByOffset(List<YoutubeChatMessage> input) {
  final List<(int, YoutubeChatMessage)> indexed = <(int, YoutubeChatMessage)>[
    for (int i = 0; i < input.length; i++) (i, input[i]),
  ];
  indexed.sort(((int, YoutubeChatMessage) a, (int, YoutubeChatMessage) b) {
    final int byOffset = a.$2.offsetMs.compareTo(b.$2.offsetMs);
    return byOffset != 0 ? byOffset : a.$1.compareTo(b.$1);
  });
  return <YoutubeChatMessage>[
    for (final (int, YoutubeChatMessage) e in indexed) e.$2,
  ];
}

/// 取一页：用 [continuation] 从视频时刻 [playerOffsetMs] 起取。
typedef YoutubeChatReplayPageFetch =
    Future<YoutubeChatReplayPage> Function(
      String continuation,
      int playerOffsetMs,
    );

/// innertube 请求体的 client 段（两个接口共用）。
Map<String, Object?> _innertubeContext() => <String, Object?>{
  'client': <String, Object?>{
    'clientName': 'WEB',
    'clientVersion': kYoutubeChatWebClientVersion,
    'hl': 'ja',
  },
};

yt.YoutubeHttpClient _createChatHttpClient() => yt.YoutubeHttpClient(
  createAppHttpIoClient(connectionTimeout: kYoutubeConnectTimeout),
);

Future<String> _postInnertube(
  yt.YoutubeHttpClient http,
  String endpoint,
  Map<String, Object?> body,
) async {
  final String text = await http
      .postString(
        Uri.parse(
          'https://www.youtube.com/youtubei/v1/$endpoint?prettyPrint=false',
        ),
        body: body,
        headers: const <String, String>{'content-type': 'application/json'},
      )
      .timeout(kYoutubeChatRequestTimeout);
  return text;
}

/// innertube POST：[endpoint]（如 `next`）+ JSON 请求体 → 响应正文。
typedef YoutubeInnertubePost =
    Future<String> Function(String endpoint, Map<String, Object?> body);

/// IO：查 [videoId] 有没有聊天回放，有则返回入口 continuation。没有 / 失败都返回 null
/// （聊天栏是可选增强，查不到就是不出按钮）。[post] 仅供测试注入。
Future<String?> fetchYoutubeChatReplayEntry(
  String videoId, {
  @visibleForTesting YoutubeInnertubePost? post,
}) async {
  final yt.YoutubeHttpClient? http = post == null
      ? _createChatHttpClient()
      : null;
  final YoutubeInnertubePost send =
      post ??
      (String endpoint, Map<String, Object?> body) =>
          _postInnertube(http!, endpoint, body);
  try {
    final String body = await send('next', <String, Object?>{
      'context': _innertubeContext(),
      'videoId': videoId,
    });
    return await Isolate.run(() => decodeYoutubeChatReplayEntry(body));
  } catch (_) {
    return null;
  } finally {
    http?.close();
  }
}

/// 把 `/youtubei/v1/next` 的响应正文解成入口 continuation（非 JSON 对象 / 没有聊天回放
/// 都是 null）。
String? decodeYoutubeChatReplayEntry(String body) {
  final Object? decoded = jsonDecode(body);
  return decoded is Map
      ? parseYoutubeChatReplayEntry(decoded.cast<String, Object?>())
      : null;
}

/// `get_live_chat_replay` 的请求体：从视频时刻 [playerOffsetMs] 起用 [continuation] 取。
Map<String, Object?> youtubeChatReplayRequestBody(
  String continuation,
  int playerOffsetMs,
) => <String, Object?>{
  'context': _innertubeContext(),
  'continuation': continuation,
  'currentPlayerState': <String, Object?>{
    'playerOffsetMs': '${playerOffsetMs < 0 ? 0 : playerOffsetMs}',
  },
};

/// 生产用的取页函数：一个 session 共用一个 HTTP client（[close] 在 session 结束时调）。
class YoutubeChatReplayHttpFetcher {
  YoutubeChatReplayHttpFetcher() : _http = _createChatHttpClient();

  final yt.YoutubeHttpClient _http;

  Future<YoutubeChatReplayPage> fetch(
    String continuation,
    int playerOffsetMs,
  ) async {
    final String body = await _postInnertube(
      _http,
      'live_chat/get_live_chat_replay',
      youtubeChatReplayRequestBody(continuation, playerOffsetMs),
    );
    return Isolate.run(() => decodeYoutubeChatReplayPage(body));
  }

  void close() => _http.close();
}

/// 把响应正文解成一页（非 JSON 对象抛 [FormatException]，交给 session 记失败）。
YoutubeChatReplayPage decodeYoutubeChatReplayPage(String body) {
  final Object? decoded = jsonDecode(body);
  if (decoded is! Map) {
    throw const FormatException('live chat replay: not a JSON object');
  }
  return parseYoutubeChatReplayPage(decoded.cast<String, Object?>());
}

/// 聊天回放会话的状态。
enum YoutubeChatReplayStatus {
  /// 还没取过（或刚跳转，旧窗口已清）且没有请求在途。
  idle,

  /// 有请求在途。
  loading,

  /// 已有一段连续窗口，可接着往后取。
  ready,

  /// 窗口已到聊天回放末尾（再往后没有消息）。
  ended,

  /// 最近一次请求失败；[YoutubeChatReplaySession.retry] 之前不再自动请求。
  failed,
}

/// 一个视频的聊天回放会话：持有「播放头附近的一段连续消息窗口」并按播放进度分页。
///
/// 窗口是 `[coveredFromMs, coveredToMs]` 上**没有缺口**的一段：
/// - 播放头在窗口里、离窗口尾不到 [lookaheadMs] → 用 next continuation 接着往后取；
/// - 播放头跳出窗口（往回拖到窗口前、或往前拖过窗口尾 + [lookaheadMs]）→ 丢掉旧窗口，
///   用 seek continuation 从新位置重开一段（不拼接两段，免得列表里出现看不出的断层）；
/// - 消息超过 [maxMessages] 时从最旧的一头裁（只裁播放头之前的），窗口起点随之后移。
///
/// 同一时刻最多一个请求在途；跳转时旧请求的结果按代号作废。失败后停在
/// [YoutubeChatReplayStatus.failed]，不自动重试（[retry] 由用户触发），不会对 YouTube
/// 连续打请求。
class YoutubeChatReplaySession {
  YoutubeChatReplaySession({
    required String entryContinuation,
    required YoutubeChatReplayPageFetch fetch,
    this.onChanged,
    this.lookaheadMs = 20000,
    this.maxMessages = 3000,
  }) : _entryContinuation = entryContinuation,
       _fetch = fetch;

  final String _entryContinuation;
  final YoutubeChatReplayPageFetch _fetch;

  /// 消息 / 状态变了（UI 据此重建）。
  final void Function()? onChanged;

  /// 播放头离窗口尾不到这么远就预取下一页。
  final int lookaheadMs;

  /// 窗口里最多留这么多条（长直播几小时的聊天可达十万条）。
  final int maxMessages;

  final List<YoutubeChatMessage> _messages = <YoutubeChatMessage>[];
  final Set<String> _ids = <String>{};
  String? _next;
  String? _seek;
  int? _coveredFrom;
  int? _coveredTo;
  bool _ended = false;
  bool _failed = false;
  bool _disposed = false;
  int _generation = 0;
  int? _inFlightTarget;
  bool _inFlightIsSeek = false;
  int _lastPositionMs = 0;

  /// 当前窗口里的消息，按时间升序（只读视图，随会话更新，不拷贝）。
  late final List<YoutubeChatMessage> messages =
      UnmodifiableListView<YoutubeChatMessage>(_messages);

  /// 窗口覆盖的时间段；还没有窗口时为 null。
  ({int fromMs, int toMs})? get covered {
    final int? from = _coveredFrom;
    final int? to = _coveredTo;
    return from == null || to == null ? null : (fromMs: from, toMs: to);
  }

  YoutubeChatReplayStatus get status {
    if (_failed) return YoutubeChatReplayStatus.failed;
    if (_inFlightTarget != null) return YoutubeChatReplayStatus.loading;
    if (_coveredFrom == null) return YoutubeChatReplayStatus.idle;
    return _ended
        ? YoutubeChatReplayStatus.ended
        : YoutubeChatReplayStatus.ready;
  }

  /// 播放头到了 [positionMs]：按需取页（见类注释）。返回本次触发的请求（没触发 = 立即
  /// 完成），测试可据此等待。
  Future<void> syncTo(int positionMs) {
    if (_disposed) return Future<void>.value();
    _lastPositionMs = positionMs;
    if (_failed) return Future<void>.value();
    final int? from = _coveredFrom;
    final int? to = _coveredTo;
    // 已到末尾的窗口向后无限延伸：再往后本来就没有消息，不为它重开窗口。
    final bool inWindow =
        from != null &&
        to != null &&
        positionMs >= from &&
        (_ended || positionMs <= to + lookaheadMs);
    if (inWindow) {
      if (_ended || _inFlightTarget != null) return Future<void>.value();
      if (to - positionMs >= lookaheadMs) return Future<void>.value();
      final String? next = _next;
      if (next == null) return Future<void>.value();
      return _request(next, to, seek: false);
    }
    // 窗口外：已有一个落在附近的跳转请求在途就等它，不重复打。
    final int? pending = _inFlightTarget;
    if (pending != null &&
        _inFlightIsSeek &&
        (positionMs - pending).abs() <= lookaheadMs) {
      return Future<void>.value();
    }
    return _request(_seek ?? _entryContinuation, positionMs, seek: true);
  }

  /// 失败后用户点「重试」：清掉失败态，按最后的播放头重新同步。
  Future<void> retry() {
    if (_disposed) return Future<void>.value();
    _failed = false;
    _notify();
    return syncTo(_lastPositionMs);
  }

  void dispose() {
    _disposed = true;
    _generation++;
  }

  Future<void> _request(
    String continuation,
    int offsetMs, {
    required bool seek,
  }) async {
    final int generation = ++_generation;
    _inFlightTarget = offsetMs;
    _inFlightIsSeek = seek;
    if (seek) {
      // 跳转：旧窗口作废（列表立刻清空，不让用户看到别处的消息）。
      _messages.clear();
      _ids.clear();
      _coveredFrom = null;
      _coveredTo = null;
      _ended = false;
    }
    _notify();
    YoutubeChatReplayPage page;
    try {
      page = await _fetch(continuation, offsetMs);
    } catch (_) {
      if (_disposed || generation != _generation) return;
      _inFlightTarget = null;
      _failed = true;
      _notify();
      return;
    }
    if (_disposed || generation != _generation) return;
    _inFlightTarget = null;
    _apply(page, offsetMs, seek: seek);
    _notify();
    // 一页可能只覆盖几秒（聊天刷得快时），离播放头还不够远就接着取。
    if (!_ended && !_failed) unawaited(syncTo(_lastPositionMs));
  }

  void _apply(
    YoutubeChatReplayPage page,
    int requestedMs, {
    required bool seek,
  }) {
    bool added = false;
    for (final YoutubeChatMessage m in page.messages) {
      if (!_ids.add(m.id)) continue;
      _insertSorted(m);
      added = true;
    }
    _next = page.nextContinuation;
    if (page.seekContinuation != null) _seek = page.seekContinuation;
    final int lastOffset = page.messages.isEmpty
        ? requestedMs
        : page.messages.last.offsetMs;
    if (seek) {
      final int firstOffset = page.messages.isEmpty
          ? requestedMs
          : page.messages.first.offsetMs;
      _coveredFrom = firstOffset < requestedMs ? firstOffset : requestedMs;
      _coveredTo = lastOffset > requestedMs ? lastOffset : requestedMs;
    } else {
      final int to = _coveredTo ?? requestedMs;
      _coveredTo = lastOffset > to ? lastOffset : to;
    }
    // 到头：没有 next continuation；或接续页什么新东西都没带（再请求也只会原地打转）。
    _ended = page.nextContinuation == null || (!seek && !added);
    _trim();
  }

  void _insertSorted(YoutubeChatMessage m) {
    if (_messages.isEmpty || _messages.last.offsetMs <= m.offsetMs) {
      _messages.add(m);
      return;
    }
    int lo = 0;
    int hi = _messages.length;
    while (lo < hi) {
      final int mid = (lo + hi) >> 1;
      if (_messages[mid].offsetMs <= m.offsetMs) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    _messages.insert(lo, m);
  }

  /// 超过 [maxMessages] 时从最旧的一头裁——只裁播放头之前的（播放头之后的是马上要显示
  /// 的内容，裁了窗口起点就会越过播放头，下一次同步变成无谓的跳转重取）。
  void _trim() {
    final int excess = _messages.length - maxMessages;
    if (excess <= 0) return;
    int n = 0;
    while (n < excess && _messages[n].offsetMs < _lastPositionMs) {
      n++;
    }
    if (n == 0) return;
    for (int i = 0; i < n; i++) {
      _ids.remove(_messages[i].id);
    }
    _messages.removeRange(0, n);
    _coveredFrom = _messages.first.offsetMs;
  }

  void _notify() {
    if (_disposed) return;
    onChanged?.call();
  }
}

/// [messages]（按时间升序）里 `offsetMs <= positionMs` 的条数——即播放到此刻「已经发出」
/// 的消息数（二分）。
int youtubeChatVisibleCount(List<YoutubeChatMessage> messages, int positionMs) {
  int lo = 0;
  int hi = messages.length;
  while (lo < hi) {
    final int mid = (lo + hi) >> 1;
    if (messages[mid].offsetMs <= positionMs) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  return lo;
}
