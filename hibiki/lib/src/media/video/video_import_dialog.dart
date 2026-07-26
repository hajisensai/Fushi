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
import 'package:hibiki/src/media/video/video_book_repository.dart';
import 'package:hibiki/src/media/video/video_filename_parser.dart';
import 'package:hibiki/src/sync/ttu_filename.dart';
import 'package:hibiki/src/utils/cover_image.dart';
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
    show videoCoverFileName, extractVideoCover, extractPlaylistCover;

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
/// 书架/视频库长按菜单「设置封面」共用此入口（消除两处手抄），统一封面服务
/// `MediaCoverService.applyVideoCoverManual` 薄路由到这里。封面写到与导入
/// 时自动截图同一路径（同一 [videoCoverFileName]），所以 DB 里的 `coverPath`
/// 字符串不变；而 [FileImage] 按 `(path, scale)` 而非内容/mtime 缓存解码，覆盖
/// 同名文件后必须驱逐旧条目，否则 UI 重建时命中旧解码、用户重设封面后看到的
/// 还是旧图（直到缓存淘汰或重启）。驱逐走 [evictLocalCoverCache]：裸 FileImage
/// 键与 `resizedFileImage` 的 ResizeImage 键是两个不同 key，只清前者的话走降
/// 采样渲染的卡片（ShelfFileCover 等）仍命中旧解码。
///
/// [coversDirectory] 是测试接缝：默认经唯一入口 [AppPaths] 派生
/// `<documents>/video_covers`（TODO-935 E0），测试传临时目录即可断言真实落盘。
Future<String> setVideoCoverFromPickedFile({
  required VideoBookRepository repo,
  required String bookUid,
  required String pickedPath,
  Directory? coversDirectory,
}) async {
  final Directory coverDir =
      coversDirectory ?? await AppPaths.videoCoversDirectory();
  await coverDir.create(recursive: true);
  final String dest = p.join(coverDir.path, videoCoverFileName(bookUid));
  await File(pickedPath).copy(dest);
  await evictLocalCoverCache(dest);
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
  String? streamUrl,
}) {
  if (busy) return false;
  // TODO-1157：粘贴了可播流 URL 即可导入（把流媒体当视频源之一，像本地视频一样入库）。
  if (streamUrl != null && isPlayableStreamUrl(streamUrl)) return true;
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
    this.initialStreamUrl,
    super.key,
  });

  final VideoBookRepository repo;
  final String? initialVideoPath;
  final String? initialSubtitlePath;

  /// 拖入 m3u8/m3u 播放列表时预填的路径。非空时对话框打开后自动走
  /// [_importPlaylistFromPath] 解析并导入（一次性，无需用户再点确认），与手动
  /// 点「播放列表」按钮的语义一致——播放列表无可附加的整本字幕/视频可调。
  final String? initialPlaylistPath;

  /// 拖入网络流 URL（浏览器地址栏/链接拖进来）时预填的 URL。非空且可播时对话框打开后
  /// 自动走 [_importStreamUrl] 导入（一次性、无需再点确认），与拖 m3u8 自动导入语义一致
  /// （TODO-1306）；非可播 URL 只预填到 URL 输入框、不自动导入。
  final String? initialStreamUrl;

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
    // 拖入网络流 URL（TODO-1306）：预填 URL 输入框；可播则开窗后自动导入（首帧后执行，
    // 与拖 m3u8 一致），非可播只预填不导入（isPlayableStreamUrl 兜底非法 scheme）。
    final String? droppedUrl = widget.initialStreamUrl;
    if (droppedUrl != null) {
      _streamUrlController.text = droppedUrl;
      if (isPlayableStreamUrl(droppedUrl)) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _importStreamUrl(droppedUrl.trim());
        });
      }
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
        streamUrl: _streamUrlController.text,
        busy: _busy,
      );

  Future<void> _pickVideo() async {
    // 安卓：走真实路径浏览器拿绝对路径（不复制到 cache，清缓存不失效）；
    // 桌面/iOS 及安卓无全文件访问时回退 file_picker（board 1112）。
    // 视频不限扩展名（allowedExtensions:null），避免维护第二份视频扩展名清单。
    final AppModel appModel =
        ProviderScope.containerOf(context, listen: false).read(appProvider);
    final String? path = await pickRealFilePath(
      context: context,
      appModel: appModel,
    );
    if (path == null || !mounted) return;
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
    // 字幕在导入时即被解析成 cues 当场消费，不以绝对路径长期引用，故维持系统文件
    // 选择器（board 1360——用户报「导入选字幕文件的选择器变了」）：用户熟悉，且能触达
    // Downloads / 云盘 / 最近文件等真实路径浏览器覆盖不到的位置。视频本体仍走
    // 真实路径浏览器（绝对路径不复制、清缓存不失效），只有字幕回退系统选择器。扩展名
    // 集与 _autoAttachSubtitle / parseSubtitleCues 支持列表对齐。
    final String? path = await pickSystemFilePath(
      context: context,
      allowedExtensions: const <String>{'srt', 'vtt', 'ass', 'ssa'},
    );
    if (path == null || !mounted) return;
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

      // 统一合集 Phase 2：多集拆成 N 条独立 VideoBooks 行 + 一个 playlist 合集
      // （单一真相源 importSplitPlaylist，与 v38 迁移落库形状对齐）。
      final ({int collectionId, List<String> episodeUids}) result =
          await widget.repo.importSplitPlaylist(
        collectionName: p.basenameWithoutExtension(m3u8Path),
        entries: entries,
      );
      final String firstUid = result.episodeUids.first;
      // TODO-1237 ①：遍历各集取首个可用封面（首集缺失/远端占位时退到后续集）给首集
      // 承接（合集卡封面纯函数取首成员封面）。桌面 ffmpeg；移动端无 ffmpeg 时留空占位。
      final String? coverPath = await extractPlaylistCover(
        episodePaths: entries.map((PlaylistEntry e) => e.path).toList(),
        bookUid: firstUid,
      );
      if (coverPath != null) {
        await widget.repo.updateCover(firstUid, coverPath);
      }

      // v49：手动选/拖入 m3u8 播放列表也是用户明示导入，整本只记 1 条 added 活动
      // 事件（title=合集名=m3u8 文件名、mediaKey=首集 uid）。
      await widget.repo.recordVideoImportActivity(
        bookUid: firstUid,
        title: p.basenameWithoutExtension(m3u8Path),
      );

      if (!mounted) return;
      debugPrint(
        '[hibiki-drop] [video-import] importedPlaylist collection='
        '${result.collectionId} episodes=${result.episodeUids.length} '
        'playlist=${p.basename(m3u8Path)}',
      );
      Navigator.pop(context, firstUid);
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
      int importedCount = 0;
      for (final VideoGroup group in groups) {
        // null = 该组文件已在库、被去重跳过（TODO-1237 ②）；只统计真正新导入的。
        final String? uid = await _importGroup(group);
        if (uid != null) {
          lastBookUid = uid;
          importedCount++;
        }
      }
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(t.video_import_folder_done(count: importedCount))),
      );
      Navigator.pop(context, lastBookUid);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// 导入一个系列分组：多集 → playlist VideoBook（身份 `video/playlist/<系列名>`），
  /// 单集 → 单片 VideoBook（内嵌默认字幕轨）。返回写入的 bookUid。
  Future<String?> _importGroup(VideoGroup group) async {
    // TODO-1237 ②：文件夹扫描去重——同一物理文件已在库则跳过，不再 uniqueVideoBookUid
    // 加后缀建 `X (2)` 重复条目（对齐 EPUB 扫描的 skipIfExists，BUG-443）。以首集/单片
    // 绝对路径判重（findByVideoPath 的单一真相，按 normalizeVideoPath 归一），返回 null
    // 表示本组已导入、被跳过。
    if (await widget.repo.isVideoPathReferenced(group.episodes.first.path)) {
      return null;
    }
    if (group.isPlaylist) {
      final List<PlaylistEntry> entries = group.episodes
          .map((VideoEpisode e) => PlaylistEntry(title: e.title, path: e.path))
          .toList();
      // 统一合集 Phase 2：拆成 N 条独立 VideoBooks 行 + 一个 playlist 合集
      // （合集名用系列名）。封面给首集承接。
      final ({int collectionId, List<String> episodeUids}) result =
          await widget.repo.importSplitPlaylist(
        collectionName: group.series,
        entries: entries,
      );
      final String firstUid = result.episodeUids.first;
      final String? coverPath = await extractPlaylistCover(
        episodePaths: entries.map((PlaylistEntry e) => e.path).toList(),
        bookUid: firstUid,
      );
      if (coverPath != null) {
        await widget.repo.updateCover(firstUid, coverPath);
      }
      // v49：一个多集播放列表只记 1 条 added 活动事件（title=合集名、mediaKey=首集
      // uid），绝不每集一条——避免刷屏（约束2）。
      await widget.repo.recordVideoImportActivity(
        bookUid: firstUid,
        title: group.series,
      );
      return firstUid;
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
    // v49：文件夹扫描里的单集视频，记一条 added 活动事件。
    await widget.repo.recordVideoImportActivity(
      bookUid: bookUid,
      title: p.basenameWithoutExtension(only.path),
    );
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
    // TODO-1157：粘贴了可播流 URL 时优先把它当视频源导入（进书架、可重开）；无 URL 才走
    // 本地文件导入。流媒体与本地文件互斥填写，故 URL 有效即短路本地路径。
    final String streamUrl = _streamUrlController.text.trim();
    if (isPlayableStreamUrl(streamUrl)) {
      await _importStreamUrl(streamUrl);
      return;
    }
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

      // v49：用户明示导入单个视频成功 → 记一条 added 活动事件（喂首页 Activity
      // 时间轴）。best-effort（方法内吞异常只 log），不影响视频已导入。
      await widget.repo.recordVideoImportActivity(
        bookUid: bookUid,
        title: p.basenameWithoutExtension(videoPath),
      );

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

  /// TODO-1157：把粘贴的流媒体 URL 当作一种视频源**导入**（像本地视频一样落 VideoBooks、
  /// 进书架、可重复打开），而不再「即播不入库」。videoPath 存原始 URL（YouTube=watch URL、
  /// 直链/HLS=直链），外挂字幕 URL + 防盗链 header 存进 [VideoBooks.streamSpecJson]；
  /// 重开时由 [buildStreamVideoLaunch] 据此重建流客户端（YouTube 重解析）。导入后 pop 回
  /// bookUid（与本地导入一致，回书架而非立即播放），身份 [streamVideoBookUid] 稳定去重。
  Future<void> _importStreamUrl(String url) async {
    setState(() => _busy = true);
    try {
      final String bookUid = await _uniqueBookUid(streamVideoBookUid(url));
      final String subtitleUrlRaw = _streamSubtitleUrlController.text.trim();
      final String? subtitleUrl =
          isPlayableStreamUrl(subtitleUrlRaw) ? subtitleUrlRaw : null;
      final String referer = _streamRefererController.text.trim();
      final String userAgent = _streamUserAgentController.text.trim();
      final StreamVideoSpec spec = StreamVideoSpec(
        subtitleUrl: subtitleUrl,
        subtitleFileName:
            subtitleUrl == null ? null : _subtitleFileNameForUrl(subtitleUrl),
        referer: referer.isEmpty ? null : referer,
        userAgent: userAgent.isEmpty ? null : userAgent,
      );
      // TODO-1281：YouTube 导入时用 watch URL 派生的标题恒是字面 "watch"（query 里的
      // ?v= 才是视频标识），且流媒体无本地文件可 ffmpeg 抽封面 → 名字错 + 无封面。故对
      // YouTube URL 轻量抓一次元数据（真实标题 + 缩略图 URL），落库真名 + 下载封面。
      // best-effort：抓取失败退回 URL 派生标题 + 无封面，导入不中止（见
      // [resolveYoutubeMetadata]）。直链/HLS 无此问题，保持原逻辑。
      String title = _streamTitleForUrl(url);
      String? coverPath;
      switch (streamImportCoverStrategy(url)) {
        case StreamImportCoverStrategy.youtubeThumbnail:
          coverPath = await _resolveYoutubeImportCover(
            url,
            bookUid,
            (String resolved) => title = resolved,
          );
        case StreamImportCoverStrategy.ffmpegFrame:
          // TODO-1304：直链/HLS 也出封面。videoPath 是可 seek 的流 URL → ffmpeg 抽一帧
          // （桌面 CLI / 移动端 ffmpeg-kit，均支持 http 输入，经 _isRemoteFfmpegInput 放行）。
          // 抽不到（无 ffmpeg / 流不可 seek）→ null，书架占位（与本地视频无 ffmpeg 一致，不中止）。
          coverPath = await extractVideoCover(videoPath: url, bookUid: bookUid);
      }
      await widget.repo.saveVideoBook(VideoBooksCompanion(
        bookUid: Value(bookUid),
        title: Value(title),
        videoPath: Value(url),
        streamSpecJson: Value<String?>(spec.toStorageJson()),
        coverPath: Value<String?>(coverPath),
        importedAt: Value(DateTime.now()),
      ));
      // v49：用户明示导入流媒体成功 → 记一条 added 活动事件（title=解析出的流标题）。
      await widget.repo
          .recordVideoImportActivity(bookUid: bookUid, title: title);
      if (!mounted) return;
      debugPrint(
        '[hibiki-drop] [video-import] importedStream bookUid=$bookUid '
        'url=$url',
      );
      Navigator.pop(context, bookUid);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// TODO-1304：YouTube 导入封面 + 真实标题（best-effort，绝不阻断导入）。
  ///
  /// watch URL 派生的标题恒是字面 "watch"（`?v=` 才是标识）、且流媒体无本地文件可 ffmpeg
  /// 抽帧 → 用 [resolveYoutubeMetadata] 轻量抓一次真实标题（经 [onTitle] 回传）+ 缩略图
  /// URL，再 [downloadVideoCoverToPath] 落封面。缩略图下载失败（[downloadVideoCoverToPath]
  /// 返回 null）旧代码**完全静默**——无从区分「网络失败」与「没实现/URL 拼错」；这里**重试
  /// 一次并记日志**留证。metadata 抓取抛异常（超时/网络）→ 记日志、退回 URL 派生标题 +
  /// 无封面（导入仍成功）。
  Future<String?> _resolveYoutubeImportCover(
    String url,
    String bookUid,
    void Function(String title) onTitle,
  ) async {
    try {
      final YoutubeMetadata meta = await resolveYoutubeMetadata(url);
      if (meta.title.trim().isNotEmpty) onTitle(meta.title.trim());
      final Directory coverDir = await AppPaths.videoCoversDirectory();
      final String outputPath =
          p.join(coverDir.path, videoCoverFileName(bookUid));
      String? cover = await downloadVideoCoverToPath(
        coverUrl: meta.thumbnailUrl,
        outputPath: outputPath,
      );
      if (cover == null) {
        // 一次重试：区分瞬时网络失败（重试常成功）与持续失败（记日志留证）。
        debugPrint('[hibiki][youtube] 缩略图下载失败，重试一次：${meta.thumbnailUrl}');
        cover = await downloadVideoCoverToPath(
          coverUrl: meta.thumbnailUrl,
          outputPath: outputPath,
        );
        if (cover == null) {
          debugPrint(
            '[hibiki][youtube] 缩略图重试仍失败（网络/URL 问题），书架用占位：'
            '${meta.thumbnailUrl}',
          );
        }
      }
      return cover;
    } catch (e) {
      debugPrint('[hibiki][youtube] import metadata resolve failed: $e');
      return null;
    }
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
                  if (_streamUrlValid) _doImport();
                },
              ),
              const SizedBox(height: 4),
              Text(
                t.video_import_stream_url_hint,
                style: Theme.of(context).textTheme.bodySmall,
              ),
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
