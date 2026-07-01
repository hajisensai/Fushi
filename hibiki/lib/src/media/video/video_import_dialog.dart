import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/src/media/drag_drop/drop_classification.dart';
import 'package:hibiki/src/media/drag_drop/hibiki_file_drop_target.dart';
import 'package:hibiki/src/media/drag_drop/import_dialog_drop.dart';
import 'package:hibiki/src/media/import/real_path_directory_picker.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/media/import/sidecar_finder.dart';
import 'package:hibiki/src/media/video/m3u8_playlist.dart';
import 'package:hibiki/src/media/video/url_stream_video.dart';
import 'package:hibiki/src/media/video/youtube_source_resolver.dart';
import 'package:hibiki/src/pages/implementations/video_hibiki_page.dart';
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_filename_parser.dart';
import 'package:hibiki/src/sync/hibiki_library_host_service.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart';
import 'package:hibiki/utils.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/storage/app_paths.dart';
import 'package:path/path.dart' as p;
// TODO-817 M1c: videoCoverFileName / extractVideoCover 已下沉到
// desktop_audio_clipper.dart（ffmpeg 封面抽取的归宿，使扫描器无需 import UI 层）；
// 从这里 re-export 让既有调用点（home_video_page / playlist_book_uid_test）零改动。
export 'package:hibiki/src/utils/misc/desktop_audio_clipper.dart'
    show videoCoverFileName, extractVideoCover;

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
  // TODO-935 E0：封面目录经唯一入口 [AppPaths] 派生 `<documents>/video_covers`。
  final Directory coverDir = await AppPaths.videoCoversDirectory();
  await coverDir.create(recursive: true);
  final String dest = p.join(coverDir.path, videoCoverFileName(bookUid));
  await File(pickedPath).copy(dest);
  PaintingBinding.instance.imageCache.evict(FileImage(File(dest)));
  await repo.updateCover(bookUid, dest);
  return dest;
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
  final TextEditingController _streamUrlController = TextEditingController();
  final TextEditingController _streamSubtitleUrlController =
      TextEditingController();
  final TextEditingController _streamRefererController =
      TextEditingController();
  final TextEditingController _streamUserAgentController =
      TextEditingController();
  bool _streamAdvancedExpanded = false;

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

  @override
  void dispose() {
    _streamUrlController.dispose();
    _streamSubtitleUrlController.dispose();
    _streamRefererController.dispose();
    _streamUserAgentController.dispose();
    super.dispose();
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
    final AppModel appModel =
        ProviderScope.containerOf(context, listen: false).read(appProvider);
    final String? dir = await pickRealDirectoryPath(
      context: context,
      appModel: appModel,
    );
    if (dir == null) return;
    if (!mounted) return;

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

  /// 当前粘贴的视频 URL 是否可播（http/https 直链）。空串/非法 scheme → false。
  bool get _streamUrlValid => isPlayableStreamUrl(_streamUrlController.text);

  /// 当前粘贴的 URL 是否命中已知网页视频站（YouTube/Netflix 等）。命中时显示软警告
  /// 并在点播放前弹「仍要尝试/取消」确认——不阻断、不按后缀硬拒（TODO-1000 part-A1）。
  bool get _streamUrlIsWebPage =>
      isKnownWebPageVideoUrl(_streamUrlController.text);

  /// 「播放流」（TODO-850 阶段①）：把粘贴的 URL + 可选字幕 URL + 可选防盗链 header
  /// 包成 [UrlStreamVideoClient] 喂进既有远端播放链（[VideoHibikiPage.neutralizedRemote]）。
  ///
  /// 阶段①只播不入库：不写 VideoBooks、不碰 DB schema。bookUid 由 [streamVideoBookUid]
  /// 派生（同一 URL 稳定，断点 prefs 续看可对齐）。直接 push 远端播放页后 pop(null)——
  /// 调用方（home_video / 书架）把 null 当「无新增入库，不刷新书架」，既有 import 路径
  /// 行为不变（Never break userspace）。
  /// 「播放流」入口：URL 命中已知网页视频站时先弹软警告确认（带「仍要尝试」逃生口），
  /// 用户确认后或非网页站时直接走 [_playStreamUrlConfirmed]。不据域名硬拒。
  Future<void> _playStreamUrl() async {
    final String url = _streamUrlController.text.trim();
    if (!isPlayableStreamUrl(url)) return;
    if (isKnownWebPageVideoUrl(url)) {
      final bool proceed = await _confirmWebPageUrl();
      if (!proceed || !mounted) return;
    }
    await _playStreamUrlConfirmed();
  }

  /// 网页视频站 URL 软警告确认框：标题 + 正文说明「网页地址非直链、Hibiki 暂不解析」，
  /// 「取消」返回 false、「仍要尝试」返回 true（逃生口，避免误伤边缘合法情况）。
  Future<bool> _confirmWebPageUrl() async {
    final bool? proceed = await showDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(t.video_import_webpage_url_warning_title),
        content: Text(t.video_import_webpage_url_warning_body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.video_import_webpage_url_try_anyway),
          ),
        ],
      ),
    );
    return proceed ?? false;
  }

  /// 实际把粘贴的流 URL 包成 [UrlStreamVideoClient] 喂进远端播放链（原 _playStreamUrl 主体）。
  ///
  /// TODO-1000：YouTube URL 先经 [resolveYoutubeSource] 解析出最高清 video-only + audio-only
  /// 分离流 + timedtext 字幕 cue（muxed 限 360p，不用），再包成 client 喂同一条远端播放链。
  Future<void> _playStreamUrlConfirmed() async {
    final String url = _streamUrlController.text.trim();
    if (!isPlayableStreamUrl(url)) return;

    final String bookUid = streamVideoBookUid(url);
    final UrlStreamVideoClient client;
    final String title;

    if (isYoutubeUrl(url)) {
      final YoutubeResolvedSource resolved;
      try {
        resolved = await resolveYoutubeSource(url);
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(t.video_file_error_content)),
          );
        }
        return;
      }
      if (!mounted) return;
      client = UrlStreamVideoClient(
        streamUrl: resolved.streamUrl,
        audioStreamUrl: resolved.audioStreamUrl,
        preresolvedCues: resolved.cues,
        httpHeaderFields: resolved.httpHeaders,
      );
      title = resolved.title;
    } else {
      final String subtitleUrlRaw = _streamSubtitleUrlController.text.trim();
      final String? subtitleUrl =
          isPlayableStreamUrl(subtitleUrlRaw) ? subtitleUrlRaw : null;
      final Map<String, String> headers = <String, String>{};
      final String referer = _streamRefererController.text.trim();
      final String userAgent = _streamUserAgentController.text.trim();
      if (referer.isNotEmpty) headers['Referer'] = referer;
      if (userAgent.isNotEmpty) headers['User-Agent'] = userAgent;
      client = UrlStreamVideoClient(
        streamUrl: url,
        subtitleUrl: subtitleUrl,
        subtitleFileName:
            subtitleUrl == null ? null : _subtitleFileNameForUrl(subtitleUrl),
        httpHeaderFields: headers,
      );
      title = _streamTitleForUrl(url);
    }

    final RemoteVideoInfo info = RemoteVideoInfo(id: bookUid, title: title);
    final NavigatorState navigator = Navigator.of(context);
    // 先关本对话框（避免播放页叠在对话框之上），再 push 远端播放页。
    navigator.pop();
    navigator.push(
      adaptivePageRoute<void>(
        builder: (_) => VideoHibikiPage.neutralizedRemote(
          info: info,
          repo: widget.repo,
          client: client,
        ),
      ),
    );
  }

  /// 从字幕 URL 末段取文件名（保留扩展名给字幕格式路由）；取不到回退 `subtitle`。
  String _subtitleFileNameForUrl(String url) {
    final Uri? uri = Uri.tryParse(url);
    final String last = (uri != null && uri.pathSegments.isNotEmpty)
        ? uri.pathSegments.last
        : '';
    return last.isEmpty ? 'subtitle' : last;
  }

  /// 流标题：取 URL 末段文件名（无扩展名）；取不到回退 host；再不行回退原 URL。
  String _streamTitleForUrl(String url) {
    final Uri? uri = Uri.tryParse(url);
    if (uri == null) return url;
    if (uri.pathSegments.isNotEmpty && uri.pathSegments.last.isNotEmpty) {
      return p.basenameWithoutExtension(uri.pathSegments.last);
    }
    return uri.host.isNotEmpty ? uri.host : url;
  }

  /// 拖文件进本对话框 → 有 m3u8/m3u 播放列表则走 [_importPlaylistFromPath]
  /// 一次性解析导入（与手动点「播放列表」一致，会关窗）；否则第一个视频写
  /// `_videoPath`、第一个字幕写 `_subtitlePath`。纯解析交给 [resolveVideoDialogDrop]。
  void _handleDialogDrop(List<String> paths, Offset _) {
    if (_busy) return;
    final DroppedFiles files = classifyDroppedFiles(paths);
    final VideoDialogDropResult r = resolveVideoDialogDrop(files);
    if (r.isEmpty) return;
    final String? playlist = r.playlistPath;
    if (playlist != null) {
      _importPlaylistFromPath(playlist);
      return;
    }
    setState(() {
      if (r.videoPath != null) _videoPath = r.videoPath;
      if (r.subtitlePath != null) _subtitlePath = r.subtitlePath;
    });
  }

  @override
  Widget build(BuildContext context) {
    return HibikiFileDropTarget(
      enabled: !_busy,
      debugLabel: 'video-import-dialog',
      onDrop: _handleDialogDrop,
      child: AlertDialog(
        title: Text(t.video_import_title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              // 粘贴 URL 在线流（TODO-850 阶段①）：直链/HLS/m3u8 即播 + 可选外挂字幕 +
              // 可选防盗链 header。与本地文件导入区分（独立分支，不走 _pickPlaylist）。
              TextField(
                controller: _streamUrlController,
                enabled: !_busy,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: t.video_import_stream_url_field,
                  hintText: 'https://...',
                  prefixIcon: const Icon(Icons.link),
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) {
                  if (_streamUrlValid) _playStreamUrl();
                },
              ),
              const SizedBox(height: 4),
              Text(
                t.video_import_stream_url_hint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
              // 网页视频站 URL 软警告内联条（TODO-1000 part-A1）：命中 YouTube/Netflix 等
              // 网页地址时提示「非直链、暂不解析」；不禁用播放按钮，仅在点播时弹确认。
              if (_streamUrlIsWebPage) ...<Widget>[
                const SizedBox(height: 4),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(
                      Icons.warning_amber_rounded,
                      size: 16,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        t.video_import_webpage_url_warning_body,
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: Theme.of(context).colorScheme.error,
                            ),
                      ),
                    ),
                  ],
                ),
              ],
              const SizedBox(height: 8),
              TextField(
                controller: _streamSubtitleUrlController,
                enabled: !_busy,
                keyboardType: TextInputType.url,
                autocorrect: false,
                decoration: InputDecoration(
                  labelText: t.video_import_stream_subtitle_url_field,
                  hintText: 'https://...',
                  prefixIcon: const Icon(Icons.subtitles_outlined),
                  isDense: true,
                ),
              ),
              const SizedBox(height: 4),
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: _busy
                      ? null
                      : () => setState(() =>
                          _streamAdvancedExpanded = !_streamAdvancedExpanded),
                  icon: Icon(_streamAdvancedExpanded
                      ? Icons.expand_less
                      : Icons.expand_more),
                  label: Text(t.video_import_stream_advanced),
                ),
              ),
              if (_streamAdvancedExpanded) ...<Widget>[
                TextField(
                  controller: _streamRefererController,
                  enabled: !_busy,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: t.video_import_stream_referer,
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _streamUserAgentController,
                  enabled: !_busy,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: t.video_import_stream_user_agent,
                    isDense: true,
                  ),
                ),
              ],
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: (_busy || !_streamUrlValid) ? null : _playStreamUrl,
                icon: const Icon(Icons.play_circle_outline),
                label: Text(
                  t.video_import_stream_play,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const Divider(height: 24),
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
      ),
    );
  }
}
