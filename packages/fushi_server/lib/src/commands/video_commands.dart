/// `fushi_server video …`：视频文件的 ED2K 哈希 / AniDB 身份、sidecar 重写、片段导出、
/// 蓝光盘探测。
///
/// ```
/// video hash         <file>
/// video identify     <file>
/// video sidecar write <workId>|--all [--replace]
/// video clip         <file> --from <t> --to <t> -o <out> [--subs x.srt | --burn-subs x.ass] [--audio-track N] [--bitrate kbps]
/// video probe-bluray <dir>
/// ```
///
/// 引擎入口：`anidb_ed2k.dart`（离线算哈希）、`anidb_hash_identity_service.dart`
/// （AniDB UDP `FILE`）、`VideoSourceScrapeCoordinator.rewriteSidecarsForStoredWork`
/// （同一套 `video_sidecar_writer.dart` 所有权账本）、`video_clip_exporter.dart`、
/// `bluray_disc.dart` + `bluray_probe.dart`。
///
/// AniDB 纪律（CLAUDE.md「动画刮削」）：UDP 客户端身份是 Fushi 自己登记的
/// （`kBundledAniDbClient`，或偏好里用户自填的），**绝不冒用 Shoko 的**；账号 / 密码
/// 缺任一项就在发任何请求前判不可用（69）。账号可从环境变量 `FUSHI_ANIDB_USERNAME` /
/// `FUSHI_ANIDB_PASSWORD` 给（不进 argv），其次是与 app 同名的偏好键。
library;

import 'dart:io';

import 'package:args/args.dart';
import 'package:fushi_audio/fushi_audio_core.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/foundation/pref_store.dart';
import 'package:fushi_engine/media/video/bluray/bluray_disc.dart';
import 'package:fushi_engine/media/video/bluray/bluray_probe.dart';
import 'package:fushi_engine/media/video/metadata/anidb_ed2k.dart';
import 'package:fushi_engine/media/video/metadata/anidb_file_identity_store.dart';
import 'package:fushi_engine/media/video/metadata/anidb_hash_identity_service.dart';
import 'package:fushi_engine/media/video/metadata/anidb_udp_file_client.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_config.dart';
import 'package:fushi_engine/media/video/metadata/video_source_scrape_task.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_engine/media/video/video_clip_exporter.dart';
import 'package:fushi_engine/media/video/video_clip_subtitle.dart';
import 'package:fushi_engine/media/video/video_duration_probe.dart';
import 'package:fushi_server/src/commands/cli_module.dart';
import 'package:fushi_server/src/commands/subs_commands.dart' show ffmpegUnavailableReason;
import 'package:fushi_server/src/commands/video_cli_support.dart';
import 'package:fushi_server/src/server_runtime.dart';
import 'package:fushi_server/src/video_scrape_host.dart';
import 'package:path/path.dart' as p;

const String kAniDbUsernameEnv = 'FUSHI_ANIDB_USERNAME';
const String kAniDbPasswordEnv = 'FUSHI_ANIDB_PASSWORD';

const String _usage = '''
video（视频文件工具）:
  video hash          <file>                 （离线算 AniDB ED2K 哈希）
  video identify      <file>                 （ED2K + AniDB UDP FILE；账号见 video_commands.dart 文件头）
  video sidecar write <workId>|--all [--replace]   （按库内已刮资料重写 NFO + 封面，不重新识别）
  video clip          <file> --from 1:23 --to 1:45 -o x.mkv [--subs x.srt | --burn-subs x.ass] [--audio-track N] [--bitrate kbps]
                      （--burn-subs 用 ffmpeg 的 libass `subtitles` 滤镜硬烧，必然重编码视频）
  video probe-bluray  <dir>                  （读 BDMV 播放列表：可播标题、时长、音轨 / 字幕轨）
  每个子命令都支持 --json。''';

class VideoCliModule extends CliModule {
  const VideoCliModule();

  @override
  List<String> get commands => const <String>['video'];

  @override
  String get usage => _usage;

  @override
  void register(ArgParser parser) => buildVideoParser(parser.addCommand('video'));

  @override
  Future<int> run(String name, ArgResults command, CliContext ctx) {
    final ArgResults? sub = command.command;
    if (sub == null) {
      stderr.writeln(_usage);
      return Future<int>.value(kExitUsage);
    }
    final ArgResults leaf = sub.command ?? sub;
    final CliIo io = CliIo(json: jsonFlag(leaf));
    // hash / probe-bluray 是纯本地文件操作，不开数据库也能跑——但 identify / sidecar
    // 要 DB 与偏好，统一走 runtime 保持一处前置（配置缺失照样 66）。
    return ctx.withRuntime((ServerRuntime rt) => runVideoCommand(sub, rt: rt, io: io));
  }
}

/// 给 `video` 登记子命令的参数表。
void buildVideoParser(ArgParser video) {
  addJsonFlag(video.addCommand('hash'));
  addJsonFlag(video.addCommand('identify'));
  final ArgParser sidecar = video.addCommand('sidecar');
  addJsonFlag(sidecar.addCommand('write'))
    ..addFlag('all', negatable: false, help: '库里所有已刮出规范身份的作品')
    ..addFlag('replace', negatable: false, help: '替换 Fushi 自己写下且未被改动过的旧 sidecar（第三方文件仍受保护）');
  addJsonFlag(video.addCommand('clip'))
    ..addOption('from', help: '起点（秒 / mm:ss / hh:mm:ss.mmm / 1500ms）')
    ..addOption('to', help: '终点（同上）')
    ..addOption('out', abbr: 'o', help: '输出文件（扩展名决定容器）')
    ..addOption('subs', help: '把这份字幕裁到区间内软封进片段（mkv / webm；mp4 封不下文本字幕会自动跳过）')
    ..addOption(
      'burn-subs',
      help: '用 ffmpeg 的 libass（subtitles 滤镜）把这份 SRT / ASS / VTT 硬烧进画面（重编码视频；与 --subs 互斥）',
    )
    ..addOption('audio-track', help: '音轨序号（0 起）')
    ..addOption('bitrate', help: '视频目标码率 kbps（缺省能 copy 就 copy）');
  addJsonFlag(video.addCommand('probe-bluray'));
}

/// 运行期依赖（测试注入）。
class VideoDeps {
  const VideoDeps({
    this.hasher = hashAnidbFile,
    this.environment,
    this.identityServiceFactory,
    this.ffmpegProblem = ffmpegUnavailableReason,
    this.sidecarRewriter,
    this.ffmpegBackend = resolveFfmpegBackend,
    this.ffmpegFilters = probeFfmpegFilterNames,
  });

  final AnidbFileHasher hasher;

  /// 读 AniDB 账号的环境变量（null = 进程环境）。
  final Map<String, String>? environment;

  /// 造 AniDB 身份服务（null = 生产装配：真 UDP 客户端 + DB 持久层）。
  final AnidbHashIdentityService Function(AnidbUdpConfig config, FushiDatabase db)? identityServiceFactory;

  /// ffmpeg / ffprobe 可用性探测。
  final Future<String?> Function({required bool probe}) ffmpegProblem;

  /// sidecar 重写（null = 生产：服务端刮削协调器）。返回 null = 作品不存在。
  final Future<SourceScrapeReport?> Function(ServerRuntime rt, int workId, {required bool replace})? sidecarRewriter;

  /// `--burn-subs` 探滤镜与烧录用的 ffmpeg 后端（生产：引擎装配点 [resolveFfmpegBackend]，
  /// 与片段导出 / 字幕对齐同一套查找与覆盖规则）。
  final FfmpegBackend Function() ffmpegBackend;

  /// 本机 ffmpeg 编进的滤镜名（`ffmpeg -hide_banner -filters`）。
  final Future<Set<String>> Function() ffmpegFilters;

  Map<String, String> get env => environment ?? Platform.environment;
}

/// 分发 `video` 的子命令。
Future<int> runVideoCommand(
  ArgResults sub, {
  required ServerRuntime rt,
  required CliIo io,
  VideoDeps deps = const VideoDeps(),
}) async {
  switch (sub.name) {
    case 'hash':
      return videoHash(sub, io: io, deps: deps);
    case 'identify':
      return videoIdentify(sub, rt: rt, io: io, deps: deps);
    case 'sidecar':
      final ArgResults? leaf = sub.command;
      if (leaf == null || leaf.name != 'write') return io.fail(kExitUsage, '用法: video sidecar write <workId>|--all');
      return videoSidecarWrite(leaf, rt: rt, io: io, deps: deps);
    case 'clip':
      return videoClip(sub, io: io, deps: deps);
    case 'probe-bluray':
      return videoProbeBluray(sub, io: io);
  }
  return io.fail(kExitUsage, _usage);
}

int? _requireOneFile(ArgResults sub, CliIo io, String usage) {
  if (sub.rest.length != 1) return io.fail(kExitUsage, '用法: $usage');
  if (!File(sub.rest.single).existsSync()) return io.fail(kExitNoInput, '找不到文件: ${sub.rest.single}');
  return null;
}

/// 长任务进度：每过 5% 在 stderr 刷一次（不打满屏）。
void Function(int, int) _progressPrinter(CliIo io, String label) {
  int lastPercent = -1;
  return (int done, int total) {
    if (total <= 0) return;
    final int percent = (done * 100 ~/ total);
    if (percent == lastPercent || (percent % 5 != 0 && percent != 100)) return;
    lastPercent = percent;
    io.err.write('\r$label $percent%   ');
    if (percent == 100) io.err.writeln();
  };
}

/// ED2K 链接（`ed2k://|file|<名>|<字节>|<哈希>|/`），名字里的 `|` 换成 `_`。
String ed2kLink(String fileName, int size, String ed2k) =>
    'ed2k://|file|${fileName.replaceAll('|', '_')}|$size|$ed2k|/';

Map<String, Object?> _hashJson(String path, AnidbEd2kHash hash) => <String, Object?>{
  'path': path,
  'size': hash.size,
  'ed2k': hash.ed2k,
  if (hash.alternativeEd2k != null && hash.alternativeEd2k != hash.ed2k) 'alternativeEd2k': hash.alternativeEd2k,
  'link': ed2kLink(p.basename(path), hash.size, hash.ed2k),
};

Future<int> videoHash(ArgResults sub, {required CliIo io, required VideoDeps deps}) async {
  final int? bad = _requireOneFile(sub, io, 'video hash <file>');
  if (bad != null) return bad;
  final String path = p.absolute(sub.rest.single);
  final AnidbEd2kHash hash = await deps.hasher(path, onProgress: _progressPrinter(io, 'ED2K'));
  if (io.json) {
    io.writeJson(<String, Object?>{'ok': true, 'exitCode': kExitOk, ..._hashJson(path, hash)});
  } else {
    io.out.writeln('${hash.ed2k}  ${hash.size}  $path');
    if (hash.alternativeEd2k != null && hash.alternativeEd2k != hash.ed2k) {
      io.out.writeln('（整块倍数文件的另一种算法: ${hash.alternativeEd2k}）');
    }
  }
  return kExitOk;
}

/// AniDB UDP 配置：偏好表（与 app 同一判据，含客户端身份解析）+ 环境变量里的账号。
AnidbUdpConfig resolveAniDbUdpConfig(PrefStore prefs, Map<String, String> env, {required String locale}) {
  final VideoSourceScrapeGlobalConfig config = VideoSourceScrapeGlobalConfig.fromPreferences(
    prefs,
    resolvedTmdbApiKey: '',
    uiLocaleTag: locale,
  );
  final AnidbUdpConfig fromPrefs = config.anidbUdpConfig;
  final String user = (env[kAniDbUsernameEnv] ?? '').trim();
  final String password = env[kAniDbPasswordEnv] ?? '';
  if (user.isEmpty && password.isEmpty) return fromPrefs;
  return AnidbUdpConfig(
    username: user.isNotEmpty ? user : fromPrefs.username,
    password: password.isNotEmpty ? password : fromPrefs.password,
    clientName: fromPrefs.clientName,
    clientVersion: fromPrefs.clientVersion,
  );
}

/// AniDB 不可用的原因（发请求前判）；可用返回 null。
String? aniDbUnavailableReason(AnidbUdpConfig config) {
  if (config.isAvailable) return null;
  final List<String> missing = <String>[
    if (!RegExp(r'^[a-z]{4,16}$').hasMatch(config.clientName) || config.clientVersion <= 0) '已登记的 AniDB UDP 客户端身份',
    if (!RegExp(r'^[a-zA-Z0-9_-]+$').hasMatch(config.username)) 'AniDB 用户名',
    if (config.password.isEmpty) 'AniDB 密码',
  ];
  return 'AniDB 不可用：缺${missing.isEmpty ? '有效配置' : missing.join('、')}。'
      '设环境变量 $kAniDbUsernameEnv / $kAniDbPasswordEnv，或从已配好的 Fushi 经互联同步；'
      '只算哈希用 video hash';
}

Map<String, Object?> _identityJson(AnidbFileIdentity identity) => <String, Object?>{
  'fileId': identity.fileId,
  'animeId': identity.animeId,
  'episodeId': identity.episodeId,
  'episodeNumber': identity.episodeNumber,
  'animeType': identity.animeType,
  'romajiTitle': identity.romajiTitle,
  'kanjiTitle': identity.kanjiTitle,
  'englishTitle': identity.englishTitle,
  'episodeTitle': identity.episodeTitle,
  'episodeRomajiTitle': identity.episodeRomajiTitle,
  'episodeKanjiTitle': identity.episodeKanjiTitle,
  if (identity.episodeAirDate != null) 'episodeAirDate': identity.episodeAirDate,
  if (identity.isDeprecated) 'deprecated': true,
  'fileVersion': identity.fileVersion,
  if (identity.crcMatches != null) 'crcMatches': identity.crcMatches,
  if (identity.otherEpisodes.isNotEmpty)
    'otherEpisodes': <Map<String, Object?>>[
      for (final AnidbEpisodeShare share in identity.otherEpisodes)
        <String, Object?>{
          'episodeId': share.episodeId,
          'percentage': share.percentage,
          if (share.episodeNumber != null) 'episodeNumber': share.episodeNumber,
        },
    ],
};

/// AniDB 失败 → 退出码：凭据 / 封禁 / 网络这类「依赖不可用」给 69，其余 1。
int aniDbFailureExitCode(Object? error) {
  if (error is AnidbUdpException) {
    return switch (error.reason) {
      AnidbUdpFailure.invalidInput || AnidbUdpFailure.malformedResponse => kExitFailure,
      _ => kExitUnavailable,
    };
  }
  if (error is SocketException) return kExitUnavailable;
  return kExitFailure;
}

Future<int> videoIdentify(
  ArgResults sub, {
  required ServerRuntime rt,
  required CliIo io,
  required VideoDeps deps,
}) async {
  final int? bad = _requireOneFile(sub, io, 'video identify <file>');
  if (bad != null) return bad;
  final String path = p.absolute(sub.rest.single);
  final AnidbUdpConfig config = resolveAniDbUdpConfig(rt.prefs, deps.env, locale: rt.config.metadataLocale);
  // 发请求前的硬门：缺账号或缺已登记客户端身份就不开 socket。
  final String? reason = aniDbUnavailableReason(config);
  if (reason != null) return io.fail(kExitUnavailable, reason);

  final AnidbHashIdentityService service = deps.identityServiceFactory != null
      ? deps.identityServiceFactory!(config, rt.db)
      : AnidbHashIdentityService(
          // 命令本身就是显式请求：不看「刮削时自动算哈希」那个开关。
          enabled: true,
          config: config,
          store: AnidbFileIdentityDatabaseStore(rt.db),
        );
  final AnidbHashIdentityResult result;
  try {
    result = await service.identifyFile(path, onProgress: _progressPrinter(io, 'ED2K'));
  } finally {
    await service.close();
  }
  final int code = switch (result.status) {
    AnidbHashIdentityStatus.matched => kExitOk,
    AnidbHashIdentityStatus.notFound => kExitFailure,
    AnidbHashIdentityStatus.disabled || AnidbHashIdentityStatus.unavailable => kExitUnavailable,
    AnidbHashIdentityStatus.cancelled => kExitFailure,
    AnidbHashIdentityStatus.failed => aniDbFailureExitCode(result.error),
  };
  final AnidbFileIdentity? identity = result.identity;
  if (io.json) {
    io.writeJson(<String, Object?>{
      'ok': code == kExitOk,
      'exitCode': code,
      'status': result.status.name,
      if (result.hash != null) ..._hashJson(path, result.hash!),
      if (result.matchedEd2k != null) 'matchedEd2k': result.matchedEd2k,
      'fromStore': result.fromStore,
      if (identity != null) 'identity': _identityJson(identity),
      if (result.confirmedMalId != null) 'malId': result.confirmedMalId,
      if (result.status == AnidbHashIdentityStatus.notFound) ...<String, Object?>{
        'missAttempts': result.missAttempts,
        'missExhausted': result.missExhausted,
      },
      if (result.error != null) 'error': result.error.toString(),
      if (result.mappingError != null) 'mappingError': result.mappingError.toString(),
      if (result.episodeInfoError != null) 'episodeInfoError': result.episodeInfoError.toString(),
    });
  } else {
    switch (result.status) {
      case AnidbHashIdentityStatus.matched:
        io.out.writeln(
          'aid ${identity!.animeId}  eid ${identity.episodeId}  ep ${identity.episodeNumber}  '
          '${identity.romajiTitle}${identity.kanjiTitle.isEmpty ? '' : ' / ${identity.kanjiTitle}'}'
          '${result.confirmedMalId == null ? '' : '  mal ${result.confirmedMalId}'}'
          '${result.fromStore ? '  (本地记录)' : ''}',
        );
      case AnidbHashIdentityStatus.notFound:
        io.out.writeln('AniDB 未收录这份文件（ed2k ${result.hash?.ed2k}，第 ${result.missAttempts} 次未命中）');
      default:
        io.err.writeln('识别失败: ${result.status.name}${result.error == null ? '' : ' ${result.error}'}');
    }
  }
  return code;
}

Map<String, Object?> _reportJson(SourceScrapeReport report) => <String, Object?>{
  'nfoWritten': report.nfoWritten,
  'imagesWritten': report.imagesWritten,
  'protected': report.protectedArtifacts,
  'unchanged': report.unchangedArtifacts,
  'warnings': <String>[for (final SourceScrapeIssue w in report.warnings) _issueText(w)],
  'errors': <String>[for (final SourceScrapeIssue e in report.errors) _issueText(e)],
};

String _issueText(SourceScrapeIssue issue) => '${issue.message}${issue.path == null ? '' : ' (${issue.path})'}';

Future<SourceScrapeReport?> _productionSidecarRewriter(ServerRuntime rt, int workId, {required bool replace}) async {
  final ServerVideoScrape scrape = ServerVideoScrape(db: rt.db, prefs: rt.prefs, config: () => rt.config);
  try {
    return await scrape.coordinator.rewriteSidecarsForStoredWork(workId, replaceOwnArtifacts: replace);
  } finally {
    scrape.close();
  }
}

Future<int> videoSidecarWrite(
  ArgResults leaf, {
  required ServerRuntime rt,
  required CliIo io,
  required VideoDeps deps,
}) async {
  final bool all = leaf['all'] as bool;
  if (all == leaf.rest.isNotEmpty || leaf.rest.length > 1) {
    return io.fail(kExitUsage, '用法: video sidecar write <workId> | video sidecar write --all');
  }
  final List<int> workIds;
  if (all) {
    workIds = <int>[for (final VideoMetadataWorkRow row in await rt.db.getAllVideoMetadataWorks()) row.id];
  } else {
    final int? id = int.tryParse(leaf.rest.single);
    if (id == null) return io.fail(kExitUsage, 'workId 需要整数（video_metadata_works.id），收到 "${leaf.rest.single}"');
    workIds = <int>[id];
  }
  final rewrite = deps.sidecarRewriter ?? _productionSidecarRewriter;
  final bool replace = leaf['replace'] as bool;
  final List<Map<String, Object?>> rows = <Map<String, Object?>>[];
  int failures = 0;
  for (int i = 0; i < workIds.length; i++) {
    final int id = workIds[i];
    if (workIds.length > 1) io.err.writeln('[${i + 1}/${workIds.length}] work $id');
    try {
      final SourceScrapeReport? report = await rewrite(rt, id, replace: replace);
      if (report == null) {
        if (!all) return io.fail(kExitNoInput, '没有这个作品: $id');
        continue;
      }
      if (report.errors.isNotEmpty) failures++;
      rows.add(<String, Object?>{'workId': id, 'ok': report.errors.isEmpty, ..._reportJson(report)});
    } on StateError catch (e) {
      // 没有规范身份 / 不在本地来源里：单个作品时是业务失败，--all 时记下跳过。
      failures++;
      rows.add(<String, Object?>{'workId': id, 'ok': false, 'skipped': true, 'reason': e.message});
    }
  }
  final int code = failures == 0 ? kExitOk : kExitFailure;
  if (io.json) {
    io.writeJson(<String, Object?>{'ok': code == kExitOk, 'exitCode': code, 'works': rows});
  } else {
    for (final Map<String, Object?> row in rows) {
      if (row['skipped'] == true) {
        io.out.writeln('work ${row['workId']}: 跳过（${row['reason']}）');
        continue;
      }
      io.out.writeln(
        'work ${row['workId']}: NFO ${row['nfoWritten']}，图片 ${row['imagesWritten']}，'
        '受保护 ${row['protected']}，未变 ${row['unchanged']}',
      );
      for (final Object? e in row['errors'] as List<Object?>) {
        io.out.writeln('  ! $e');
      }
    }
    if (rows.isEmpty) io.out.writeln('（没有可写的作品）');
  }
  return code;
}

/// 读一份字幕文件成 cue（按扩展名选解析器）；不认识的格式返回 null。
List<AudioCue>? parseSubtitleFileCues(String path, String content) {
  const String key = 'cli-clip';
  return switch (p.extension(path).toLowerCase()) {
    '.srt' => SrtParser.parseString(content: content, bookKey: key),
    '.vtt' => VttParser.parseString(content: content, bookKey: key),
    '.ass' || '.ssa' => AssParser.parseString(content: content, bookKey: key),
    _ => null,
  };
}

Future<int> videoClip(ArgResults sub, {required CliIo io, required VideoDeps deps}) async {
  const String usage = 'video clip <file> --from <t> --to <t> -o <out>';
  if (sub.rest.length != 1) return io.fail(kExitUsage, '用法: $usage');
  final String? fromRaw = sub['from'] as String?;
  final String? toRaw = sub['to'] as String?;
  final String? outRaw = sub['out'] as String?;
  if (fromRaw == null || toRaw == null || outRaw == null || outRaw.trim().isEmpty) {
    return io.fail(kExitUsage, '用法: $usage（--from / --to / -o 都必填）');
  }
  final int? startMs = parseClockArgToMs(fromRaw);
  final int? endMs = parseClockArgToMs(toRaw);
  if (startMs == null || endMs == null) return io.fail(kExitUsage, '时间写法不认识：--from $fromRaw --to $toRaw');
  if (endMs <= startMs) return io.fail(kExitUsage, '--to 必须晚于 --from');
  int? audioTrack;
  int? bitrate;
  if (sub['audio-track'] != null) {
    audioTrack = int.tryParse(sub['audio-track'] as String);
    if (audioTrack == null || audioTrack < 0) return io.fail(kExitUsage, '--audio-track 需要非负整数');
  }
  if (sub['bitrate'] != null) {
    bitrate = int.tryParse(sub['bitrate'] as String);
    if (bitrate == null || bitrate <= 0) return io.fail(kExitUsage, '--bitrate 需要正整数（kbps）');
  }
  final String? burnPath = sub['burn-subs'] as String?;
  if (burnPath != null && sub['subs'] != null) {
    return io.fail(kExitUsage, '--subs（软封）与 --burn-subs（硬烧）只能二选一');
  }
  final String input = p.absolute(sub.rest.single);
  if (!File(input).existsSync()) return io.fail(kExitNoInput, '找不到视频文件: $input');
  final String output = p.absolute(outRaw);
  if (p.equals(input, output)) return io.fail(kExitUsage, '输出不能覆盖输入文件');

  if (burnPath != null) {
    return _videoClipBurn(
      input: input,
      output: output,
      subtitlePath: burnPath,
      startMs: startMs,
      endMs: endMs,
      audioTrack: audioTrack,
      bitrate: bitrate,
      io: io,
      deps: deps,
    );
  }

  final List<String> subtitleContents = <String>[];
  final String? subsPath = sub['subs'] as String?;
  if (subsPath != null) {
    if (!File(subsPath).existsSync()) return io.fail(kExitNoInput, '找不到字幕文件: $subsPath');
    final List<AudioCue>? cues = parseSubtitleFileCues(subsPath, await File(subsPath).readAsString());
    if (cues == null) return io.fail(kExitUsage, '字幕格式不认识（支持 .srt / .vtt / .ass / .ssa）: $subsPath');
    final String? srt = buildClipSrtContent(cues: cues, startMs: startMs, endMs: endMs);
    if (srt == null) {
      io.err.writeln('区间内没有字幕台词，只导出视频音频');
    } else {
      subtitleContents.add(srt);
      if (resolveClipSubtitleCodec(output) == null) {
        io.err.writeln('${p.extension(output)} 容器封不下文本字幕（见 resolveClipSubtitleCodec），将跳过字幕；要带字幕用 .mkv');
      }
    }
  }
  final String? ffmpeg = await deps.ffmpegProblem(probe: false);
  if (ffmpeg != null) return io.fail(kExitUnavailable, ffmpeg);

  io.err.writeln('导出 ${formatClockMs(startMs)} → ${formatClockMs(endMs)} …');
  final VideoClipExportResult result = await exportVideoClipViaFfmpeg(
    inputPath: input,
    startMs: startMs,
    endMs: endMs,
    outputPath: output,
    audioStreamIndex: audioTrack,
    subtitleContents: subtitleContents,
    videoBitrateKbps: bitrate,
  );
  if (!result.isSuccess) {
    final int code = switch (result.failure) {
      VideoClipExportFailure.ffmpegUnavailable => kExitUnavailable,
      VideoClipExportFailure.inputMissing => kExitNoInput,
      VideoClipExportFailure.invalidRange => kExitUsage,
      _ => kExitFailure,
    };
    return io.fail(code, '导出失败: ${result.failure?.name}${result.detail == null ? '' : ' ${result.detail}'}');
  }
  if (io.json) {
    io.writeJson(<String, Object?>{
      'ok': true,
      'exitCode': kExitOk,
      'output': result.outputPath,
      'startMs': startMs,
      'endMs': endMs,
      'subtitleTracks': result.subtitleTrackCount,
      'bytes': File(result.outputPath!).lengthSync(),
    });
  } else {
    io.out.writeln('已写入 ${result.outputPath}（字幕轨 ${result.subtitleTrackCount} 条）');
  }
  return kExitOk;
}

/// 烧录允许的字幕扩展名（libass 经 libavformat 读：SRT / ASS / SSA / WebVTT）。
const Set<String> kBurnSubtitleExtensions = <String>{'.srt', '.ass', '.ssa', '.vtt'};

/// 跑 `ffmpeg -hide_banner -filters` 取滤镜名；起不来 / 超时 / 解不出返回空集合
/// （调用方按「不能烧」处理）。
///
/// 与 app 的片段导出共用引擎的唯一探测点 [queryFfmpegFilterNames]（经
/// [FfmpegBackend.runQuery] 收 stdout，可执行文件同样走「配置文件 `ffmpeg:` 覆盖 >
/// `FUSHI_FFMPEG` > 随包 > PATH」解析），不再自己 `Process.start` 一份（BUG-2938）。
Future<Set<String>> probeFfmpegFilterNames() =>
    queryFfmpegFilterNames(resolveFfmpegBackend(), const Duration(seconds: 30));

/// ffmpeg 烧录一次的上限（重编码比 copy 慢得多，长片段给足时间）。
const Duration _kBurnTimeout = Duration(minutes: 30);

/// `video clip --burn-subs`：用 ffmpeg 自带 libass（`subtitles` 滤镜）硬烧。
///
/// 与 app 的烧录路径（引擎 `exportVideoClipViaFfmpeg` 的 PNG + overlay，渲染器由
/// Flutter 提供）不同，无头端没有排版引擎，交给 libass 排版；滤镜 / 时间轴对齐 / 转义
/// 的纯函数在引擎 `buildFfmpegVideoClipLibassBurnArgs`。与 app 的「烧不了就静默退成
/// 无字幕导出」不同，命令行显式要了硬字幕，烧不了就报错，不交出一个没字幕的片段。
Future<int> _videoClipBurn({
  required String input,
  required String output,
  required String subtitlePath,
  required int startMs,
  required int endMs,
  required int? audioTrack,
  required int? bitrate,
  required CliIo io,
  required VideoDeps deps,
}) async {
  final String subs = p.absolute(subtitlePath);
  if (!File(subs).existsSync()) return io.fail(kExitNoInput, '找不到字幕文件: $subtitlePath');
  if (!kBurnSubtitleExtensions.contains(p.extension(subs).toLowerCase())) {
    return io.fail(kExitUsage, '字幕格式不认识（--burn-subs 支持 .srt / .ass / .ssa / .vtt）: $subtitlePath');
  }
  final String? ffmpeg = await deps.ffmpegProblem(probe: false);
  if (ffmpeg != null) return io.fail(kExitUnavailable, ffmpeg);
  final Set<String> filters = await deps.ffmpegFilters();
  if (!ffmpegHasLibassSubtitlesFilter(filters)) {
    return io.fail(
      kExitUnavailable,
      filters.isEmpty
          ? '探测 ffmpeg 滤镜失败（`ffmpeg -hide_banner -filters` 没给出滤镜表），无法确认能否硬烧字幕'
          : '本机 ffmpeg 没有 libass 的 `$kLibassSubtitlesFilter` 滤镜（编译时没带 --enable-libass），'
                '不能硬烧字幕；换一个带 libass 的 ffmpeg（配置文件 ffmpeg 路径），或改用 --subs 软封（输出用 .mkv）',
    );
  }
  final FfmpegBackend backend = deps.ffmpegBackend();
  final File out = File(output);
  out.parent.createSync(recursive: true);
  io.err.writeln('硬烧字幕导出 ${formatClockMs(startMs)} → ${formatClockMs(endMs)}（重编码）…');
  final FfmpegRunResult result;
  try {
    result = await backend.run(
      buildFfmpegVideoClipLibassBurnArgs(
        inputPath: input,
        startMs: startMs,
        endMs: endMs,
        outputPath: output,
        subtitlePath: subs,
        windows: Platform.isWindows,
        audioStreamIndex: audioTrack,
        videoBitrateKbps: bitrate,
      ),
      _kBurnTimeout,
    );
  } on ProcessException catch (e) {
    return io.fail(kExitUnavailable, '找不到 ffmpeg（${describeFfmpegProcessException(e)}）');
  }
  if (!result.isSuccess || !out.existsSync() || out.lengthSync() == 0) {
    if (out.existsSync()) out.deleteSync();
    final String reason = extractFfmpegFailureReason(result.output);
    return io.fail(kExitFailure, '硬烧字幕失败${reason.isEmpty ? '（${result.failureSummary}）' : ': $reason'}');
  }
  if (io.json) {
    io.writeJson(<String, Object?>{
      'ok': true,
      'exitCode': kExitOk,
      'output': output,
      'startMs': startMs,
      'endMs': endMs,
      'burnedSubtitles': subs,
      'subtitleTracks': 0,
      'bytes': out.lengthSync(),
    });
  } else {
    io.out.writeln('已写入 $output（字幕已硬烧进画面）');
  }
  return kExitOk;
}

/// 轨道的 CLI JSON（引擎的 `toJson` 是落库用的短键，这里给人和脚本读的全名）。
Map<String, Object?> _audioJson(AudioTrackFacts a) => <String, Object?>{
  'index': a.index,
  if (a.codec != null) 'codec': a.codec,
  if (a.language != null) 'language': a.language,
  if (a.channels != null) 'channels': a.channels,
  if (a.title != null) 'title': a.title,
};

Map<String, Object?> _subtitleJson(SubtitleTrackFacts s) => <String, Object?>{
  'index': s.index,
  if (s.codec != null) 'codec': s.codec,
  if (s.language != null) 'language': s.language,
  if (s.title != null) 'title': s.title,
};

Map<String, Object?> _factsJson(VideoProbeFacts facts) => <String, Object?>{
  if (facts.durationMs != null) 'durationMs': facts.durationMs,
  if (facts.fileSizeBytes != null) 'streamBytes': facts.fileSizeBytes,
  if (facts.video != null)
    'video': <String, Object?>{
      if (facts.video!.codec != null) 'codec': facts.video!.codec,
      if (facts.video!.height != null) 'height': facts.video!.height,
      if (facts.video!.frameRateMilli != null) 'fps': facts.video!.frameRateMilli! / 1000,
    },
  'audio': <Map<String, Object?>>[for (final AudioTrackFacts a in facts.audioTracks) _audioJson(a)],
  'subtitles': <Map<String, Object?>>[for (final SubtitleTrackFacts s in facts.subtitleTracks) _subtitleJson(s)],
};

Future<int> videoProbeBluray(ArgResults sub, {required CliIo io}) async {
  if (sub.rest.length != 1) return io.fail(kExitUsage, '用法: video probe-bluray <dir>');
  final String dir = p.absolute(sub.rest.single);
  if (!Directory(dir).existsSync()) return io.fail(kExitNoInput, '找不到目录: $dir');
  final String? root = blurayDiscRootForDirectory(dir);
  if (root == null) return io.fail(kExitNoInput, '不是蓝光盘目录（找不到 BDMV/PLAYLIST）: $dir');
  final BlurayDisc? disc = await readBlurayDisc(root);
  if (disc == null) return io.fail(kExitFailure, '读不出这张盘的播放列表: $root');
  final List<Map<String, Object?>> titles = <Map<String, Object?>>[];
  for (final BlurayTitle title in disc.titles) {
    final VideoProbeFacts facts = await probeBlurayPlaylistFacts(title.playlistPath);
    titles.add(<String, Object?>{
      'playlist': title.playlist.fileName,
      'path': title.playlistPath,
      'name': title.name,
      'mainFeature': title.isMainFeature,
      'durationMs': title.duration.inMilliseconds,
      'chapters': title.playlist.chapters.length,
      'clips': title.playlist.clipIds,
      if (!facts.isUnavailable) 'facts': _factsJson(facts),
    });
  }
  final int code = titles.isEmpty ? kExitFailure : kExitOk;
  if (io.json) {
    io.writeJson(<String, Object?>{
      'ok': code == kExitOk,
      'exitCode': code,
      'root': disc.rootPath,
      'name': disc.name,
      'playlists': disc.playlists.length,
      'titles': titles,
    });
  } else {
    io.out.writeln('${disc.name}  (${disc.rootPath})  播放列表 ${disc.playlists.length} 条，可播标题 ${titles.length} 条');
    for (final Map<String, Object?> t in titles) {
      final Map<String, Object?>? facts = t['facts'] as Map<String, Object?>?;
      final Map<String, Object?>? video = facts?['video'] as Map<String, Object?>?;
      final List<Object?> audio = facts?['audio'] as List<Object?>? ?? const <Object?>[];
      final List<Object?> subs = facts?['subtitles'] as List<Object?>? ?? const <Object?>[];
      io.out.writeln(
        '${t['mainFeature'] == true ? '*' : ' '} ${t['playlist']}  ${formatClockMs(t['durationMs'] as int)}  '
        '${video?['codec'] ?? '?'} ${video?['height'] ?? '?'}p  音轨 ${audio.length}  字幕 ${subs.length}  ${t['name']}',
      );
    }
    if (titles.isEmpty) io.out.writeln('（筛选后没有可播标题）');
  }
  return code;
}
