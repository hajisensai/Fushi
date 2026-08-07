import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:path/path.dart' as p;
import 'package:fushi/src/media/drag_drop/drop_classification.dart';
import 'package:fushi/src/media/drag_drop/hibiki_file_drop_target.dart';
import 'package:fushi/src/media/drag_drop/import_dialog_drop.dart';
import 'package:fushi/src/media/audiobook/audiobook_alignment_service.dart';
import 'package:fushi/src/media/audiobook/subtitle_rematch.dart';
import 'package:fushi/src/media/audiobook/text_to_epub.dart';
import 'package:fushi/src/media/import/audiobook_health_summary.dart';
import 'package:fushi/src/media/import/import_carrier.dart';
import 'package:fushi/src/media/import/import_dialog_frame.dart';
import 'package:fushi/src/media/import/import_flow_mixin.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/media/import/sidecar_finder.dart';
import 'package:fushi/src/media/media_cover_service.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/epub/book_title_conflict.dart';
import 'package:fushi/src/epub/epub_importer.dart';
import 'package:fushi/src/media/manga/manga_import_dialog.dart';
import 'package:fushi/src/media/manga/manga_module.dart';
import 'package:fushi/src/pdf/pdf_importer.dart';
import 'package:fushi/utils.dart';

/// 统一"导入书"对话框。EPUB、字幕、音频可按需组合，一次导入。
///
/// 路由规则（以"选中了什么"为准）：
///
/// - **仅 EPUB**：[EpubImporter] 解压 + 入 Drift，书自然出现在书架。
/// - **仅字幕（可带音频）**：解析 cues → [CuesToEpub] 生成真 EPUB 并
///   [EpubImporter] 导入；同时把 cues + audio 路径落到 Isar [SrtBook] / [AudioCue]。
/// - **EPUB + 字幕（可带音频）**：先 [EpubImporter] 导入 EPUB 拿 `bookId`；再用
///   [EpubParser] 读回章节文本，跑 [EpubSrtMatcher] + [SasayakiMatchCodec]，
///   把 cue 对齐到真实 EPUB；cues + 可选音频落到 [AudiobookRepository]。
/// - **音频但无字幕**：非法组合，音频必须配合字幕使用。
///
/// **漫画不在此列**：漫画有独立入口与独立对话框 [MangaImportDialog]（载体不同，
/// 可填字段就不同——漫画没有字幕/音频/对齐，书籍没有 OCR）。本框仍然**认得**漫画
/// 载体，但只做一件事：弹一次明确确认后把路径转交漫画流程（[_handoffIfManga]）。
class BookImportDialog extends StatefulWidget {
  const BookImportDialog({
    required this.repo,
    required this.audiobookRepo,
    required this.db,
    this.initialEpubPath,
    this.initialSubtitlePath,
    this.initialAudioPaths,
    this.imageArchiveProbe,
    super.key,
  });

  final SrtBookRepository repo;
  final AudiobookRepository audiobookRepo;
  final HibikiDatabase db;
  final String? initialEpubPath;
  final String? initialSubtitlePath;

  /// 拖拽导入预填：随新书一起拖入的音频文件路径。EPUB+音频拖到书架空白处时透传，
  /// 否则丢失（书架 `importNewBook` 此前未携带 `files.audios`）。音频必配字幕，
  /// 故仅预填展示——`_doImport` 的「音频必须配字幕」校验照旧（拖 EPUB+音频无字幕
  /// 时仍要求补字幕）。
  final List<String>? initialAudioPaths;

  /// 测试计数缝：生产始终走 [MangaModule.isImageArchive]；回归测试只在外层计数后
  /// 委托同一个真判据，证明真实对话框没有重复执行昂贵的整包载体判定。
  @visibleForTesting
  final bool Function(String path)? imageArchiveProbe;

  @override
  State<BookImportDialog> createState() => _BookImportDialogState();
}

class _BookImportDialogState extends State<BookImportDialog>
    with ImportFlowMixin<BookImportDialog> {
  final TextEditingController _titleCtrl = TextEditingController();
  final TextEditingController _authorCtrl = TextEditingController();

  /// 标题框当前内容的来源，决定选/重选文件时能否覆盖（见 [resolveImportTitle]，
  /// TODO-1362）。用户在标题框手打即置 [ImportTitleSource.user]，此后自动派生不再
  /// 覆盖；同来源重选（如再点一次「选书」换一本）刷新为新书名。
  ImportTitleSource _titleSource = ImportTitleSource.none;

  String? _epubPath;
  String? _subtitlePath;
  List<String> _audioPaths = [];
  String? _coverPath;
  String? _audioCoverPath;
  // 内嵌封面抽取（m4b 等经 ffmpeg probe，桌面端有数百毫秒~数秒延迟）的在途
  // Future。各触发点赋值，导入时 _applyBestCoverToEpub 先 await 它，避免用户在
  // 抽取未返回时点「导入」导致 _audioCoverPath 仍为 null 被吞掉（BUG-483）。
  Future<void>? _coverExtraction;
  // TODO-1034 次要：单调递增的抽取序号，用于让晚到的旧抽取放弃写 _audioCoverPath。
  int _coverExtractionToken = 0;

  // 原始文件名（file_picker 在 Android 上返回的 cache 路径文件名可能与原始不同）
  String? _epubName;
  String? _subtitleName;

  bool _pickerActive = false;

  /// TODO-935 ①A：「引用原文件（不复制）」开关。仅桌面可见/可选；移动端
  /// file_picker 返回缓存临时副本，引用即指向会被清掉的文件，故恒 false。
  bool _referenceOriginal = false;

  bool _autoWindow = true;
  int _searchWindow = EpubSrtMatcher.defaultSearchWindow;
  double _similarityThreshold = EpubSrtMatcher.defaultSimilarityThreshold;

  bool get _willRunMatcher {
    if (_epubPath == null || _subtitlePath == null) return false;
    final String ext = _subtitlePath!.split('.').last.toLowerCase();
    return SubtitleRematch.supportedFormats.contains(ext);
  }

  bool get _hasSubtitles => _subtitlePath != null;

  /// 从所选文件名派生的书名 [derived] 回填标题框，覆盖决策委托纯函数
  /// [resolveImportTitle]（[incoming] 为本次来源）：同来源重选或标题为空才刷新，
  /// 跨来源保持「非空不覆盖」，用户手打的标题永不被覆盖（TODO-1362）。可从
  /// initState / setState 内调用——只改字段与控制器，不自行触发 setState。
  void _autoFillTitle(String derived, ImportTitleSource incoming) {
    final ({String text, ImportTitleSource source}) next = resolveImportTitle(
      currentText: _titleCtrl.text,
      currentSource: _titleSource,
      incoming: incoming,
      derived: derived,
    );
    _titleSource = next.source;
    if (next.text != _titleCtrl.text) {
      _titleCtrl.text = next.text;
    }
  }

  @override
  void initState() {
    super.initState();
    _carrierResolver = ImportCarrierResolver(
      isDirectory: (String pth) => Directory(pth).existsSync(),
      isImageArchive: widget.imageArchiveProbe ?? MangaModule.isImageArchive,
    );
    final String? epub = widget.initialEpubPath;
    if (epub != null) {
      _epubPath = epub;
      _epubName = p.basename(epub);
      // 目录（漫画页图文件夹）没有扩展名概念——目录名带点时
      // basenameWithoutExtension 会把 `第01巻.v2` 截成 `第01巻`，当书名用就错了。
      _autoFillTitle(
        Directory(epub).existsSync()
            ? p.basename(epub)
            : p.basenameWithoutExtension(epub),
        ImportTitleSource.epub,
      );
    }
    final String? sub = widget.initialSubtitlePath;
    if (sub != null) {
      _subtitlePath = sub;
      _subtitleName = p.basename(sub);
    }
    final List<String>? audios = widget.initialAudioPaths;
    if (audios != null && audios.isNotEmpty) {
      _audioPaths = List<String>.of(audios);
      // 预填音频时尝试抽内嵌封面（与 _pickAudio 路径一致）。首帧后跑，避免在
      // initState 内同步触发 setState / 平台通道调用。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        if (_coverPath == null) {
          _tryExtractAudioCover();
        }
        // 元数据回填独立于封面：即使已选封面也要试补空标题/作者（TODO-1045）。
        _tryExtractAudioMetadata();
      });
    }
  }

  @override
  void dispose() {
    _titleCtrl.dispose();
    _authorCtrl.dispose();
    // 进度 ValueNotifier 由 ImportFlowMixin.dispose() 经 super 链释放。
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return HibikiFileDropTarget(
      enabled: !importing,
      debugLabel: 'book-import-dialog',
      onDrop: _handleDialogDrop,
      child: BookImportDialogFrame(
        title: Text(t.srt_import),
        content: _buildForm(),
        actions: [
          // 漫画入口（「OCR 导入漫画」/「在线目录」）均已移出书籍导入框：
          // OCR 归 [MangaImportDialog]，在线目录归下载页。书籍框只做书。
          adaptiveDialogAction(
            context: context,
            onPressed: () => Navigator.pop(context),
            child: Text(t.dialog_cancel),
          ),
          buildImportAction(context, onImport: _doImport),
        ],
      ),
    );
  }

  /// 选/拖进来的路径若其实是漫画载体，弹一次明确确认并转交 [MangaImportDialog]。
  ///
  /// 返回 `true` 表示「本路径已被漫画流程接手，书籍侧不要再收下它」——用户在确认
  /// 框里点取消也算接手（不继续按书导入，那只会产出一本乱码书）。
  ///
  /// 为什么书籍入口还要认漫画：图片型 `.zip` / 扫描版 `.epub` 与词典包/普通电子书
  /// 同形，拖到书架时分类层按扩展名归 books（它刻意不为每次拖 EPUB 白开一次包）。
  /// 此前这里是**静默**转漫画导入；现在改成用户可见的一次确认——识别照旧，分派不
  /// 再背着用户发生。
  Future<bool> _handoffIfManga(String path) async {
    if (!_classifyCarrier(path).isManga) return false;
    final bool? go = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(t.manga_import_detected_title),
        content: Text(
          t.manga_import_detected_message(name: p.basename(path)),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.dialog_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.manga_import_detected_confirm),
          ),
        ],
      ),
    );
    if (go != true || !mounted) return true;

    final bool? imported = await showAppDialog<bool>(
      context: context,
      builder: (_) => MangaImportDialog(db: widget.db, initialPath: path),
    );
    if (mounted) {
      // 关掉书籍框并把漫画侧的导入结果透传出去，书架照常刷新。
      Navigator.pop(context, imported == true);
    }
    return true;
  }

  /// 判定一个待导入路径的载体身份。文件系统判据在此注入，分类函数本身不碰 IO。
  ///
  /// 走 [ImportCarrierResolver] 而不是每次裸调 `classifyImportCarrier`：同一路径在一次
  /// 导入里会被问到三次（选中闸门 / `_doImport` 兜底闸门 / `_importEpubOnly` 分派），
  /// 而 `.zip` / `.epub` 的定性要真开包，问三次就整包解压三次。有声书对齐路径尤其亏
  /// ——它不进 `_importEpubOnly`，那几次开包纯属白开。记忆按路径失效，换文件会重算。
  late final ImportCarrierResolver _carrierResolver;

  ImportCarrier _classifyCarrier(String path) => _carrierResolver.resolve(path);

  /// 拖文件进本对话框 → 分类 → 按字段覆盖（仅填命中类，不清用户已选）。
  /// 纯解析交给 [resolveBookDialogDrop]；此处只 setState + sidecar/封面副作用。
  Future<void> _handleDialogDrop(List<String> paths, Offset _) async {
    if (importing) return;
    final DroppedFiles files = classifyDroppedFiles(paths);
    final BookDialogDropResult r = resolveBookDialogDrop(files);
    if (r.isEmpty) return;
    final String? droppedEpub = r.epubPath;
    // 拖进来的「书」其实是漫画（图片型 zip / 扫描版 epub）→ 确认后转交漫画流程。
    if (droppedEpub != null && await _handoffIfManga(droppedEpub)) return;
    if (!mounted) return;
    final bool gotAudio = r.audioPaths.isNotEmpty;
    setState(() {
      if (droppedEpub != null) {
        _epubPath = droppedEpub;
        _epubName = p.basename(droppedEpub);
        _autoFillTitle(
            p.basenameWithoutExtension(droppedEpub), ImportTitleSource.epub);
      }
      if (r.subtitlePath != null) {
        _subtitlePath = r.subtitlePath;
        _subtitleName = p.basename(r.subtitlePath!);
      }
      if (gotAudio) {
        _audioPaths = r.audioPaths;
        _audioCoverPath = null;
      }
    });
    // 拖入主书文件时顺带扫同目录 sidecar（仅填空、不覆盖）；拖入音频时抽内嵌封面。
    if (droppedEpub != null) {
      _autoAttachSidecars(droppedEpub);
    }
    if (gotAudio) {
      if (_coverPath == null) {
        _tryExtractAudioCover();
      }
      _tryExtractAudioMetadata();
    }
  }

  Widget _buildForm() {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          t.srt_import_hint_epub_or_srt,
          style: tokens.type.metadata,
        ),
        SizedBox(height: tokens.spacing.gap),
        AdaptiveSettingsSection(
          children: [
            _epubRow(),
            _subtitleRow(),
            _audioRow(),
            _coverRow(),
          ],
        ),
        if (isDesktopPlatform && _audioPaths.isNotEmpty) ...[
          SizedBox(height: tokens.spacing.gap),
          AdaptiveSettingsSection(
            children: [
              AdaptiveSettingsSwitchRow(
                title: t.audiobook_reference_original,
                subtitle: t.audiobook_reference_original_desc,
                icon: Icons.link_outlined,
                value: _referenceOriginal,
                onChanged: importing
                    ? null
                    : (bool v) => setState(() => _referenceOriginal = v),
              ),
            ],
          ),
        ],
        SizedBox(height: tokens.spacing.rowVertical),
        HibikiTextField(
          controller: _titleCtrl,
          labelText: t.srt_import_title_hint,
          // 用户一旦在标题框手打即锁定来源为 user，此后重选文件不再覆盖（TODO-1362）。
          // Flutter 不会为程序化的 controller.text= 触发 onChanged，故仅真实用户输入
          // （含屏幕键盘/粘贴，经 HibikiTextField 转发）才置 user。
          onChanged: (String _) => _titleSource = ImportTitleSource.user,
        ),
        SizedBox(height: tokens.spacing.gap),
        HibikiTextField(
          controller: _authorCtrl,
          labelText: t.srt_import_author_hint,
        ),
        if (_willRunMatcher) ...[
          SizedBox(height: tokens.spacing.rowVertical),
          AdaptiveSettingsSection(
            children: [
              AdaptiveSettingsSwitchRow(
                title: t.auto_select_search_window,
                subtitle: t.auto_select_search_window_hint,
                value: _autoWindow,
                onChanged: importing
                    ? null
                    : (bool value) => setState(() => _autoWindow = value),
              ),
            ],
          ),
          if (!_autoWindow) ...[
            SizedBox(height: tokens.spacing.gap),
            SubtitleRematchWindowSlider(
              value: _searchWindow,
              onChanged: (v) => setState(() => _searchWindow = v),
            ),
            SizedBox(height: tokens.spacing.gap),
            SubtitleRematchThresholdSlider(
              value: _similarityThreshold,
              onChanged: (v) => setState(() => _similarityThreshold = v),
            ),
          ],
        ],
        if (importing) ...buildProgressSection(context, tokens),
      ],
    );
  }

  Widget _epubRow() {
    return HibikiFilePickerRow(
      title: t.srt_import_pick_epub,
      subtitle: _epubPath == null ? null : _epubName ?? p.basename(_epubPath!),
      icon: Icons.menu_book_outlined,
      onTap: () => _pickEpub(),
      actions: [
        HibikiIconButton(
          icon: Icons.menu_book_outlined,
          tooltip: t.srt_import_pick_epub,
          isWideTapArea: true,
          onTap: _pickEpub,
        ),
      ],
    );
  }

  Widget _subtitleRow() {
    return HibikiFilePickerRow(
      title: t.srt_import_pick_subtitle_files,
      subtitle: _subtitlePath == null
          ? null
          : _subtitleName ?? p.basename(_subtitlePath!),
      icon: Icons.subtitles_outlined,
      onTap: _pickSubtitle,
      actions: [
        if (_subtitlePath != null)
          HibikiIconButton(
            icon: Icons.close,
            tooltip: t.dialog_clear,
            isWideTapArea: true,
            onTap: () async => setState(() {
              _subtitlePath = null;
              _subtitleName = null;
            }),
          ),
        HibikiIconButton(
          icon: Icons.subtitles_outlined,
          tooltip: t.srt_import_pick_subtitle_files,
          isWideTapArea: true,
          onTap: _pickSubtitle,
        ),
      ],
    );
  }

  Widget _audioRow() {
    return HibikiFilePickerRow(
      title: t.srt_import_pick_audio_files,
      subtitle: _audioPaths.isEmpty
          ? null
          : _audioPaths.length == 1
              ? p.basename(_audioPaths.first)
              : t.file_count(count: _audioPaths.length),
      icon: Icons.audio_file_outlined,
      onTap: _pickAudio,
      actions: [
        if (_audioPaths.isNotEmpty)
          HibikiIconButton(
            icon: Icons.close,
            tooltip: t.dialog_clear,
            isWideTapArea: true,
            onTap: () async => setState(() {
              _audioPaths = [];
              _audioCoverPath = null;
            }),
          ),
        HibikiIconButton(
          icon: Icons.audio_file_outlined,
          tooltip: t.srt_import_pick_audio_files,
          isWideTapArea: true,
          onTap: _pickAudio,
        ),
      ],
    );
  }

  // ── 文件/目录选择 ────────────────────────────────────────────────────────

  static final List<String> _bookExtensions = [
    'epub',
    // PDF 阅读器 Phase 1：PDF 走独立 PdfImporter（真渲染，不经 TextToEpub 文本转换），
    // 在 [_importEpubOnly] 里按 .pdf 扩展名分支。
    'pdf',
    // 漫画扩展名仍留在书籍选择器里，但**不再由本框导入**：选中后 [_handoffIfManga]
    // 弹一次确认并转交 [MangaImportDialog]。留着是为了不打断老习惯——用户从书架
    // 「导入书籍」里选到一本漫画时，得到的是一句「这是漫画」而不是「格式不支持」。
    // `.zip` / `.epub` 无论如何都得留（图片型压缩包与词典包/普通电子书同形）。
    'mokuro',
    'cbz',
    'zip',
    ...TextToEpub.supportedExtensions,
  ];

  Future<void> _pickEpub({bool anyFile = false}) async {
    if (_pickerActive) return;
    _pickerActive = true;
    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: anyFile ? FileType.any : FileType.custom,
        allowedExtensions: anyFile ? null : _bookExtensions,
      );
      final PlatformFile? file = result?.files.single;
      final String? path = file?.path;
      if (path != null && file != null && mounted) {
        // 选中的其实是漫画载体 → 明确确认后转交漫画流程，不再静默按书导入。
        if (await _handoffIfManga(path)) return;
        if (!mounted) return;
        setState(() {
          _epubPath = path;
          _epubName = file.name;
          _autoFillTitle(
            file.name.replaceAll(
                RegExp(
                    r'\.(epub|pdf|mokuro|cbz|zip|txt|html?|xhtml|md|markdown|rst|org|csv|tsv|log|json|xml)$',
                    caseSensitive: false),
                ''),
            ImportTitleSource.epub,
          );
        });
        await _autoAttachSidecars(path);
      }
    } finally {
      _pickerActive = false;
    }
  }

  /// 选中主书文件后，扫同目录同名字幕/音频自动填进对应行（仅填空、不覆盖
  /// 用户手选）。音频必须配字幕，故仅在字幕已就位时才填音频。桌面端有效；
  /// 移动端是缓存副本目录、扫不到兄弟文件，[findSidecars] 静默返回空。
  Future<void> _autoAttachSidecars(String mainPath) async {
    final SidecarMatch m = await findSidecars(mainPath);
    if (!mounted || m.isEmpty) return;
    bool attachedSub = false;
    bool attachedAudio = false;
    setState(() {
      if (_subtitlePath == null && m.subtitlePath != null) {
        _subtitlePath = m.subtitlePath;
        _subtitleName = p.basename(m.subtitlePath!);
        attachedSub = true;
      }
      final bool hasSub = _subtitlePath != null;
      if (_audioPaths.isEmpty && hasSub && m.audioPaths.isNotEmpty) {
        _audioPaths = m.audioPaths;
        attachedAudio = true;
      }
    });
    if (attachedAudio) {
      if (_coverPath == null) {
        await _tryExtractAudioCover();
      }
      await _tryExtractAudioMetadata();
    }
    final List<String> parts = <String>[
      if (attachedSub)
        t.import_sidecar_subtitle(name: p.basename(_subtitlePath!)),
      if (attachedAudio) t.import_sidecar_audio(count: _audioPaths.length),
    ];
    if (parts.isNotEmpty && mounted) {
      HibikiToast.show(
        msg: parts.join(' · '),
        severity: ToastSeverity.info,
      );
    }
  }

  static const Set<String> _subtitleExtensions = {
    'srt',
    'lrc',
    'vtt',
    'ass',
    'ssa',
  };

  Future<void> _pickSubtitle() async {
    if (_pickerActive) return;
    _pickerActive = true;
    try {
      // 字幕导入时即被解析成 cues / 生成 EPUB 当场消费，不以绝对路径长期引用，故维持
      // 系统文件选择器（board 1360）：用户熟悉，且能触达 Downloads / 云盘 / 最近文件。
      final String? path = await pickSystemFilePath(
        context: context,
        allowedExtensions: _subtitleExtensions,
      );
      if (path == null || !mounted) return;
      final String ext = p.extension(path).toLowerCase().replaceFirst('.', '');
      if (!_subtitleExtensions.contains(ext)) {
        HibikiToast.show(
          msg: t.import_unsupported_file_format(ext: '.$ext'),
          severity: ToastSeverity.error,
        );
        return;
      }

      setState(() {
        _subtitlePath = path;
        _subtitleName = p.basename(path);
        final String name = p.basename(path);
        final int dot = name.lastIndexOf('.');
        _autoFillTitle(dot > 0 ? name.substring(0, dot) : name,
            ImportTitleSource.subtitle);
      });
    } finally {
      _pickerActive = false;
    }
  }

  Future<void> _pickAudio() async {
    if (_pickerActive) return;
    _pickerActive = true;
    try {
      final AppModel appModel =
          ProviderScope.containerOf(context, listen: false).read(appProvider);
      final List<String> paths = await pickRealFilePaths(
        context: context,
        appModel: appModel,
        allowedExtensions: AudiobookStorage.audioExtensionsNoDot,
      );
      if (!mounted) return;
      paths.sort(compareAudioFilePath);

      if (paths.isNotEmpty) {
        setState(() {
          _audioPaths = paths;
          _audioCoverPath = null;
        });
        if (_coverPath == null) {
          await _tryExtractAudioCover();
        }
        await _tryExtractAudioMetadata();
      }
    } finally {
      _pickerActive = false;
    }
  }

  /// 启动内嵌封面抽取，并把在途 Future 存进 [_coverExtraction]，使无论调用方
  /// fire-and-forget 还是 await，导入时 [_applyBestCoverToEpub] 都能 await 同一个
  /// Future 后再读 [_audioCoverPath]（已完成则零等待）。返回该 Future 以兼容仍想
  /// await 的调用点。
  Future<void> _tryExtractAudioCover() {
    // TODO-1034 次要：fire-and-forget 多次触发时，给每次抽取发一个单调递增 token；
    // 只有「仍是最新一次」的抽取才允许写 _audioCoverPath，避免晚到的旧抽取覆盖新封面。
    final int token = ++_coverExtractionToken;
    final Future<void> extraction = _runCoverExtraction(token);
    _coverExtraction = extraction;
    return extraction;
  }

  /// 等内嵌封面抽取（可能仍在途）落定，使读取 [_audioCoverPath] 不会在 ffmpeg
  /// probe 未返回时拿到 null 把封面吞掉（BUG-483 / TODO-1034）。已完成则零等待。
  /// 主路径 [_applyBestCoverToEpub] 与字幕书+m4b 路径 [_importSubtitleBook] 共用。
  Future<void> _awaitCoverExtraction() async {
    final Future<void>? extraction = _coverExtraction;
    if (extraction != null) {
      await extraction;
    }
  }

  Future<void> _runCoverExtraction(int token) async {
    if (_audioPaths.isEmpty) return;
    final Directory tmpDir = await getTemporaryDirectory();
    final String outputPath = p.join(
      tmpDir.path,
      'audio_cover_${DateTime.now().millisecondsSinceEpoch}.jpg',
    );
    for (final String audioPath in _audioPaths) {
      final String? result = await TtsChannel.instance.extractEmbeddedCover(
        audioPath: audioPath,
        outputPath: outputPath,
      );
      if (result != null && mounted && token == _coverExtractionToken) {
        setState(() => _audioCoverPath = result);
        return;
      }
    }
  }

  /// TODO-1045：从第一个含 tag 的音频容器（M4B/M4A/MP3…）读标题/作者，**仅当对应
  /// 输入框为空时**回填（复用 sidecar 的「填空不覆盖」闸门，绝不覆盖用户手打的值）。
  ///
  /// 与封面抽取同触发点、并行独立一趟：封面走 ffmpeg 抽帧、元数据走 ffprobe，本就是
  /// 两个可执行/两次进程，无法共用一次 spawn。缺 ffprobe / 无 tag 时
  /// [TtsChannel.extractAudioMetadata] 返回 null，保留文件名兜底。全程 mounted 检查
  /// + setState；「仅填空」闸门天然避免异步竞态覆盖用户已手打的值。
  ///
  /// 身份安全：自动填的标题只写进导入前可编辑的 [_titleCtrl]，与既有「标题来自文件名
  /// 兜底」同语义时机——bookKey=sanitizeTtuFilename(title) 仍由用户可见/可改的标题派生，
  /// 零新增身份风险。
  Future<void> _tryExtractAudioMetadata() async {
    if (_audioPaths.isEmpty) return;
    // 两框都已填就无事可做（避免无谓 ffprobe 进程）。
    if (_titleCtrl.text.isNotEmpty && _authorCtrl.text.isNotEmpty) return;
    for (final String audioPath in _audioPaths) {
      final AudioMetadata? meta =
          await TtsChannel.instance.extractAudioMetadata(audioPath: audioPath);
      if (meta == null) continue;
      if (!mounted) return;
      final bool fillAuthor = _authorCtrl.text.isEmpty && meta.author != null;
      if (meta.title != null || fillAuthor) {
        setState(() {
          if (meta.title != null) {
            _autoFillTitle(meta.title!, ImportTitleSource.metadata);
          }
          if (fillAuthor) _authorCtrl.text = meta.author!;
        });
      }
      // 找到首个含可用 tag 的文件即停（多文件有声书用第一段的容器 tag）。
      if (meta.title != null || meta.author != null) return;
    }
  }

  Widget _coverRow() {
    final String? effectiveCover = _coverPath ?? _audioCoverPath;
    return HibikiFilePickerRow(
      title: t.srt_import_pick_cover,
      subtitle: effectiveCover == null ? null : p.basename(effectiveCover),
      icon: Icons.image_outlined,
      onTap: _pickCover,
      actions: [
        if (effectiveCover != null)
          HibikiIconButton(
            icon: Icons.close,
            tooltip: t.dialog_clear,
            isWideTapArea: true,
            onTap: () async => setState(() {
              _coverPath = null;
              _audioCoverPath = null;
            }),
          ),
        HibikiIconButton(
          icon: Icons.image_outlined,
          tooltip: t.srt_import_pick_cover,
          isWideTapArea: true,
          onTap: _pickCover,
        ),
      ],
    );
  }

  Future<void> _pickCover() async {
    if (_pickerActive) return;
    _pickerActive = true;
    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.image,
      );
      if (result == null || !mounted) return;
      final String? path = result.files.first.path;
      if (path != null) {
        setState(() => _coverPath = path);
      }
    } finally {
      _pickerActive = false;
    }
  }

  /// 把封面图写进 EPUB **解压目录内**（`<extractDir>/cover<ext>`）并落库相对名
  /// `coverPath`——这是「EPUB 包内容的一部分」，不是三岛的独立封面文件
  /// （thumbnails/ / video_covers/ / game_covers/），目录与键派生都不同。
  /// 写盘仍走统一收口 [MediaCoverService.applyCoverFile]：导入时 extractDir 是
  /// 新目录、该路径此前从未被解码（驱逐是空操作），但收口保证将来任何「同路径
  /// 重写封面」的调用形态都自动满足「写盘→双键驱逐」不变量。
  Future<void> _applyCoverToEpub(String bookKey, {String? sourcePath}) async {
    final String source = sourcePath ?? _coverPath!;
    // Locate the extracted dir via the stored extract_dir column (the on-disk
    // folder name may still be a legacy int id; the column is the truth).
    final EpubBookRow? row = await widget.db.getEpubBook(bookKey);
    if (row == null) return;
    final String extractDir = row.extractDir;
    final String ext = p.extension(source);
    final String dest = p.join(extractDir, 'cover$ext');
    await MediaCoverService.applyCoverFile(
      source: File(source),
      destPath: dest,
    );
    await (widget.db.update(widget.db.epubBooks)
          ..where((tbl) => tbl.bookKey.equals(bookKey)))
        .write(EpubBooksCompanion(coverPath: Value('cover$ext')));
  }

  Future<bool> _epubHasCover(String bookKey) async {
    final row = await (widget.db.select(widget.db.epubBooks)
          ..where((tbl) => tbl.bookKey.equals(bookKey)))
        .getSingleOrNull();
    return row?.coverPath != null;
  }

  // ── 导入 ────────────────────────────────────────────────────────────────

  /// 同名书弹窗回调，喂给 [EpubImporter]。是→加后缀，否/关闭→取消这本书。
  Future<DuplicateChoice> _askOnDuplicate(
    String proposedTitle,
  ) async {
    if (!mounted) return DuplicateChoice.cancel;
    final bool? keep = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(t.book_import_duplicate_title),
        content: Text(t.book_import_duplicate_message(name: proposedTitle)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.book_import_duplicate_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.book_import_duplicate_keep),
          ),
        ],
      ),
    );
    return keep == true ? DuplicateChoice.suffix : DuplicateChoice.cancel;
  }

  Future<void> _doImport() async {
    if (_epubPath == null && !_hasSubtitles) {
      HibikiToast.show(
        msg: t.srt_import_missing_input,
        severity: ToastSeverity.error,
      );
      return;
    }
    // 兜底闸门：选/拖两条入口在收下路径时就已过 [_handoffIfManga]，但 initialEpubPath
    // 是构造参数直接塞进来的（书架拖入决策层刻意不为每个 EPUB 开包，图片型 .epub 会
    // 以 books 身份到达这里）。同一个闸门在此再守一次，漫画绝不会走进书籍导入分支。
    final String? epubPath = _epubPath;
    if (epubPath != null && await _handoffIfManga(epubPath)) return;
    if (!mounted) return;
    if (_epubPath != null && !_hasSubtitles && _audioPaths.isNotEmpty) {
      HibikiToast.show(
        msg: t.srt_import_audio_needs_subtitle,
        severity: ToastSeverity.error,
      );
      return;
    }
    final String title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      HibikiToast.show(
        msg: t.srt_import_missing_title,
        severity: ToastSeverity.error,
      );
      return;
    }

    // 失败日志/toast/importing 复位收敛到 ImportFlowMixin.runImport 模板；
    // 同名弹窗选「否」不是错误，走 isCancelled 分支只提示取消并 pop(false)。
    await runImport(
      logTag: 'BookImportDialog.import',
      debugMessage: (Object e) => 'BookImportDialog error: $e',
      isCancelled: (Object e) => e is DuplicateImportCancelledException,
      onCancelled: () {
        if (mounted) {
          HibikiToast.show(
            msg: t.book_import_duplicate_cancelled,
            severity: ToastSeverity.info,
          );
          Navigator.pop(context, false);
        }
      },
      action: () async {
        reportProgress(0, '');
        final String? authorText =
            _authorCtrl.text.trim().isEmpty ? null : _authorCtrl.text.trim();

        debugPrint(
            '[hibiki-import] route: epub=$_epubPath sub=$_subtitlePath audio=${_audioPaths.length} files');
        String? tail;
        if (_epubPath != null && _hasSubtitles) {
          debugPrint('[hibiki-import] → _importEpubWithAlignment');
          tail = await _importEpubWithAlignment(title: title);
        } else if (_hasSubtitles) {
          debugPrint('[hibiki-import] → _importSubtitleBook');
          await _importSubtitleBook(title: title, author: authorText);
        } else {
          debugPrint('[hibiki-import] → _importEpubOnly');
          await _importEpubOnly(title: title);
        }

        if (mounted) {
          final String msg = tail == null
              ? t.srt_import_success
              : '${t.srt_import_success} · $tail';
          HibikiToast.show(msg: msg, severity: ToastSeverity.success);
          Navigator.pop(context, true);
        }
      },
    );
  }

  Future<void> _importSubtitleBook({
    required String title,
    required String? author,
  }) async {
    final String uid = 'srtbook_${DateTime.now().millisecondsSinceEpoch}';
    reportProgress(0.1, t.import_step_parsing);

    final List<AudioCue> cues = await parseCuesForFormat(
      File(_subtitlePath!),
      uid,
      0,
    );
    debugPrint('[hibiki-import] subtitleBook: parsed ${cues.length} cues');

    String bookKey = '';
    if (cues.isNotEmpty) {
      try {
        reportProgress(0.3, t.import_step_building_epub);
        final Directory tmpDir = await getTemporaryDirectory();
        final String epubPath = p.join(tmpDir.path, 'cues_to_epub_$uid.epub');
        await CuesToEpub.convert(
          title: title,
          cues: cues,
          outputPath: epubPath,
          author: author,
        );
        reportProgress(0.5, t.import_step_importing_epub);
        bookKey = await EpubImporter.importFromPath(
          db: widget.db,
          filePath: epubPath,
          fileName: '${title.replaceAll(RegExp(r'[^\w\s\-]'), '')}.epub',
          policy: DuplicatePolicy.ask(_askOnDuplicate),
        );
        debugPrint(
            '[hibiki-import] subtitleBook: EPUB import done, key=$bookKey');
      } on DuplicateImportCancelledException {
        // 取消必须冒泡到顶层中止整次导入，不能被吞成 bookId=0 继续。
        rethrow;
      } catch (e, stack) {
        // BUG-439：坏 EPUB（FormatException 等）以前在这里被吞掉、bookKey 留空串，
        // 下面仍无条件 save 出一条没有 EpubBooks 行的孤儿 SrtBook 壳行——书架有卡
        // 却打不开（reader 定位磁盘返回 exists:false → book_file_not_found）。
        // EPUB 是字幕书的正文载体，载体生成/导入失败这本书就不可读，必须让整次
        // 导入失败而不是落孤儿壳行。与上面的取消同理冒泡到顶层报错。
        ErrorLogService.instance.log('BookImportDialog.epubImport', e, stack);
        debugPrint('[hibiki-import] EPUB generation/import failed: $e');
        rethrow;
      }
    }

    reportProgress(0.7, t.import_step_persisting);
    final Directory persistDir = await _ensurePersistDir(uid);
    final String persistedSrt = await AudiobookStorage.persistFileWithProgress(
      File(_subtitlePath!),
      persistDir,
      onProgress: (int copied, int total) {
        reportProgress(
            0.7, t.import_step_copying_file(name: p.basename(_subtitlePath!)));
      },
    );

    // TODO-935 ①A：引用模式（仅桌面）直接存原始绝对路径，不复制（仿 VideoBooks）。
    final bool referenceAudio = _referenceOriginal && isDesktopPlatform;
    await AudiobookStorage.cleanAudioFiles(persistDir);
    final List<String> persistedAudioPaths = [];
    if (referenceAudio) {
      persistedAudioPaths.addAll(_audioPaths);
    } else {
      for (final String src in _audioPaths) {
        persistedAudioPaths.add(
          await AudiobookStorage.persistFileWithProgress(
            File(src),
            persistDir,
            onProgress: (int copied, int total) {
              reportProgress(
                  0.8, t.import_step_copying_file(name: p.basename(src)));
            },
          ),
        );
      }
    }

    reportProgress(0.9, t.import_step_saving);
    final SrtBook book = SrtBook()
      ..uid = uid
      ..title = title
      ..srtPath = persistedSrt
      ..importedAt = DateTime.now().millisecondsSinceEpoch
      ..bookKey = bookKey;
    if (persistedAudioPaths.isNotEmpty) {
      book.audioPaths = persistedAudioPaths;
    }
    if (author != null) {
      book.author = author;
    }
    // TODO-1034：与主路径同根因——读 _audioCoverPath 前必须先等内嵌封面抽取落定，
    // 否则用户在 ffmpeg probe 未返回时点「导入」会把封面吞掉。
    await _awaitCoverExtraction();
    final String? coverSource = _coverPath ?? _audioCoverPath;
    if (coverSource != null) {
      final String ext = p.extension(coverSource);
      final String dest = p.join(persistDir.path, 'cover$ext');
      await File(coverSource).copy(dest);
      book.coverPath = dest;
    }

    debugPrint('[hibiki-import] SrtBook save: uid=$uid title="$title" '
        'bookKey=$bookKey cues=${cues.length}');

    await widget.repo.save(book);
    await widget.repo.saveCues(uid: uid, cues: cues);
    reportProgress(1, t.import_step_done);
  }

  Future<void> _importEpubOnly({required String title}) async {
    final File file = File(_epubPath!);

    reportProgress(0.2, t.import_step_reading);

    // 载体身份此前是在这里靠 4 个 if（含一次真读包）现场嗅出来的；现在它在**选中
    // 文件那一刻**就已由 [classifyImportCarrier] 定死，且漫画载体根本进不来（三个
    // 入口都过 [_handoffIfManga]）。这里只剩书籍侧的三种去向。
    final ImportCarrier carrier = _classifyCarrier(_epubPath!);

    // PDF 阅读器 Phase 1：.pdf 走独立 PdfImporter（pdfrx 真渲染 + 落库 format='pdf'）。
    // PDF 封面在 PdfImporter 内栅格化首页得到，故不走 _applyBestCoverToEpub。
    if (carrier == ImportCarrier.pdf) {
      reportProgress(0.5, t.import_step_importing_epub);
      await PdfImporter.importFromPath(
        db: widget.db,
        filePath: _epubPath!,
        fileName: _epubName ?? p.basename(_epubPath!),
        title: title,
        policy: DuplicatePolicy.ask(_askOnDuplicate),
      );
      reportProgress(1, t.import_step_done);
      return;
    }

    final String bookKey;
    if (carrier == ImportCarrier.text) {
      reportProgress(0.3, t.import_step_converting_epub);
      final Uint8List bytes =
          await TextToEpub.convert(file: file, title: title);
      final String filename =
          '${title.replaceAll(RegExp(r'[^\w\s\-]'), '')}.epub';
      reportProgress(0.5, t.import_step_importing_epub);
      bookKey = await EpubImporter.import(
        db: widget.db,
        bytes: bytes,
        fileName: filename,
        policy: DuplicatePolicy.ask(_askOnDuplicate),
      );
    } else {
      reportProgress(0.5, t.import_step_importing_epub);
      bookKey = await EpubImporter.importFromPath(
        db: widget.db,
        filePath: _epubPath!,
        fileName: _epubName ?? p.basename(_epubPath!),
        policy: DuplicatePolicy.ask(_askOnDuplicate),
      );
    }

    await _applyBestCoverToEpub(bookKey);
    reportProgress(1, t.import_step_done);
  }

  Future<void> _applyBestCoverToEpub(String bookKey) async {
    // 等内嵌封面抽取（可能仍在途）落定再判断，否则用户在 ffmpeg 未返回时点导入会把
    // _audioCoverPath 当 null 吞掉封面（BUG-483）。已完成则零等待。
    await _awaitCoverExtraction();
    if (_coverPath != null) {
      await _applyCoverToEpub(bookKey);
    } else if (_audioCoverPath != null && !(await _epubHasCover(bookKey))) {
      await _applyCoverToEpub(bookKey, sourcePath: _audioCoverPath);
    }
  }

  Future<String?> _importEpubWithAlignment({required String title}) async {
    final File epubFile = File(_epubPath!);

    reportProgress(0.05, t.import_step_reading);
    final String bookKey;
    if (TextToEpub.isSupported(_epubPath!)) {
      reportProgress(0.1, t.import_step_converting_epub);
      final Uint8List importBytes =
          await TextToEpub.convert(file: epubFile, title: title);
      final String importFilename =
          '${title.replaceAll(RegExp(r'[^\w\s\-]'), '')}.epub';
      reportProgress(0.2, t.import_step_importing_epub);
      bookKey = await EpubImporter.import(
        db: widget.db,
        bytes: importBytes,
        fileName: importFilename,
        policy: DuplicatePolicy.ask(_askOnDuplicate),
      );
    } else {
      reportProgress(0.2, t.import_step_importing_epub);
      bookKey = await EpubImporter.importFromPath(
        db: widget.db,
        filePath: _epubPath!,
        fileName: _epubName ?? p.basename(_epubPath!),
        policy: DuplicatePolicy.ask(_askOnDuplicate),
      );
    }

    await _applyBestCoverToEpub(bookKey);

    // EPUB 导入之后的对齐落库下沉到非 UI 的 alignAndPersistAudiobook：解析章节、
    // 解析 cue、跑 matcher、持久字幕/音频、写 Audiobooks + 配对 SrtBook + cue +
    // health overlay。对话框只把进度/文案/字段透传给 service，行为逐字节等价。
    final AudiobookAlignmentResult result = await alignAndPersistAudiobook(
      db: widget.db,
      repo: widget.repo,
      audiobookRepo: widget.audiobookRepo,
      bookKey: bookKey,
      title: title,
      author: _authorCtrl.text.trim().isEmpty ? null : _authorCtrl.text.trim(),
      subtitlePath: _subtitlePath!,
      audioPaths: _audioPaths,
      autoWindow: _autoWindow,
      searchWindow: _searchWindow,
      similarityThreshold: _similarityThreshold,
      onProgress: reportProgress,
      messages: AudiobookAlignmentMessages(
        readingIdb: t.import_step_reading_idb,
        parsing: t.import_step_parsing,
        matching: t.import_step_matching,
        persisting: t.import_step_persisting,
        saving: t.import_step_saving,
        done: t.import_step_done,
        copyingFile: (String name) => t.import_step_copying_file(name: name),
      ),
    );

    return summarizeAudiobookHealth(result.health);
  }

  Future<Directory> _ensurePersistDir(String key) =>
      AudiobookStorage.ensurePersistDir(key);
}

@visibleForTesting
class BookImportDialogFrame extends StatelessWidget {
  const BookImportDialogFrame({
    required this.title,
    required this.content,
    required this.actions,
    super.key,
  });

  final Widget title;
  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return ImportDialogFrame(
      leadingIcon: Icons.library_add_outlined,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          DefaultTextStyle.merge(
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: tokens.type.listTitle.copyWith(
              fontWeight: FontWeight.w600,
            ),
            child: title,
          ),
          SizedBox(height: tokens.spacing.gap),
          content,
        ],
      ),
      actions: actions,
    );
  }
}

/// 导入对话框标题框内容的来源。优先级不是全序：规则是「同来源重选或标题为空才刷新」，
/// 跨来源保持既有「非空即不覆盖」语义（见 [resolveImportTitle]，TODO-1362）。
enum ImportTitleSource {
  /// 标题框为空、从未被任何来源填过。
  none,

  /// 从内嵌音频标签（M4B/MP3 等）自动读出的标题（TODO-1045）。
  metadata,

  /// 从字幕文件名派生的标题。
  subtitle,

  /// 从书文件（EPUB / txt 等）文件名派生的标题。
  epub,

  /// 用户在标题框手动输入的标题——永不被自动派生覆盖。
  user,
}

/// 选/重选导入文件后，标题框应显示的书名及其来源（纯函数，TODO-1362 可测核心）。
///
/// 「先选魔眼再重选尸人、下方书名不刷新」的根因是各选文件点仅在标题为空时回填，
/// 一旦有了自动派生书名，重选便永不更新。此函数用来源身份取代「仅空时回填」：
/// - 标题被用户手打过（[currentSource] == user 且非空）→ 永不覆盖，尊重用户输入。
/// - 标题为空、或本次来源 [incoming] 与当前来源相同（同槽位重选换一本）→ 刷新为
///   新派生的 [derived]。
/// - 否则（跨来源且标题非空，如已有 epub 书名时又选了字幕/读到音频标签）→ 保持不变，
///   与旧「非空即不覆盖」行为逐位等价，零跨来源回归。
@visibleForTesting
({String text, ImportTitleSource source}) resolveImportTitle({
  required String currentText,
  required ImportTitleSource currentSource,
  required ImportTitleSource incoming,
  required String derived,
}) {
  final bool userOwned =
      currentSource == ImportTitleSource.user && currentText.isNotEmpty;
  if (!userOwned && (currentText.isEmpty || incoming == currentSource)) {
    return (text: derived, source: incoming);
  }
  return (text: currentText, source: currentSource);
}
