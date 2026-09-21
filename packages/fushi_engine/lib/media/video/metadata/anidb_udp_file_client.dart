import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:meta/meta.dart';

/// A registered AniDB client identity and the user's website credentials.
/// Never include this object or wire packets in logs.
class AnidbUdpConfig {
  const AnidbUdpConfig({
    required this.username,
    required this.password,
    required this.clientName,
    required this.clientVersion,
    this.host = 'api.anidb.net',
    this.port = 9000,
    this.localPort = 19000,
    // Shoko `AniDBSocketHandler` 收发各 30 s；AniDB 高峰期 FILE 常要十几秒才
    // 回，15 s 会把慢应答误判成丢包（BUG-2592）。
    this.timeout = const Duration(seconds: 30),
  });
  final String username, password, clientName, host;
  final int clientVersion, port, localPort;
  final Duration timeout;
  bool get isAvailable =>
      RegExp(r'^[a-z]{4,16}$').hasMatch(clientName) &&
      clientVersion > 0 &&
      RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(username) &&
      password.isNotEmpty &&
      host.isNotEmpty &&
      port > 0 &&
      port <= 65535 &&
      localPort > 1024 &&
      localPort <= 65535 &&
      timeout > Duration.zero;
}

enum AnidbUdpFailure {
  unavailable,
  invalidInput,
  authentication,
  clientOutdated,
  clientBanned,
  banned,
  session,
  accessDenied,
  maintenance,
  server,
  timeout,

  /// 连续无应答后的本地退避窗口内，报文未发出（不是服务端拒绝）。
  backoff,
  network,
  malformedResponse,
  closed,
}

class AnidbUdpException implements Exception {
  const AnidbUdpException(this.reason, {this.code});
  final AnidbUdpFailure reason;
  final int? code;
  @override
  String toString() => 'AnidbUdpException(${reason.name}, code: $code)';
}

/// 一个文件覆盖的另一条 AniDB 集（Shoko `CrossRef_File_Episode` 的
/// `EpisodeID` + `Percentage`）：`01-02` 合集、拆成两半的剧场版都会出现。
class AnidbEpisodeShare {
  const AnidbEpisodeShare({
    required this.episodeId,
    required this.percentage,
    this.episodeNumber,
    this.airedAt,
    this.englishTitle,
    this.romajiTitle,
    this.kanjiTitle,
  });
  final int episodeId;

  /// 该集占本文件的百分比（AniDB 给的；没给时按份数均分）。
  final int percentage;

  /// FILE 应答只给 eid；集号 / 播出日 / 三语集名要再问一次 `EPISODE eid=`
  /// 才有（[AnidbUdpFileClient.episode]），问到前全为 null。有了这些这一集才能
  /// 与主集一样进 TMDB 逐集链接、绑成第二条分集行（Shoko `CrossRef_File_Episode`
  /// 一文件多集）。
  final String? episodeNumber;
  final DateTime? airedAt;
  final String? englishTitle, romajiTitle, kanjiTitle;

  /// 集信息已问到（集号在手；播出日 / 集名可能 AniDB 本就没登记）。
  bool get isResolved => episodeNumber != null;

  /// `yyyy-MM-dd`，与 [AnidbFileIdentity.episodeAirDate] 同形。
  String? get airDate => _airDateOf(airedAt);

  /// 三语集名里非空的那几条。
  List<String> get titles => <String>[
        for (final String? title in <String?>[
          englishTitle,
          romajiTitle,
          kanjiTitle
        ])
          if (title != null && title.trim().isNotEmpty) title,
      ];

  /// 把 `EPISODE` 应答填进来（eid 不同则原样返回）。
  AnidbEpisodeShare withInfo(AnidbEpisodeInfo info) => info.episodeId != episodeId
      ? this
      : AnidbEpisodeShare(
          episodeId: episodeId,
          percentage: percentage,
          episodeNumber: info.episodeNumber,
          airedAt: info.airedAt,
          englishTitle: info.englishTitle,
          romajiTitle: info.romajiTitle,
          kanjiTitle: info.kanjiTitle,
        );

  @override
  bool operator ==(Object other) =>
      other is AnidbEpisodeShare &&
      other.episodeId == episodeId &&
      other.percentage == percentage &&
      other.episodeNumber == episodeNumber &&
      other.airedAt == airedAt &&
      other.englishTitle == englishTitle &&
      other.romajiTitle == romajiTitle &&
      other.kanjiTitle == kanjiTitle;

  @override
  int get hashCode => Object.hash(episodeId, percentage);

  @override
  String toString() =>
      'AnidbEpisodeShare($episodeId, $percentage%${episodeNumber == null ? '' : ', ep $episodeNumber'})';
}

String? _airDateOf(DateTime? aired) {
  if (aired == null) return null;
  final DateTime utc = aired.toUtc();
  return '${utc.year.toString().padLeft(4, '0')}-'
      '${utc.month.toString().padLeft(2, '0')}-'
      '${utc.day.toString().padLeft(2, '0')}';
}

/// AniDB FILE `state` 位（Shoko `GetFile_State`）。
abstract final class AnidbFileState {
  static const int crcMatch = 1;
  static const int crcError = 2;
  static const int isV2 = 4;
  static const int isV3 = 8;
  static const int isV4 = 16;
  static const int isV5 = 32;
  static const int uncensored = 64;
  static const int censored = 128;
  static const int chaptered = 4096;
}

class AnidbFileIdentity {
  const AnidbFileIdentity({
    required this.fileId,
    required this.animeId,
    required this.episodeId,
    required this.episodeNumber,
    required this.romajiTitle,
    required this.kanjiTitle,
    required this.englishTitle,
    required this.episodeTitle,
    required this.episodeRomajiTitle,
    required this.episodeKanjiTitle,
    this.animeType = '',
    this.episodeAiredAt,
    this.otherEpisodes = const <AnidbEpisodeShare>[],
    this.isDeprecated = false,
    this.fileState = 0,
  });
  final int fileId, animeId, episodeId;

  /// AniDB 动画类型原文（FILE amask byte1 bit4：`TV Series` / `OVA` / `Movie` /
  /// `Web` / `TV Special` / `Music Video` / `Other`）；'' = 未取到（v111 之前
  /// 落的行）。Shoko 的作品形态由它决定，本仓单文件单元的 kind 也跟它走。
  final String animeType;

  /// AniDB 说这是电影（Shoko `AnimeType.Movie`）。
  bool get isMovieType => animeType.trim().toLowerCase() == 'movie';
  final String episodeNumber,
      romajiTitle,
      kanjiTitle,
      englishTitle,
      episodeTitle,
      episodeRomajiTitle,
      episodeKanjiTitle;

  /// 除 [episodeId] 之外本文件还覆盖的集（FILE 的 eid 列表 + `other episodes`
  /// 列），按 AniDB 给的顺序；单集文件为空。
  final List<AnidbEpisodeShare> otherEpisodes;

  /// AniDB 已把这份文件标为过时（有更新的版本 / 已从库里撤下）；Shoko
  /// `ReleaseInfo.IsCorrupted` 的来源之一。
  final bool isDeprecated;

  /// FILE `state` 位图（[AnidbFileState]）。
  final int fileState;

  /// CRC 与 AniDB 登记值的比对结果：true 匹配、false 不匹配、null 未知。
  bool? get crcMatches => (fileState & AnidbFileState.crcMatch) != 0
      ? true
      : (fileState & AnidbFileState.crcError) != 0
          ? false
          : null;

  /// 文件版本 v1–v5（AniDB 只标 v2 起）。
  int get fileVersion => (fileState & AnidbFileState.isV5) != 0
      ? 5
      : (fileState & AnidbFileState.isV4) != 0
          ? 4
          : (fileState & AnidbFileState.isV3) != 0
              ? 3
              : (fileState & AnidbFileState.isV2) != 0
                  ? 2
                  : 1;

  /// 集播出日（UTC 零点；UDP `EPISODE` 的 `aired`）。FILE 应答里没有这一项，
  /// 由 [AnidbUdpFileClient.episode] 另问一次补上；null = 尚未取到 / AniDB
  /// 未登记。Shoko 集级链接的第一评级 DateAndTitle 靠它。
  final DateTime? episodeAiredAt;

  /// `yyyy-MM-dd`，与 TMDB 集 `airDate` 同形，直接喂逐集匹配器。
  String? get episodeAirDate => _airDateOf(episodeAiredAt);

  /// 还没问到集信息的其余集（要补 `EPISODE`）。
  bool get hasUnresolvedOtherEpisodes =>
      otherEpisodes.any((AnidbEpisodeShare share) => !share.isResolved);

  AnidbFileIdentity copyWith({
    DateTime? episodeAiredAt,
    List<AnidbEpisodeShare>? otherEpisodes,
    String? animeType,
  }) =>
      AnidbFileIdentity(
        fileId: fileId,
        animeId: animeId,
        episodeId: episodeId,
        episodeNumber: episodeNumber,
        romajiTitle: romajiTitle,
        kanjiTitle: kanjiTitle,
        englishTitle: englishTitle,
        episodeTitle: episodeTitle,
        episodeRomajiTitle: episodeRomajiTitle,
        episodeKanjiTitle: episodeKanjiTitle,
        animeType: animeType ?? this.animeType,
        episodeAiredAt: episodeAiredAt ?? this.episodeAiredAt,
        otherEpisodes: otherEpisodes ?? this.otherEpisodes,
        isDeprecated: isDeprecated,
        fileState: fileState,
      );
}

/// UDP `EPISODE` 应答（wiki UDP_API_Definition：
/// `eid|aid|length|rating|votes|epno|eng|romaji|kanji|aired|type`）。
/// 只保留集级链接要用的字段；Shoko `RequestGetEpisode` 同样只取 eid/aid。
class AnidbEpisodeInfo {
  const AnidbEpisodeInfo({
    required this.episodeId,
    required this.animeId,
    required this.episodeNumber,
    required this.airedAt,
    this.englishTitle = '',
    this.romajiTitle = '',
    this.kanjiTitle = '',
  });
  final int episodeId, animeId;
  final String episodeNumber;

  /// 播出日（UTC 零点）；AniDB 未登记（`aired` 为 0）时为 null。
  final DateTime? airedAt;

  /// 三语集名（`eng|romaji|kanji`）；一文件多集里「其余集」的标题只有这里能拿到。
  final String englishTitle, romajiTitle, kanjiTitle;
}

/// Request/response transport; implementations must discard other peers/tags.
abstract interface class AnidbUdpTransport {
  Future<String> exchange(String packet, String tag, Duration timeout);
  Future<void> send(String packet);
  void cancelPending();
  Future<void> close();
}

typedef AnidbUdpTransportFactory = Future<AnidbUdpTransport> Function(
    AnidbUdpConfig config);

/// One persistent socket/session, with serialized commands and no automatic
/// retries. Keep a client for a scan batch, then await [close]. Cache successful
/// identities durably in the caller; this client also deduplicates within a batch.
/// Protocol: https://wiki.anidb.net/UDP_API_Definition (FILE masks, AUTH, flooding).
class AnidbUdpFileClient {
  AnidbUdpFileClient({
    required this.config,
    AnidbUdpTransportFactory? transportFactory,
    @visibleForTesting bool sharedRateGate = false,
    this.idleLogout = const Duration(minutes: 5),
  })  : _factory = transportFactory ?? AnidbDatagramTransport.connect,
        // 进程级节流 / 退避 / 封禁只对真实 UDP 传输生效；内存传输默认不走
        // （没有网络也就没有 flood），测试要验退避时显式打开。
        _gated = sharedRateGate || transportFactory == null;
  final AnidbUdpConfig config;
  final AnidbUdpTransportFactory _factory;
  final bool _gated;

  /// 多久没有业务请求就主动 LOGOUT（Shoko `AniDBUDPConnectionHandler` 5 min）。
  /// 客户端与刮削协调器同寿命，一批扫完后会话不该一直挂着占 AniDB 的连接；
  /// 下一批第一条请求自动重新 AUTH。
  final Duration idleLogout;
  Timer? _idleTimer;
  AnidbUdpTransport? _transport;
  String? _session;
  AnidbUdpException? _terminalFailure;
  bool _closed = false;
  Future<void>? _closing;
  bool clientUpdateAvailable = false;
  Future<void> _tail = Future<void>.value();
  int _tag = 0;
  final Map<String, AnidbFileIdentity?> _cache = {};
  final Map<int, AnidbEpisodeInfo?> _episodes = {};

  /// 320 未收录只在批次尺度内去重：客户端与协调器同寿命，永久缓存会让 AniDB
  /// 后来收录的文件在本进程里再也查不到；持久层另有 7 天复查期。
  final Map<String, int> _missAt = {};
  static const int _missCacheMs = 60 * 60 * 1000;
  static Future<void> _sendTail = Future<void>.value();
  static final Stopwatch _clock = Stopwatch()..start();
  static int _nextSendMs = 0;
  static int _blockedUntilMs = 0;

  /// 测试用：把进程级节流 / 退避 / 封禁状态归零，并可换成假时钟（毫秒）与
  /// 假睡眠（节流等待）。
  @visibleForTesting
  static void resetSharedState({
    int Function()? clockMs,
    Future<void> Function(Duration)? sleep,
  }) {
    _sendTail = Future<void>.value();
    _nextSendMs = 0;
    _blockedUntilMs = 0;
    _blockedReason = AnidbUdpFailure.maintenance;
    _timeoutStreak = 0;
    _lastSendMs = -1;
    _activeSinceMs = -1;
    _clockOverride = clockMs;
    _sleepOverride = sleep;
  }

  static int Function()? _clockOverride;
  static Future<void> Function(Duration)? _sleepOverride;
  static int get _nowMs => _clockOverride?.call() ?? _clock.elapsedMilliseconds;
  static Future<void> _sleep(Duration duration) =>
      (_sleepOverride ?? Future<void>.delayed)(duration);

  /// 当前退避 / 封禁还剩多久；不在窗口内为 [Duration.zero]。报告文案用。
  static Duration get sharedBlockRemaining {
    final int remaining = _blockedUntilMs - _nowMs;
    return remaining > 0 ? Duration(milliseconds: remaining) : Duration.zero;
  }

  Future<T> _serialize<T>(Future<T> Function() action) {
    _idleTimer?.cancel();
    final Future<T> result = _tail.then((_) => action());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _tail = _tail.then((_) => _armIdleLogout());
    return result;
  }

  /// 最近一条请求结束后起一个空闲计时；到点且仍有会话就在下一个发送槽发
  /// LOGOUT 并清会话（不等应答）。任何新请求进队列都会先取消它。
  void _armIdleLogout() {
    _idleTimer?.cancel();
    if (_closed || _session == null) return;
    _idleTimer = Timer(idleLogout, () {
      _idleTimer = null;
      if (_closed || _session == null) return;
      final String session = _session!;
      _session = null;
      _tail = _tail.then((_) async {
        try {
          await _request('LOGOUT', {'s': session}, responseRequired: false);
        } on AnidbUdpException {
          // 尽力而为；会话在服务端 35 分钟后也会自己过期。
        }
      });
    });
  }

  Future<AnidbFileIdentity?> lookup({
    required int size,
    required String ed2k,
  }) =>
      _serialize(() async {
        if (_closed) throw const AnidbUdpException(AnidbUdpFailure.closed);
        if (!config.isAvailable) {
          throw const AnidbUdpException(AnidbUdpFailure.unavailable);
        }
        if (_terminalFailure != null) throw _terminalFailure!;
        if (size <= 0 || !RegExp(r'^[a-fA-F0-9]{32}$').hasMatch(ed2k)) {
          throw const AnidbUdpException(AnidbUdpFailure.invalidInput);
        }
        final String key = '$size:${ed2k.toLowerCase()}';
        if (_cache.containsKey(key)) {
          final AnidbFileIdentity? cached = _cache[key];
          if (cached != null || _nowMs - (_missAt[key] ?? 0) < _missCacheMs) {
            return cached;
          }
          _cache.remove(key);
          _missAt.remove(key);
        }
        if (_cache.length >= 2048) {
          _missAt.remove(_cache.keys.first);
          _cache.remove(_cache.keys.first);
        }
        await _ensureSession();
        _Reply file = await _requestFile(size, ed2k);
        if (file.code == 501 || file.code == 506 || file.code == 505) {
          // The virtual connection expires after 35 idle minutes (wiki
          // UDP_API_Definition), and this client lives as long as the scrape
          // coordinator, so the first FILE of a later batch routinely lands on
          // a dead session. Re-authenticate once and resend; a second
          // rejection is a real session failure (BUG-2586). 505 follows Shoko
          // (`UDPRequest.ParseResponse`: ILLEGAL INPUT OR ACCESS DENIED ⇒
          // invalid session ⇒ log in again and resend).
          _session = null;
          await _ensureSession();
          file = await _requestFile(size, ed2k);
        }
        if (file.code == 320) {
          _cache[key] = null;
          _missAt[key] = _nowMs;
          return null;
        }
        if (file.code != 220) _fail(file.code);
        final AnidbFileIdentity identity = parseFileReply(file.data);
        _cache[key] = identity;
        return identity;
      });

  /// 220 FILE 数据行 → 身份。列序由 [_requestFile] 的掩码决定：
  /// `fid|aid|eid|other eps|deprecated|state|type|romaji|kanji|english|epno|ep|ep romaji|ep kanji`
  /// （Shoko `RequestGetFile.ParseResponse` 同样按掩码固定下标取列）。
  /// eid 列可能是 `eid'eid,pct` 列表（一文件多集），首项是主集；
  /// `other eps` 两种写法：`eid'pct'eid'pct` 或 `eid,pct'eid,pct`。
  @visibleForTesting
  static AnidbFileIdentity parseFileReply(String data) {
    final List<String> fields = data.split('|');
    if (fields.length < 14) {
      throw const AnidbUdpException(AnidbUdpFailure.malformedResponse);
    }
    final int? fileId = int.tryParse(fields[0].trim());
    final int? animeId = int.tryParse(fields[1].trim());
    final List<AnidbEpisodeShare> episodes = _parseEpisodeList(fields[2]);
    if (fileId == null ||
        fileId <= 0 ||
        animeId == null ||
        animeId <= 0 ||
        episodes.isEmpty ||
        !RegExp(r'^(?:[SCTPO])?\d+$').hasMatch(fields[10])) {
      throw const AnidbUdpException(AnidbUdpFailure.malformedResponse);
    }
    // 主集之外的集：eid 列表的其余项 + other episodes 列，按 eid 去重保序。
    final Set<int> seen = <int>{episodes.first.episodeId};
    final List<AnidbEpisodeShare> others = <AnidbEpisodeShare>[
      for (final AnidbEpisodeShare share in <AnidbEpisodeShare>[
        ...episodes.skip(1),
        ..._parseOtherEpisodes(fields[3]),
      ])
        if (seen.add(share.episodeId)) share,
    ];
    return AnidbFileIdentity(
      fileId: fileId,
      animeId: animeId,
      episodeId: episodes.first.episodeId,
      otherEpisodes: others,
      isDeprecated: fields[4].trim() == '1',
      fileState: int.tryParse(fields[5].trim()) ?? 0,
      animeType: fields[6].trim(),
      romajiTitle: fields[7],
      kanjiTitle: fields[8],
      englishTitle: fields[9],
      episodeNumber: fields[10],
      episodeTitle: fields[11],
      episodeRomajiTitle: fields[12],
      episodeKanjiTitle: fields[13],
    );
  }

  /// eid 列：单个 `eid`，或 `'` 分隔的 `eid[,pct]` 列表（没给百分比按份数均分）。
  static List<AnidbEpisodeShare> _parseEpisodeList(String raw) {
    final String text = raw.trim();
    if (text.isEmpty) return const <AnidbEpisodeShare>[];
    final int? single = int.tryParse(text);
    if (single != null) {
      return single > 0
          ? <AnidbEpisodeShare>[
              AnidbEpisodeShare(episodeId: single, percentage: 100)
            ]
          : const <AnidbEpisodeShare>[];
    }
    final List<String> parts = text.split("'");
    final int even = (100 / parts.length).round();
    final List<AnidbEpisodeShare> result = <AnidbEpisodeShare>[];
    for (final String part in parts) {
      final List<String> pair = part.split(',');
      final int? eid = int.tryParse(pair[0].trim());
      if (eid == null || eid <= 0) continue;
      final int? pct = pair.length > 1 ? int.tryParse(pair[1].trim()) : null;
      result.add(AnidbEpisodeShare(episodeId: eid, percentage: pct ?? even));
    }
    return result;
  }

  /// `other episodes` 列（Shoko 两种格式）；认不出的格式当空（不因它废掉身份）。
  static List<AnidbEpisodeShare> _parseOtherEpisodes(String raw) {
    final String text = raw.trim();
    if (text.isEmpty) return const <AnidbEpisodeShare>[];
    final List<String> parts = text.split("'");
    final List<AnidbEpisodeShare> result = <AnidbEpisodeShare>[];
    if (RegExp(r"^(?:\d+'\d+)(?:'\d+'\d+)*$").hasMatch(text)) {
      for (int i = 0; i + 1 < parts.length; i += 2) {
        final int? eid = int.tryParse(parts[i]);
        final int? pct = int.tryParse(parts[i + 1]);
        if (eid != null && eid > 0 && pct != null) {
          result.add(AnidbEpisodeShare(episodeId: eid, percentage: pct));
        }
      }
    } else if (RegExp(r"^(?:\d+,\d+)(?:'\d+,\d+)*$").hasMatch(text)) {
      for (final String part in parts) {
        final List<String> pair = part.split(',');
        final int? eid = int.tryParse(pair[0]);
        final int? pct = int.tryParse(pair[1]);
        if (eid != null && eid > 0 && pct != null) {
          result.add(AnidbEpisodeShare(episodeId: eid, percentage: pct));
        }
      }
    }
    return result;
  }

  // fmask byte1: bit6 aid, bit5 eid, bit2 other episodes, bit1 deprecated,
  // bit0 state（Shoko 取 0x77，本仓不要 gid / mylist）。fid 恒为首列。
  // amask byte1 bit4 = anime type（Shoko 的作品形态来源；本仓 kind 跟它走）；
  // byte2 bits7/6/5 = anime titles; byte3 bits7..4 = epno/titles.
  Future<_Reply> _requestFile(int size, String ed2k) => _request('FILE', {
        'size': '$size',
        'ed2k': ed2k.toLowerCase(),
        'fmask': '6700000000',
        'amask': '10e0f000',
        's': _session!,
      });

  /// 按 eid 取集信息（主要是播出日）。240 → 信息；340 NO SUCH EPISODE → null。
  /// 与 [lookup] 同一条串行队列、同一套节流 / 退避 / 会话续期；每 eid 在客户端
  /// 寿命内只问一次。
  Future<AnidbEpisodeInfo?> episode({required int episodeId}) =>
      _serialize(() async {
        if (_closed) throw const AnidbUdpException(AnidbUdpFailure.closed);
        if (!config.isAvailable) {
          throw const AnidbUdpException(AnidbUdpFailure.unavailable);
        }
        if (_terminalFailure != null) throw _terminalFailure!;
        if (episodeId <= 0) {
          throw const AnidbUdpException(AnidbUdpFailure.invalidInput);
        }
        if (_episodes.containsKey(episodeId)) return _episodes[episodeId];
        if (_episodes.length >= 2048) _episodes.remove(_episodes.keys.first);
        await _ensureSession();
        _Reply reply = await _requestEpisode(episodeId);
        if (reply.code == 501 || reply.code == 506 || reply.code == 505) {
          _session = null;
          await _ensureSession();
          reply = await _requestEpisode(episodeId);
        }
        if (reply.code == 340) return _episodes[episodeId] = null;
        if (reply.code != 240) _fail(reply.code);
        final List<String> fields = reply.data.split('|');
        if (fields.length < 10) {
          throw const AnidbUdpException(AnidbUdpFailure.malformedResponse);
        }
        final int? eid = int.tryParse(fields[0]);
        final int? aid = int.tryParse(fields[1]);
        final int? aired = int.tryParse(fields[9].trim());
        if (eid == null ||
            eid <= 0 ||
            aid == null ||
            aid <= 0 ||
            aired == null ||
            !RegExp(r'^(?:[SCTPO])?\d+$').hasMatch(fields[5])) {
          throw const AnidbUdpException(AnidbUdpFailure.malformedResponse);
        }
        return _episodes[episodeId] = AnidbEpisodeInfo(
          episodeId: eid,
          animeId: aid,
          episodeNumber: fields[5],
          airedAt: aired <= 0
              ? null
              : DateTime.fromMillisecondsSinceEpoch(aired * 1000, isUtc: true),
          englishTitle: fields[6].trim(),
          romajiTitle: fields[7].trim(),
          kanjiTitle: fields[8].trim(),
        );
      });

  Future<_Reply> _requestEpisode(int episodeId) => _request('EPISODE', {
        'eid': '$episodeId',
        's': _session!,
      });

  /// Settings "test login": AUTH only, no FILE query. The caller must still
  /// await [close] so the session is released with a LOGOUT. Same flood/ban
  /// bookkeeping as a scan batch; a bad password is terminal for this client.
  Future<void> verifyLogin() => _serialize(() async {
        if (_closed) throw const AnidbUdpException(AnidbUdpFailure.closed);
        if (!config.isAvailable) {
          throw const AnidbUdpException(AnidbUdpFailure.unavailable);
        }
        if (_terminalFailure != null) throw _terminalFailure!;
        await _ensureSession();
      });

  Future<void> _ensureSession() async {
    if (_session != null) return;
    final Map<String, String> values = <String, String>{
      'user': config.username,
      'pass': config.password,
      'protover': '3',
      'client': config.clientName,
      'clientver': '${config.clientVersion}',
      'enc': 'UTF-8',
      'comp': '0',
    };
    _Reply auth;
    try {
      // 第一轮登录超时不进退避：Shoko `LoginWithFallbacks` 对登录超时先
      // `ForceReconnection`（重建 socket）再登一次，本地端口状态坏掉时这一步
      // 才是真正的修复。
      auth = await _request('AUTH', values, backoffOnTimeout: false);
    } on AnidbUdpException catch (error) {
      if (error.reason != AnidbUdpFailure.timeout) rethrow;
      final AnidbUdpTransport? stale = _transport;
      _transport = null;
      await stale?.close();
      auth = await _request('AUTH', values);
    }
    if (auth.code != 200 && auth.code != 201) _fail(auth.code);
    final RegExpMatch? sessionMatch = RegExp(
      r'^([a-zA-Z0-9]{4,8}) LOGIN ACCEPTED(?: - NEW VERSION AVAILABLE)?$',
    ).firstMatch(auth.message);
    if (sessionMatch == null) {
      throw const AnidbUdpException(AnidbUdpFailure.malformedResponse);
    }
    _session = sessionMatch[1]!;
    clientUpdateAvailable = auth.code == 201;
  }

  /// Shoko parity for a silent server (`AniDBUDPConnectionHandler.SendInternal`
  /// + `ConnectionHandler.IsBanned`): a request that gets no reply is resent
  /// once with the same tag, and if that is also silent the request fails with
  /// [AnidbUdpFailure.timeout] — it is **not** a ban. Shoko only treats
  /// `555 BANNED` (and an all-zero reply) as a ban, for `BanTimerResetLength`
  /// = 1.5 h; every other reply code clears the ban flag. Server-side "try
  /// again later" codes (600/601/602/604) start a 300 s backoff.
  ///
  /// Our previous rule "two silent datagrams ⇒ banned 90 min" turned every
  /// transient loss into a process-wide freeze: one FILE timing out mid-sweep
  /// made all remaining files of all works report "限流或维护" (BUG-2592).
  /// Instead consecutive timeouts back off exponentially (Shoko's queue
  /// `RetryPolicy`: 30 s × 2ⁿ) so a genuinely silent server is still probed
  /// only every few minutes, while a single lost datagram costs one file.
  static const Duration _serverBan = Duration(minutes: 90);
  static const Duration _serverBackoff = Duration(minutes: 5);
  static const Duration _timeoutBackoffBase = Duration(seconds: 30);
  static const Duration _timeoutBackoffMax = Duration(minutes: 10);
  static AnidbUdpFailure _blockedReason = AnidbUdpFailure.maintenance;
  static int _timeoutStreak = 0;

  /// Shoko `UDPRateLimiter`：`BaseRateInSeconds` 2、`SlowRateMultiplier` 3、
  /// `SlowRatePeriodMultiplier` 5、`ResetPeriodMultiplier` 60。
  static const int _shortDelayMs = 2000;
  static const int _longDelayMs = 6000;
  static const int _shortPeriodMs = 10000;
  static const int _resetPeriodMs = 120000;
  static int _lastSendMs = -1;
  static int _activeSinceMs = -1;

  /// 本包发出后到下一包的最小间隔：按「活跃时长」在短/长间隔间切换。
  static int _rateLimitDelayMs() {
    final int now = _nowMs;
    if (_lastSendMs < 0 || now - _lastSendMs > _resetPeriodMs) {
      _activeSinceMs = now;
    }
    _lastSendMs = now;
    return now - _activeSinceMs > _shortPeriodMs ? _longDelayMs : _shortDelayMs;
  }

  static void _block(AnidbUdpFailure reason, Duration duration) {
    _blockedUntilMs = _nowMs + duration.inMilliseconds;
    _blockedReason = reason;
  }

  /// 连续第 n 次双超时 → 退避 30 s × 2ⁿ⁻¹，封顶 10 分钟。
  static void _backoffAfterTimeout() {
    _timeoutStreak++;
    final int factor = 1 << (_timeoutStreak - 1).clamp(0, 30);
    final int ms = (_timeoutBackoffBase.inMilliseconds * factor)
        .clamp(0, _timeoutBackoffMax.inMilliseconds);
    _block(AnidbUdpFailure.backoff, Duration(milliseconds: ms));
  }

  /// 收到任何一条 AniDB 应答：链路是通的，清掉超时退避（Shoko：任何响应码都
  /// 把 `IsBanned` 写回 false）。真 ban（555/504）不由这里清——它们在收到应答
  /// 时才写入，且之后不再发包。
  static void _noteReply() {
    _timeoutStreak = 0;
    if (_blockedReason == AnidbUdpFailure.backoff) _blockedUntilMs = 0;
  }

  Future<_Reply> _request(String command, Map<String, String> values,
      {bool responseRequired = true, bool backoffOnTimeout = true}) async {
    final String tag = 'f${++_tag}';
    final String packet = '$command ${({
      ...values,
      'tag': tag
    }).entries.map((MapEntry<String, String> entry) => '${entry.key}=${_escape(entry.value)}').join('&')}';
    if (utf8.encode(packet).length > 1400) {
      throw const AnidbUdpException(AnidbUdpFailure.invalidInput);
    }
    for (int attempt = 0;; attempt++) {
      try {
        return await _exchangeOnce(command, packet, tag,
            responseRequired: responseRequired);
      } on AnidbUdpException catch (error) {
        if (error.reason == AnidbUdpFailure.network) _session = null;
        rethrow;
      } on TimeoutException {
        // Same tag on purpose: a late reply to the first datagram still
        // answers this command.
        if (attempt == 0 && responseRequired) continue;
        if (_gated && backoffOnTimeout) _backoffAfterTimeout();
        _session = null;
        throw const AnidbUdpException(AnidbUdpFailure.timeout);
      } catch (_) {
        _session = null;
        throw const AnidbUdpException(AnidbUdpFailure.network);
      }
    }
  }

  Future<_Reply> _exchangeOnce(String command, String packet, String tag,
      {required bool responseRequired}) async {
    _transport ??= await _factory(config);
    if (_closed && command != 'LOGOUT') {
      throw const AnidbUdpException(AnidbUdpFailure.closed);
    }
    // Shared across all clients in the app isolate（Shoko `UDPRateLimiter`）：
    // 基准 2 s 一包；连续活跃超过 10 s 后放慢到 6 s；空闲超过 120 s 重置回
    // 短间隔。AniDB 的"长期不超过四秒一包"由 6 s 段兜住。
    // In-memory test transports have no network and need no flood delay.
    if (_gated) {
      final Future<void> turn = _sendTail.then((_) async {
        if (_closed && command != 'LOGOUT') {
          throw const AnidbUdpException(AnidbUdpFailure.closed);
        }
        if (_nowMs < _blockedUntilMs) {
          throw AnidbUdpException(_blockedReason);
        }
        final int delay = _nextSendMs - _nowMs;
        if (delay > 0) await _sleep(Duration(milliseconds: delay));
        if (_closed && command != 'LOGOUT') {
          throw const AnidbUdpException(AnidbUdpFailure.closed);
        }
        if (_nowMs < _blockedUntilMs) {
          throw AnidbUdpException(_blockedReason);
        }
        _nextSendMs = _nowMs + _rateLimitDelayMs();
      });
      _sendTail = turn.then<void>(
        (_) {},
        onError: (Object _, StackTrace __) {},
      );
      await turn;
    }
    if (_closed && command != 'LOGOUT') {
      throw const AnidbUdpException(AnidbUdpFailure.closed);
    }
    if (!responseRequired) {
      await _transport!.send(packet);
      // No response was requested; this is not a successful server reply.
      return const _Reply(0, '', '');
    }
    final String raw = await _transport!.exchange(packet, tag, config.timeout);
    if (_gated) _noteReply();
    return _Reply.parse(raw, tag);
  }

  Never _fail(int code) {
    final AnidbUdpFailure reason = switch (code) {
      500 => AnidbUdpFailure.authentication,
      503 => AnidbUdpFailure.clientOutdated,
      504 => AnidbUdpFailure.clientBanned,
      555 => AnidbUdpFailure.banned,
      501 || 505 || 506 || 598 => AnidbUdpFailure.session,
      502 => AnidbUdpFailure.accessDenied,
      600 || 601 || 602 || 604 => AnidbUdpFailure.maintenance,
      _ => AnidbUdpFailure.server,
    };
    // Shoko：505 ⇒ IsInvalidSession，506/598 ⇒ ClearSession，ban ⇒ 清会话。
    if (reason == AnidbUdpFailure.session || code == 555 || code == 504) {
      _session = null;
    }
    if (_gated) {
      if (code == 555 || code == 504) {
        _block(reason, _serverBan);
      } else if (reason == AnidbUdpFailure.maintenance) {
        // Shoko `UDPRequest.ParseResponse`：600/601/602/604 → 300 s backoff。
        _block(reason, _serverBackoff);
      }
    }
    if (code == 500 || code == 503 || code == 504 || code == 555) {
      // Stop a queued scan from repeatedly authenticating bad credentials.
      // A new client after changing configuration may try again.
      _terminalFailure = AnidbUdpException(reason, code: code);
    }
    throw AnidbUdpException(reason, code: code);
  }

  /// Cancels the pending receive immediately, sends a best-effort LOGOUT at the
  /// next permitted send slot, then releases the fixed local port. Does not wait
  /// for LOGOUT acknowledgement. Callers must await this before opening a batch.
  Future<void> close() {
    if (_closing != null) return _closing!;
    _closed = true;
    _idleTimer?.cancel();
    _idleTimer = null;
    _transport?.cancelPending();
    final Future<void> closing = _closing = _serialize(() async {
      try {
        if (_session != null) {
          await _request('LOGOUT', {'s': _session!}, responseRequired: false);
        }
      } on AnidbUdpException {
        // Best-effort logout; never keep the local socket open after failure.
      } finally {
        _session = null;
        await _transport?.close();
        _transport = null;
      }
    });
    if (_transport is AnidbDatagramTransport) {
      AnidbDatagramTransport._registerClosing(config.localPort, closing);
    }
    return closing;
  }
}

// AniDB specifies HTML entities, NOT URI percent/form-url encoding.
String _escape(String value) => value
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('\r\n', '\n')
    .replaceAll('\r', '\n')
    .replaceAll('\n', '<br />');

class _Reply {
  const _Reply(this.code, this.message, this.data);
  final int code;
  final String message, data;
  static _Reply parse(String text, String tag) {
    final List<String> lines = text.trimRight().split('\n');
    final String header = lines.first;
    final String bare =
        header.startsWith('$tag ') ? header.substring(tag.length + 1) : header;
    final RegExpMatch? match = RegExp(r'^(\d{3}) (.*)$').firstMatch(bare);
    if (match == null ||
        (!header.startsWith('$tag ') && !bare.startsWith('6'))) {
      throw const AnidbUdpException(AnidbUdpFailure.malformedResponse);
    }
    final String data = lines.length > 1 ? lines[1] : '';
    return _Reply(
      int.parse(match[1]!),
      match[2]!,
      (data.startsWith('$tag ') ? data.substring(tag.length + 1) : data)
          .replaceAll('<br />', '\n'),
    );
  }
}

/// Fixed local port, source endpoint verification, and one outstanding request.
class AnidbDatagramTransport implements AnidbUdpTransport {
  AnidbDatagramTransport._(this._socket, this._remote, this._port);
  final RawDatagramSocket _socket;
  final InternetAddress _remote;
  final int _port;
  StreamSubscription<RawSocketEvent>? _subscription;
  Completer<String>? _pending;
  String? _expectedTag;
  static final Map<int, Future<void>> _closingByPort = {};

  static void _registerClosing(int port, Future<void> closing) {
    // A failed best-effort logout must not prevent a new owner using the port
    // after the socket has been released. The caller still receives its error.
    final Future<void> released =
        closing.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    _closingByPort[port] = released;
    unawaited(released.then((_) {
      if (identical(_closingByPort[port], released)) {
        _closingByPort.remove(port);
      }
    }));
  }

  static Future<AnidbUdpTransport> connect(AnidbUdpConfig config) async {
    final List<InternetAddress> addresses = await InternetAddress.lookup(
      config.host,
      type: InternetAddressType.IPv4,
    ).timeout(config.timeout);
    // A coordinator may dispose without awaiting close and its successor may
    // immediately start a scan. Wait only for a known closing owner, never for
    // an active client or by changing to another (AniDB rate-sensitive) port.
    await _closingByPort[config.localPort];
    final RawDatagramSocket socket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      config.localPort,
      reuseAddress: false,
    );
    final AnidbDatagramTransport transport = AnidbDatagramTransport._(
      socket,
      addresses.first,
      config.port,
    );
    transport._subscription = socket.listen(
      transport._onEvent,
      onError: (Object _) => transport._failPending(),
      onDone: transport._failPending,
    );
    return transport;
  }

  void _failPending() {
    final Completer<String>? pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const AnidbUdpException(AnidbUdpFailure.network));
    }
  }

  void _onEvent(RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    Datagram? datagram;
    while ((datagram = _socket.receive()) != null) {
      final Datagram received = datagram!;
      if (received.address.address != _remote.address ||
          received.port != _port) {
        continue;
      }
      final Completer<String>? pending = _pending;
      if (pending == null || pending.isCompleted) continue;
      String text;
      try {
        text = utf8.decode(received.data);
      } on FormatException {
        continue;
      }
      if (!text.startsWith('$_expectedTag ') &&
          !RegExp(r'^6\d\d ').hasMatch(text)) {
        continue;
      }
      pending.complete(text);
    }
  }

  @override
  Future<String> exchange(String packet, String tag, Duration timeout) async {
    if (_pending != null) throw StateError('AniDB request already pending');
    final Completer<String> pending = Completer<String>();
    _pending = pending;
    _expectedTag = tag;
    try {
      _sendDatagram(packet);
      return await pending.future.timeout(timeout);
    } finally {
      _pending = null;
      _expectedTag = null;
    }
  }

  @override
  Future<void> send(String packet) async {
    _sendDatagram(packet);
  }

  void _sendDatagram(String packet) {
    final List<int> bytes = utf8.encode(packet);
    if (_socket.send(bytes, _remote, _port) != bytes.length) {
      throw const AnidbUdpException(AnidbUdpFailure.network);
    }
  }

  @override
  void cancelPending() {
    final Completer<String>? pending = _pending;
    if (pending != null && !pending.isCompleted) {
      pending.completeError(const AnidbUdpException(AnidbUdpFailure.closed));
    }
  }

  @override
  Future<void> close() async {
    _failPending();
    _socket.close();
    await _subscription?.cancel();
  }
}
