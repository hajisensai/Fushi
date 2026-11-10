import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:fushi/src/sync/interconnect_post_transport.dart';
import 'package:fushi/src/sync/remote_dictionary_reachability.dart';
import 'package:fushi/src/sync/sync_repository.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi_engine/dictionary/dictionary_media_types.dart'
    show kRemoteDictionaryMediaMaxBytes, safeDictionaryMediaPath;
import 'package:fushi_engine/sync/fushi_remote_lookup_service.dart'
    show
        RemoteLookupDictionaryConfig,
        kRemoteLookupChineseScriptVariantsField,
        kRemoteLookupDictionariesField,
        kRemoteLookupDictionaryConfigAppliedField,
        kRemoteLookupLanguageField,
        kRemoteLookupRubyField;
import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'package:http/http.dart' as http;
import 'package:path/path.dart' as p;

/// 互联配对查询：本次调用尝试了至少一个已启用候选地址，但**没有任何一个候选
/// 返回过 HTTP 响应**（连接拒绝 / 超时 / DNS 解析失败等传输层失败）——即
/// 「配对设备不可达」。与「设备可达但没有这个词的结果」（返回 null，含
/// 404/405/非 2xx/正常空结果）在传输层严格区分，供上层（WordAudioResolver）
/// 对 fushi-remote 音频源做失败冷却（对齐 remoteAudio 源的 TODO-1057/BUG-488
/// 机制）。音频路径 [FushiRemoteLookupClient.lookupAudioUrl] 与词典路径
/// [FushiRemoteLookupClient.searchDictionary] 现在**对称**抛出：词典路径此前是
/// 全仓唯一不消费 `allUnreachable` 的调用点，导致配对设备离线时每次查词都要把
/// 「3s × 候选数」重付一遍（BUG-1302）。
class RemoteLookupUnreachableError implements Exception {
  RemoteLookupUnreachableError(this.message);

  final String message;

  @override
  String toString() => 'RemoteLookupUnreachableError: $message';
}

const Duration kRemoteAudioMaterializedCacheTtl = Duration(days: 7);
const int kRemoteAudioMaterializedCacheMaxBytes = 64 * 1024 * 1024;

class FushiRemoteLookupClient {
  FushiRemoteLookupClient({
    required SyncRepository repo,
    FushiClientUrl? onlyCandidate,
    http.Client? httpClient,
    http.Client Function(String expectedFingerprint)? pinnedClientFactory,
    Future<Directory> Function()? pinnedAudioCacheDirectoryProvider,
    Duration timeout = const Duration(seconds: 3),
    Duration audioTransferTimeout = kInterconnectAssetTransferTimeout,
    bool trackDictionaryStyles = false,
    bool Function(String hostId)? skipDictionaryHost,
    void Function(Map<String, bool> reachableByHost)? onDictionaryHostOutcomes,
  }) : _transport = InterconnectPostTransport(
         repo: repo,
         httpClient: httpClient,
         pinnedClientFactory: pinnedClientFactory,
       ),
       _onlyCandidate = onlyCandidate,
       _timeout = timeout,
       _audioTransferTimeout = audioTransferTimeout,
       _trackDictionaryStyles = trackDictionaryStyles,
       _skipDictionaryHost = skipDictionaryHost,
       _onDictionaryHostOutcomes = onDictionaryHostOutcomes,
       _pinnedAudioCacheDirectoryProvider =
           pinnedAudioCacheDirectoryProvider ??
           _defaultPinnedAudioCacheDirectory;

  /// 候选轮询 / 鉴权 / 指纹钉扎 / socket 回收统一由 [InterconnectPostTransport]
  /// 承担——本类只管端点、超时与响应体的语义解析。
  final InterconnectPostTransport _transport;
  final FushiClientUrl? _onlyCandidate;

  /// RPC 往返预算：量的是「对端还活着吗」。
  ///
  /// 3s 保持不变（BUG-4275 复核过）：它包住的是整个查词往返（host 上的查词本身 +
  /// 回包，走 Tailscale / 公网时单程就几百 ms），缩短会把慢而活着的 host 误判成死的，
  /// 造成远端结果时有时无。离线的代价不靠缩短它来降，而是靠可达性追踪只付一次：判死
  /// 之后查词直接跳过（[_skipDictionaryHost]），恢复由后台探测发现。
  final Duration _timeout;

  /// 词典端点要跳过的 host（[remoteDictionaryHostIdOf] 口径）：可达性追踪判为不可达的
  /// host 不再发请求（BUG-4275）。全部跳过 = 没有候选 = 「无结果」（返回 null），不抛
  /// [RemoteLookupUnreachableError]——那只留给真正试过且全失败的那一次。
  final bool Function(String hostId)? _skipDictionaryHost;

  /// 每次词典端点请求后按 host 报传输层结局（[RemoteHostOutcomes.reachableByHost]），
  /// 交给共享的可达性追踪（[RemoteDictionaryReachability.record]）。
  final void Function(Map<String, bool> reachableByHost)?
  _onDictionaryHostOutcomes;

  /// 音频资产整包下载预算：量的是字节传输，与 [_timeout] 不同量纲（BUG-1811 续）。
  final Duration _audioTransferTimeout;
  final Future<Directory> Function() _pinnedAudioCacheDirectoryProvider;

  /// BUG-3425：查词时是否按 `stylesRevision` 门控顺带取 host 的词典自带样式。
  ///
  /// 只给**在本端渲染并导出远端结果**、且实例跨查词复用的调用方开（游戏串流、
  /// `AppModel` 的 remote-first 查词，BUG-3612）。开着时返回的结果带上
  /// [DictionarySearchResult.remoteDictionaryStyles]。
  /// 首查发空指纹，host 整表下发一次；之后带上缓存的指纹，host 只回指纹。每次
  /// 查词都新建实例的调用方开了等于每次整表重下，所以默认关、请求体不变。
  final bool _trackDictionaryStyles;
  String? _dictionaryStylesRevision;
  Map<String, String>? _hostDictionaryStyles;

  /// host 最近一次下发的词典样式（词典名 → CSS）。指纹不变期间保持**同一个**
  /// 不可变实例（弹窗按身份判断要不要重注入）。null = 还没查过，或 host 不认识
  /// `stylesRevision`（老 host：回包里没有 `dictionaryStylesRevision`）——调用方
  /// 此时自行回落 [dictionaryStyles] 端点。
  Map<String, String>? get hostDictionaryStyles => _hostDictionaryStyles;

  /// [hostDictionaryStyles] 对应的 host 指纹。
  String? get dictionaryStylesRevision => _dictionaryStylesRevision;

  /// 每台 host（[remoteDictionaryHostIdOf]）最近一次**带了词典选择**的查词回执：
  /// true = host 按请求方的选择查了（回包 `dictionaryConfigApplied: true`）；
  /// false = host 收到了选择却没套用（老 host 不认这个字段）——UI 据此提示
  /// 「这台服务器还不支持按配置选词典」。没发过选择的 host 不在表里。
  final Map<String, bool> _dictionaryConfigAppliedByHost = <String, bool>{};

  /// [_dictionaryConfigAppliedByHost] 的只读视图。
  Map<String, bool> get dictionaryConfigAppliedByHost =>
      Map<String, bool>.unmodifiable(_dictionaryConfigAppliedByHost);

  static Future<Directory> _defaultPinnedAudioCacheDirectory() async {
    final Directory supportRoot = await AppPaths.supportRootDirectory();
    return Directory(p.join(supportRoot.path, 'remote_lookup_audio_cache'));
  }

  /// 查远端词典。三种结局（与 [lookupAudioUrl] 对称）：
  /// - 返回结果：某候选可达且有词条；
  /// - 返回 null：可达但无结果（含 404/405/非 2xx/空结果），或根本未配对；
  /// - 抛 [RemoteLookupUnreachableError]：所有已启用候选全部传输层失败
  ///   （连接拒绝/超时/DNS）——「配对设备死了」，供上层计入失败冷却。
  ///
  /// 为什么词典路径也必须抛（BUG-1302）：远端查词排在本地缓存**之前**
  /// （`AppModel.searchDictionary` 的 remote-first 语义），配对设备离线/换网/
  /// 休眠时每次查词都要把「3s × 候选数」全额付一遍，且因为短路在缓存之前，
  /// 重复查同一个词也不例外——这正是用户报的「某些机器上查词要 4-5 秒」。
  ///
  /// [language]：本端这次查词的语言（BCP-47）。带上后 host 按它而不是 host 自己正在读
  /// 的内容决定是否开简体 → 繁體回落；null / 空串不发该字段（旧 host 本就忽略它）。
  ///
  /// [chineseScriptVariants]：本端用户的简繁互查开关。非 null 才发 `zhScriptVariants`
  /// 字段，host 用它代替自己的开关；旧 host 忽略它，按旧行为（中文语言即互查）。
  ///
  /// [rubySpans]：原文自带振假名（以 [term] 为坐标系）。非空才发 `ruby` 字段，host 让引擎
  /// 把读音吻合的同长度候选排前面；空时请求体与旧版逐字相同（旧 host 本就忽略该字段）。
  ///
  /// [dictionaryConfigFor]：按候选（即按 host）给出本端生效配置对这台 host 的词典选择
  /// （`DictionaryRepository.filtersForHost`）。返回非 null 才发 `dictionaries` 字段，
  /// host 把它当这次请求的唯一真相；null / 不传时请求体与旧版逐字相同。只发给开着
  /// [FushiClientUrl.lookupEnabled] 的地址。
  Future<DictionarySearchResult?> searchDictionary({
    required String term,
    required bool wildcards,
    required int maximumTerms,
    String? language,
    bool? chineseScriptVariants,
    List<FushiRubySpan> rubySpans = const <FushiRubySpan>[],
    RemoteLookupDictionaryConfig? Function(FushiClientUrl candidate)?
    dictionaryConfigFor,
  }) async {
    final String? lookupLanguage = (language == null || language.trim().isEmpty)
        ? null
        : language.trim();
    final Map<String, dynamic> body = <String, dynamic>{
      'term': term,
      'wildcards': wildcards,
      'maximumTerms': maximumTerms,
      if (lookupLanguage != null) kRemoteLookupLanguageField: lookupLanguage,
      if (chineseScriptVariants != null)
        kRemoteLookupChineseScriptVariantsField: chineseScriptVariants,
      if (rubySpans.isNotEmpty)
        kRemoteLookupRubyField: FushiRubySpan.listToWire(rubySpans),
      // 空串 ≠ 任何 host 指纹 ⇒ 首查必拿到整表。
      if (_trackDictionaryStyles)
        'stylesRevision': _dictionaryStylesRevision ?? '',
    };
    // 每台 host 各自的选择：同一 host 的多条地址算出同一份，只算一次。
    final Map<String, RemoteLookupDictionaryConfig?> configByHost =
        <String, RemoteLookupDictionaryConfig?>{};
    RemoteLookupDictionaryConfig? configFor(FushiClientUrl candidate) =>
        configByHost.putIfAbsent(
          remoteDictionaryHostIdOf(candidate),
          () => dictionaryConfigFor!(candidate),
        );
    final InterconnectPostOutcome outcome = await _postLookup(
      path: '/api/lookup/dictionary',
      body: body,
      bodyFor: dictionaryConfigFor == null
          ? null
          : (FushiClientUrl candidate) {
              final RemoteLookupDictionaryConfig? config = configFor(candidate);
              return config == null
                  ? null
                  : <String, dynamic>{
                      ...body,
                      kRemoteLookupDictionariesField: config.toJson(),
                    };
            },
    );
    final FushiClientUrl? winner = outcome.candidate;
    if (winner != null && outcome.json != null) {
      final String hostId = remoteDictionaryHostIdOf(winner);
      if (configByHost[hostId] != null) {
        _dictionaryConfigAppliedByHost[hostId] =
            outcome.json![kRemoteLookupDictionaryConfigAppliedField] == true;
      }
    }
    if (outcome.allUnreachable) {
      throw RemoteLookupUnreachableError(
        'all enabled paired candidates failed at the transport layer '
        '(connection refused / timeout / DNS) for /api/lookup/dictionary',
      );
    }
    final Map<String, dynamic>? json = outcome.json;
    if (_trackDictionaryStyles && json != null) {
      _adoptHostDictionaryStyles(json);
    }
    if (json == null || json['type'] != 'dictionaryResult') return null;
    final dynamic resultJson = json['result'];
    if (resultJson is! Map) return null;
    final DictionarySearchResult result = _parseDictionaryResult(
      Map<String, dynamic>.from(resultJson),
    );
    result.popupJson = json['popupJson']?.toString();
    // BUG-3612：结果在本端渲染 / 导出，随附 host 的词典样式，弹窗按结果判断用哪份
    // （老 host 不认 `stylesRevision` 时为 null，弹窗照旧用本机样式）。
    if (_trackDictionaryStyles) {
      result.remoteDictionaryStyles = _hostDictionaryStyles;
    }
    // BUG-1570：kanji-only 结果（单字命中汉字词典但无词条）也算有效结果——与本地
    // 路径的 kanjiOnly 分支同语义。瘦 client（本地无词典）此前会把它当「无结果」
    // 丢掉转本地兜底，而本地根本没有汉字词典。
    return (result.entries.isEmpty && result.kanjiResults.isEmpty)
        ? null
        : result;
  }

  /// 读回包里的 `dictionaryStylesRevision` / `dictionaryStyles`（BUG-3425）：
  /// - 没有指纹（老 host）⇒ 什么都不动；
  /// - 指纹与缓存相同 ⇒ 沿用缓存实例（host 本就不会重发正文）；
  /// - 指纹变了且带正文 ⇒ 换成新的不可变实例并记下指纹；只有指纹没有正文（不该
  ///   发生）⇒ 不记指纹，下次照旧要整表。
  void _adoptHostDictionaryStyles(Map<String, dynamic> json) {
    final Object? revision = json['dictionaryStylesRevision'];
    if (revision is! String) return;
    if (revision == _dictionaryStylesRevision) return;
    final Object? styles = json['dictionaryStyles'];
    if (styles is! Map) return;
    _hostDictionaryStyles = Map<String, String>.unmodifiable(<String, String>{
      for (final MapEntry<Object?, Object?> e in styles.entries)
        if (e.key is String && e.value is String)
          e.key! as String: e.value! as String,
    });
    _dictionaryStylesRevision = revision;
  }

  DictionarySearchResult _parseDictionaryResult(Map<String, dynamic> json) {
    final List<DictionaryEntry> entries = <DictionaryEntry>[];
    final dynamic entriesJson = json['entries'];
    if (entriesJson is List) {
      for (final dynamic entry in entriesJson) {
        if (entry is String) {
          entries.add(DictionaryEntry.fromJson(entry));
        } else if (entry is Map) {
          entries.add(DictionaryEntry.fromJson(jsonEncode(entry)));
        }
      }
    }
    // BUG-1570：host 发的 `result` 是 DictionarySearchResult.toJson() 全量字段，
    // 这里此前只取 searchTerm/bestLength/scrollPosition/entries 四个，把
    // truncated / headwordCount / kanjiResults 静默丢掉。后果（remote-first 语义下
    // 远端结果直接返回、不再走本地富化）：截断标志恒 false → 「加载更多」永不出现
    // （BUG-1472 在远端路径整个失效）；headwordCount 恒 0 → 即便分页也拿错基数
    // （BUG-1478 同理失效）；单字查询的汉字卡（kanjiResults）在远端结果里恒空。
    // 老 host 不发这些字段时保持原默认值，行为不变。
    final List<FushiKanjiResult> kanjiResults = <FushiKanjiResult>[];
    final dynamic kanjiJson = json['kanjiResults'];
    if (kanjiJson is List) {
      for (final dynamic kanji in kanjiJson) {
        if (kanji is Map) {
          kanjiResults.add(
            FushiKanjiResult.fromMap(Map<String, dynamic>.from(kanji)),
          );
        }
      }
    }
    return DictionarySearchResult(
      searchTerm: json['searchTerm']?.toString() ?? '',
      bestLength: (json['bestLength'] as num?)?.toInt() ?? 0,
      scrollPosition: (json['scrollPosition'] as num?)?.toInt() ?? 0,
      truncated: json['truncated'] as bool? ?? false,
      headwordCount: (json['headwordCount'] as num?)?.toInt() ?? 0,
      kanjiResults: kanjiResults,
      entries: entries,
    );
  }

  /// 查远端单词音频。三种结局：
  /// - 返回可播放 ref：明文 HTTP peer 保持短命 URL；带指纹的 HTTPS peer 由本类
  ///   使用同一指纹取回字节并物化成本地文件，避免 WebView/native player 丢失钉扎；
  /// - 返回 null：可达但无音频（含 404/405/非 2xx/正常空结果），或根本未配对；
  /// - 抛 [RemoteLookupUnreachableError]：所有已启用候选全部传输层失败
  ///   （连接拒绝/超时/DNS）——「配对设备死了」，供上层计入失败冷却。
  Future<String?> lookupAudioUrl({
    required String expression,
    required String reading,
  }) async {
    final InterconnectPostOutcome outcome = await _postLookup(
      path: '/api/lookup/audio',
      body: <String, dynamic>{'expression': expression, 'reading': reading},
      dictionaryLookup: false,
    );
    if (outcome.allUnreachable) {
      throw RemoteLookupUnreachableError(
        'all enabled paired candidates failed at the transport layer '
        '(connection refused / timeout / DNS) for /api/lookup/audio',
      );
    }
    final Map<String, dynamic>? json = outcome.json;
    if (json == null || json['type'] != 'audioResult') return null;
    final String? urlText = json['url'] as String?;
    if (urlText == null || urlText.isEmpty) return null;
    final Uri? uri = Uri.tryParse(urlText);
    final FushiClientUrl? candidate = outcome.candidate;
    final String? fingerprint = candidate?.fingerprintSha256;
    final bool pinnedCandidate =
        candidate != null && fingerprint != null && fingerprint.isNotEmpty;
    if (!pinnedCandidate) return urlText;
    if (uri == null || !uri.isScheme('https')) return null;

    final InterconnectBytesOutcome? asset;
    try {
      asset = await _transport.getLookupAudioBytes(
        candidate: candidate,
        uri: uri,
        timeout: _timeout,
        transferTimeout: _audioTransferTimeout,
      );
    } on InterconnectAssetUnreachableError catch (error, stack) {
      Error.throwWithStackTrace(
        RemoteLookupUnreachableError(
          'paired candidate succeeded at /api/lookup/audio but its pinned '
          'audio asset was unreachable: $error',
        ),
        stack,
      );
    }
    if (asset == null) return null;
    return _materializePinnedAudio(
      asset.bytes,
      cache: await _pinnedAudioCacheDirectoryProvider(),
      contentType: asset.contentType ?? json['contentType']?.toString(),
    );
  }

  /// 远端词典自带的 CSS（`/api/lookup/dictionary/styles`）：查词结果来自对端时，
  /// 弹窗必须用**对端**这份样式渲染（本机未必装了同名词典，装了也可能是另一版）。
  /// - 返回 map：只含对端确实装着的词典（可能为空——老 host 没这个端点也是空）；
  /// - 抛 [RemoteLookupUnreachableError]：与 [searchDictionary] 同一判据。
  ///
  /// [dictionaries] 为 null 时取对端整套样式。
  Future<Map<String, String>> dictionaryStyles([
    Iterable<String>? dictionaries,
  ]) async {
    final List<String>? names = dictionaries?.toSet().toList();
    if (names != null && names.isEmpty) return const <String, String>{};
    final InterconnectPostOutcome outcome = await _postLookup(
      path: '/api/lookup/dictionary/styles',
      body: <String, dynamic>{if (names != null) 'dictionaries': names},
    );
    if (outcome.allUnreachable) {
      throw RemoteLookupUnreachableError(
        'all enabled paired candidates failed at the transport layer '
        '(connection refused / timeout / DNS) for /api/lookup/dictionary/styles',
      );
    }
    final Map<String, dynamic>? json = outcome.json;
    final Object? styles = json?['styles'];
    if (json == null || json['type'] != 'dictionaryStyles' || styles is! Map) {
      return const <String, String>{};
    }
    return <String, String>{
      for (final MapEntry<Object?, Object?> e in styles.entries)
        if (e.key is String &&
            e.value is String &&
            (names == null || names.contains(e.key)))
          e.key! as String: e.value! as String,
    };
  }

  /// 远端词典媒体文件（外字 / 音调图 / 词典脚本，`/api/lookup/dictionary/media`）。
  /// 路径先在本端按与 host 同一判据（[safeDictionaryMediaPath]）收紧，越级的请求根本
  /// 不发出去；回包超过 [kRemoteDictionaryMediaMaxBytes] 视为无效。
  /// - 返回 null：路径非法 / 对端没有这个文件 / 老 host；
  /// - 抛 [RemoteLookupUnreachableError]：与 [searchDictionary] 同一判据。
  Future<RemoteDictionaryMedia?> dictionaryMedia({
    required String dictionary,
    required String path,
  }) async {
    final String? safePath = safeDictionaryMediaPath(path);
    if (dictionary.isEmpty || safePath == null) return null;
    final InterconnectPostOutcome outcome = await _postLookup(
      path: '/api/lookup/dictionary/media',
      body: <String, dynamic>{'dictionary': dictionary, 'path': safePath},
      // 媒体是字节传输，不是「对端还活着吗」的 RPC 往返（见 [_audioTransferTimeout]）。
      timeout: _audioTransferTimeout,
    );
    if (outcome.allUnreachable) {
      throw RemoteLookupUnreachableError(
        'all enabled paired candidates failed at the transport layer '
        '(connection refused / timeout / DNS) for /api/lookup/dictionary/media',
      );
    }
    final Map<String, dynamic>? json = outcome.json;
    final Object? data = json?['data'];
    final Object? contentType = json?['contentType'];
    if (json == null ||
        json['type'] != 'dictionaryMedia' ||
        data is! String ||
        contentType is! String ||
        contentType.isEmpty) {
      return null;
    }
    final Uint8List bytes;
    try {
      bytes = base64Decode(data);
    } on FormatException {
      return null;
    }
    if (bytes.isEmpty || bytes.length > kRemoteDictionaryMediaMaxBytes) {
      return null;
    }
    return RemoteDictionaryMedia(bytes: bytes, contentType: contentType);
  }

  /// 后台再探测一台判死的词典 host（[remoteDictionaryHostIdOf] 口径）：用 [_timeout]
  /// 的预算 GET 一次目录清单（[kRemoteDictionaryCatalogPath]，与主进程目录服务的探测
  /// 同一个端点），只看传输层结局并经 [_onDictionaryHostOutcomes] 记回可达性追踪；
  /// 回包内容不用。给没有目录服务的进程（`:popup` / 悬浮词典 engine）挂到
  /// [RemoteDictionaryReachability.probe]，查词路径本身因此从不在已知死掉的 host 上等。
  /// 凭据被拒（401）照样记成可达（对端活着），异常交给追踪器记日志。
  Future<void> probeDictionaryHost(String hostId) async {
    final RemoteHostOutcomes outcomes = RemoteHostOutcomes();
    try {
      await _transport.getJson(
        path: kRemoteDictionaryCatalogPath,
        timeout: _timeout,
        authErrorMessage: 'Fushi server rejected dictionary catalog token',
        candidateFilter: (FushiClientUrl candidate) =>
            candidate.isDictionaryLookupCandidate &&
            remoteDictionaryHostIdOf(candidate) == hostId,
        onCandidateOutcome: outcomes.add,
      );
    } finally {
      if (!outcomes.isEmpty) {
        _onDictionaryHostOutcomes?.call(outcomes.reachableByHost);
      }
    }
  }

  /// [dictionaryLookup]：词典端点（查词 / 词典样式 / 词典媒体）只发给开着
  /// [FushiClientUrl.lookupEnabled] 的地址——关掉「用这台服务器查词典」的 host 既不该
  /// 回答查词，样式与外字也不该从它那儿取。音频端点不受这个开关影响。
  ///
  /// 词典端点还按共享可达性追踪跳过已知不可达的 host，并把每台 host 这次的传输层
  /// 结局报回去（BUG-4275）；音频端点两者都不做（它有自己的失败冷却）。
  Future<InterconnectPostOutcome> _postLookup({
    required String path,
    required Map<String, dynamic> body,
    Duration? timeout,
    bool dictionaryLookup = true,
    Map<String, dynamic>? Function(FushiClientUrl candidate)? bodyFor,
  }) async {
    final bool Function(String hostId)? skip = _skipDictionaryHost;
    final RemoteHostOutcomes? outcomes =
        dictionaryLookup && _onDictionaryHostOutcomes != null
        ? RemoteHostOutcomes()
        : null;
    try {
      return await _transport.post(
        path: path,
        body: body,
        timeout: timeout ?? _timeout,
        authErrorMessage: 'Fushi server rejected remote lookup token',
        onlyCandidate: _onlyCandidate,
        bodyFor: bodyFor,
        candidateFilter: dictionaryLookup
            ? (FushiClientUrl candidate) =>
                  candidate.lookupEnabled &&
                  !(skip?.call(remoteDictionaryHostIdOf(candidate)) ?? false)
            : null,
        onCandidateOutcome: outcomes?.add,
      );
    } finally {
      // 凭据被拒（抛 SyncAuthError）也照记：拿到了 401 就说明 host 活着。
      if (outcomes != null && !outcomes.isEmpty) {
        _onDictionaryHostOutcomes!(outcomes.reachableByHost);
      }
    }
  }
}

/// 对端词典媒体文件（[FushiRemoteLookupClient.dictionaryMedia]）。
class RemoteDictionaryMedia {
  const RemoteDictionaryMedia({required this.bytes, required this.contentType});

  final Uint8List bytes;
  final String contentType;
}

Future<String?> _materializePinnedAudio(
  List<int> bytes, {
  required Directory cache,
  required String? contentType,
}) async {
  if (bytes.isEmpty) return null;
  final String digest = sha256.convert(bytes).toString();
  final String extension = _audioExtensionForContentType(contentType);
  await cache.create(recursive: true);
  final File output = File(p.join(cache.path, '$digest.$extension'));
  if (await output.exists()) {
    if (await _fileMatchesDigest(output, digest)) {
      await output.setLastAccessed(DateTime.now());
      return output.path;
    }
    await output.delete();
  }

  // 淘汰只发生在写路径上：自动发音是热路径，缓存命中不该再付一次「全目录 list +
  // 逐文件 stat」。写前 prune 保证新文件落盘后不会把缓存顶出上限。
  await _pruneRemoteAudioCache(cache);

  // Publish atomically: simultaneous lookups for the same clip may race, but
  // no player should ever observe a half-written file.
  final Directory staging = await cache.createTemp('write_');
  try {
    final File temporary = File(p.join(staging.path, 'audio.$extension'));
    await temporary.writeAsBytes(bytes, flush: true);
    try {
      await temporary.rename(output.path);
    } on FileSystemException {
      if (!await output.exists() || !await _fileMatchesDigest(output, digest)) {
        rethrow;
      }
    }
    await output.setLastAccessed(DateTime.now());
    await _pruneRemoteAudioCache(cache, protectedPath: output.path);
    return output.path;
  } finally {
    if (await staging.exists()) {
      await staging.delete(recursive: true);
    }
  }
}

Future<bool> _fileMatchesDigest(File file, String expectedDigest) async {
  try {
    final Digest actual = await sha256.bind(file.openRead()).first;
    return actual.toString() == expectedDigest;
  } on FileSystemException {
    return false;
  }
}

Future<void> _pruneRemoteAudioCache(
  Directory cache, {
  String? protectedPath,
}) async {
  final DateTime now = DateTime.now();
  final DateTime expiresBefore = now.subtract(kRemoteAudioMaterializedCacheTtl);
  final DateTime staleStagingBefore = now.subtract(const Duration(hours: 1));
  final List<({File file, FileStat stat})> survivors =
      <({File file, FileStat stat})>[];

  await for (final FileSystemEntity entity in cache.list(followLinks: false)) {
    try {
      final FileStat stat = await entity.stat();
      if (entity is Directory) {
        if (p.basename(entity.path).startsWith('write_') &&
            stat.modified.isBefore(staleStagingBefore)) {
          await entity.delete(recursive: true);
        }
        continue;
      }
      if (entity is! File) continue;
      if (entity.path != protectedPath &&
          stat.accessed.isBefore(expiresBefore)) {
        await entity.delete();
        continue;
      }
      survivors.add((file: entity, stat: stat));
    } on FileSystemException {
      // Cache cleanup is best-effort. A concurrent lookup can rename/delete an
      // entry between list() and stat()/delete(); the next pass reconciles it.
    }
  }

  int totalBytes = survivors.fold<int>(
    0,
    (int total, ({File file, FileStat stat}) entry) => total + entry.stat.size,
  );
  survivors.sort((a, b) => a.stat.accessed.compareTo(b.stat.accessed));
  for (final ({File file, FileStat stat}) entry in survivors) {
    if (totalBytes <= kRemoteAudioMaterializedCacheMaxBytes) break;
    if (entry.file.path == protectedPath) continue;
    try {
      await entry.file.delete();
      totalBytes -= entry.stat.size;
    } on FileSystemException {
      // Concurrent cache consumers may already have removed this entry.
    }
  }
}

String _audioExtensionForContentType(String? raw) {
  final String contentType = (raw ?? '').split(';').first.trim().toLowerCase();
  return switch (contentType) {
    'audio/ogg' || 'audio/opus' => 'ogg',
    'audio/mp4' || 'audio/aac' => 'm4a',
    'audio/wav' || 'audio/x-wav' => 'wav',
    'audio/flac' || 'audio/x-flac' => 'flac',
    'audio/webm' => 'webm',
    _ => 'mp3',
  };
}
