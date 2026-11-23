import 'dart:io';
import 'dart:typed_data';

import 'package:fushi_cli/fushi_cli.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/media/audio_cd/audio_cd_disc.dart';
import 'package:fushi_engine/media/audio_cd/audio_cd_ripper.dart';
import 'package:fushi_engine/media/music/disc/music_disc.dart';
import 'package:fushi_engine/media/video/ffmpeg_backend.dart';
import 'package:fushi_music/fushi_music.dart';
import 'package:path/path.dart' as p;

import 'package:fushi/src/media/audio_cd/audio_cd_import.dart';
import 'package:fushi/src/media/drag_drop/drop_classification.dart'
    show kPluginPackageExtensions;
import 'package:fushi/src/media/music/disc/music_disc_import.dart';
import 'package:fushi/src/media/music/lyrics/music_lyrics_service.dart';
import 'package:fushi/src/media/music/music_audio_intake.dart';
import 'package:fushi/src/media/music/music_online_sources.dart'
    show uninstallMusicPlugin;
import 'package:fushi/src/media/music/plugin/music_plugin_gate.dart';
import 'package:fushi/src/media/source_library/source_library_scanner.dart';
import 'package:fushi/src/models/module_id.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/ops/ctl_music_routes.dart' show kMusicCtlRoot;
import 'package:fushi/src/ops/op_context.dart';
import 'package:fushi/src/pages/implementations/music/music_disc_actions.dart'
    show musicDiscChapterDefaultTitle;

/// 音乐库「把东西搬进 / 搬出曲库」的控制通道路由（拍板台 PGpPujl99g / BUG-5123：
/// CLI 要能做 app 里能点的操作）。每条路由调界面按钮背后的同一个方法，只把文件选择器 /
/// 确认框换成参数：
///
/// - 导入音频文件：曲库页「添加音频文件」/ 拖放的 `MusicAudioIntake.importMusicFiles`
///   （同一口径：纯音频 + MV 视频容器；已被音乐来源覆盖的重扫来源，其余「仅此一次」导入）；
/// - 光盘：工具栏「添加光盘」/「光盘 › 光盘镜像…」（[pickAndAddMusicDiscs] /
///   [pickAndAddMusicDiscImages] 的 [musicDiscCandidatesAt] + [registerMusicDiscs]）、
///   「章节导入为曲目」（[importMusicDiscChapters] 的 [MusicDiscImportService.importChapters]，
///   曲目默认名同界面）、「从曲库移除」（`removeMusicDisc`）；
/// - 插件：设置页插件列表的安装（[pickAndInstallMusicPlugin] 选文件之后的
///   inspect → 确认 → install，确认改成 `confirm`）、启停、卸载；
/// - 歌词：歌词页「导出 TTML」的 [MusicLyricsService.exportBesideAudio]（另收 `lrc`）；
/// - 音频 CD：视频 / 音乐导入入口的 [importAudioCdIfPresent]（抓轨成 FLAC 再「仅此一次」
///   导入），抓轨要几分钟，后台跑、按任务查进度，可取消。
///
/// CLI 侧是 `fushi_cli music import / disc-* / plugin-* / lyrics-export / audio-cd*`
/// （`packages/fushi_cli/lib/src/commands/music_import_commands.dart`）。
List<CtlRoute> buildMusicImportCtlRoutes(
  OpContext context,
) => buildMusicImportCtlRoutesFor(
  MusicImportCtlDeps(
    database: () => context.appModel.database,
    musicEnabled: () =>
        context.appModel.moduleVisibility.isEnabled(ModuleId.music),
    isReadonly: () => context.appModel.isMigrationReadonly,
    intakeAudioFiles: (FushiDatabase db, List<String> paths) =>
        MusicAudioIntake(db).importMusicFiles(paths),
    discService: (FushiDatabase db) => MusicDiscImportService(db),
    discCandidates: musicDiscCandidatesAt,
    plugins: () => isMusicPluginSourcesAvailable
        ? context.appModel.musicPluginManager
        : null,
    prefs: () =>
        context.appModel.isPreferencesReady ? context.appModel.prefsRepo : null,
    exportLyrics: (MusicLyricsTrackRef track, String format, bool overwrite) =>
        _exportLyrics(context.appModel.musicLyrics, track, format, overwrite),
    audioCd: const MusicCtlAudioCd(
      layoutOf: audioCdLayoutOfDirectory,
      canRip: canRipAudioCd,
      rip: _ripToDocuments,
      importRipped: _importRipped,
    ),
  ),
);

Future<String?> _exportLyrics(
  MusicLyricsService service,
  MusicLyricsTrackRef track,
  String format,
  bool overwrite,
) async {
  final MusicLyricsResolution? resolution = await service.resolve(track);
  if (resolution == null) return null;
  return service.exportBesideAudio(
    track,
    resolution.timeline,
    format,
    overwrite: overwrite,
  );
}

Future<String?> _ripToDocuments(
  String dir,
  AudioCdLayout layout,
  AudioCdRipCancellation cancellation,
  void Function(AudioCdRipProgress progress) onProgress,
) async {
  final AudioCdRipResult? result = await ripAudioCd(
    discPath: dir,
    layout: layout,
    outputRoot: (await audioCdRipOutputRoot()).path,
    ffmpeg: resolveFfmpegBackend(),
    cancellation: cancellation,
    onProgress: onProgress,
  );
  return result?.directory;
}

Future<int> _importRipped(FushiDatabase db, String directory) async {
  final SourceScanSummary? summary = await importRippedAudioCd(
    db: db,
    directory: directory,
  );
  if (summary?.error case final String error) throw StateError(error);
  return summary?.importedMediaCount ?? 0;
}

/// 音频 CD 抓轨的几个入口（测试注入假件，不碰光驱 / FFmpeg）。
class MusicCtlAudioCd {
  const MusicCtlAudioCd({
    required this.layoutOf,
    required this.canRip,
    required this.rip,
    required this.importRipped,
  });

  final AudioCdLayout? Function(String dir) layoutOf;
  final bool Function(AudioCdLayout layout, String dir) canRip;

  /// 抓到数据目录，返回抓好的目录；取消返回 null，失败抛。
  final Future<String?> Function(
    String dir,
    AudioCdLayout layout,
    AudioCdRipCancellation cancellation,
    void Function(AudioCdRipProgress progress) onProgress,
  )
  rip;

  /// 抓好的目录导入曲库，返回入库曲目数；扫描失败抛。
  final Future<int> Function(FushiDatabase db, String directory) importRipped;
}

/// 路由依赖（测试逐项注入）。
class MusicImportCtlDeps {
  const MusicImportCtlDeps({
    required this.database,
    required this.musicEnabled,
    required this.intakeAudioFiles,
    required this.discService,
    required this.discCandidates,
    required this.plugins,
    required this.exportLyrics,
    required this.audioCd,
    this.isReadonly,
    this.prefs,
    this.clock,
  });

  final FushiDatabase Function() database;
  final bool Function() musicEnabled;
  final bool Function()? isReadonly;
  final Future<MusicAudioIntakeResult> Function(
    FushiDatabase db,
    List<String> paths,
  )
  intakeAudioFiles;
  final MusicDiscImportService Function(FushiDatabase db) discService;
  final Future<List<String>> Function(String path) discCandidates;

  /// 本机能自己跑插件时的管理器；null = 不可用（iOS 合规门 / 没有插件运行时）。
  final MusicPluginManager? Function() plugins;

  /// 偏好仓库（卸载插件时清它在「来源」页的条目）；null / 返回 null = 偏好没就绪，只卸载。
  final PreferencesRepository? Function()? prefs;

  /// 解析 [track] 当前生效的歌词并导出到音频旁；没有歌词返回 null。
  final Future<String?> Function(
    MusicLyricsTrackRef track,
    String format,
    bool overwrite,
  )
  exportLyrics;
  final MusicCtlAudioCd audioCd;
  final int Function()? clock;
}

/// 音频 CD 抓轨任务状态。
enum MusicAudioCdJobStatus { running, done, failed, cancelled }

/// 一次抓轨 + 入库。
class MusicAudioCdJob {
  MusicAudioCdJob(this.id, this.dir, this.startedAt);

  final String id;
  final String dir;
  final int startedAt;
  final AudioCdRipCancellation cancellation = AudioCdRipCancellation();
  MusicAudioCdJobStatus status = MusicAudioCdJobStatus.running;
  int track = 0;
  int trackCount = 0;
  double fraction = 0;
  String? directory;
  int? imported;
  String? error;
  int? finishedAt;

  Map<String, Object?> toJson() => <String, Object?>{
    'id': id,
    'status': status.name,
    'dir': dir,
    'track': track,
    'trackCount': trackCount,
    'fraction': fraction,
    'startedAt': startedAt,
    'finishedAt': ?finishedAt,
    'directory': ?directory,
    'imported': ?imported,
    'error': ?error,
    if (cancellation.isCancelled && status == MusicAudioCdJobStatus.running)
      'cancelRequested': true,
  };
}

/// 进程内的抓轨任务登记：光驱一次只能抓一张，同时只跑一个；记住最后一个供查询。
class MusicAudioCdJobs {
  MusicAudioCdJobs();

  static final MusicAudioCdJobs instance = MusicAudioCdJobs();

  MusicAudioCdJob? last;
  int _seq = 0;

  MusicAudioCdJob? get running =>
      last?.status == MusicAudioCdJobStatus.running ? last : null;

  MusicAudioCdJob start(String dir, int now) =>
      last = MusicAudioCdJob('audio-cd-$now-${++_seq}', dir, now);
}

/// 歌词导出格式（`FushiLyrics.export` 认的两种：ttml 无损，lrc 丢声部 / 和声 / 注音）。
const List<String> kMusicLyricsExportFormats = <String>['ttml', 'lrc'];

/// 路由表本体。
List<CtlRoute> buildMusicImportCtlRoutesFor(
  MusicImportCtlDeps deps, {
  MusicAudioCdJobs? audioCdJobs,
}) {
  final MusicAudioCdJobs cdJobs = audioCdJobs ?? MusicAudioCdJobs.instance;
  int now() => (deps.clock ?? () => DateTime.now().millisecondsSinceEpoch)();

  void requireMusic() {
    if (!deps.musicEnabled()) {
      throw const CtlFailure.rejected('音乐模块已在设置里关闭（music）');
    }
  }

  void requireWritable() {
    requireMusic();
    if (deps.isReadonly?.call() ?? false) {
      throw const CtlFailure.rejected('数据已迁移到新版，旧版处于只读状态');
    }
  }

  String absolutePath(CtlCall call, String name) {
    final String raw = call.requireString(name).trim();
    if (!p.isAbsolute(raw)) {
      throw CtlFailure.badRequest('$name 必须是绝对路径：$raw');
    }
    return p.normalize(raw);
  }

  MusicPluginManager requirePlugins() {
    requireMusic();
    final MusicPluginManager? manager = deps.plugins();
    if (manager == null) {
      throw const CtlFailure.unsupported('本机不能运行音乐插件（插件管理不可用）');
    }
    return manager;
  }

  Future<MusicDiscSourceRow> requireDisc(CtlCall call) async {
    final String uid = call.params['uid'] ?? '';
    final MusicDiscSourceRow? disc = await deps.database().getMusicDiscSource(
      uid,
    );
    if (disc == null) {
      throw CtlFailure.notFound('曲库里没有光盘 $uid（见 music discs）');
    }
    return disc;
  }

  Future<MusicDiscInfo> readDisc(MusicDiscSourceRow disc) async {
    try {
      return await deps.discService(deps.database()).readDisc(disc.path);
    } on MusicDiscUnreadableException {
      throw CtlFailure.rejected('读不出这张盘（不在原路径，或不是可读的 DVD / 蓝光）：${disc.path}');
    }
  }

  Future<Uint8List> readPackage(String path) async {
    final File file = File(path);
    if (!file.existsSync()) throw CtlFailure.notFound('文件不存在：$path');
    final String ext = p.extension(path).toLowerCase().replaceFirst('.', '');
    if (!kPluginPackageExtensions.contains(ext)) {
      throw CtlFailure.badRequest(
        '不是插件包（${kPluginPackageExtensions.join(' / ')}）：$path',
      );
    }
    return file.readAsBytes();
  }

  Future<MusicPluginPackageInfo> inspect(
    MusicPluginManager manager,
    Uint8List bytes,
  ) async {
    try {
      return await manager.inspect(bytes);
    } on MusicPluginException catch (e) {
      throw CtlFailure.rejected('插件包校验没过：${e.message}');
    }
  }

  return <CtlRoute>[
    // ── 导入音频文件 ───────────────────────────────────────────────────
    CtlRoute.post('$kMusicCtlRoot/import', (CtlCall call) async {
      requireWritable();
      final List<String> paths = call.stringList('paths');
      if (paths.isEmpty) {
        throw const CtlFailure.badRequest('paths 至少给一个音频 / MV 文件的绝对路径');
      }
      for (final String path in paths) {
        if (!p.isAbsolute(path)) {
          throw CtlFailure.badRequest('paths 里必须是绝对路径：$path');
        }
      }
      final FushiDatabase db = deps.database();
      final MusicAudioIntakeResult result = await deps.intakeAudioFiles(
        db,
        <String>[for (final String path in paths) p.normalize(path)],
      );
      return <String, Object?>{
        if (result.errors.isNotEmpty) 'ok': false,
        'imported': result.importedFiles,
        'rescannedSources': result.rescannedSourceIds,
        'skipped': result.skippedPaths,
        'errors': result.errors,
        'tracks': (await db.listMusicTracks()).length,
      };
    }),

    // ── 光盘 ───────────────────────────────────────────────────────────
    CtlRoute.get('$kMusicCtlRoot/discs', (CtlCall call) async {
      requireMusic();
      final FushiDatabase db = deps.database();
      final Map<String, MusicAlbumRow> albumByDisc = <String, MusicAlbumRow>{
        for (final MusicAlbumRow a in await db.listMusicAlbums())
          if (a.discUid != null) a.discUid!: a,
      };
      return <String, Object?>{
        'discs': <Object?>[
          for (final MusicDiscSourceRow d in await db.listMusicDiscSources())
            _discJson(d, albumByDisc[d.discUid]),
        ],
      };
    }),
    CtlRoute.post('$kMusicCtlRoot/discs', (CtlCall call) async {
      requireWritable();
      final String path = absolutePath(call, 'path');
      if (!FileSystemEntity.isDirectorySync(path) &&
          !FileSystemEntity.isFileSync(path)) {
        throw CtlFailure.notFound('路径不存在：$path');
      }
      final List<String> discs = await deps.discCandidates(path);
      if (discs.isEmpty) {
        throw CtlFailure.rejected('$path 里认不出 DVD / 蓝光盘或 .iso 镜像');
      }
      final FushiDatabase db = deps.database();
      final Set<String> before = <String>{
        for (final MusicDiscSourceRow d in await db.listMusicDiscSources())
          d.discUid,
      };
      final MusicDiscRegisterReport report = await registerMusicDiscs(
        deps.discService(db),
        discs,
      );
      final List<MusicDiscSourceRow> after = await db.listMusicDiscSources();
      return <String, Object?>{
        if (report.albumUids.isEmpty) 'ok': false,
        'albums': report.albumUids,
        // 这次新登记的盘（之前已在曲库里的只刷新路径，不算新增；撤销只移除这些）。
        'added': <String>[
          for (final MusicDiscSourceRow d in after)
            if (!before.contains(d.discUid)) d.discUid,
        ],
        'failed': <Object?>[
          for (final MapEntry<String, Exception> f in report.failures.entries)
            <String, Object?>{
              'path': f.key,
              'error': f.value is MusicDiscUnreadableException
                  ? 'unreadable'
                  : '${f.value}',
            },
        ],
      };
    }),
    CtlRoute.delete('$kMusicCtlRoot/discs/:uid', (CtlCall call) async {
      if (call.optBool('confirm') != true) {
        throw const CtlFailure.badRequest(
          '从曲库移除光盘需要 confirm: true（CLI 用 --yes）',
        );
      }
      requireWritable();
      final MusicDiscSourceRow disc = await requireDisc(call);
      // 专辑详情「从曲库移除」同一方法：盘上的文件不动，曲目软删。
      await deps.database().removeMusicDisc(
        discUid: disc.discUid,
        deletedAt: now(),
      );
      return <String, Object?>{
        'deleted': true,
        'uid': disc.discUid,
        'path': disc.path,
      };
    }),
    CtlRoute.get('$kMusicCtlRoot/discs/:uid/titles', (CtlCall call) async {
      requireMusic();
      final MusicDiscSourceRow disc = await requireDisc(call);
      final MusicDiscInfo info = await readDisc(disc);
      final Set<int> imported = <int>{
        for (final MusicDiscTrackRef r in decodeMusicDiscTitleMap(
          disc.titleMapJson,
        ))
          r.titleNumber,
      };
      return <String, Object?>{
        'uid': disc.discUid,
        'name': info.name,
        'kind': info.kind.name,
        'titles': <Object?>[
          for (final MusicDiscTitle t in info.titles)
            <String, Object?>{
              'number': t.number,
              'label': t.label,
              'durationMs': t.duration.inMilliseconds,
              'chapters': t.chapters.length,
              if (t.isMainFeature) 'main': true,
              if (imported.contains(t.number)) 'imported': true,
            },
        ],
      };
    }),
    CtlRoute.post('$kMusicCtlRoot/discs/:uid/chapters', (CtlCall call) async {
      requireWritable();
      final MusicDiscSourceRow disc = await requireDisc(call);
      final MusicDiscInfo info = await readDisc(disc);
      final List<String> raw = call.stringList('titles');
      final Set<int> chosen;
      if (raw.isEmpty) {
        // 界面默认勾选：上一轮导入过的 title，第一次导入勾正片。
        final Set<int> previous = <int>{
          for (final MusicDiscTrackRef r in decodeMusicDiscTitleMap(
            disc.titleMapJson,
          ))
            r.titleNumber,
        };
        chosen = previous.isNotEmpty
            ? previous
            : <int>{
                for (final MusicDiscTitle t in info.titles)
                  if (t.isMainFeature) t.number,
              };
      } else {
        chosen = <int>{
          for (final String s in raw)
            int.tryParse(s.trim()) ??
                (throw CtlFailure.badRequest('titles 里应是 title 号：$s')),
        };
      }
      final Set<int> known = <int>{
        for (final MusicDiscTitle t in info.titles) t.number,
      };
      final List<int> unknown = <int>[
        for (final int n in chosen)
          if (!known.contains(n)) n,
      ];
      if (unknown.isNotEmpty) {
        throw CtlFailure.badRequest(
          '盘上没有 title ${unknown.join('、')}（见 music disc-titles）',
        );
      }
      if (chosen.isEmpty) {
        throw const CtlFailure.badRequest('没有可导入的 title：用 titles 指定');
      }
      final bool multiple = chosen.length > 1;
      final int count;
      try {
        count = await deps
            .discService(deps.database())
            .importChapters(
              info,
              titleNumbers: chosen,
              chapterTitle: (MusicDiscTitle title, MusicDiscChapter c) =>
                  musicDiscChapterDefaultTitle(
                    title,
                    c,
                    multipleTitles: multiple,
                  ),
            );
      } on MusicDiscNoChaptersException {
        throw const CtlFailure.rejected('选中的 title 都认不出章节');
      }
      return <String, Object?>{
        'uid': disc.discUid,
        'titles': chosen.toList()..sort(),
        'tracks': count,
      };
    }),

    // ── 插件 ───────────────────────────────────────────────────────────
    CtlRoute.get('$kMusicCtlRoot/plugins', (CtlCall call) async {
      final MusicPluginManager manager = requirePlugins();
      return <String, Object?>{
        'plugins': <Object?>[
          for (final InstalledMusicPlugin plugin
              in await manager.listInstalled())
            <String, Object?>{
              'id': plugin.id,
              'enabled': plugin.enabled,
              if (plugin.info case final MusicPluginPackageInfo info)
                ..._packageJson(info),
              'error': ?plugin.error,
            },
        ],
      };
    }),
    CtlRoute.post('$kMusicCtlRoot/plugins/inspect', (CtlCall call) async {
      final MusicPluginManager manager = requirePlugins();
      final Uint8List bytes = await readPackage(absolutePath(call, 'path'));
      final MusicPluginPackageInfo info = await inspect(manager, bytes);
      return <String, Object?>{
        ..._packageJson(info),
        'signerChanged': await manager.signerChanged(info),
      };
    }),
    CtlRoute.post('$kMusicCtlRoot/plugins/install', (CtlCall call) async {
      requireWritable();
      final MusicPluginManager manager = requirePlugins();
      final Uint8List bytes = await readPackage(absolutePath(call, 'path'));
      final MusicPluginPackageInfo info = await inspect(manager, bytes);
      if (call.optBool('confirm') != true) {
        // 界面先弹清单 / 权限 / 签名再装；这里同样要用户看过（plugin-inspect）再确认。
        throw CtlFailure(
          409,
          'confirm_required',
          '安装「${info.manifest.name}」${info.manifest.version}'
              '（权限：${info.manifest.permissions.join('、')}）会执行插件代码：'
              '先用 plugin-inspect 看清单，确认后带 confirm=true 再装',
        );
      }
      final String? digest = call.optString('digest');
      if (digest != null && digest != info.digest) {
        throw const CtlFailure.conflict('插件包在确认之后变了（摘要不符），重新 inspect 再装');
      }
      final MusicPluginPackageInfo installed;
      try {
        installed = await manager.install(bytes, info.digest);
      } on MusicPluginException catch (e) {
        throw CtlFailure.rejected('安装失败：${e.message}');
      }
      return <String, Object?>{'installed': true, ..._packageJson(installed)};
    }),
    CtlRoute.put('$kMusicCtlRoot/plugins/:id/enabled', (CtlCall call) async {
      requireWritable();
      final MusicPluginManager manager = requirePlugins();
      final String id = call.params['id'] ?? '';
      final bool? enabled = call.optBool('enabled');
      if (enabled == null) throw const CtlFailure.badRequest('enabled 缺失');
      final InstalledMusicPlugin? plugin = await _installed(manager, id);
      if (plugin == null) {
        throw CtlFailure.notFound('没装插件 $id（见 music plugins）');
      }
      await manager.setEnabled(id, enabled);
      return <String, Object?>{
        'id': id,
        'enabled': enabled,
        'previous': plugin.enabled,
      };
    }),
    CtlRoute.delete('$kMusicCtlRoot/plugins/:id', (CtlCall call) async {
      if (call.optBool('confirm') != true) {
        throw const CtlFailure.badRequest('卸载插件需要 confirm: true（CLI 用 --yes）');
      }
      requireWritable();
      final MusicPluginManager manager = requirePlugins();
      final String id = call.params['id'] ?? '';
      if (await _installed(manager, id) == null) {
        throw CtlFailure.notFound('没装插件 $id（见 music plugins）');
      }
      // 设置页「卸载」同一方法：删包、插件存储与加密凭据，并清「来源」页里的条目。
      await uninstallMusicPlugin(manager, deps.prefs?.call(), id);
      return <String, Object?>{'deleted': true, 'id': id};
    }),

    // ── 歌词导出 ───────────────────────────────────────────────────────
    CtlRoute.post('$kMusicCtlRoot/tracks/:uid/lyrics/export', (
      CtlCall call,
    ) async {
      requireMusic();
      final String uid = call.params['uid'] ?? '';
      final FushiDatabase db = deps.database();
      final MusicTrackRow? track = await db.getMusicTrack(uid);
      if (track == null || track.deletedAt != null) {
        throw CtlFailure.notFound('曲库里没有曲目 $uid（见 music tracks）');
      }
      final String format = (call.optString('format') ?? 'ttml').toLowerCase();
      if (!kMusicLyricsExportFormats.contains(format)) {
        throw CtlFailure.badRequest(
          'format 只能是 ${kMusicLyricsExportFormats.join(' / ')}：$format',
        );
      }
      final MusicAlbumRow? album = track.albumUid == null
          ? null
          : await db.getMusicAlbum(track.albumUid!);
      final MusicLyricsTrackRef ref = MusicLyricsTrackRef(
        trackUid: track.trackUid,
        path: track.path,
        title: track.title,
        artist: track.artistCredit ?? album?.albumArtistCredit,
        album: album?.title,
        durationMs: track.durationMs,
        cueStartMs: track.cueStartMs,
      );
      if (!ref.isLocalFile) {
        throw const CtlFailure.rejected('这首不是本机文件（网络 / 插件 / 光盘曲目），没有「文件旁边」');
      }
      final String? written;
      try {
        written = await deps.exportLyrics(
          ref,
          format,
          call.optBool('overwrite') ?? false,
        );
      } on FileSystemException catch (e) {
        if (e.message == 'lyrics file already exists') {
          throw CtlFailure.conflict('${e.path} 已存在：确认覆盖后带 overwrite=true');
        }
        throw CtlFailure.rejected('写不出歌词文件：${e.message}（${e.path}）');
      }
      if (written == null) {
        throw const CtlFailure.notFound('这首没有可导出的歌词（先选 / 生成歌词）');
      }
      return <String, Object?>{'uid': uid, 'format': format, 'path': written};
    }),

    // ── 音频 CD ────────────────────────────────────────────────────────
    CtlRoute.get('$kMusicCtlRoot/audio-cd', (CtlCall call) async {
      requireMusic();
      final MusicAudioCdJob? job = cdJobs.last;
      return job == null
          ? const <String, Object?>{'active': false}
          : <String, Object?>{
              'active': job.status == MusicAudioCdJobStatus.running,
              ...job.toJson(),
            };
    }),
    CtlRoute.post('$kMusicCtlRoot/audio-cd', (CtlCall call) async {
      requireWritable();
      final String dir = absolutePath(call, 'dir');
      final MusicAudioCdJob? running = cdJobs.running;
      if (running != null) {
        throw CtlFailure.conflict('已有抓轨在跑（任务 ${running.id}）');
      }
      final AudioCdLayout? layout = deps.audioCd.layoutOf(dir);
      if (layout == null) throw CtlFailure.rejected('$dir 不是音频 CD');
      if (!deps.audioCd.canRip(layout, dir)) {
        throw const CtlFailure.unsupported('本机抓不了这张盘（.cda 只能在 Windows 本机光驱上抓）');
      }
      final FushiDatabase db = deps.database();
      final MusicAudioCdJob job = cdJobs.start(dir, now());
      // 后台跑：抓轨几分钟，进度经 GET 查；取消只停抓轨，已抓的轨留在数据目录里复用。
      () async {
        try {
          final String? ripped = await deps.audioCd.rip(
            dir,
            layout,
            job.cancellation,
            (AudioCdRipProgress progress) {
              job
                ..track = progress.trackIndex + 1
                ..trackCount = progress.trackCount
                ..fraction = progress.fraction;
            },
          );
          if (ripped == null || job.cancellation.isCancelled) {
            job.status = MusicAudioCdJobStatus.cancelled;
            return;
          }
          job
            ..directory = ripped
            ..imported = await deps.audioCd.importRipped(db, ripped)
            ..fraction = 1
            ..status = MusicAudioCdJobStatus.done;
        } on Object catch (e) {
          job
            ..error = e is AudioCdException ? e.message : '$e'
            ..status = MusicAudioCdJobStatus.failed;
        } finally {
          job.finishedAt = now();
        }
      }();
      return <String, Object?>{'taskId': job.id, ...job.toJson()};
    }),
    CtlRoute.post('$kMusicCtlRoot/audio-cd/cancel', (CtlCall call) async {
      requireMusic();
      final MusicAudioCdJob? job = cdJobs.running;
      if (job == null) throw const CtlFailure.notFound('没有正在跑的抓轨');
      job.cancellation.cancel();
      return <String, Object?>{'taskId': job.id, ...job.toJson()};
    }),
  ];
}

Future<InstalledMusicPlugin?> _installed(
  MusicPluginManager manager,
  String id,
) async {
  for (final InstalledMusicPlugin plugin in await manager.listInstalled()) {
    if (plugin.id == id) return plugin;
  }
  return null;
}

Map<String, Object?> _packageJson(MusicPluginPackageInfo info) =>
    <String, Object?>{
      'id': info.manifest.id,
      'name': info.manifest.name,
      'version': info.manifest.version,
      'capabilities': info.manifest.capabilities,
      'permissions': info.manifest.permissions,
      'networkDomains': info.manifest.networkDomains,
      'author': ?info.manifest.author,
      'signer': ?info.signer,
      'trustedSigner': info.trustedSigner,
      'digest': info.digest,
    };

Map<String, Object?> _discJson(
  MusicDiscSourceRow d,
  MusicAlbumRow? album,
) => <String, Object?>{
  'uid': d.discUid,
  'path': d.path,
  'kind': d.kind,
  if (album != null) 'albumUid': album.albumUid,
  if (album != null) 'title': album.title,
  'importedTitles': <int>{
    for (final MusicDiscTrackRef r in decodeMusicDiscTitleMap(d.titleMapJson))
      r.titleNumber,
  }.toList(),
};
