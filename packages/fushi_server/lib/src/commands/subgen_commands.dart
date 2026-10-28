/// `fushi_server subgen …`：离线跑视频日语字幕管线（识别 → AI 校对 → 导出）。
///
/// ```
/// subgen <视频或目录>... [--title T] [--no-ai] [--segmenter auto|moss|window]
///        [--moss-backend auto|cuda|vulkan|cpu] [--suffix ja] [--regen-glossary]
///        [--glossary g.json] [--dry-run] [--season] [--out-dir D]
///        [--moss-cli audiocpp_cli] [--moss-model moss.gguf] [--json]
/// ```
///
/// - 每个位置参数是一组：目录 = 递归找视频（`kVideoExtensions`，按路径排序），默认
///   整季（已有 `<视频名>.<后缀>.srt` 的集跳过）；文件 = 合成一组单集（`--season`
///   时按整季）。
/// - 作品上下文：视频在服务端库里就用 `SubtitleWorkContextLoader`（刮削身份 / 角色
///   日文名），否则 `--title` 或目录名 + `fallbackSubtitleWorkKey`。
/// - AI：配置文件 `ai:` 段那一家（`ServerAiSettings` 把字幕校对指给它）；没配又没给
///   `--no-ai` 时直接报错（69），不悄悄跳过校对。
/// - `--glossary`：导入 / 覆盖这部作品的专名表（JSON：`{"entries":[...]}` 或条目
///   数组），条目一律标成用户编辑过、资料指纹按当前资料算——之后不会被自动重新
///   生成覆盖（除非 `--regen-glossary`，那也会保留这些条目）。
/// - `--out-dir`：字幕全部写进这个目录，不碰视频目录。
/// - `--moss-cli` / `--moss-model`：直接用本机已有的 audio.cpp CLI 与 GGUF，不走
///   下载目录。
/// - 进度打 stderr；结束打每集结果与 AI 用量（应答没带用量的调用单列，不按 0 计）。
///   `--dry-run` 只列要处理 / 跳过的集与校对费用预估，不识别、不调 AI。
///
/// 管线缓存在 `<数据目录>/support/asr_jobs/video_subtitles/`，与 host 任务共用：中断
/// 后再跑同一批视频即从断点续。
library;

import 'dart:convert';
import 'dart:io';

import 'package:args/args.dart';
import 'package:crypto/crypto.dart';
import 'package:fushi_engine/ai/ai_chat_client.dart';
import 'package:fushi_engine/ai/ai_feature.dart';
import 'package:fushi_engine/ai/ai_provider_config.dart';
import 'package:fushi_engine/ai/web_knowledge.dart';
import 'package:fushi_engine/media/media_extensions.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/ai_text_completer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_draft.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary_builder.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_glossary_drift_store.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_pipeline_cancel.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/subtitle_work_context_loader.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_pipeline.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer.dart';
import 'package:fushi_engine/media/video/subtitle/asr_proofread/video_subtitle_recognizer_factory.dart';
import 'package:fushi_engine/media/video/video_duration_probe.dart';
import 'package:fushi_server/src/commands/cli_module.dart';
import 'package:fushi_server/src/commands/command_io.dart';
import 'package:fushi_server/src/config/server_ai_config.dart';
import 'package:fushi_server/src/host_bindings.dart';
import 'package:fushi_server/src/server_runtime.dart';
import 'package:path/path.dart' as p;

const String _usage = '''
subgen <视频或目录>... [--title T] [--no-ai] [--segmenter auto|moss|window]
       [--moss-backend auto|cuda|vulkan|cpu] [--suffix ja] [--regen-glossary]
       [--glossary g.json] [--dry-run] [--season] [--out-dir D]
       [--moss-cli audiocpp_cli] [--moss-model moss.gguf] [--json]
  目录 = 递归找视频、默认整季（已有字幕的集跳过）；AI 用配置 ai: 段那一家''';

/// 解析后的 `subgen` 参数。
class SubgenOptions {
  const SubgenOptions({
    required this.inputs,
    this.title,
    this.ai = true,
    this.segmenter = VideoSubtitleSegmenterMode.auto,
    this.mossBackend = MossBackendPreference.auto,
    this.suffix = 'ja',
    this.regenerateGlossary = false,
    this.glossaryFile,
    this.dryRun = false,
    this.season = false,
    this.outDir,
    this.mossCli,
    this.mossModel,
    this.json = false,
  });

  final List<String> inputs;
  final String? title;
  final bool ai;
  final VideoSubtitleSegmenterMode segmenter;
  final MossBackendPreference mossBackend;
  final String suffix;
  final bool regenerateGlossary;
  final String? glossaryFile;
  final bool dryRun;
  final bool season;
  final String? outDir;
  final String? mossCli;
  final String? mossModel;
  final bool json;
}

/// 给 `subgen` 登记参数表。
void buildSubgenParser(ArgParser parser) {
  addJsonFlag(parser)
    ..addOption('title', help: '作品名（库里没有刮削身份时用；缺省目录名）')
    ..addFlag('ai', defaultsTo: true, help: 'AI 校对（--no-ai 只识别 + 拆分 + 导出）')
    ..addOption(
      'segmenter',
      help: '分段：auto（能用 MOSS 就用）| moss（强制，不可用即失败）| window（滑窗）',
      allowed: <String>[
        for (final VideoSubtitleSegmenterMode m
            in VideoSubtitleSegmenterMode.values)
          m.name,
      ],
      defaultsTo: 'auto',
    )
    ..addOption(
      'moss-backend',
      help: 'MOSS 的 audio.cpp 后端',
      allowed: <String>[
        for (final MossBackendPreference b in MossBackendPreference.values)
          b.name,
      ],
      defaultsTo: 'auto',
    )
    ..addOption('suffix', help: '输出 <视频名>.<后缀>.srt', defaultsTo: 'ja')
    ..addFlag('regen-glossary', negatable: false, help: '资料没变也重新生成专名表')
    ..addOption('glossary', help: '导入 / 覆盖专名表的 JSON 文件')
    ..addFlag('dry-run', negatable: false, help: '只列要处理 / 跳过的集与费用预估')
    ..addFlag('season', negatable: false, help: '文件参数也按整季（跳过已有字幕的集）')
    ..addOption('out-dir', help: '字幕写到这个目录（缺省视频旁）')
    ..addOption('moss-cli', help: '直接用这个 audiocpp_cli（不走下载目录）')
    ..addOption('moss-model', help: '直接用这个 MOSS GGUF（不走下载目录）');
}

/// `ArgResults` → [SubgenOptions]；用法错误抛 [FormatException]。
SubgenOptions parseSubgenOptions(ArgResults command) {
  if (command.rest.isEmpty) {
    throw const FormatException('subgen: 至少给一个视频文件或目录');
  }
  T pick<T extends Enum>(List<T> values, String name) =>
      values.firstWhere((T e) => e.name == command[name] as String);
  final String suffix = command['suffix'] as String;
  if (!RegExp(r'^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)*$').hasMatch(suffix)) {
    throw FormatException('subgen: 后缀不合法 "$suffix"');
  }
  return SubgenOptions(
    inputs: <String>[for (final String a in command.rest) p.absolute(a)],
    title: command['title'] as String?,
    ai: command['ai'] as bool,
    segmenter: pick(VideoSubtitleSegmenterMode.values, 'segmenter'),
    mossBackend: pick(MossBackendPreference.values, 'moss-backend'),
    suffix: suffix,
    regenerateGlossary: command['regen-glossary'] as bool,
    glossaryFile: command['glossary'] as String?,
    dryRun: command['dry-run'] as bool,
    season: command['season'] as bool,
    outDir: command['out-dir'] as String?,
    mossCli: command['moss-cli'] as String?,
    mossModel: command['moss-model'] as String?,
    json: wantsJson(command),
  );
}

/// 一组视频（一部作品）。
class SubgenGroup {
  const SubgenGroup({
    required this.videos,
    required this.folder,
    required this.wholeSeason,
  });

  /// 按路径排序。
  final List<String> videos;

  /// 作品的兜底目录（目录参数本身 / 文件所在目录）。
  final String folder;
  final bool wholeSeason;
}

/// 位置参数 → 分组：每个目录一组（递归找视频、整季）；全部文件合成一组（[season]
/// 时整季）。不存在的路径、不是视频的文件抛 [FileSystemException]。
List<SubgenGroup> collectSubgenGroups(
  List<String> inputs, {
  bool season = false,
}) {
  bool isVideo(String path) =>
      kVideoExtensions.contains(p.extension(path).toLowerCase());
  final List<SubgenGroup> groups = <SubgenGroup>[];
  final List<String> files = <String>[];
  for (final String input in inputs) {
    if (FileSystemEntity.isDirectorySync(input)) {
      final List<String> videos = <String>[
        for (final FileSystemEntity e in Directory(
          input,
        ).listSync(recursive: true, followLinks: false))
          if (e is File && isVideo(e.path)) e.path,
      ]..sort();
      groups.add(SubgenGroup(videos: videos, folder: input, wholeSeason: true));
    } else if (File(input).existsSync()) {
      if (!isVideo(input)) {
        throw FileSystemException('不是视频文件', input);
      }
      files.add(input);
    } else {
      throw FileSystemException('找不到', input);
    }
  }
  if (files.isNotEmpty) {
    groups.add(
      SubgenGroup(
        videos: files..sort(),
        folder: p.dirname(files.first),
        wholeSeason: season,
      ),
    );
  }
  return groups;
}

/// 解析 `--glossary` 文件：`{"entries": [...]}` 或条目数组。条目一律标成用户编辑过。
List<SubtitleGlossaryEntry> parseSubgenGlossaryFile(String text) {
  final Object? decoded = jsonDecode(text);
  final Object? list = decoded is Map ? decoded['entries'] : decoded;
  if (list is! List) {
    throw const FormatException('专名表 JSON 要么是条目数组，要么是 {"entries": [...]}');
  }
  final List<SubtitleGlossaryEntry> entries = <SubtitleGlossaryEntry>[];
  for (final (int i, Object? e) in list.indexed) {
    if (e is! Map) continue;
    final SubtitleGlossaryEntry entry;
    try {
      entry = SubtitleGlossaryEntry.fromJson(e.cast<String, Object?>());
    } on TypeError catch (err) {
      // 字段类型不对（如 ja 写成数字）：按数据错误报出是第几条，而不是带堆栈崩掉。
      throw FormatException('专名表第 ${i + 1} 条字段类型不对：$err');
    }
    if (entry.ja.isNotEmpty) entries.add(entry.copyWith(userEdited: true));
  }
  return entries;
}

/// 没有刮削数据的视频平均每秒多少字（估费用用）：K-ON 基准 286 s 转写 2847 字
/// ≈ 10 字/秒是台词密集段，整集含 OP/ED 与空白取 7。
const double kSubgenEstimateCharsPerSecond = 7;

/// 运行期依赖（测试注入假实现）。
class SubgenDeps {
  const SubgenDeps({
    this.resolveRecognizer = _resolveRecognizer,
    this.probeDurationMs = probeVideoDurationMs,
    this.completerFactory,
  });

  final Future<VideoSubtitleRecognizerChoice> Function(
    VideoSubtitleSegmenterMode mode,
    MossBackendPreference backend, {
    String? mossCli,
    String? mossModel,
  })
  resolveRecognizer;

  final Future<int?> Function(String videoPath) probeDurationMs;

  /// null = 用 [AiChatTextCompleter]（配置 `ai:` 段那一家）。
  final AiTextCompleter Function(AiProviderConfig provider)? completerFactory;
}

Future<VideoSubtitleRecognizerChoice> _resolveRecognizer(
  VideoSubtitleSegmenterMode mode,
  MossBackendPreference backend, {
  String? mossCli,
  String? mossModel,
}) => resolveServerVideoSubtitleRecognizer(
  mode: mode,
  mossBackend: backend,
  mossCliPath: mossCli,
  mossModelPath: mossModel,
);

/// `subgen` 模块。
class SubgenModule extends CliModule {
  const SubgenModule({
    this.deps = const SubgenDeps(),
    this.io = const CommandIo(),
  });

  final SubgenDeps deps;

  /// 输出端（测试注入缓冲区）。
  final CommandIo io;

  @override
  List<String> get commands => const <String>['subgen'];

  @override
  String get usage => _usage;

  @override
  void register(ArgParser parser) =>
      buildSubgenParser(parser.addCommand('subgen'));

  @override
  Future<int> run(String name, ArgResults command, CliContext ctx) async {
    final SubgenOptions options;
    try {
      options = parseSubgenOptions(command);
    } on FormatException catch (e) {
      return io.usage(e.message, _usage);
    }
    return ctx.withRuntime(
      (ServerRuntime rt) => runSubgen(options, rt: rt, io: io, deps: deps),
    );
  }
}

/// 跑 `subgen`（[SubgenModule.run] 去掉参数解析之后的部分）。
Future<int> runSubgen(
  SubgenOptions options, {
  required ServerRuntime rt,
  required CommandIo io,
  SubgenDeps deps = const SubgenDeps(),
}) async {
  final List<SubgenGroup> groups;
  try {
    groups = collectSubgenGroups(options.inputs, season: options.season);
  } on FileSystemException catch (e) {
    io.err.writeln('${e.message}: ${e.path}');
    return kExitNoInput;
  }
  if (groups.every((SubgenGroup g) => g.videos.isEmpty)) {
    io.err.writeln('没有找到视频文件');
    return kExitNoInput;
  }

  // --glossary 是「这一部作品」的专名表：先整份解析好（坏文件在做任何事之前就报
  // 数据错误），并且只允许一部作品——多个目录会把同一份表导进每一部。
  List<SubtitleGlossaryEntry>? glossaryEntries;
  if (options.glossaryFile != null) {
    if (groups.where((SubgenGroup g) => g.videos.isNotEmpty).length > 1) {
      io.err.writeln('--glossary 只能用于一部作品；多个目录请分开运行');
      return kExitUsage;
    }
    try {
      glossaryEntries = parseSubgenGlossaryFile(
        await File(options.glossaryFile!).readAsString(),
      );
    } on FileSystemException catch (e) {
      io.err.writeln('读不了专名表 ${options.glossaryFile}: ${e.message}');
      return kExitNoInput;
    } on FormatException catch (e) {
      io.err.writeln('专名表 ${options.glossaryFile} 格式不对：${e.message}');
      return kExitDataError;
    }
  }

  AiProviderConfig? provider;
  if (options.ai) {
    final ServerAiSettings settings = ServerAiSettings(() => rt.config.ai);
    provider = settings.aiFeatureAssignments.resolve(
      AiFeature.subtitleProofread,
      settings.aiProviders,
    );
    if (provider == null) {
      io.err.writeln(
        '没有可用的 AI 提供商（配置文件 ai: 段${rt.config.ai?.problem() == null ? '未配置' : '：${rt.config.ai!.problem()}'}）；'
        '配好后重试，或加 --no-ai 只识别不校对',
      );
      return kExitUnavailable;
    }
  } else if (options.glossaryFile != null) {
    io.err.writeln('提示：--no-ai 时不校对，--glossary 只会存进库里、本次用不上');
  }

  final VideoSubtitleRecognizerChoice choice;
  try {
    choice = await deps.resolveRecognizer(
      options.segmenter,
      options.mossBackend,
      mossCli: options.mossCli,
      mossModel: options.mossModel,
    );
  } on VideoSubtitleRecognizeFailure catch (e) {
    io.err.writeln(e.message);
    return kExitUnavailable;
  }
  io.err.writeln(
    '识别器: ${choice.recognizer.id}'
    '${choice.mossBackend == null ? '' : '（MOSS ${choice.mossBackend!.cliValue}）'}'
    '${choice.mossUnavailableReason == null ? '' : '；没用上 MOSS：${choice.mossUnavailableReason}'}',
  );

  final Directory jobsRoot = videoSubtitleJobsRootUnder(rt.paths.support);
  final Directory? outDir = options.outDir == null
      ? null
      : Directory(p.absolute(options.outDir!));
  if (outDir != null && !options.dryRun) await outDir.create(recursive: true);
  final SubtitleGlossaryDriftStore glossaryStore = SubtitleGlossaryDriftStore(
    rt.db,
  );
  final List<WebKnowledgeSite> sites = ServerAiSettings(
    () => rt.config.ai,
  ).aiWebKnowledgeSites;

  final List<Map<String, Object?>> report = <Map<String, Object?>>[];
  final SubtitleAiUsageTally total = SubtitleAiUsageTally();
  int failures = 0;
  for (final SubgenGroup group in groups) {
    if (group.videos.isEmpty) continue;
    final SubtitleWorkContext work = await _workContext(
      rt,
      group,
      options.title,
    );
    io.err.writeln(
      '作品: ${work.title}（${work.workKey}${work.hasScrapedData ? '，有刮削数据' : '，无刮削数据'}）'
      ' ${group.videos.length} 集${group.wholeSeason ? '（整季）' : ''}',
    );
    if (glossaryEntries != null && !options.dryRun) {
      await _importGlossary(glossaryEntries, work, glossaryStore, sites, io);
    }
    final AiChatClient? client = provider == null || options.dryRun
        ? null
        : AiChatClient();
    final WebKnowledgeClient? web = client == null || sites.isEmpty
        ? null
        : WebKnowledgeClient(sites: sites);
    final VideoSubtitlePipeline pipeline = VideoSubtitlePipeline(
      recognizer: choice.recognizer,
      jobsRoot: jobsRoot,
      subtitleSuffix: options.suffix,
      exportDir: outDir,
      probeDurationMs: deps.probeDurationMs,
      // dry-run 不调 AI：管线只用来算路径，不装 AI。
      ai: provider == null || options.dryRun
          ? null
          : VideoSubtitleAiConfig(
              completer:
                  deps.completerFactory?.call(provider) ??
                  AiChatTextCompleter(client: client!, provider: provider),
              glossaryStore: glossaryStore,
              webKnowledge: web,
              regenerateGlossary: options.regenerateGlossary,
            ),
    );
    try {
      if (options.dryRun) {
        report.add(
          await _dryRun(pipeline, group, work, options, deps, io, choice),
        );
        continue;
      }
      final Stopwatch watch = Stopwatch()..start();
      final VideoSubtitlePipelineResult result = await pipeline.run(
        videoPaths: group.videos,
        work: work,
        wholeSeason: group.wholeSeason,
        onProgress: _progressPrinter(io.err),
      );
      watch.stop();
      io.err.writeln();
      total.addTally(result.usage);
      if (result.glossaryIdentityUnverified) {
        io.err.writeln(
          '警告：专名表的人名大多没在识别稿里出现（作品身份来自刮削，照常校对）；'
          '听到: ${result.glossaryHeardNames.join('、')}；'
          '没听到: ${result.glossaryMissingNames.join('、')}',
        );
      }
      report.add(<String, Object?>{
        'work': work.title,
        'workKey': work.workKey,
        'seconds': watch.elapsedMilliseconds / 1000,
        'glossaryRegenerated': result.glossaryRegenerated,
        if (result.glossaryIdentityUnverified)
          'glossaryIdentityWarning': <String, Object?>{
            'heard': result.glossaryHeardNames,
            'missing': result.glossaryMissingNames,
          },
        'usage': result.usage.toJson(),
        'episodes': <Map<String, Object?>>[
          for (final VideoSubtitleEpisodeResult e in result.episodes)
            <String, Object?>{
              'video': e.videoPath,
              'status': e.status.name,
              if (e.outputPath != null) 'output': e.outputPath,
              if (e.styledOutputPath != null)
                'styledOutput': e.styledOutputPath,
              if (e.styleReference != null) 'styleReference': e.styleReference,
              if (e.styledError != null) 'styledError': e.styledError,
              if (e.reason != null) 'reason': e.reason,
              'cues': e.cueCount,
            },
        ],
      });
    } on SubtitlePipelineCancelled {
      io.err.writeln('\n已取消（已落盘的阶段保留，重跑即续）');
      return kExitFailure;
    } on SubtitleAiRequestFailure catch (e) {
      io.err.writeln(
        '\n暂停：AI 请求失败（${e.reason}${e.detail == null ? '' : '：${e.detail}'}）；'
        '缓存已保留，处理后重跑即续',
      );
      _reportFailedGroup(io, report, total, work, 'ai_request_failed', e.usage);
      failures++;
    } on SubtitleGlossaryValidationFailure catch (e) {
      // 「停下让用户处理」：把最后一次生成的表落盘，用户改好后经 --glossary 喂回来。
      final File candidate = File(
        p.join(
          jobsRoot.path,
          'glossary_candidates',
          '${sha1.convert(utf8.encode(work.workKey))}.json',
        ),
      );
      await candidate.parent.create(recursive: true);
      await candidate.writeAsString(
        const JsonEncoder.withIndent(' ').convert(<Map<String, Object?>>[
          for (final SubtitleGlossaryEntry entry in e.candidate) entry.toJson(),
        ]),
      );
      io.err.writeln('\n专名表校验没通过：$e；可用 --glossary 手工给一份，或先刮削作品');
      io.err.writeln('  候选表已写到 ${candidate.path}（改好后 --glossary 它重跑）');
      if (e.heardNames.isNotEmpty || e.missingNames.isNotEmpty) {
        io.err.writeln('  听到的人名: ${e.heardNames.join('、')}');
        io.err.writeln('  没听到的人名: ${e.missingNames.join('、')}');
      }
      if (e.conflicts.isNotEmpty) {
        io.err.writeln('  矛盾: ${e.conflicts.join(' / ')}');
      }
      _reportFailedGroup(
        io,
        report,
        total,
        work,
        'glossary_${e.problem.name}',
        e.usage,
        extra: <String, Object?>{'glossaryCandidate': candidate.path},
      );
      failures++;
    } on VideoSubtitleRecognizeFailure catch (e) {
      io.err.writeln('\n识别失败：${e.message}');
      failures++;
    } finally {
      client?.close();
      web?.close();
    }
  }

  if (options.json) {
    io.json(<String, Object?>{
      'recognizer': choice.recognizer.id,
      if (choice.mossBackend != null) 'mossBackend': choice.mossBackend!.name,
      if (choice.mossUnavailableReason != null)
        'mossUnavailableReason': choice.mossUnavailableReason,
      'dryRun': options.dryRun,
      'groups': report,
      if (!options.dryRun) 'usage': total.toJson(),
    });
  } else {
    _printReport(io.out, report, total, dryRun: options.dryRun);
  }
  return failures == 0 ? kExitOk : kExitFailure;
}

/// 失败的一组照样进结果与总账：已经花掉的 AI 用量不能因为失败就显示成 0 次调用。
void _reportFailedGroup(
  CommandIo io,
  List<Map<String, Object?>> report,
  SubtitleAiUsageTally total,
  SubtitleWorkContext work,
  String failure,
  SubtitleAiUsageTally? usage, {
  Map<String, Object?> extra = const <String, Object?>{},
}) {
  if (usage != null) {
    total.addTally(usage);
    io.err.writeln(
      '  失败前已调用 AI ${usage.calls} 次：输入 ${usage.inputTokens}、输出 '
      '${usage.outputTokens} token${usage.hasUnknown ? '（${usage.callsWithoutUsage} 次没带用量）' : ''}',
    );
  }
  report.add(<String, Object?>{
    'work': work.title,
    'workKey': work.workKey,
    'failure': failure,
    if (usage != null) 'usage': usage.toJson(),
    ...extra,
    'episodes': const <Object?>[],
  });
}

Future<SubtitleWorkContext> _workContext(
  ServerRuntime rt,
  SubgenGroup group,
  String? title,
) async {
  final SubtitleWorkContextLoader loader = SubtitleWorkContextLoader(rt.db);
  for (final String video in group.videos) {
    final SubtitleWorkContext? found = await loader.forVideoPath(video);
    if (found != null) return found;
  }
  final String name = title ?? p.basename(group.folder);
  return SubtitleWorkContext(
    workKey: fallbackSubtitleWorkKey(
      folderPath: title == null ? group.folder : null,
      title: name,
    ),
    title: name,
  );
}

/// `--glossary`：条目全部标成用户编辑，资料指纹按当前资料算（之后不会被自动重生成）。
Future<void> _importGlossary(
  List<SubtitleGlossaryEntry> entries,
  SubtitleWorkContext work,
  SubtitleGlossaryStore store,
  List<WebKnowledgeSite> sites,
  CommandIo io,
) async {
  final int now = DateTime.now().millisecondsSinceEpoch;
  await store.save(
    work.workKey,
    SubtitleGlossary(
      entries: entries,
      sourceFingerprint: subtitleGlossaryFingerprint(
        work,
        webSiteIds: <String>[for (final WebKnowledgeSite s in sites) s.id],
      ),
      generatedAt: now,
      userEditedAt: now,
    ),
  );
  io.err.writeln('已导入专名表 ${entries.length} 条 → ${work.workKey}');
}

Future<Map<String, Object?>> _dryRun(
  VideoSubtitlePipeline pipeline,
  SubgenGroup group,
  SubtitleWorkContext work,
  SubgenOptions options,
  SubgenDeps deps,
  CommandIo io,
  VideoSubtitleRecognizerChoice choice,
) async {
  final List<Map<String, Object?>> episodes = <Map<String, Object?>>[];
  final List<List<SubtitleDraftCue>> toProofread = <List<SubtitleDraftCue>>[];
  bool estimated = false;
  for (final String video in group.videos) {
    final String target = pipeline.subtitlePathFor(video);
    final Directory dir = pipeline.jobDirFor(video);
    if (group.wholeSeason && File(target).existsSync()) {
      episodes.add(<String, Object?>{
        'video': video,
        'action': 'skip',
        'reason': 'subtitle exists: ${p.basename(target)}',
      });
      continue;
    }
    final bool finalDone = File(
      p.join(dir.path, VideoSubtitleJobFiles.finalCues),
    ).existsSync();
    final File drafts = File(
      p.join(dir.path, VideoSubtitleJobFiles.drafts(choice.recognizer.id)),
    );
    String cache = 'none';
    if (finalDone) {
      cache = 'final';
    } else if (drafts.existsSync()) {
      cache = 'drafts';
      toProofread.add(decodeSubtitleDraftCues(drafts.readAsStringSync()));
    } else {
      final int? ms = await deps.probeDurationMs(video);
      if (ms != null && ms > 0) {
        estimated = true;
        toProofread.add(_syntheticDrafts(ms));
      }
    }
    episodes.add(<String, Object?>{
      'video': video,
      'action': 'process',
      'cache': cache,
      'target': target,
    });
  }
  final Map<String, Object?> out = <String, Object?>{
    'work': work.title,
    'workKey': work.workKey,
    'episodes': episodes,
  };
  if (options.ai) {
    final SubtitleProofreadCostEstimate cost = estimateSubtitleProofreadCost(
      episodes: toProofread,
      title: work.japaneseTitle,
    );
    out['estimate'] = <String, Object?>{
      'batches': cost.batches,
      'inputTokens': cost.inputTokens,
      'outputTokens': cost.outputTokens,
      'fromDuration': estimated,
    };
  }
  return out;
}

/// 没有识别稿时按时长造一份「等量」稿：每 3 秒一条、每秒 [kSubgenEstimateCharsPerSecond] 字。
List<SubtitleDraftCue> _syntheticDrafts(int durationMs) {
  const int stepMs = 3000;
  final int chars = (kSubgenEstimateCharsPerSecond * stepMs / 1000).round();
  return <SubtitleDraftCue>[
    for (int t = 0; t + stepMs <= durationMs; t += stepMs)
      SubtitleDraftCue(startMs: t, endMs: t + stepMs, text: 'あ' * chars),
  ];
}

void Function(VideoSubtitleProgress) _progressPrinter(StringSink err) {
  String last = '';
  return (VideoSubtitleProgress pr) {
    final String episode = pr.episodeIndex == null
        ? ''
        : '[${pr.episodeIndex! + 1}/${pr.episodeCount}] ';
    final String line =
        '$episode${pr.stage.name} ${(pr.fraction * 100).toStringAsFixed(0)}% '
        '${pr.message}';
    if (line == last) return;
    last = line;
    err.write('\r${line.padRight(72)}');
  };
}

void _printReport(
  StringSink out,
  List<Map<String, Object?>> groups,
  SubtitleAiUsageTally total, {
  required bool dryRun,
}) {
  for (final Map<String, Object?> g in groups) {
    out.writeln('== ${g['work']}（${g['workKey']}）');
    if (g['failure'] != null) {
      final Object? u = g['usage'];
      out.writeln(
        '  失败：${g['failure']}'
        '${u is Map ? '（已调用 AI ${u['calls']} 次）' : ''}',
      );
    }
    for (final Object? raw in g['episodes']! as List<Object?>) {
      final Map<String, Object?> e = (raw! as Map<Object?, Object?>).cast();
      final String name = p.basename('${e['video']}');
      if (dryRun) {
        out.writeln(
          '  ${e['action'] == 'skip' ? '跳过' : '处理'}  $name'
          '${e['reason'] != null ? '  （${e['reason']}）' : ''}'
          '${e['cache'] != null && e['cache'] != 'none' ? '  （缓存: ${e['cache']}）' : ''}',
        );
      } else {
        out.writeln(
          '  ${e['status']}  $name  ${e['cues']} 条'
          '${e['output'] != null ? '  → ${e['output']}' : ''}'
          '${e['styledOutput'] != null ? '  + ${e['styledOutput']}（样式取自 ${e['styleReference']}）' : ''}'
          '${e['styledError'] != null ? '  （ASS 未导出：${e['styledError']}）' : ''}'
          '${e['reason'] != null ? '  （${e['reason']}）' : ''}',
        );
      }
    }
    final Object? estimate = g['estimate'];
    if (estimate is Map) {
      out.writeln(
        '  校对预估: ${estimate['batches']} 批，输入约 ${estimate['inputTokens']} token、'
        '输出约 ${estimate['outputTokens']} token'
        '${estimate['fromDuration'] == true ? '（部分按时长估）' : ''}；'
        '专名表每作品另计一次，写法统一只送可疑行',
      );
    }
    if (g['seconds'] != null) out.writeln('  耗时 ${g['seconds']} s');
  }
  if (!dryRun && total.calls > 0) {
    out.writeln(
      'AI 用量: ${total.calls} 次调用，输入 ${total.inputTokens}、输出 ${total.outputTokens}、'
      '缓存读 ${total.cacheReadTokens}、缓存写 ${total.cacheWriteTokens} token',
    );
    if (total.hasUnknown) {
      out.writeln('  其中 ${total.callsWithoutUsage} 次应答没带用量（token 未知，未计入上面）');
    }
  }
}
