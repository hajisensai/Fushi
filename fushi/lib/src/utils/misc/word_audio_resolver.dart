import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/models/audio_source_config.dart';
import 'package:fushi/src/sync/fushi_remote_lookup_client.dart'
    show RemoteLookupUnreachableError;
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/local_audio_db.dart'
    show LocalAudioUnavailableError;
import 'package:fushi/src/utils/misc/word_audio_cache.dart'
    show cacheWordAudioBytes, sniffWordAudioExtension;
import 'package:fushi_engine/utils/net/app_http.dart';

/// 弱网下的连接超时上限：从 5s 放宽到 8s，减少慢握手被误判为失败（TODO-1057）。
const Duration kRemoteAudioConnectTimeout = Duration(seconds: 8);

/// 远端音源列表响应读取超时上限（保持既有 10s，仅常量化便于统一维护）。
const Duration kRemoteAudioReceiveTimeout = Duration(seconds: 10);

/// 单个远端音源 host 一次失败后进入的冷却窗口：窗口内不再对同一 host 发起请求，
/// 避免死源（如用户配置的 localhost:41440）在连续查词时刷屏 + 串行拖累后续可用源
/// （TODO-1057）。窗口过后自动放行重试一次。
const Duration kRemoteAudioFailureCooldown = Duration(seconds: 45);

typedef LocalAudioQuery =
    Future<Map<String, dynamic>?> Function(String expression, String reading);
typedef IndexedLocalAudioQuery =
    Future<Map<String, dynamic>?> Function(
      String expression,
      String reading,
      int dbIndex,
    );

/// 第 dbIndex 个本地音频库的全部启用子来源命中（每项 `{file, source, dbIndex}`，
/// 按子来源优先级排序）。「选择音频源」菜单用，见 [WordAudioResolver.listConfigured]。
typedef IndexedLocalAudioListQuery =
    Future<List<Map<String, dynamic>>> Function(
      String expression,
      String reading,
      int dbIndex,
    );
typedef LocalAudioExtractor =
    Future<String?> Function(String file, String source, {int dbIndex});
typedef AudioSourceListFetcher = Future<List<String>> Function(String url);

/// 远端音源列表（Yomitan `audioSourceList`）的逐条结果：条目自带的显示名
/// （如 `NHK16` / `Forvo (user)`，可空）+ 音频 URL。供「选择音频源」菜单展开
/// 一个源返回的全部变体；[WordAudioResolver.resolveConfigured] 仍只取首条 URL。
typedef AudioSourceListEntry = ({String name, String url});
typedef AudioSourceEntryListFetcher =
    Future<List<AudioSourceListEntry>> Function(String url);

/// 把远端源直接回的音频字节落盘，返回本地文件路径（默认 [cacheWordAudioBytes]）。
typedef RemoteAudioBytesCache =
    Future<String> Function(Uint8List bytes, String fileExt);

/// 远端源可达、回了 2xx，但响应既不是音频也不是 Yomitan `audioSourceList` JSON。
/// 只作错误日志的诊断载荷（带 Content-Type 与开头字节），不往上抛。
class UnrecognizedRemoteAudioResponse implements Exception {
  UnrecognizedRemoteAudioResponse({
    required this.contentType,
    required Uint8List bytes,
  }) : byteLength = bytes.length,
       head = bytes
           .take(16)
           .map((int b) => b.toRadixString(16).padLeft(2, '0'))
           .join(' ');

  final String? contentType;
  final int byteLength;

  /// 响应开头至多 16 字节的十六进制，便于从日志判断它到底是什么。
  final String head;

  @override
  String toString() =>
      'UnrecognizedRemoteAudioResponse(contentType: ${contentType ?? '-'}, '
      'bytes: $byteLength, head: $head)';
}

/// 「选择音频源」菜单里的一项：哪个已配置源（[sourceIndex] 是它在
/// `audioSourceConfigs` 里的下标）、该源内的变体名（远端列表条目名，可空）、
/// 解析出的音频引用（远程 URL 或本地文件路径，与 [WordAudioResolver.resolveConfigured]
/// 返回值同形）。
class WordAudioCandidate {
  const WordAudioCandidate({
    required this.source,
    required this.sourceIndex,
    required this.variant,
    required this.ref,
  });

  final AudioSourceConfig source;
  final int sourceIndex;
  final String variant;
  final String ref;
}

typedef RemoteAudioQuery =
    Future<String?> Function(String expression, String reading);

class WordAudioResolver {
  WordAudioResolver({
    required this.queryLocalAudio,
    required this.extractLocalAudio,
    IndexedLocalAudioQuery? queryLocalAudioByDbIndex,
    this.queryLocalAudioListByDbIndex,
    this.queryRemoteAudio,
    AudioSourceListFetcher? fetchAudioSourceList,
    AudioSourceEntryListFetcher? fetchAudioSourceEntries,
  }) : queryLocalAudioByDbIndex =
           queryLocalAudioByDbIndex ??
           ((String expression, String reading, int _) =>
               queryLocalAudio(expression, reading)),
       fetchAudioSourceList =
           fetchAudioSourceList ??
           WordAudioResolver.defaultFetchAudioSourceList,
       // 只注入了 URL 列表 fetcher（既有测试 / 调用方）时，变体列表沿用它、
       // 条目名留空——两条路径永远打同一个端点，不会出现「播放走 A、菜单走 B」。
       fetchAudioSourceEntries =
           fetchAudioSourceEntries ??
           (fetchAudioSourceList == null
               ? WordAudioResolver.defaultFetchAudioSourceEntries
               : (String url) async => <AudioSourceListEntry>[
                   for (final String u in await fetchAudioSourceList(url))
                     (name: '', url: u),
                 ]);

  static const String localAudioUrl =
      'http://localhost:8765/localaudio/get/?term={term}&reading={reading}';
  static const String fushiRemoteAudioUrl = 'fushi://remote-audio';

  /// 旧 sentinel（Fushi 改名前写入用户音频源配置的持久化值）。经迁移导入器原样
  /// 带过来的老配置仍是这个值——读取路径两个都认，写入只写新值。
  static const String legacyRemoteAudioUrl = 'hibiki://remote-audio';

  /// fushiRemote（互联配对）源在失败冷却表里的固定 key：配对候选是一组设备
  /// 地址、整体成败一体，不按单个候选 host 拆分冷却。
  static const String fushiRemoteCooldownKey = 'fushi-remote';

  final LocalAudioQuery queryLocalAudio;
  final IndexedLocalAudioQuery queryLocalAudioByDbIndex;
  final LocalAudioExtractor extractLocalAudio;

  /// 没注入时菜单里每个本地库只列 [queryLocalAudioByDbIndex] 那一条。
  final IndexedLocalAudioListQuery? queryLocalAudioListByDbIndex;
  final RemoteAudioQuery? queryRemoteAudio;
  final AudioSourceListFetcher fetchAudioSourceList;
  final AudioSourceEntryListFetcher fetchAudioSourceEntries;

  Future<String?> resolve({
    required String expression,
    required String reading,
    required List<String> sources,
  }) async {
    for (final String template in sources) {
      if (template == localAudioUrl) {
        final String? path = await _resolveLocal(expression, reading);
        if (path != null && path.isNotEmpty) return path;
        final String? remote = await _queryRemoteLegacy(expression, reading);
        if (remote != null && remote.isNotEmpty) return remote;
        continue;
      }
      if (template == fushiRemoteAudioUrl || template == legacyRemoteAudioUrl) {
        final String? remote = await _queryRemoteLegacy(expression, reading);
        if (remote != null && remote.isNotEmpty) return remote;
        continue;
      }

      final String url = expandTemplate(
        template: template,
        expression: expression,
        reading: reading,
      );
      List<String> urls;
      try {
        urls = await fetchAudioSourceList(url);
      } catch (_) {
        // 传统 resolve() 保持“失败即跳过”语义；冷却只由 resolveConfigured 管理。
        continue;
      }
      if (urls.isNotEmpty) return urls.first;
    }

    return null;
  }

  Future<String?> resolveConfigured({
    required String expression,
    required String reading,
    required List<AudioSourceConfig> sources,
  }) async {
    int localDbIndex = 0;
    for (final AudioSourceConfig source in sources) {
      if (!source.enabled) {
        continue;
      }

      switch (source.kind) {
        case AudioSourceKind.fushiRemote:
          final RemoteAudioQuery? query = queryRemoteAudio;
          if (query == null) continue;
          // 与 remoteAudio 源同一套失败冷却（TODO-1057/BUG-488）：配对设备上次
          // 全部不可达且仍在冷却窗内则直接短路——不发请求、不再记日志，也不让
          // 死配对每次查词硬等 N 个候选 × 超时。
          if (isRemoteSourceInCooldown(fushiRemoteCooldownKey)) {
            continue;
          }
          final String? remote;
          try {
            remote = await query(expression, reading);
          } on RemoteLookupUnreachableError {
            // 传输层确认全部候选不可达（AppModel 已记过一次日志）：计入冷却并
            // 跳到下一源；「可达但无音频」返回 null，不走这里。
            _markRemoteSourceFailed(fushiRemoteCooldownKey);
            continue;
          }
          // 成功抵达（含合法「无音频」null）：清除冷却，恢复其优先级。
          _markRemoteSourceOk(fushiRemoteCooldownKey);
          if (remote != null && remote.isNotEmpty) return remote;
        case AudioSourceKind.localAudio:
          final int dbIndex = localDbIndex;
          localDbIndex++;
          final String? path = await _resolveLocalAt(
            expression,
            reading,
            dbIndex,
          );
          if (path != null && path.isNotEmpty) return path;
        case AudioSourceKind.remoteAudio:
          final String? template = source.url;
          if (template == null || template.isEmpty) continue;
          final String url = expandTemplate(
            template: template,
            expression: expression,
            reading: reading,
          );
          // 失败冷却：该 host 仍在冷却窗内则直接短路——不发请求、不再记日志，
          // 也不让死源阻塞后续可用源（TODO-1057）。
          if (isRemoteSourceInCooldown(url)) {
            continue;
          }
          List<String> urls;
          try {
            urls = await fetchAudioSourceList(url);
          } catch (_) {
            // fetcher 抛出=网络失败（defaultFetchAudioSourceList 记一次日志后 rethrow）：
            // 记录冷却并跳到下一源，绝不吞掉可诊断性。
            _markRemoteSourceFailed(url);
            continue;
          }
          // 成功抵达（含合法“无音频”空列表）：清除该 host 冷却，恢复其优先级。
          _markRemoteSourceOk(url);
          if (urls.isNotEmpty) return urls.first;
      }
    }
    return null;
  }

  /// 「选择音频源」菜单：把**每个**启用源对 [expression] / [reading] 各自解析
  /// 一遍，返回全部可用候选（按配置顺序；远端列表型源展开成多项）。
  ///
  /// 与 [resolveConfigured] 同一套逐源语义（本地库按启用序号定 dbIndex、远端
  /// 失败冷却、badResponse 当空结果），区别只在「不在首个命中处停下」。各源并发
  /// 查询，结果仍按配置顺序拼接——菜单里的顺序就是默认播放的优先级，首项即
  /// 单击 ♪ 会播的那条。同一引用只留第一次出现的那项。
  Future<List<WordAudioCandidate>> listConfigured({
    required String expression,
    required String reading,
    required List<AudioSourceConfig> sources,
  }) async {
    final List<Future<List<WordAudioCandidate>>> pending =
        <Future<List<WordAudioCandidate>>>[];
    int localDbIndex = 0;
    for (int i = 0; i < sources.length; i++) {
      final AudioSourceConfig source = sources[i];
      if (!source.enabled) continue;
      switch (source.kind) {
        case AudioSourceKind.fushiRemote:
          pending.add(_listFushiRemote(source, i, expression, reading));
        case AudioSourceKind.localAudio:
          final int dbIndex = localDbIndex;
          localDbIndex++;
          pending.add(_listLocal(source, i, expression, reading, dbIndex));
        case AudioSourceKind.remoteAudio:
          pending.add(_listRemote(source, i, expression, reading));
      }
    }
    final List<List<WordAudioCandidate>> groups = await Future.wait(pending);
    final Set<String> seen = <String>{};
    return <WordAudioCandidate>[
      for (final List<WordAudioCandidate> group in groups)
        for (final WordAudioCandidate c in group)
          if (seen.add(c.ref)) c,
    ];
  }

  Future<List<WordAudioCandidate>> _listLocal(
    AudioSourceConfig source,
    int sourceIndex,
    String expression,
    String reading,
    int dbIndex,
  ) async {
    final IndexedLocalAudioListQuery? listQuery = queryLocalAudioListByDbIndex;
    if (listQuery == null) {
      final String? path = await _resolveLocalAt(expression, reading, dbIndex);
      if (path == null || path.isEmpty) return const <WordAudioCandidate>[];
      return <WordAudioCandidate>[
        WordAudioCandidate(
          source: source,
          sourceIndex: sourceIndex,
          variant: '',
          ref: path,
        ),
      ];
    }
    // 一个本地库（Yomitan 的 android.db）里有 forvo / nhk16 / jpod 等多个子来源：
    // 全部列出来，菜单才有得选。变体名 = 子来源名，同一子来源多条（forvo 多个
    // 发音人）再带上文件所在目录名区分。
    final List<Map<String, dynamic>> rows;
    try {
      rows = await listQuery(expression, reading, dbIndex);
    } on LocalAudioUnavailableError catch (e, stack) {
      _logLocalAudioUnavailable(e, stack, expression);
      return const <WordAudioCandidate>[];
    }
    final List<String?> paths = await Future.wait(<Future<String?>>[
      for (final Map<String, dynamic> row in rows)
        _extractLocal(row, fallbackDbIndex: dbIndex).catchError((
          Object e,
          StackTrace stack,
        ) {
          if (e is LocalAudioUnavailableError) {
            _logLocalAudioUnavailable(e, stack, expression);
          }
          return null;
        }),
    ]);
    final List<String> names = <String>[
      for (final Map<String, dynamic> row in rows)
        row['source'] as String? ?? '',
    ];
    return <WordAudioCandidate>[
      for (int i = 0; i < rows.length; i++)
        if (paths[i] != null && paths[i]!.isNotEmpty)
          WordAudioCandidate(
            source: source,
            sourceIndex: sourceIndex,
            variant: localAudioVariantName(
              names[i],
              rows[i]['file'] as String? ?? '',
              sameSourceCount: names.where((String n) => n == names[i]).length,
            ),
            ref: paths[i]!,
          ),
    ];
  }

  /// 本地库候选的菜单变体名：子来源名；同一子来源有多条时再带上文件的上级目录名
  /// （forvo 子来源按发音人分目录），仍区分不了就只留子来源名。
  @visibleForTesting
  static String localAudioVariantName(
    String source,
    String file, {
    required int sameSourceCount,
  }) {
    if (sameSourceCount <= 1) return source;
    final List<String> parts = file
        .split(RegExp(r'[\\/]'))
        .where((String s) => s.isNotEmpty)
        .toList();
    if (parts.length < 2) return source;
    final String dir = parts[parts.length - 2];
    return source.isEmpty ? dir : '$source · $dir';
  }

  Future<List<WordAudioCandidate>> _listFushiRemote(
    AudioSourceConfig source,
    int sourceIndex,
    String expression,
    String reading,
  ) async {
    final RemoteAudioQuery? query = queryRemoteAudio;
    if (query == null || isRemoteSourceInCooldown(fushiRemoteCooldownKey)) {
      return const <WordAudioCandidate>[];
    }
    final String? remote;
    try {
      remote = await query(expression, reading);
    } on RemoteLookupUnreachableError {
      _markRemoteSourceFailed(fushiRemoteCooldownKey);
      return const <WordAudioCandidate>[];
    }
    _markRemoteSourceOk(fushiRemoteCooldownKey);
    if (remote == null || remote.isEmpty) return const <WordAudioCandidate>[];
    return <WordAudioCandidate>[
      WordAudioCandidate(
        source: source,
        sourceIndex: sourceIndex,
        variant: '',
        ref: remote,
      ),
    ];
  }

  Future<List<WordAudioCandidate>> _listRemote(
    AudioSourceConfig source,
    int sourceIndex,
    String expression,
    String reading,
  ) async {
    final String? template = source.url;
    if (template == null || template.isEmpty) {
      return const <WordAudioCandidate>[];
    }
    final String url = expandTemplate(
      template: template,
      expression: expression,
      reading: reading,
    );
    if (isRemoteSourceInCooldown(url)) return const <WordAudioCandidate>[];
    final List<AudioSourceListEntry> entries;
    try {
      entries = await fetchAudioSourceEntries(url);
    } catch (_) {
      _markRemoteSourceFailed(url);
      return const <WordAudioCandidate>[];
    }
    _markRemoteSourceOk(url);
    return <WordAudioCandidate>[
      for (final AudioSourceListEntry e in entries)
        WordAudioCandidate(
          source: source,
          sourceIndex: sourceIndex,
          variant: e.name,
          ref: e.url,
        ),
    ];
  }

  /// 传统 [resolve] 路径的远端查询：保持既有「失败即跳过」语义——配对设备不可
  /// 达（[RemoteLookupUnreachableError]）吞成 null 继续下一源，不记冷却（冷却
  /// 只由 [resolveConfigured] 管理，与 remoteAudio 源的既有分工一致）。
  Future<String?> _queryRemoteLegacy(String expression, String reading) async {
    try {
      return await queryRemoteAudio?.call(expression, reading);
    } on RemoteLookupUnreachableError {
      return null;
    }
  }

  Future<String?> _resolveLocal(String expression, String reading) async {
    try {
      final Map<String, dynamic>? info = await queryLocalAudio(
        expression,
        reading,
      );
      return await _extractLocal(info);
    } on LocalAudioUnavailableError catch (e, stack) {
      _logLocalAudioUnavailable(e, stack, expression);
      return null;
    }
  }

  Future<String?> _resolveLocalAt(
    String expression,
    String reading,
    int dbIndex,
  ) async {
    try {
      final Map<String, dynamic>? info = await queryLocalAudioByDbIndex(
        expression,
        reading,
        dbIndex,
      );
      return await _extractLocal(info, fallbackDbIndex: dbIndex);
    } on LocalAudioUnavailableError catch (e, stack) {
      _logLocalAudioUnavailable(e, stack, expression);
      return null;
    }
  }

  /// 本地库这次**没答上**（撞锁 / 查询预算耗尽）：与「库里真没这个词」是两回事。
  ///
  /// BUG-1413：旧实现下这两件事都是一个裸 `null`，`resolveConfigured` 只能一视同仁
  /// 跳到下一源，最终用户看到「暂无发音」，且**整条链一条日志都没有**（500ms 预算
  /// 先于库自己的 3s `busy_timeout` 到点，sqlite 的异常压根没机会抛出来）。现在记一条
  /// 用户可见的错误日志（设置 → 诊断 → 错误日志），再跳下一源。
  ///
  /// 刻意**不**做重试、**不**计入 [_markRemoteSourceFailed] 那套失败冷却：冷却是给
  /// 「连不上的死源」设计的，而本地库忙是瞬态的（绑定期建索引结束就恢复）——把一个
  /// 马上就能用的库额外禁用 45s，等于把小问题放大成「这段时间该库全哑」。
  static void _logLocalAudioUnavailable(
    LocalAudioUnavailableError e,
    StackTrace stack,
    String expression,
  ) {
    ErrorLogService.instance.log(
      'WordAudioResolver.localAudio 本地音频库未能应答'
      '（$expression / ${e.reason.name}）：本次跳过该库，'
      '这不代表库里没有这个词的发音',
      e,
      stack,
    );
  }

  Future<String?> _extractLocal(
    Map<String, dynamic>? info, {
    int fallbackDbIndex = 0,
  }) async {
    if (info == null) return null;

    final String? file = info['file'] as String?;
    final String? source = info['source'] as String?;
    if (file == null || source == null) return null;

    final int dbIndex = (info['dbIndex'] as int?) ?? fallbackDbIndex;
    return extractLocalAudio(file, source, dbIndex: dbIndex);
  }

  static String expandTemplate({
    required String template,
    required String expression,
    required String reading,
  }) {
    return template
        .replaceAll('{term}', Uri.encodeComponent(expression))
        .replaceAll('{reading}', Uri.encodeComponent(reading));
  }

  // BUG-1498：远端发音源默认是公网 Cloudflare Worker，用户也可自填任意源；原先是裸
  // `Dio(...)` 不走任何代理。经统一装配点后，用户填的 `localhost:5050`（local-audio-
  // yomichan）/ `localhost:8765`（AnkiConnect local-audio）仍走直连——`isDirectProxyTarget`
  // 闸门在解析层就把本机目标挡在代理之外。
  static final Dio _dio = createAppDio(
    options: BaseOptions(
      connectTimeout: kRemoteAudioConnectTimeout,
      receiveTimeout: kRemoteAudioReceiveTimeout,
    ),
  );

  /// 远端音源失败冷却表：host -> 冷却截止时间。窗口内命中的 host 直接短路跳过，
  /// 不发请求、不再记日志（TODO-1057）。成功时清除该 host 的条目。
  static final Map<String, DateTime> _remoteFailureCooldownUntil =
      <String, DateTime>{};

  /// 可注入的“当前时间”来源，默认 [DateTime.now]。仅供测试用极短窗 + 手动推进时钟
  /// 断言冷却行为，无需真实 sleep。生产代码永远走 [DateTime.now]。
  static DateTime Function() _nowProvider = DateTime.now;

  /// 归一化冷却 key：优先按 host 归并（同一 host 的多源/重复失败命中同一冷却项）；
  /// host 为空（相对/畸形 URL）时退回整条 url 作 key。
  static String remoteFailureCooldownKey(String url) {
    final String host = Uri.tryParse(url)?.host ?? '';
    return host.isNotEmpty ? host : url;
  }

  /// 该 url 对应的 host 是否仍处于失败冷却窗内。
  static bool isRemoteSourceInCooldown(String url) {
    final String key = remoteFailureCooldownKey(url);
    final DateTime? until = _remoteFailureCooldownUntil[key];
    if (until == null) return false;
    if (!_nowProvider().isBefore(until)) {
      // 冷却已过：清除条目，放行下一次尝试。
      _remoteFailureCooldownUntil.remove(key);
      return false;
    }
    return true;
  }

  /// 记录一次失败：把该 host 的冷却截止时间设为 now + [kRemoteAudioFailureCooldown]。
  static void _markRemoteSourceFailed(String url) {
    final String key = remoteFailureCooldownKey(url);
    _remoteFailureCooldownUntil[key] = _nowProvider().add(
      kRemoteAudioFailureCooldown,
    );
  }

  /// 记录一次成功：清除该 host 的冷却条目，让它立即恢复优先级。
  static void _markRemoteSourceOk(String url) {
    _remoteFailureCooldownUntil.remove(remoteFailureCooldownKey(url));
  }

  /// 测试钩子：注入自定义时钟。传 null 恢复 [DateTime.now]。
  @visibleForTesting
  static void debugSetNowProvider(DateTime Function()? nowProvider) {
    _nowProvider = nowProvider ?? DateTime.now;
  }

  /// 测试钩子：清空冷却表，隔离用例之间的静态状态。
  @visibleForTesting
  static void debugResetRemoteFailureCooldown() {
    _remoteFailureCooldownUntil.clear();
  }

  /// 测试钩子：读/换 [defaultFetchAudioSourceList] 底层 [_dio] 的 HTTP 适配器，
  /// 以便用例注入可控 HTTP 响应（如 404）验证 badResponse 归一为空结果（TODO-1265）。
  /// 生产代码从不调用；用例须在 tearDown 里还原原适配器，避免串味。
  @visibleForTesting
  static HttpClientAdapter get debugHttpClientAdapter => _dio.httpClientAdapter;

  @visibleForTesting
  static set debugHttpClientAdapter(HttpClientAdapter adapter) {
    _dio.httpClientAdapter = adapter;
  }

  static Future<List<String>> defaultFetchAudioSourceList(String url) async =>
      <String>[
        for (final AudioSourceListEntry e
            in await defaultFetchAudioSourceEntries(url))
          e.url,
      ];

  /// [defaultFetchAudioSourceList] 的带名版本：保留 `audioSources[].name`，供
  /// 「选择音频源」菜单区分同一源的多个变体。错误语义与它完全一致（它就是本
  /// 函数的投影）。
  ///
  /// 远端源有两种响应形态（对齐 Yomitan 的「Custom URL」与「Custom URL (JSON)」）：
  /// - 响应本身就是音频（`Content-Type: audio/*` 或音频魔数，如 uapis.cn 词典发音、
  ///   GPT-SoVITS `/tts`）：字节经 [cacheAudioBytes] 落盘，返回一条指向本地文件的
  ///   条目——复用这一次请求的字节，播放端不再请求第二遍；
  /// - 响应是 `audioSourceList` JSON：按列表展开。
  ///
  /// 两种都不是（可达、2xx，但格式认不出）记一条「格式不认识」的错误日志并当空
  /// 结果返回——**不** rethrow，因为服务器是通的，计入 host 冷却会把格式问题误判
  /// 成死源（BUG：直返音频的源被当 JSON 解析失败后冷却，永远没声音）。
  /// 把远端音源的连接级失败翻成给用户看的一句话。
  ///
  /// 反馈 uY5I6JRU39：旧实现把**任何** [SocketException] 都报成「无法解析 host」，
  /// 而安卓上配了 `localhost` 音源（本机没有服务在听）时真实错误是 `Connection
  /// refused`——域名解析根本成功了，提示把人引去查网络 / DNS。这里按套接字错误的
  /// 实际种类分开：解析失败 → [Translations.audio_source_dns_error]；连接被拒 →
  /// [Translations.audio_source_connection_refused]；其它套接字错误照实给出系统消息。
  @visibleForTesting
  static String describeAudioSourceFetchError(Object e, String host) {
    if (e is! DioError) return t.audio_source_error(detail: '$e');
    final Object? inner = e.error;
    if (inner is SocketException) {
      if (isSocketHostLookupFailure(inner)) {
        return t.audio_source_dns_error(host: host);
      }
      if (isSocketConnectionRefused(inner)) {
        return t.audio_source_connection_refused(host: host);
      }
      return t.audio_source_request_error(
        detail: inner.osError?.message ?? inner.message,
      );
    }
    if (e.type == DioErrorType.connectionTimeout) {
      return t.audio_source_timeout(host: host);
    }
    return t.audio_source_request_error(detail: e.message ?? e.type.name);
  }

  /// dart:io 的 DNS 失败统一抛 `SocketException('Failed host lookup: ...')`。
  @visibleForTesting
  static bool isSocketHostLookupFailure(SocketException e) =>
      e.message.contains('Failed host lookup');

  /// 连接被拒：Linux / Android `ECONNREFUSED`=111，macOS / iOS 61，Windows
  /// `WSAECONNREFUSED`=10061。
  @visibleForTesting
  static bool isSocketConnectionRefused(SocketException e) {
    final int? code = e.osError?.errorCode;
    return code == 111 || code == 61 || code == 10061;
  }

  static Future<List<AudioSourceListEntry>> defaultFetchAudioSourceEntries(
    String url, {
    RemoteAudioBytesCache cacheAudioBytes = cacheWordAudioBytes,
  }) async {
    final Response<List<int>> response;
    try {
      response = await _dio.get<List<int>>(
        url,
        options: Options(responseType: ResponseType.bytes),
      );
    } catch (e, stack) {
      // TODO-1265 根因修：`badResponse`＝服务器**可达**并回了一个非 2xx（最典型是 404
      // ——「这个源没有这个词的发音」），与 200 空 audioSources 语义完全相同，只是端点
      // 用 HTTP 状态而非空列表表达「没有」。**绝不能把它当死源失败**：BUG-488 的冷却
      // 是为「连不上的死源」（连接拒绝/超时/DNS）设计的；把可达源因某个词缺音频而
      // host 级冷却 45s，会让**这个源有音频的其它词也一起没声音**（回归：查一个源没有
      // 的词后，整段时间里该源全哑）。故 badResponse 直接当空结果返回：不记错误日志、
      // 不 rethrow → resolveConfigured 不冷却、继续下一源、该源对下个词仍可用。
      if (e is DioError && e.type == DioErrorType.badResponse) {
        return const <AudioSourceListEntry>[];
      }
      final host = Uri.tryParse(url)?.host ?? url;
      final String detail = describeAudioSourceFetchError(e, host);
      ErrorLogService.instance.log(detail, e, stack);
      // rethrow 让上层 resolveConfigured 把这次失败计入 host 冷却（TODO-1057）；
      // 日志已在此记过一次，冷却窗内 resolveConfigured 会短路不再重入此处，故不刷屏。
      // 仅剩连接级失败（不可达/超时/DNS）走到这里——正是 BUG-488 要冷却的死源。
      rethrow;
    }

    final Uint8List bytes = Uint8List.fromList(response.data ?? const <int>[]);
    if (bytes.isEmpty) return const <AudioSourceListEntry>[];
    final String? contentType = response.headers.value(
      Headers.contentTypeHeader,
    );
    final String? audioExt = sniffWordAudioExtension(
      bytes,
      contentType: contentType,
    );
    if (audioExt != null) {
      return <AudioSourceListEntry>[
        (name: '', url: await cacheAudioBytes(bytes, audioExt)),
      ];
    }
    final List<AudioSourceListEntry>? entries = parseAudioSourceListBody(bytes);
    if (entries != null) return entries;
    final String host = Uri.tryParse(url)?.host ?? '';
    ErrorLogService.instance.log(
      t.audio_source_unrecognized_response(host: host.isEmpty ? url : host),
      UnrecognizedRemoteAudioResponse(contentType: contentType, bytes: bytes),
      StackTrace.current,
    );
    return const <AudioSourceListEntry>[];
  }

  /// 把响应体按 Yomitan `audioSourceList` JSON 解析。是合法 JSON 就返回条目（不是
  /// `audioSourceList` 形状 / 列表为空 = 该源没有这个词的发音，返回空列表）；
  /// **不是 JSON** 返回 null，交调用方按「格式不认识」处理。
  @visibleForTesting
  static List<AudioSourceListEntry>? parseAudioSourceListBody(Uint8List bytes) {
    final Object? body;
    try {
      body = jsonDecode(utf8.decode(bytes));
    } on FormatException {
      return null;
    }
    if (body is! Map) return const <AudioSourceListEntry>[];

    final Object? sources = body['audioSources'];
    if (body['type'] != 'audioSourceList' || sources is! List) {
      return const <AudioSourceListEntry>[];
    }

    return sources
        .whereType<Map>()
        .map(
          (Map source) => (
            name: source['name']?.toString() ?? '',
            url: source['url']?.toString() ?? '',
          ),
        )
        .where((AudioSourceListEntry entry) => entry.url.isNotEmpty)
        .toList(growable: false);
  }
}
