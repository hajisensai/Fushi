/// `fushi_server subs …`：外挂字幕的搜索 / 下载 / 按内嵌轨对时间轴 / 找回原稿 / 时长自检。
///
/// ```
/// subs search   <videoId|file> [--provider opensubtitles|subdl|jimaku] [-l ja] [--query …] [--season N] [--episode N]
/// subs download <resultId> --to <video> [--out x.srt] [--force]
/// subs sync     <video> <subtitle> [--dry-run] [--force] [--out x.srt]
/// subs restore  <subtitle> [--out x.srt]
/// subs check    <video> <subtitle>
/// ```
///
/// 全部是离线命令（直接开数据目录）。引擎入口：
/// - 搜索 / 下载：`OpenSubtitlesClient` / `SubdlClient` / `JimakuClient`，经引擎的
///   `VideoSubtitleRegistry` 合并去重；
/// - 对齐：`embedded_reference_subtitle_sync.dart`（ffmpeg 抽内嵌文本轨），改写前经
///   `subtitle_alignment_backup.dart` 登记原稿，`subs restore` 由此找回；
/// - 自检：`subtitle_timing_check.dart`（ffprobe 探视频时长）。
///
/// 凭据只从环境变量或偏好表读，不进 argv：环境变量（显式意图，优先）
/// `FUSHI_OPENSUBTITLES_API_KEY` / `FUSHI_OPENSUBTITLES_USERNAME` /
/// `FUSHI_OPENSUBTITLES_PASSWORD`、`FUSHI_SUBDL_API_KEY`、`FUSHI_JIMAKU_API_KEY`；
/// 其次是与 app 同名的偏好键（`video_subtitle_opensubtitles_config` /
/// `video_subtitle_subdl_api_key` / `jimaku_api_key` 及其 `*_enabled`），它们在
/// 互联的「服务账号」共享清单里（`InterconnectServiceConfigSnapshot`）。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:args/args.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/media/external_provider.dart';
import 'package:fushi_engine/media/video/download/video_subtitle_registry.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/jimaku_client.dart';
import 'package:fushi_engine/media/video/subtitle/embedded_reference_subtitle_sync.dart';
import 'package:fushi_engine/media/video/subtitle/open_subtitles_client.dart';
import 'package:fushi_engine/media/video/subtitle/subdl_client.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_alignment_backup.dart';
import 'package:fushi_engine/media/video/subtitle/subtitle_timing_check.dart';
import 'package:fushi_engine/media/video/subtitle/video_subtitle_provider.dart';
import 'package:fushi_engine/media/video/video_duration_probe.dart';
import 'package:fushi_engine/media/video/video_filename_parser.dart';
import 'package:fushi_engine/utils/net/app_http.dart';
import 'package:fushi_server/src/commands/cli_module.dart';
import 'package:fushi_server/src/commands/video_cli_support.dart';
import 'package:fushi_server/src/server_runtime.dart';
import 'package:path/path.dart' as p;

/// 支持的字幕来源 id（与引擎 provider 的 `id` 一致）。
const List<String> kSubsProviderIds = <String>['opensubtitles', kSubdlSubtitleProviderId, 'jimaku'];

const String kOpenSubtitlesApiKeyEnv = 'FUSHI_OPENSUBTITLES_API_KEY';
const String kOpenSubtitlesUsernameEnv = 'FUSHI_OPENSUBTITLES_USERNAME';
const String kOpenSubtitlesPasswordEnv = 'FUSHI_OPENSUBTITLES_PASSWORD';
const String kSubdlApiKeyEnv = 'FUSHI_SUBDL_API_KEY';
const String kJimakuApiKeyEnv = 'FUSHI_JIMAKU_API_KEY';

/// 与 app `PreferencesRepository` 同名的偏好键。
const String kOpenSubtitlesConfigPref = 'video_subtitle_opensubtitles_config';
const String kSubdlApiKeyPref = 'video_subtitle_subdl_api_key';
const String kSubdlEnabledPref = 'video_subtitle_subdl_enabled';
const String kJimakuApiKeyPref = 'jimaku_api_key';
const String kJimakuEnabledPref = 'jimaku_enabled';

const String _usage = '''
subs（外挂字幕；凭据只读环境变量 / 偏好表，见 subs_commands.dart 文件头）:
  subs search   <videoId|file> [--provider opensubtitles|subdl|jimaku] [-l ja] [--query 标题] [--season N] [--episode N]
  subs download <resultId> --to <video> [--out x.srt] [--force]   （resultId 取自上一次 subs search）
  subs sync     <video> <subtitle> [--dry-run] [--force] [--out x.srt]   （按视频内嵌文本轨对时间轴，需 ffmpeg）
  subs restore  <subtitle> [--out x.srt]   （找回 subs sync 改写前的原稿）
  subs check    <video> <subtitle>   （字幕时长是否与视频自洽，需 ffprobe）
  每个子命令都支持 --json。''';

class SubsCliModule extends CliModule {
  const SubsCliModule();

  @override
  List<String> get commands => const <String>['subs'];

  @override
  String get usage => _usage;

  @override
  void register(ArgParser parser) => buildSubsParser(parser.addCommand('subs'));

  @override
  Future<int> run(String name, ArgResults command, CliContext ctx) {
    final ArgResults? sub = command.command;
    if (sub == null) {
      stderr.writeln(_usage);
      return Future<int>.value(kExitUsage);
    }
    final CliIo io = CliIo(json: jsonFlag(sub));
    return ctx.withRuntime((ServerRuntime rt) => runSubsCommand(sub, rt: rt, io: io));
  }
}

/// 给 `subs` 登记五个子命令的参数表。
void buildSubsParser(ArgParser subs) {
  addJsonFlag(subs.addCommand('search'))
    ..addMultiOption('provider', help: '只问这些来源（缺省 = 全部已配置的）', allowed: kSubsProviderIds)
    ..addMultiOption('language', abbr: 'l', help: '语言代码（ja / en / zh …），可重复或逗号分隔')
    ..addOption('query', abbr: 'q', help: '覆盖按文件名解析出的标题')
    ..addOption('season', help: '季号')
    ..addOption('episode', help: '集号');
  addJsonFlag(subs.addCommand('download'))
    ..addOption('to', help: '字幕要配的视频文件（必填）')
    ..addOption('out', abbr: 'o', help: '输出路径（缺省 <视频名>.<语言>.<扩展名>，放视频旁）')
    ..addFlag('force', negatable: false, help: '输出文件已存在时覆盖');
  addJsonFlag(subs.addCommand('sync'))
    ..addFlag('dry-run', negatable: false, help: '只报告判定，不写盘')
    ..addFlag('force', negatable: false, help: '证据只够「待确认」档时也照样应用')
    ..addOption('out', abbr: 'o', help: '写到别处（缺省原地改写，原稿另存可 subs restore）');
  addJsonFlag(subs.addCommand('restore')).addOption('out', abbr: 'o', help: '写到别处（缺省原地还原）');
  addJsonFlag(subs.addCommand('check'));
}

/// 运行期依赖（测试注入假实现，不连网络、不跑 ffmpeg）。
class SubsDeps {
  const SubsDeps({
    this.providerFactory = createSubsProvider,
    this.environment,
    this.probeDurationMs = _probeDurationMs,
    this.loadReferences = loadEmbeddedReferenceTracks,
    this.ffmpegProblem = ffmpegUnavailableReason,
  });

  /// 按来源 id 与凭据造一个 provider。
  final VideoSubtitleProvider Function(String providerId, SubsCredentials credentials) providerFactory;

  /// 读凭据用的环境变量（null = 进程环境）。
  final Map<String, String>? environment;

  /// 视频时长探测（ffprobe）。
  final Future<int?> Function(String videoPath) probeDurationMs;

  /// 读视频内嵌文本轨（ffmpeg）。
  final SubtitleReferenceTrackLoader loadReferences;

  /// ffmpeg / ffprobe 是否可用；可用返回 null，否则返回原因。
  final Future<String?> Function({required bool probe}) ffmpegProblem;

  Map<String, String> get env => environment ?? Platform.environment;
}

Future<int?> _probeDurationMs(String videoPath) => probeVideoDurationMs(videoPath);

/// 试跑一次 `ffmpeg -version`（[probe] 为 true 时是 ffprobe），起不来返回原因。
///
/// `syncSubtitleToEmbeddedReferences` 把一切异常降级成「没有参考轨」——那是给自动
/// 下载路径的纪律；命令行要分得清「视频没有内嵌字幕」和「本机没装 ffmpeg」，所以先探。
Future<String?> ffmpegUnavailableReason({required bool probe}) async {
  final String tool = probe ? 'ffprobe' : 'ffmpeg';
  try {
    final FfmpegBackend backend = resolveFfmpegBackend();
    final FfmpegRunResult result = probe
        ? await backend.runProbe(const <String>['-version'], const Duration(seconds: 15))
        : await backend.run(const <String>['-version'], const Duration(seconds: 15));
    if (result.isSuccess) return null;
    return '$tool 跑不起来：${result.failureSummary}';
  } on ProcessException catch (e) {
    return '找不到 $tool（${describeFfmpegProcessException(e)}）；装 ffmpeg 或在配置文件里填 ffmpeg / ffprobe 路径';
  }
}

/// 三家来源的凭据（环境变量优先，其次偏好表）。
class SubsCredentials {
  const SubsCredentials({
    required this.openSubtitles,
    required this.subdlApiKey,
    required this.subdlEnabled,
    required this.jimakuApiKey,
    required this.jimakuEnabled,
  });

  final OpenSubtitlesConfig openSubtitles;
  final String subdlApiKey;
  final bool subdlEnabled;
  final String jimakuApiKey;
  final bool jimakuEnabled;

  /// [providerId] 能不能用；不能用时返回给用户的配置提示，能用返回 null。
  String? unavailableReason(String providerId) {
    switch (providerId) {
      case 'opensubtitles':
        if (!openSubtitles.enabled) return 'OpenSubtitles 已在偏好里关闭（设 $kOpenSubtitlesApiKeyEnv 可临时启用）';
        if (openSubtitles.effectiveApiKey.isEmpty) {
          return 'OpenSubtitles 没有 API key：设环境变量 $kOpenSubtitlesApiKeyEnv，或从已配好的 Fushi 经互联同步';
        }
        return null;
      case kSubdlSubtitleProviderId:
        if (subdlApiKey.isEmpty) return 'SubDL 没有 API key：设环境变量 $kSubdlApiKeyEnv，或从已配好的 Fushi 经互联同步';
        if (!subdlEnabled) return 'SubDL 已在偏好里关闭（设 $kSubdlApiKeyEnv 可临时启用）';
        return null;
      case 'jimaku':
        if (jimakuApiKey.isEmpty) return 'Jimaku 没有 API key：设环境变量 $kJimakuApiKeyEnv，或从已配好的 Fushi 经互联同步';
        if (!jimakuEnabled) return 'Jimaku 已在偏好里关闭（设 $kJimakuApiKeyEnv 可临时启用）';
        return null;
    }
    return '未知字幕来源 $providerId';
  }
}

String _env(Map<String, String> env, String name) => (env[name] ?? '').trim();

/// 读凭据：环境变量是显式意图，给了就视为启用；否则按偏好表（与 app 同一判据）。
SubsCredentials resolveSubsCredentials(PrefStore prefs, Map<String, String> env) {
  OpenSubtitlesConfig openSubtitles = _openSubtitlesFromPrefs(prefs);
  final String osKey = _env(env, kOpenSubtitlesApiKeyEnv);
  final String osUser = _env(env, kOpenSubtitlesUsernameEnv);
  final String osPassword = env[kOpenSubtitlesPasswordEnv] ?? '';
  if (osKey.isNotEmpty || osUser.isNotEmpty) {
    openSubtitles = OpenSubtitlesConfig(
      apiKey: osKey.isNotEmpty ? osKey : openSubtitles.apiKey,
      username: osUser.isNotEmpty ? osUser : openSubtitles.username,
      password: osPassword.isNotEmpty ? osPassword : openSubtitles.password,
      userAgent: openSubtitles.userAgent,
      baseUrl: openSubtitles.baseUrl,
      priority: openSubtitles.priority,
      allowInsecureHttp: openSubtitles.allowInsecureHttp,
    );
  }
  final String subdlEnv = _env(env, kSubdlApiKeyEnv);
  final String jimakuEnv = _env(env, kJimakuApiKeyEnv);
  return SubsCredentials(
    openSubtitles: openSubtitles,
    subdlApiKey: subdlEnv.isNotEmpty ? subdlEnv : _prefString(prefs, kSubdlApiKeyPref),
    subdlEnabled: subdlEnv.isNotEmpty || _prefBool(prefs, kSubdlEnabledPref, defaultValue: true),
    jimakuApiKey: jimakuEnv.isNotEmpty ? jimakuEnv : _prefString(prefs, kJimakuApiKeyPref),
    jimakuEnabled: jimakuEnv.isNotEmpty || _prefBool(prefs, kJimakuEnabledPref, defaultValue: true),
  );
}

String _prefString(PrefStore prefs, String key) {
  final Object? value = prefs.getPref(key, defaultValue: '');
  return value is String ? value.trim() : '';
}

bool _prefBool(PrefStore prefs, String key, {required bool defaultValue}) {
  final Object? value = prefs.getPref(key, defaultValue: defaultValue);
  return value is bool ? value : defaultValue;
}

/// 与 app `PreferencesRepository.videoSubtitleOpenSubtitlesConfig` 同一解码口径：
/// 没配置过 / 解不开 = [OpenSubtitlesConfig.unconfigured]。
OpenSubtitlesConfig _openSubtitlesFromPrefs(PrefStore prefs) {
  final String raw = _prefString(prefs, kOpenSubtitlesConfigPref);
  if (raw.isEmpty) return OpenSubtitlesConfig.unconfigured();
  try {
    final Object? decoded = jsonDecode(raw);
    if (decoded is! Map) return OpenSubtitlesConfig.unconfigured();
    return OpenSubtitlesConfig.fromJson(<String, Object?>{
      for (final MapEntry<Object?, Object?> e in decoded.entries) e.key.toString(): e.value,
    });
  } on Object catch (e) {
    stderr.writeln('偏好 $kOpenSubtitlesConfigPref 解不开，按未配置处理：$e');
    return OpenSubtitlesConfig.unconfigured();
  }
}

/// 生产的 provider 装配（出站一律经 `createAppHttpIoClient`，跟随全应用代理）。
VideoSubtitleProvider createSubsProvider(String providerId, SubsCredentials credentials) {
  switch (providerId) {
    case 'opensubtitles':
      return OpenSubtitlesClient(config: credentials.openSubtitles);
    case kSubdlSubtitleProviderId:
      return SubdlClient(apiKey: credentials.subdlApiKey);
    case 'jimaku':
      return JimakuCliSubtitleProvider(JimakuClient(apiKey: credentials.jimakuApiKey, client: createAppHttpIoClient()));
  }
  throw ArgumentError.value(providerId, 'providerId', '未知字幕来源');
}

/// 命令行用的 Jimaku provider：按标题搜条目 → 列文件 → 只留文本字幕。
///
/// app 侧同职责的 `JimakuVideoSubtitleProvider` 住在 `fushi/`（无头端 import 不到）；
/// 这里只实现命令行需要的「按标题 + 集号」子集，没有 AniList / TMDB 关联键（命令行
/// 的输入只有文件名）。下载与 app 走同一个 `JimakuClient.downloadFile`。
class JimakuCliSubtitleProvider implements VideoSubtitleProvider {
  JimakuCliSubtitleProvider(this._client, {this.priority = 100});

  final JimakuClient _client;

  @override
  final int priority;

  @override
  String get id => 'jimaku';

  @override
  bool get allowsFreeProbeDownload => true;

  @override
  Future<ProviderBatchResult<VideoSubtitleCandidate>> search(VideoSubtitleSearchRequest request) async {
    final List<String> titles = <String>{
      request.effectiveQuery,
      ...request.alternateTitles,
    }.where((String t) => t.trim().isNotEmpty).toList();
    try {
      final List<JimakuEntry> entries = await _client.searchEntries(
        queryFallbacks: titles,
        throwOnError: true,
        animeFilter: switch (request.anime) {
          true => JimakuAnimeFilter.anime,
          false => JimakuAnimeFilter.liveAction,
          null => JimakuAnimeFilter.either,
        },
      );
      final List<VideoSubtitleCandidate> out = <VideoSubtitleCandidate>[];
      for (final JimakuEntry entry in entries) {
        final List<JimakuFile> files = await _client.listFiles(
          entry.id,
          episode: request.effectiveEpisode,
          throwOnError: true,
        );
        for (final JimakuFile file in files) {
          if (!file.isTextSubtitle) continue;
          final String language = detectSubtitleLanguage(file.name) ?? '';
          if (request.languages.isNotEmpty && !request.languages.contains(language)) continue;
          out.add(_JimakuCliCandidate(entry: entry, file: file, language: language, providerPriority: priority));
        }
      }
      return ProviderBatchResult<VideoSubtitleCandidate>.success(out);
    } on Object catch (error) {
      return ProviderBatchResult<VideoSubtitleCandidate>.failure(
        ExternalProviderFailure.fromException(providerId: id, operation: 'search', error: error),
      );
    }
  }

  @override
  Future<VideoSubtitleDownload> download(VideoSubtitleCandidate candidate) async {
    if (candidate is! _JimakuCliCandidate) {
      throw const ExternalProviderFailure(
        providerId: 'jimaku',
        operation: 'download',
        kind: ExternalProviderFailureKind.unsupported,
        message: 'candidate belongs to another provider',
      );
    }
    final Uint8List? bytes = await _client.downloadFile(candidate.file.url, throwOnError: true);
    if (bytes == null || bytes.isEmpty) {
      throw const ExternalProviderFailure(
        providerId: 'jimaku',
        operation: 'download',
        kind: ExternalProviderFailureKind.unavailable,
        message: 'subtitle download failed',
        retryable: true,
      );
    }
    return VideoSubtitleDownload(bytes: bytes, fileName: candidate.file.name, language: candidate.language);
  }

  @override
  void close() => _client.close();
}

class _JimakuCliCandidate extends VideoSubtitleCandidate {
  _JimakuCliCandidate({
    required this.entry,
    required this.file,
    required super.language,
    required super.providerPriority,
  }) : super(
         providerId: 'jimaku',
         remoteId: '${entry.id}:${file.name}',
         fileName: file.name,
         releaseName: entry.name,
         episode: file.episode,
         fileSize: file.size,
         uploadedAtMs: file.lastModifiedMs,
         collectionId: '${entry.id}',
         collectionLabel: entry.name,
       );

  final JimakuEntry entry;
  final JimakuFile file;
}

/// 分发 `subs` 的子命令。
Future<int> runSubsCommand(
  ArgResults sub, {
  required ServerRuntime rt,
  required CliIo io,
  SubsDeps deps = const SubsDeps(),
}) async {
  switch (sub.name) {
    case 'search':
      return subsSearch(sub, rt: rt, io: io, deps: deps);
    case 'download':
      return subsDownload(sub, rt: rt, io: io, deps: deps);
    case 'sync':
      return subsSync(sub, io: io, deps: deps);
    case 'restore':
      return subsRestore(sub, io: io);
    case 'check':
      return subsCheck(sub, io: io, deps: deps);
  }
  return io.fail(kExitUsage, _usage);
}

// ─── search / download ──────────────────────────────────────────────

/// `subs search` 的一次请求（会落进搜索缓存，`subs download` 原样重放）。
class SubsSearchSpec {
  const SubsSearchSpec({
    required this.query,
    this.season,
    this.episode,
    this.languages = const <String>[],
    this.videoPath,
    this.fileSize,
    this.movieHash,
  });

  factory SubsSearchSpec.fromJson(Map<String, Object?> json) => SubsSearchSpec(
    query: json['query'] as String? ?? '',
    season: json['season'] as int?,
    episode: json['episode'] as int?,
    languages: (json['languages'] as List<Object?>? ?? const <Object?>[]).whereType<String>().toList(),
    videoPath: json['videoPath'] as String?,
    fileSize: json['fileSize'] as int?,
    movieHash: json['movieHash'] as String?,
  );

  final String query;
  final int? season;
  final int? episode;
  final List<String> languages;
  final String? videoPath;
  final int? fileSize;
  final String? movieHash;

  VideoSubtitleSearchRequest toRequest() => VideoSubtitleSearchRequest(
    query: query,
    season: season,
    episode: episode,
    languages: languages,
    fingerprint: fileSize == null
        ? null
        : LocalVideoFingerprint(
            fileSize: fileSize!,
            openSubtitlesMovieHash: movieHash,
            fileName: videoPath == null ? null : p.basename(videoPath!),
          ),
  );

  Map<String, Object?> toJson() => <String, Object?>{
    'query': query,
    if (season != null) 'season': season,
    if (episode != null) 'episode': episode,
    'languages': languages,
    if (videoPath != null) 'videoPath': videoPath,
    if (fileSize != null) 'fileSize': fileSize,
    if (movieHash != null) 'movieHash': movieHash,
  };
}

/// 搜索缓存的落点：`<support>/cli/subs_last_search.json`。
File subsSearchCacheFile(ServerRuntime rt) => File(p.join(rt.paths.support.path, 'cli', 'subs_last_search.json'));

/// 把 `-l ja,en -l zh` 摊平成去重的小写列表。
List<String> splitLanguages(Iterable<String> raw) => <String>{
  for (final String chunk in raw)
    for (final String part in chunk.split(','))
      if (part.trim().isNotEmpty) part.trim().toLowerCase(),
}.toList();

int? _intOption(ArgResults sub, String name) {
  final String? raw = sub[name] as String?;
  if (raw == null) return null;
  final int? value = int.tryParse(raw.trim());
  if (value == null || value < 0) throw FormatException('--$name 需要非负整数，收到 "$raw"');
  return value;
}

Future<int> subsSearch(ArgResults sub, {required ServerRuntime rt, required CliIo io, required SubsDeps deps}) async {
  if (sub.rest.length != 1) return io.fail(kExitUsage, '用法: subs search <videoId|file> [--provider …] [-l ja]');
  final int? season;
  final int? episode;
  try {
    season = _intOption(sub, 'season');
    episode = _intOption(sub, 'episode');
  } on FormatException catch (e) {
    return io.fail(kExitUsage, e.message);
  }
  final String target = sub.rest.single;
  // 目标：现成的文件路径优先，其次库内视频 id（video_books.book_uid）。
  String? videoPath;
  String? libraryTitle;
  if (File(target).existsSync()) {
    videoPath = p.absolute(target);
  } else {
    final VideoBookRow? book = await rt.db.getVideoBookByBookUid(target);
    if (book == null) return io.fail(kExitNoInput, '既不是文件也不是库内视频 id: $target');
    libraryTitle = book.title;
    if (File(book.videoPath).existsSync()) videoPath = book.videoPath;
  }
  final VideoNameInfo? parsed = videoPath == null ? null : parseVideoFilename(p.basename(videoPath));
  final String query = ((sub['query'] as String?)?.trim().isNotEmpty ?? false)
      ? (sub['query'] as String).trim()
      : (parsed?.series.trim().isNotEmpty ?? false)
      ? parsed!.series.trim()
      : (libraryTitle ?? '').trim();
  int? fileSize;
  String? movieHash;
  if (videoPath != null) {
    fileSize = await File(videoPath).length();
    try {
      movieHash = await computeOpenSubtitlesMovieHash(videoPath);
    } on Object catch (e) {
      io.err.writeln('算不出 OpenSubtitles 文件指纹，退回按标题搜：$e');
    }
  }
  final SubsSearchSpec spec = SubsSearchSpec(
    query: query,
    season: season ?? parsed?.season,
    episode: episode ?? parsed?.episode,
    languages: splitLanguages(sub['language'] as List<String>),
    videoPath: videoPath,
    fileSize: fileSize,
    movieHash: movieHash,
  );
  if (spec.query.isEmpty && spec.movieHash == null) {
    return io.fail(kExitUsage, '解析不出标题：用 --query 指定');
  }

  final SubsCredentials credentials = resolveSubsCredentials(rt.prefs, deps.env);
  final List<String> wanted = (sub['provider'] as List<String>).isEmpty
      ? kSubsProviderIds
      : (sub['provider'] as List<String>);
  final bool explicit = (sub['provider'] as List<String>).isNotEmpty;
  final List<String> usable = <String>[];
  final Map<String, String> skipped = <String, String>{};
  for (final String id in wanted) {
    final String? reason = credentials.unavailableReason(id);
    if (reason == null) {
      usable.add(id);
    } else {
      skipped[id] = reason;
    }
  }
  if (usable.isEmpty || (explicit && skipped.isNotEmpty)) {
    return io.fail(kExitUnavailable, skipped.values.join('\n'), extra: <String, Object?>{'unavailable': skipped});
  }
  for (final MapEntry<String, String> e in skipped.entries) {
    io.err.writeln('跳过 ${e.key}：${e.value}');
  }

  io.err.writeln(
    '搜索 "${spec.query}"'
    '${spec.season == null ? '' : ' S${spec.season}'}${spec.episode == null ? '' : ' E${spec.episode}'}'
    ' @ ${usable.join(', ')} …',
  );
  final VideoSubtitleRegistry registry = VideoSubtitleRegistry(<VideoSubtitleProvider>[
    for (final String id in usable) deps.providerFactory(id, credentials),
  ]);
  final ProviderBatchResult<VideoSubtitleCandidate> result;
  try {
    result = await registry.search(spec.toRequest());
  } finally {
    registry.close();
  }
  final List<Map<String, Object?>> rows = <Map<String, Object?>>[
    for (final VideoSubtitleCandidate c in result.items) subsCandidateJson(c),
  ];
  final List<Map<String, Object?>> failures = <Map<String, Object?>>[
    for (final ExternalProviderFailure f in result.failures)
      <String, Object?>{'provider': f.providerId, 'kind': f.kind.name, 'message': f.message},
  ];
  final File cache = subsSearchCacheFile(rt);
  await cache.parent.create(recursive: true);
  await cache.writeAsString(
    jsonEncode(<String, Object?>{
      'savedAt': DateTime.now().toUtc().toIso8601String(),
      'spec': spec.toJson(),
      'providers': usable,
      'results': rows,
    }),
  );

  // 全部来源都失败（没有任何一家成功应答）才算依赖不可用；部分失败照常出结果。
  final bool allFailed = result.successfulProviderCount == 0 && failures.isNotEmpty;
  final int code = allFailed ? kExitUnavailable : (rows.isEmpty ? kExitFailure : kExitOk);
  if (io.json) {
    io.writeJson(<String, Object?>{
      'ok': code == kExitOk,
      'exitCode': code,
      'spec': spec.toJson(),
      'results': rows,
      'failures': failures,
      if (skipped.isNotEmpty) 'skipped': skipped,
    });
  } else {
    for (final Map<String, Object?> row in rows) {
      io.out.writeln(
        '${row['id']}\t${(row['language'] as String).isEmpty ? '-' : row['language']}\t'
        '${row['fileName']}${row['releaseName'] == null ? '' : '\t${row['releaseName']}'}',
      );
    }
    if (rows.isEmpty) io.out.writeln('（没有结果）');
  }
  for (final Map<String, Object?> f in failures) {
    io.err.writeln('! ${f['provider']}: ${f['kind']} ${f['message']}');
  }
  return code;
}

/// 一条候选的 JSON 形状（`id` = `subs download` 认的 resultId）。
Map<String, Object?> subsCandidateJson(VideoSubtitleCandidate c) => <String, Object?>{
  'id': c.identityKey,
  'provider': c.providerId,
  'remoteId': c.remoteId,
  'fileName': c.fileName,
  'language': c.language,
  if (c.releaseName != null) 'releaseName': c.releaseName,
  if (c.season != null) 'season': c.season,
  if (c.episode != null) 'episode': c.episode,
  if (c.fileSize != null) 'fileSize': c.fileSize,
  'downloadCount': c.downloadCount,
  if (c.hearingImpaired) 'hearingImpaired': true,
  if (c.aiTranslated) 'aiTranslated': true,
  if (c.fromTrusted) 'fromTrusted': true,
  if (c.uploadedAtMs != null)
    'uploadedAt': DateTime.fromMillisecondsSinceEpoch(c.uploadedAtMs!, isUtc: true).toIso8601String(),
};

/// 下载字幕的缺省落点：`<视频目录>/<视频名>.<语言>.<扩展名>`（语言未知则省略）。
String defaultSubtitleOutputPath({required String videoPath, required String fileName, required String language}) {
  String ext = p.extension(fileName).toLowerCase();
  if (!const <String>{'.srt', '.ass', '.ssa', '.vtt', '.sub', '.lrc'}.contains(ext)) ext = '.srt';
  final String lang = language.trim().toLowerCase().replaceAll(RegExp(r'[^a-z0-9-]'), '');
  return p.join(p.dirname(videoPath), '${p.basenameWithoutExtension(videoPath)}${lang.isEmpty ? '' : '.$lang'}$ext');
}

Future<int> subsDownload(ArgResults sub, {required ServerRuntime rt, required CliIo io, required SubsDeps deps}) async {
  if (sub.rest.length != 1) return io.fail(kExitUsage, '用法: subs download <resultId> --to <video>');
  final String? to = sub['to'] as String?;
  if (to == null || to.trim().isEmpty) return io.fail(kExitUsage, 'subs download 需要 --to <video>');
  final String videoPath = p.absolute(to);
  if (!File(videoPath).existsSync()) return io.fail(kExitNoInput, '找不到视频文件: $videoPath');
  final String resultId = sub.rest.single;
  final int colon = resultId.indexOf(':');
  if (colon <= 0) return io.fail(kExitUsage, 'resultId 形如 <provider>:<remoteId>（取自 subs search 的第一列）');
  final String providerId = resultId.substring(0, colon);
  if (!kSubsProviderIds.contains(providerId)) return io.fail(kExitUsage, '未知字幕来源 $providerId');

  final File cache = subsSearchCacheFile(rt);
  if (!cache.existsSync()) return io.fail(kExitNoInput, '没有搜索记录：先跑 subs search');
  final Map<String, Object?> cached;
  try {
    cached = (jsonDecode(await cache.readAsString()) as Map<Object?, Object?>).cast<String, Object?>();
  } on Object catch (e) {
    return io.fail(kExitNoInput, '搜索记录损坏（${cache.path}）：$e；重新跑 subs search');
  }
  final List<Map<String, Object?>> rows = (cached['results'] as List<Object?>? ?? const <Object?>[])
      .whereType<Map<Object?, Object?>>()
      .map((Map<Object?, Object?> m) => m.cast<String, Object?>())
      .toList();
  if (!rows.any((Map<String, Object?> r) => r['id'] == resultId)) {
    return io.fail(kExitNoInput, '$resultId 不在上一次 subs search 的结果里');
  }
  final SubsSearchSpec spec = SubsSearchSpec.fromJson(
    (cached['spec'] as Map<Object?, Object?>? ?? const <Object?, Object?>{}).cast<String, Object?>(),
  );

  final SubsCredentials credentials = resolveSubsCredentials(rt.prefs, deps.env);
  final String? reason = credentials.unavailableReason(providerId);
  if (reason != null) return io.fail(kExitUnavailable, reason);

  // 候选对象只能由 provider 自己造（下载需要它私有的定位信息），所以按缓存的请求
  // 重问一次这一家，再按 identityKey 认回同一条。
  final VideoSubtitleProvider provider = deps.providerFactory(providerId, credentials);
  final VideoSubtitleDownload download;
  try {
    io.err.writeln('重新定位 $resultId …');
    final ProviderBatchResult<VideoSubtitleCandidate> result = await provider.search(spec.toRequest());
    VideoSubtitleCandidate? candidate;
    for (final VideoSubtitleCandidate c in result.items) {
      if (c.identityKey == resultId) {
        candidate = c;
        break;
      }
    }
    if (candidate == null) {
      if (result.items.isEmpty && result.failures.isNotEmpty) {
        return io.fail(kExitUnavailable, '$providerId 搜索失败：${result.failures.first.message}');
      }
      return io.fail(kExitFailure, '$resultId 已不在 $providerId 的搜索结果里');
    }
    io.err.writeln('下载 ${candidate.fileName} …');
    download = await provider.download(candidate);
  } on ExternalProviderFailure catch (e) {
    return io.fail(
      e.kind == ExternalProviderFailureKind.unauthorized || e.kind == ExternalProviderFailureKind.unavailable
          ? kExitUnavailable
          : kExitFailure,
      '$providerId 下载失败：${e.kind.name} ${e.message}',
    );
  } finally {
    provider.close();
  }

  final String outPath = (sub['out'] as String?)?.trim().isNotEmpty ?? false
      ? p.absolute(sub['out'] as String)
      : defaultSubtitleOutputPath(videoPath: videoPath, fileName: download.fileName, language: download.language);
  if (File(outPath).existsSync() && !(sub['force'] as bool)) {
    return io.fail(kExitFailure, '已存在: $outPath（加 --force 覆盖）');
  }
  await File(outPath).parent.create(recursive: true);
  await File(outPath).writeAsBytes(download.bytes, flush: true);

  // 落盘后的时长自检只做提示：这是用户亲手挑的那一条，不替他拒收。
  final SubtitleTimingCheck check = await _timingCheck(download.bytes, videoPath, deps);
  if (io.json) {
    io.writeJson(<String, Object?>{
      'ok': true,
      'exitCode': kExitOk,
      'id': resultId,
      'output': outPath,
      'fileName': download.fileName,
      'language': download.language,
      'bytes': download.bytes.length,
      'timing': <String, Object?>{'verdict': check.verdict.name, if (check.detail != null) 'detail': check.detail},
    });
  } else {
    io.out.writeln('已写入 $outPath（${download.bytes.length} 字节）');
  }
  if (check.verdict != SubtitleTimingVerdict.ok) {
    io.err.writeln('注意：时长自检 ${check.verdict.name}${check.detail == null ? '' : '（${check.detail}）'}');
  }
  return kExitOk;
}

Future<SubtitleTimingCheck> _timingCheck(Uint8List bytes, String videoPath, SubsDeps deps) async {
  final SubtitleTimingSummary summary = summarizeSubtitleTiming(utf8.decode(bytes, allowMalformed: true));
  final int? durationMs = await deps.probeDurationMs(videoPath);
  return checkSubtitleTiming(summary, video: durationMs == null ? null : KnownVideoDuration.probed(durationMs));
}

// ─── sync / restore / check ─────────────────────────────────────────

/// 两个位置参数都得是存在的文件；不满足时返回退出码，满足返回 null。
int? _requireFiles(ArgResults sub, CliIo io, List<String> names, String usage) {
  if (sub.rest.length != names.length) return io.fail(kExitUsage, '用法: $usage');
  for (int i = 0; i < names.length; i++) {
    if (!File(sub.rest[i]).existsSync()) return io.fail(kExitNoInput, '找不到${names[i]}: ${sub.rest[i]}');
  }
  return null;
}

/// 对齐结果的 JSON 形状。
Map<String, Object?> referenceSyncJson(EmbeddedReferenceSyncResult result) => <String, Object?>{
  'status': result.status.name,
  'kind': result.kind.name,
  'changesTiming': result.changesTiming,
  if (result.decision != null) ...<String, Object?>{
    'agreeingGroups': result.decision!.agreeingGroups,
    'conflicting': result.decision!.conflicting,
    'offsets': <Map<String, Object?>>[
      for (final s in result.decision!.segments)
        <String, Object?>{'offsetSeconds': s.offsetSeconds, if (s.splitSeconds != null) 'splitSeconds': s.splitSeconds},
    ],
    'offsetsText': formatAlignmentOffsets(result.decision!.segments),
  },
  'shifted': result.retime?.shiftedCount ?? 0,
  'dropped': result.retime?.droppedCount ?? 0,
};

Future<int> subsSync(ArgResults sub, {required CliIo io, required SubsDeps deps}) async {
  final int? bad = _requireFiles(sub, io, <String>['视频文件', '字幕文件'], 'subs sync <video> <subtitle>');
  if (bad != null) return bad;
  final String videoPath = p.absolute(sub.rest[0]);
  final String subtitlePath = p.absolute(sub.rest[1]);
  final Uint8List bytes = await File(subtitlePath).readAsBytes();
  if (await findSubtitleAlignmentOriginal(bytes) != null) {
    return io.fail(kExitFailure, '这份字幕已经是按内嵌轨对齐写下的产物；要重来先 subs restore $subtitlePath');
  }
  final String? ffmpeg = await deps.ffmpegProblem(probe: false) ?? await deps.ffmpegProblem(probe: true);
  if (ffmpeg != null) return io.fail(kExitUnavailable, ffmpeg);

  io.err.writeln('抽取内嵌字幕轨并判定（整片 demux，可能要几十秒）…');
  final EmbeddedReferenceSyncResult result = await syncSubtitleToEmbeddedReferences(
    subtitleBytes: bytes,
    videoPath: videoPath,
    videoDurationMs: await deps.probeDurationMs(videoPath),
    loadReferences: deps.loadReferences,
  );
  final Map<String, Object?> payload = referenceSyncJson(result);
  final (int, String)? problem = _syncProblem(result, force: sub['force'] as bool);
  if (problem != null) {
    if (io.json) {
      io.writeJson(<String, Object?>{
        'ok': problem.$1 == kExitOk,
        'exitCode': problem.$1,
        ...payload,
        'applied': false,
        'message': problem.$2,
      });
      io.err.writeln(problem.$2);
    } else {
      (problem.$1 == kExitOk ? io.out : io.err).writeln(problem.$2);
    }
    return problem.$1;
  }
  final String offsets = formatAlignmentOffsets(result.decision!.segments);
  if (sub['dry-run'] as bool) {
    if (io.json) {
      io.writeJson(<String, Object?>{'ok': true, 'exitCode': kExitOk, ...payload, 'applied': false, 'dryRun': true});
    } else {
      io.out.writeln('将平移 $offsets（${result.retime!.shiftedCount} 条），--dry-run 未写盘');
    }
    return kExitOk;
  }
  final Uint8List aligned = result.retime!.bytes;
  final String outPath = (sub['out'] as String?)?.trim().isNotEmpty ?? false
      ? p.absolute(sub['out'] as String)
      : subtitlePath;
  // 先登记原稿再写：登记失败就不改，绝不留下一份找不回原样的字幕（与自动路径同一纪律）。
  try {
    await saveSubtitleAlignmentOriginal(original: bytes, aligned: aligned);
  } on FileSystemException catch (e) {
    return io.fail(kExitFailure, '原稿备份写不进去，放弃改写：${e.message} ${e.path ?? ''}');
  }
  await File(outPath).writeAsBytes(aligned, flush: true);
  if (io.json) {
    io.writeJson(<String, Object?>{'ok': true, 'exitCode': kExitOk, ...payload, 'applied': true, 'output': outPath});
  } else {
    io.out.writeln('已对齐 $offsets，写入 $outPath（原稿可用 subs restore 找回）');
  }
  return kExitOk;
}

/// 不能（或不必）应用时的退出码与说明；可以应用返回 null。
(int, String)? _syncProblem(EmbeddedReferenceSyncResult result, {required bool force}) {
  switch (result.status) {
    case EmbeddedReferenceSyncStatus.noReference:
      return (kExitFailure, '视频没有可当参考的内嵌文本字幕轨（生肉 / 只有图形字幕 / 抽取失败），无法对齐');
    case EmbeddedReferenceSyncStatus.subtitleUnreadable:
      return (kExitFailure, '字幕里可对齐的台词太少或解析不出时间轴');
    case EmbeddedReferenceSyncStatus.decided:
      break;
  }
  final String kind = result.kind.name;
  if (kind == 'refused') return (kExitFailure, '证据不足或互相矛盾，拒绝改动（${result.describe()}）');
  if (!result.changesTiming) return (kExitOk, '时间轴已经贴着视频，无需改动');
  if (kind == 'needsConfirmation' && !force) {
    return (
      kExitFailure,
      '只有「待确认」档的证据（${formatAlignmentOffsets(result.decision!.segments)}，'
          '${result.decision!.agreeingGroups} 组一致）；确认无误加 --force 应用',
    );
  }
  return null;
}

Future<int> subsRestore(ArgResults sub, {required CliIo io}) async {
  final int? bad = _requireFiles(sub, io, <String>['字幕文件'], 'subs restore <subtitle>');
  if (bad != null) return bad;
  final String subtitlePath = p.absolute(sub.rest.single);
  final Uint8List? original = await findSubtitleAlignmentOriginal(await File(subtitlePath).readAsBytes());
  if (original == null) {
    return io.fail(kExitFailure, '这份字幕不是 subs sync / 自动对齐写下的产物（或原稿备份已不在）');
  }
  final String outPath = (sub['out'] as String?)?.trim().isNotEmpty ?? false
      ? p.absolute(sub['out'] as String)
      : subtitlePath;
  await File(outPath).writeAsBytes(original, flush: true);
  if (io.json) {
    io.writeJson(<String, Object?>{'ok': true, 'exitCode': kExitOk, 'output': outPath, 'bytes': original.length});
  } else {
    io.out.writeln('已还原原稿到 $outPath');
  }
  return kExitOk;
}

Future<int> subsCheck(ArgResults sub, {required CliIo io, required SubsDeps deps}) async {
  final int? bad = _requireFiles(sub, io, <String>['视频文件', '字幕文件'], 'subs check <video> <subtitle>');
  if (bad != null) return bad;
  final String videoPath = p.absolute(sub.rest[0]);
  final String text = utf8.decode(await File(sub.rest[1]).readAsBytes(), allowMalformed: true);
  final SubtitleTimingSummary summary = summarizeSubtitleTiming(text);
  final int? durationMs = await deps.probeDurationMs(videoPath);
  final SubtitleTimingCheck check = checkSubtitleTiming(
    summary,
    video: durationMs == null ? null : KnownVideoDuration.probed(durationMs),
  );
  // 内容本身就坏（读不出 / 全零 / 比视频长得多）是业务失败；内容没问题但量不到视频
  // 时长，说明主判据根本没跑——那是依赖问题（ffprobe），不能报「通过」。
  final int code = check.rejected
      ? kExitFailure
      : durationMs == null
      ? kExitUnavailable
      : kExitOk;
  if (io.json) {
    io.writeJson(<String, Object?>{
      'ok': code == kExitOk,
      'exitCode': code,
      'verdict': check.verdict.name,
      if (check.detail != null) 'detail': check.detail,
      'cueCount': summary.cueCount,
      'firstStartMs': summary.firstStartMs,
      'lastEndMs': summary.lastEndMs,
      'videoDurationMs': durationMs,
    });
  } else {
    io.out.writeln('${check.verdict.name}${check.detail == null ? '' : ': ${check.detail}'}');
    io.out.writeln(
      '字幕 ${summary.cueCount} 条，${formatClockMs(summary.firstStartMs)} → ${formatClockMs(summary.lastEndMs)}；'
      '视频 ${durationMs == null ? '时长未知' : formatClockMs(durationMs)}',
    );
  }
  if (durationMs == null && !check.rejected) {
    io.err.writeln('探测不到视频时长（ffprobe 不可用或不是视频文件），只做了字幕内容自检');
  }
  return code;
}
