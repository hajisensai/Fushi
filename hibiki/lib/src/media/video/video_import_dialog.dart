import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/src/media/import/sidecar_finder.dart';
import 'package:hibiki/src/media/video/m3u8_playlist.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_filename_parser.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// 为 m3u8 播放列表生成跨设备稳定 bookUid：`video/playlist/<sanitize(文件名)>`。
///
/// 纯函数（抽出便于单测）。**只取文件名（去扩展名）经 [sanitizeTtuFilename]
/// 派生**，与书的身份哲学（`bookKey = sanitizeTtuFilename(title)`）对齐——
/// 换机器/移动文件夹身份不变，跨设备同步可对齐。同名碰撞交给
/// [uniqueVideoBookUid] 在导入时加后缀去重，而非把完整绝对路径哈希进身份。
String playlistBookUid(String m3u8Path) {
  final String base = _crossPlatformBasenameWithoutExtension(m3u8Path);
  return 'video/playlist/${sanitizeTtuFilename(base)}';
}

/// 取路径最后一段并去扩展名，**同时把 `/` 和 `\` 都当分隔符**（与宿主平台无关）。
///
/// 纯函数。`p.basenameWithoutExtension` 只认宿主平台的分隔符——在 Linux/macOS 上
/// 不会把 Windows 路径的 `\` 当分隔符，于是 `D:\a\x.mkv` 整串被当文件名，破坏
/// 「同一文件名跨不同绝对路径/不同机器得相同 bookUid」的身份不变量。这里两种分隔符
/// 都认，保证 `D:\a\E01.mkv` 与 `/home/u/E01.mkv` 在任何平台都派生出 `E01`。
String _crossPlatformBasenameWithoutExtension(String path) {
  final int sep = path.lastIndexOf(RegExp(r'[\\/]'));
  final String name = sep >= 0 ? path.substring(sep + 1) : path;
  final int dot = name.lastIndexOf('.');
  return dot > 0 ? name.substring(0, dot) : name;
}

/// 为单个视频文件生成跨设备稳定 bookUid：`video/<sanitize(文件名去扩展名)>`。
///
/// 纯函数。与 [playlistBookUid] 同源：只取文件名经 [sanitizeTtuFilename] 派生，
/// 不含目录/绝对路径，同名碰撞由 [uniqueVideoBookUid] 加后缀去重。
String singleVideoBookUid(String videoPath) {
  final String base = _crossPlatformBasenameWithoutExtension(videoPath);
  return 'video/${sanitizeTtuFilename(base)}';
}

/// 同名去重：若 [base] 已在 [existingKeys] 中，返回首个空位的加后缀变体
/// （`base (2)` / `base (3)`...）；否则原样返回。
///
/// 纯函数。照搬 EpubImporter 的**无回调静默加后缀**策略（见
/// `resolveBookTitleConflict` 的 `_uniqueSuffixedTitle`），保持"本地不出现两个
/// 同 book_uid 视频"的不变量，供同步/导入安全使用。video 导入对话框无重名提示
/// 回调基础设施，故采用与 EpubImporter 无回调路径一致的静默后缀 UX。
String uniqueVideoBookUid(String base, Set<String> existingKeys) {
  if (!existingKeys.contains(base)) return base;
  for (int i = 2;; i++) {
    final String candidate = '$base ($i)';
    if (!existingKeys.contains(candidate)) return candidate;
  }
}

/// 由 [bookUid] 生成视频封面文件名（无目录），把路径分隔符与 `:` 等非法字符
/// 归一成 `_`，避免 `video/playlist/...` 这类带 `/` `:` 的 bookUid 当文件名非法
/// （尤其 Windows）。纯函数，便于单测。
String videoCoverFileName(String bookUid) {
  final String safe = bookUid.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
  return '$safe.jpg';
}

/// 用用户挑选的图片 [pickedPath] 覆盖 [bookUid] 的封面：拷到持久化
/// `video_covers/<uid>.jpg` → **驱逐旧解码缓存** → 落库 `coverPath`，返回目标路径。
///
/// 书架/视频库长按菜单「设置封面」共用此入口（消除两处手抄）。封面写到与导入
/// 时自动截图同一路径（同一 [videoCoverFileName]），所以 DB 里的 `coverPath`
/// 字符串不变；而 [FileImage] 按 `(path, scale)` 而非内容/mtime 缓存解码，覆盖
/// 同名文件后必须 `imageCache.evict` 掉旧条目，否则 UI 重建时命中旧解码、用户
/// 重设封面后看到的还是旧图（直到缓存淘汰或重启）。
Future<String> setVideoCoverFromPickedFile({
  required VideoBookRepository repo,
  required String bookUid,
  required String pickedPath,
}) async {
  final Directory docs = await getApplicationDocumentsDirectory();
  final Directory coverDir = Directory(p.join(docs.path, 'video_covers'));
  await coverDir.create(recursive: true);
  final String dest = p.join(coverDir.path, videoCoverFileName(bookUid));
  await File(pickedPath).copy(dest);
  PaintingBinding.instance.imageCache.evict(FileImage(File(dest)));
  await repo.updateCover(bookUid, dest);
  return dest;
}

/// 提取 [videoPath] 的书架封面存进 app 文档目录的
/// `video_covers/<sanitized bookUid>.jpg`（持久路径，非 temp），返回封面绝对
/// 路径；ffmpeg 缺失（移动端）/失败时返回 null（导入仍成功，书架显示占位）。
///
/// 优先级：**① 视频自带封面**（mkv 的 `cover.*` 附件 / mp4 的 attached_pic 海报，
/// 见 [extractEmbeddedVideoCoverViaFfmpeg]）；自带封面通常是制作方/刮削器精挑的
/// 海报，比随机帧更具代表性。**② 无自带封面再退回抽帧**（[atSeconds] 处一帧，
/// 默认 10s 避开黑场片头）。两路输出同一 [outputPath]，书架显示逻辑不变。
Future<String?> extractVideoCover({
  required String videoPath,
  required String bookUid,
  double atSeconds = 10.0,
}) async {
  final Directory docs = await getApplicationDocumentsDirectory();
  final Directory coverDir = Directory(p.join(docs.path, 'video_covers'));
  final String outputPath = p.join(coverDir.path, videoCoverFileName(bookUid));
  // ① 优先视频自带封面（attached_pic）。
  final String? embedded = await extractEmbeddedVideoCoverViaFfmpeg(
    inputPath: videoPath,
    outputPath: outputPath,
  );
  if (embedded != null) return embedded;
  // ② 无自带封面：退回抽帧。
  return extractVideoFrameViaFfmpeg(
    inputPath: videoPath,
    outputPath: outputPath,
    atSeconds: atSeconds,
  );
}

/// 按字幕扩展名路由到对应解析器，返回按 [AudioCue.startMs] 升序排序的 cue。
///
/// 纯函数，无 IO / context 依赖，是 [VideoImportDialog] 的可测核心：
/// - `srt` → [SrtParser]
/// - `vtt` → [VttParser]
/// - `ass` / `ssa` → [AssParser]
/// - 其他 → 抛 [ArgumentError]
List<AudioCue> parseSubtitleCues({
  required String content,
  required String format,
  required String bookUid,
}) {
  final String normalized = format.toLowerCase();
  final List<AudioCue> cues;
  switch (normalized) {
    case 'srt':
      cues = SrtParser.parseString(content: content, bookKey: bookUid);
      break;
    case 'vtt':
      cues = VttParser.parseString(content: content, bookKey: bookUid);
      break;
    case 'ass':
    case 'ssa':
      cues = AssParser.parseString(content: content, bookKey: bookUid);
      break;
    default:
      throw ArgumentError.value(
        format,
        'format',
        'Unsupported subtitle format',
      );
  }
  cues.sort((AudioCue a, AudioCue b) => a.startMs.compareTo(b.startMs));
  return cues;
}

/// 导入按钮可用性的纯判定（抽出便于单测）。
///
/// Phase 0 放宽：只要求**选了视频**且非 busy 即可导入；外挂字幕可选——
/// 不选字幕时靠 libmpv 自动渲染视频内嵌默认字幕轨。
bool videoImportCanImport({
  required String? videoPath,
  required String? subtitlePath,
  required bool busy,
}) {
  if (busy) return false;
  if (videoPath == null) return false;
  // subtitlePath 可为 null：未选外挂字幕时用内嵌字幕轨。
  return true;
}

/// 视频导入对话框：选一个视频文件 + **可选**外挂字幕文件（srt/vtt/ass/ssa）。
///
/// - 选了字幕：解析为 cue 后写入 VideoBooks 与 audioCues 表（cue 级高亮/句导航
///   可用）。
/// - 未选字幕：仅写 VideoBooks（标记内嵌默认轨），cue 为空，字幕靠 libmpv 画面
///   渲染——cue 级功能（overlay 高亮/句导航）无数据，是 Phase 0 已知降级。
///
/// 身份：bookUid 由文件名经 [sanitizeTtuFilename] 派生（[playlistBookUid] /
/// [singleVideoBookUid]），跨设备/换目录稳定；同名碰撞导入时 [uniqueVideoBookUid]
/// 静默加后缀去重（对齐书的 name-PK 哲学）。
class VideoImportDialog extends StatefulWidget {
  const VideoImportDialog({
    required this.repo,
    this.initialVideoPath,
    this.initialSubtitlePath,
    this.initialPlaylistPath,
    super.key,
  });

  final VideoBookRepository repo;
  final String? initialVideoPath;
  final String? initialSubtitlePath;

  /// 拖入 m3u8/m3u 播放列表时预填的路径。非空时对话框打开后自动走
  /// [_importPlaylistFromPath] 解析并导入（一次性，无需用户再点确认），与手动
  /// 点「播放列表」按钮的语义一致——播放列表无可附加的整本字幕/视频可调。
  final String? initialPlaylistPath;

  @override
  State<VideoImportDialog> createState() => _VideoImportDialogState();
}

class _VideoImportDialogState extends State<VideoImportDialog> {
  String? _videoPath;
  String? _subtitlePath;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _videoPath = widget.initialVideoPath;
    _subtitlePath = widget.initialSubtitlePath;
    // 拖入 m3u8：路径已知，跳过 FilePicker，开窗后直接解析导入（首帧后执行，
    // 避免在 initState 内同步 setState）。
    final String? dropped = widget.initialPlaylistPath;
    if (dropped != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _importPlaylistFromPath(dropped);
      });
    }
  }

  bool get _canImport => videoImportCanImport(
        videoPath: _videoPath,
        subtitlePath: _subtitlePath,
        busy: _busy,
      );

  Future<void> _pickVideo() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.video,
      allowMultiple: false,
    );
    final String? path = result?.files.single.path;
    if (path == null) return;
    setState(() => _videoPath = path);
    await _autoAttachSubtitle(path);
  }

  /// 选中视频后扫同目录同名字幕自动填进字幕行（仅填空、不覆盖手选）。视频用
  /// 内嵌音轨，不接外挂音频，故 `wantAudio: false`。桌面端有效；移动端缓存副本
  /// 目录扫不到兄弟文件，[findSidecars] 静默返回空。
  Future<void> _autoAttachSubtitle(String videoPath) async {
    // 字幕集合与手选白名单（_pickSubtitle）一致，去掉 lrc——避免自动挂载接受
    // 一种手动选择会拒绝的格式。
    final SidecarMatch m = await findSidecars(
      videoPath,
      wantAudio: false,
      subtitleExts: const <String>{'srt', 'vtt', 'ass', 'ssa'},
    );
    if (!mounted || m.subtitlePath == null || _subtitlePath != null) return;
    setState(() => _subtitlePath = m.subtitlePath);
    HibikiToast.show(
      msg: t.import_sidecar_subtitle(name: p.basename(m.subtitlePath!)),
    );
  }

  Future<void> _pickSubtitle() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['srt', 'vtt', 'ass', 'ssa'],
      allowMultiple: false,
    );
    final String? path = result?.files.single.path;
    if (path == null) return;
    setState(() => _subtitlePath = path);
  }

  /// 选 m3u8 播放列表 → 交给 [_importPlaylistFromPath] 解析导入。文件选择与解析
  /// 拆开，是为了让拖入（路径已知）能复用同一条解析/落库路径，不重复逻辑。
  Future<void> _pickPlaylist() async {
    final FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const <String>['m3u8', 'm3u'],
      allowMultiple: false,
    );
    final String? m3u8Path = result?.files.single.path;
    if (m3u8Path == null) return;
    await _importPlaylistFromPath(m3u8Path);
  }

  /// 解析 [m3u8Path] 多集 → 建一个 playlist VideoBook（不复制视频，存绝对路径）→
  /// pop 回 bookUid。第一集作为初始 videoPath，sidecar 字幕在播放页按集动态加载
  /// （不在导入时解析全部 cue）。手动选择与拖入共用此路径。
  Future<void> _importPlaylistFromPath(String m3u8Path) async {
    setState(() => _busy = true);
    try {
      final String content = await readTextWithEncoding(File(m3u8Path));
      final String baseDir = p.dirname(m3u8Path);
      final List<PlaylistEntry> entries =
          parseM3u8(content: content, baseDir: baseDir);
      if (entries.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(t.video_file_error_content)),
          );
        }
        return;
      }

      final String bookUid = await _uniqueBookUid(playlistBookUid(m3u8Path));
      final String playlistJson = jsonEncode(
        entries.map((PlaylistEntry e) => e.toJson()).toList(),
      );
      // 用第一集抽帧做播放列表封面（桌面 ffmpeg；移动端无 ffmpeg 时留空占位）。
      final String? coverPath = await extractVideoCover(
        videoPath: entries.first.path,
        bookUid: bookUid,
      );
      await widget.repo.saveVideoBook(VideoBooksCompanion(
        bookUid: Value(bookUid),
        title: Value(p.basenameWithoutExtension(m3u8Path)),
        videoPath: Value(entries.first.path),
        playlistJson: Value(playlistJson),
        currentEpisode: const Value<int>(0),
        coverPath: Value<String?>(coverPath),
        importedAt: Value(DateTime.now()),
      ));

      if (!mounted) return;
      debugPrint(
        '[hibiki-drop] [video-import] importedPlaylist bookUid=$bookUid '
        'playlist=${p.basename(m3u8Path)}',
      );
      Navigator.pop(context, bookUid);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 选一个文件夹 → 扫描顶层视频文件 → 按文件名解析分组（参照 Jellyfin/anitomy，
  /// 同番归一组、按集号排序）→ 每组建一个 VideoBook（多集=playlist，单集=单片）→
  /// pop 回最后一个 bookUid。不复制视频，存绝对路径；sidecar 字幕在播放页按集探测。
  Future<void> _pickFolder() async {
    final String? dir = await FilePicker.platform.getDirectoryPath();
    if (dir == null) return;

    setState(() => _busy = true);
    try {
      final List<String> videos = listVideoFilesInDirectory(dir);
      if (videos.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(t.video_import_folder_empty)),
          );
        }
        return;
      }
      final List<VideoGroup> groups = groupVideosIntoPlaylists(videos);
      String? lastBookUid;
      for (final VideoGroup group in groups) {
        lastBookUid = await _importGroup(group);
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(t.video_import_folder_done(count: groups.length))),
      );
      Navigator.pop(context, lastBookUid);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 导入一个系列分组：多集 → playlist VideoBook（身份 `video/playlist/<系列名>`），
  /// 单集 → 单片 VideoBook（内嵌默认字幕轨）。返回写入的 bookUid。
  Future<String> _importGroup(VideoGroup group) async {
    if (group.isPlaylist) {
      final List<PlaylistEntry> entries = group.episodes
          .map((VideoEpisode e) => PlaylistEntry(title: e.title, path: e.path))
          .toList();
      final String bookUid = await _uniqueBookUid(
          'video/playlist/${sanitizeTtuFilename(group.series)}');
      final String playlistJson =
          jsonEncode(entries.map((PlaylistEntry e) => e.toJson()).toList());
      final String? coverPath = await extractVideoCover(
        videoPath: entries.first.path,
        bookUid: bookUid,
      );
      await widget.repo.saveVideoBook(VideoBooksCompanion(
        bookUid: Value(bookUid),
        title: Value(group.series),
        videoPath: Value(entries.first.path),
        playlistJson: Value(playlistJson),
        currentEpisode: const Value<int>(0),
        coverPath: Value<String?>(coverPath),
        importedAt: Value(DateTime.now()),
      ));
      return bookUid;
    }
    final VideoEpisode only = group.episodes.first;
    final String bookUid = await _uniqueBookUid(singleVideoBookUid(only.path));
    final String? coverPath =
        await extractVideoCover(videoPath: only.path, bookUid: bookUid);
    await widget.repo.saveVideoBook(VideoBooksCompanion(
      bookUid: Value(bookUid),
      title: Value(p.basenameWithoutExtension(only.path)),
      videoPath: Value(only.path),
      embeddedSubtitleTrack: const Value<int?>(0),
      coverPath: Value<String?>(coverPath),
      importedAt: Value(DateTime.now()),
    ));
    return bookUid;
  }

  /// 用现有 VideoBooks 的 book_uid 集对 [base] 做同名去重（静默加后缀）。
  /// 对齐 EpubImporter 的无回调去重 UX，保证不写入重复主键。
  Future<String> _uniqueBookUid(String base) async {
    final List<VideoBookRow> existing = await widget.repo.listAll();
    final Set<String> keys =
        existing.map((VideoBookRow r) => r.bookUid).toSet();
    return uniqueVideoBookUid(base, keys);
  }

  Future<void> _doImport() async {
    if (!_canImport) return;
    final String videoPath = _videoPath!;
    final String? subtitlePath = _subtitlePath;
    setState(() => _busy = true);
    try {
      final String bookUid =
          await _uniqueBookUid(singleVideoBookUid(videoPath));
      // 抽一帧做书架封面（桌面 ffmpeg；移动端无 ffmpeg 时留空占位）。
      final String? coverPath =
          await extractVideoCover(videoPath: videoPath, bookUid: bookUid);

      if (subtitlePath != null) {
        // 选了外挂字幕：解析为 cue，写元数据 + cue 列表。
        final String format =
            p.extension(subtitlePath).replaceFirst('.', '').toLowerCase();
        final String content = await readTextWithEncoding(File(subtitlePath));
        final List<AudioCue> cues = parseSubtitleCues(
          content: content,
          format: format,
          bookUid: bookUid,
        );

        await widget.repo.saveVideoBook(VideoBooksCompanion(
          bookUid: Value(bookUid),
          title: Value(p.basenameWithoutExtension(videoPath)),
          videoPath: Value(videoPath),
          subtitleSource: Value(subtitlePath),
          subtitleFormat: Value(format),
          coverPath: Value<String?>(coverPath),
          importedAt: Value(DateTime.now()),
        ));
        await widget.repo.saveCues(bookUid: bookUid, cues: cues);
      } else {
        // 未选外挂字幕：标记用内嵌默认轨（track 0），不写 cue——字幕靠 libmpv
        // 画面渲染，cue 级功能（高亮/句导航）无数据（Phase 0 已知降级）。
        await widget.repo.saveVideoBook(VideoBooksCompanion(
          bookUid: Value(bookUid),
          title: Value(p.basenameWithoutExtension(videoPath)),
          videoPath: Value(videoPath),
          subtitleSource: const Value<String?>(null),
          subtitleFormat: const Value<String?>(null),
          embeddedSubtitleTrack: const Value<int?>(0),
          coverPath: Value<String?>(coverPath),
          importedAt: Value(DateTime.now()),
        ));
      }

      if (!mounted) return;
      debugPrint(
        '[hibiki-drop] [video-import] imported bookUid=$bookUid '
        'video=${p.basename(videoPath)} subtitle=${subtitlePath == null ? 'none' : p.basename(subtitlePath)}',
      );
      Navigator.pop(context, bookUid);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(t.video_import_title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          FilledButton.tonalIcon(
            onPressed: _busy ? null : _pickFolder,
            icon: const Icon(Icons.create_new_folder_outlined),
            label: Text(
              t.video_import_pick_folder,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: _busy ? null : _pickPlaylist,
            icon: const Icon(Icons.playlist_play),
            label: Text(
              t.video_import_pick_playlist,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 8),
          const Divider(height: 16),
          OutlinedButton.icon(
            onPressed: _busy ? null : _pickVideo,
            icon: const Icon(Icons.movie_outlined),
            label: Text(
              _videoPath == null
                  ? t.video_import_pick_video
                  : p.basename(_videoPath!),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _busy ? null : _pickSubtitle,
            icon: const Icon(Icons.subtitles_outlined),
            label: Text(
              _subtitlePath == null
                  ? t.video_import_pick_subtitle
                  : p.basename(_subtitlePath!),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            t.video_import_subtitle_optional,
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(t.dialog_cancel),
        ),
        FilledButton(
          onPressed: _canImport ? _doImport : null,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(t.video_import_confirm),
        ),
      ],
    );
  }
}
