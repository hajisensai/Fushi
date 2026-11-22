import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:path/path.dart' as p;
import 'package:fushi/src/media/drag_drop/drop_classification.dart';
import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart';
import 'package:fushi/src/media/drag_drop/import_dialog_drop.dart';
import 'package:fushi_asr_core/asr_core.dart';
import 'package:fushi/src/asr_host/asr_host.dart';
import 'package:fushi/src/media/audiobook/asr_transcribe_sheet.dart';
import 'package:fushi_engine/media/audiobook/audiobook_alignment_service.dart';
import 'package:fushi_engine/media/audiobook/audiobook_subtitle_formats.dart';
import 'package:fushi_engine/media/audiobook/standalone_subtitle_book.dart';
import 'package:fushi/src/media/audiobook/subtitle_rematch.dart';
import 'package:fushi_engine/media/audiobook/text_to_epub.dart';
import 'package:fushi_engine/media/book_archive/book_archive_import.dart'
    show isBookArchiveContainerPath, looksLikeBookArchive;
import 'package:fushi/src/media/import/book_archive_import_dialog.dart';
import 'package:fushi/src/media/import/audiobook_health_summary.dart';
import 'package:fushi/src/media/import/import_carrier.dart';
import 'package:fushi/src/media/import/import_dialog_blocks.dart';
import 'package:fushi/src/media/import/import_dialog_frame.dart';
import 'package:fushi/src/media/import/import_surface_spec.dart';
import 'package:fushi/src/media/import/import_flow_mixin.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/media/import/sidecar_finder.dart';
import 'package:fushi/src/media/media_cover_service.dart';
import 'package:fushi_engine/media/cover_file_writer.dart'
    show CoverImageInvalidException;
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi_engine/epub/book_title_conflict.dart';
import 'package:fushi_engine/epub/epub_importer.dart';
import 'package:fushi_engine/epub/epub_parser.dart';
import 'package:fushi/src/media/manga/manga_import_dialog.dart';
import 'package:fushi/src/media/manga/manga_module.dart';
import 'package:fushi/src/pdf/pdf_importer.dart';
import 'package:fushi/src/utils/components/fushi_staggered_entrance.dart';
import 'package:fushi/src/utils/cover_image.dart' show resizedFileImage;
import 'package:fushi/src/utils/components/glass/fushi_icon.dart';
import 'package:fushi/src/utils/fushi_icons.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_inline_notice.dart';
import 'package:fushi/src/utils/components/fushi_m3e_list_card.dart';
import 'package:fushi/src/utils/components/fushi_m3e_overlays.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/components/fushi_motion_tokens.dart';
import 'package:fushi/src/utils/components/fushi_typography.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_buttons.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_feedback.dart';
import 'package:fushi/src/utils/components/glass/fushi_glass_overlays.dart';
import 'package:fushi/src/utils/components/settings_shared.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi/src/utils/misc/tts_channel.dart';

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
    this.prefs,
    required this.repo,
    required this.audiobookRepo,
    required this.db,
    this.initialEpubPath,
    this.initialSubtitlePath,
    this.initialAudioPaths,
    this.imageArchiveProbe,
    this.bookArchiveProbe,
    this.requireBook = false,
    this.pickAudioFirst = false,
    super.key,
  });

  final SrtBookRepository repo;
  final AudiobookRepository audiobookRepo;
  final FushiDatabase db;
  final String? initialEpubPath;
  final String? initialSubtitlePath;

  /// 拖拽导入预填：随新书一起拖入的音频文件路径。EPUB+音频拖到书架空白处时透传，
  /// 否则丢失（书架 `importNewBook` 此前未携带 `files.audios`）。音频仍必配字幕，
  /// 故仅预填展示——`_doImport` 的「音频必须配字幕」校验照旧，只是能转录的平台
  /// 改为弹「字幕来源」（选文件 / 转录）就地补上，不能转录的平台仍要求补字幕
  /// （BUG-2266）。
  final List<String>? initialAudioPaths;

  /// 测试计数缝：生产始终走 [MangaModule.probeImageArchive]（后台 isolate，`.epub`
  /// 探测解进书库根的 `.tmp-*`）；回归测试只在外层计数后委托同一个真判据，证明真实
  /// 对话框没有重复执行昂贵的整包载体判定。
  @visibleForTesting
  final Future<bool> Function(String path)? imageArchiveProbe;

  /// 测试缝：「这个压缩包是不是装着一批书」。生产走引擎 [looksLikeBookArchive]
  /// （zip 读条目名、rar 经 7-Zip 列目录、7z / 分卷第一卷解开后再定性）。
  @visibleForTesting
  final Future<bool> Function(String path)? bookArchiveProbe;

  /// 记住「引用原文件（不复制）」上次选择的偏好仓库（[PreferencesRepository.
  /// audiobookImportReferenceOriginal]）。null = 不读不写（测试 / 无应用上下文）。
  final PreferencesRepository? prefs;

  /// 本次导入必须带书籍文件（「给字幕书添加书籍文件」入口，见
  /// `srt_book_attach_epub.dart`）：字幕与音频已由原书预填，没选书时点导入若照常
  /// 落进字幕书分支，就会悄悄再生成一本与原书一模一样的字幕书。为真时没选书就
  /// 先弹书籍选择器，选了才继续。
  final bool requireBook;

  /// 从导入页「有声书」方式块打开（导入稿 IM15）：对话框一出现就弹音频选择器，
  /// 选完的音频进音频行，字幕 / 转录照常由「只选了音频」提示与导入校验引导补上。
  /// 只是同一个对话框的另一个起点，不另开有声书专用流程。
  final bool pickAudioFirst;
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

  /// 作者框当前内容是否由音频标签自动填入（框下写明来源；用户一改即清）。
  bool _authorAutoFilled = false;

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
  /// 桌面端初值取上次的选择（[PreferencesRepository.audiobookImportReferenceOriginal]）。
  bool _referenceOriginal = false;

  /// 切换「引用原文件」并记住这次选择（下次打开任一导入对话框沿用）。
  void _setReferenceOriginal(bool value) {
    setState(() => _referenceOriginal = value);
    final PreferencesRepository? prefs = widget.prefs;
    if (prefs != null) {
      unawaited(prefs.setAudiobookImportReferenceOriginal(value: value));
    }
  }

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
    _referenceOriginal =
        isDesktopPlatform &&
        (widget.prefs?.audiobookImportReferenceOriginal ?? false);
    _carrierResolver = ImportCarrierResolver(
      isDirectory: (String pth) => Directory(pth).existsSync(),
      // 开包定性只给异步判据：`.epub` 要整本解析 spine 才分得清纯图 / 有正文，在
      // UI isolate 上同步跑，选一本几百 MB 的文字 EPUB 界面就停住；探测的解压落点
      // 也从系统临时目录挪进书库根（崩溃残留归导入残留清扫管）。BUG-4909 遗留。
      probeImageArchive:
          widget.imageArchiveProbe ??
          (String pth) => MangaModule.probeImageArchive(widget.db, pth),
      directoryHasPageImages: MangaModule.directoryHasPageImages,
      directoryCarrierFileCount: MangaModule.directoryCarrierFileCount,
      directoryMokuroFileCount: MangaModule.directoryMokuroFileCount,
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
      unawaited(_fillTitleFromEpubMetadata(epub));
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
    if (widget.pickAudioFirst) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_pickAudio());
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
    return buildImportPopGuard(
      child: FushiFileDropTarget(
        enabled: !importing,
        debugLabel: 'book-import-dialog',
        onDrop: _handleDialogDrop,
        child: BookImportDialogFrame(
          title: t.srt_import,
          subtitle: t.srt_import_hint_epub_or_srt,
          content: _buildForm(),
          actions: [
            // 漫画入口（「OCR 导入漫画」/「在线目录」）均已移出书籍导入框：
            // OCR 归 [MangaImportDialog]，在线目录归下载页。书籍框只做书。
            // 2026-10 体验优化：导入中取消键禁用（见 buildImportPopGuard）。
            buildCancelAction(context),
            buildImportAction(
              context,
              onImport: _doImport,
              enabled: _classifyingCount == 0,
            ),
          ],
        ),
      ),
    );
  }

  /// 选/拖进来的压缩包若装着一批书（一包 EPUB / TXT / PDF，含加密包与分卷包），关掉本框、
  /// 转交「从压缩包导入书」整批导入并给一份汇总（拍板 83Fe7zQbhv）。返回 `true` 表示
  /// 已接手（或这次选择已过期），书籍侧不再收下这个路径。
  ///
  /// 本框只导一本书、要定书名与字幕 / 音频，一包多本放不进这些字段；而一包书逐本弹框
  /// 又正是汇总要消灭的体验，所以整包转交，不在本框里排队。
  Future<bool> _handoffIfBookArchives(
    List<String> paths,
    int generation,
  ) async {
    final List<String> candidates = <String>[
      for (final String path in paths)
        if (isBookArchiveContainerPath(path)) path,
    ];
    if (candidates.isEmpty || !mounted) return false;
    final Future<bool> Function(String path) probe =
        widget.bookArchiveProbe ?? looksLikeBookArchive;
    final List<String> archives = <String>[];
    setState(() => _classifyingCount++);
    try {
      for (final String path in candidates) {
        if (await probe(path)) archives.add(path);
      }
    } finally {
      if (mounted) setState(() => _classifyingCount--);
    }
    if (!mounted || _isStaleSelection(generation)) return true;
    if (archives.isEmpty) return false;
    final bool imported = await showBookArchiveImportDialog(
      context: context,
      db: widget.db,
      paths: archives,
    );
    if (mounted) Navigator.pop(context, imported);
    return true;
  }

  /// 先问「是不是一包书」还是先问「是不是漫画」：`.rar` 光看扩展名就是漫画载体，
  /// 必须先看条目名（一包 TXT 的 rar 不能被转交漫画）；`.zip` 与拖放分类同序，页图包
  /// 优先归漫画。
  static bool _bookArchiveProbeFirst(String path) =>
      p.extension(path).toLowerCase() == '.rar';

  /// 收下一个选 / 拖进来的主文件之前的两道闸门（一包书 / 漫画）。返回 `true` = 已被
  /// 别的流程接手，书籍侧不要再收下它。
  Future<bool> _handoffIfNotSingleBook(String path, int generation) async {
    if (_bookArchiveProbeFirst(path) &&
        await _handoffIfBookArchives(<String>[path], generation)) {
      return true;
    }
    if (await _handoffIfManga(path, generation)) return true;
    if (!_bookArchiveProbeFirst(path) &&
        await _handoffIfBookArchives(<String>[path], generation)) {
      return true;
    }
    return false;
  }

  /// 选/拖进来的路径若其实是漫画载体，弹一次明确确认并转交 [MangaImportDialog]。
  ///
  /// 返回 `true` 表示「本路径已被漫画流程接手，书籍侧不要再收下它」——用户在确认
  /// 框里点取消也算接手。用户选「仍按书籍导入」（仅 [canImportMangaCarrierAsBook]
  /// 放行的载体才有这个按钮）时返回 `false`，并把该路径记进 [_forcedBookPath]。
  ///
  /// 为什么书籍入口还要认漫画：图片型 `.zip` / 扫描版 `.epub` 与词典包/普通电子书
  /// 同形，拖到书架时分类层按扩展名归 books（它刻意不为每次拖 EPUB 白开一次包）。
  /// 此前这里是**静默**转漫画导入；现在改成用户可见的一次确认——识别照旧，分派不
  /// 再背着用户发生。
  ///
  /// [generation] 是发起这次判定时的 [_selectionGeneration]。定性在后台 isolate 里
  /// 跑，回来时对话框可能已经关了、用户又选了别的、或已经点了导入：这时结果作废并
  /// 返回 `true`（调用方不收下这个路径）——过期的「这是漫画」不能再弹确认框，更不能
  /// 把旧路径转交漫画流程、关掉正在导入的书籍框。
  Future<bool> _handoffIfManga(String path, int generation) async {
    if (!mounted) return true;
    setState(() => _classifyingCount++);
    final ImportCarrier carrier;
    try {
      carrier = await _classifyCarrier(path);
    } finally {
      if (mounted) setState(() => _classifyingCount--);
    }
    if (!mounted || _isStaleSelection(generation)) return true;
    if (!carrier.isManga) return false;
    final bool canImportAsBook = canImportMangaCarrierAsBook(path, carrier);
    final _MangaDetectedChoice? choice =
        await showAppDialog<_MangaDetectedChoice>(
          context: context,
          builder: (BuildContext ctx) => FushiAlertDialog(
            icon: const FushiDialogHeroIcon(
              icon: FushiIcons.manga,
              tone: FushiHeroTone.tertiary,
            ),
            title: Text(t.manga_import_detected_title),
            content: Text(
              t.manga_import_detected_message(name: p.basename(path)),
            ),
            actions: <Widget>[
              FushiTextButton(
                onPressed: () =>
                    Navigator.pop(ctx, _MangaDetectedChoice.cancel),
                child: Text(t.dialog_cancel),
              ),
              // 漫画判据会误判（插图小说 / 绘本 / 图文书），书籍管线吃得下时必须
              // 让用户坚持按书导入，否则这本书在 Fushi 里根本进不了书架。
              if (canImportAsBook)
                FushiTextButton(
                  onPressed: () =>
                      Navigator.pop(ctx, _MangaDetectedChoice.asBook),
                  child: Text(t.manga_import_detected_import_as_book),
                ),
              FushiFilledButton(
                onPressed: () =>
                    Navigator.pop(ctx, _MangaDetectedChoice.asManga),
                child: Text(t.manga_import_detected_confirm),
              ),
            ],
          ),
        );
    if (choice == _MangaDetectedChoice.asBook) {
      // 记住这次覆盖：后面 `_doImport` 兜底闸门与 `_importEpubOnly` 分派都经
      // [_classifyCarrier] 问同一个问题，覆盖必须在那里生效，否则会再弹一次。
      _forcedBookPath = path;
      return false;
    }
    if (choice != _MangaDetectedChoice.asManga || !mounted) return true;

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

  /// 选文件 / 拖入的代数。载体定性是异步的（后台 isolate），定性期间用户可能又选了
  /// 别的、或对旧选择点了导入：回来的结果只在它仍是最新一次选择、且没在导入时才收下，
  /// 否则界面显示的与正在导入的不是同一本。
  int _selectionGeneration = 0;

  /// 正在后台定性的载体数。定性要开包（大 EPUB 好几秒），期间 `importing` 还是
  /// false：不拦的话导入键照样能点，`_doImport` 兜底闸门那次定性没回来前再点一次
  /// 就会开出第二条 `_doImport`，两条一起进 [runImport]，同一本书并发导入两次。
  /// 非零时导入键禁用、`_doImport` 直接返回——定性改成异步前它是同步的，没有这个窗口。
  int _classifyingCount = 0;

  bool _isStaleSelection(int generation) =>
      !mounted || importing || generation != _selectionGeneration;

  /// 用户在「这看起来是漫画」确认框里坚持按书籍导入的路径（见 [_handoffIfManga]）。
  String? _forcedBookPath;

  Future<ImportCarrier> _classifyCarrier(String path) async =>
      path == _forcedBookPath
      ? ImportCarrier.epub
      : await _carrierResolver.resolveAsync(path);

  /// 拖文件进本对话框 → 分类 → 按字段覆盖（仅填命中类，不清用户已选）。
  /// 纯解析交给 [resolveBookDialogDrop]；此处只 setState + sidecar/封面副作用。
  Future<void> _handleDialogDrop(List<String> paths, Offset _) async {
    if (importing) return;
    // 拖进来的是装着一批书的压缩包（.7z / 一包 EPUB 的 zip / 分卷第一卷……）→ 整包转交
    // 批量导入。分类表里 `.zip` 归词典包、`.rar` 归漫画包，不先问就会被下面静默忽略。
    if (await _handoffIfBookArchives(paths, ++_selectionGeneration)) return;
    if (!mounted) return;
    final DroppedFiles files = classifyDroppedFiles(paths);
    final BookDialogDropResult r = resolveBookDialogDrop(files);
    if (r.isEmpty) return;
    final String? droppedEpub = r.epubPath;
    // 拖进来的「书」其实是漫画（图片型 zip / 扫描版 epub）→ 确认后转交漫画流程。
    if (droppedEpub != null) {
      final int generation = ++_selectionGeneration;
      if (await _handoffIfManga(droppedEpub, generation)) return;
    }
    if (!mounted) return;
    final bool gotAudio = r.audioPaths.isNotEmpty;
    setState(() {
      if (droppedEpub != null) {
        _epubPath = droppedEpub;
        _epubName = p.basename(droppedEpub);
        _autoFillTitle(
          p.basenameWithoutExtension(droppedEpub),
          ImportTitleSource.epub,
        );
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
      unawaited(_fillTitleFromEpubMetadata(droppedEpub));
    }
    if (gotAudio) {
      if (_coverPath == null) {
        _tryExtractAudioCover();
      }
      _tryExtractAudioMetadata();
    }
  }

  Widget _buildForm() {
    int step = 0;
    // 自上而下（2026-11 导入对话框统一）：
    // 一个对话框只用一个模块色系（书 = coral）：
    // ① 书籍文件主色块（模块色反色，同外层「导入书」块），也是拖放落点；
    // ② 封面 / 字幕 / 音频三格同色系小色块；
    // ③ 书名 / 作者：同色系表单色块里的 M3 填充式字段；
    // ④ 只选了音频的引导、引用原文件开关、匹配选项、进度卡。首屏错峰进场。
    Widget stagger(Widget child) =>
        FushiStaggeredEntrance(index: step++, child: child);
    return FushiEntranceScope(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          stagger(_epubRow()),
          const SizedBox(height: importDialogRhythm),
          // 音频 → 字幕 → 封面：转录依赖音频，依赖关系从左往右读。
          stagger(
            ImportPickTileGrid(
              children: <Widget>[_audioRow(), _subtitleRow(), _coverRow()],
            ),
          ),
          const SizedBox(height: importDialogRhythm),
          stagger(_bookDetails()),
          if (_audioOnlyHint != AudioOnlyImportHint.none) ...[
            const SizedBox(height: importDialogRhythm),
            stagger(_audioOnlyNotice(_audioOnlyHint)),
          ],
          if (isDesktopPlatform && _audioPaths.isNotEmpty) ...[
            const SizedBox(height: importDialogRhythm),
            stagger(
              AdaptiveSettingsSection(
                children: [
                  AdaptiveSettingsSwitchRow(
                    title: t.audiobook_reference_original,
                    subtitle: t.audiobook_reference_original_desc,
                    icon: FushiIcons.link,
                    value: _referenceOriginal,
                    onChanged: importing ? null : _setReferenceOriginal,
                  ),
                ],
              ),
            ),
          ],
          if (_willRunMatcher) ...[
            const SizedBox(height: importDialogRhythm),
            stagger(
              ImportMatchOptionsCard(
                autoToggle: AdaptiveSettingsSwitchRow(
                  title: t.auto_select_search_window,
                  subtitle: t.auto_select_search_window_hint,
                  icon: FushiIcons.settings,
                  value: _autoWindow,
                  onChanged: importing
                      ? null
                      : (bool value) => setState(() => _autoWindow = value),
                ),
                sliders: _autoWindow
                    ? const <Widget>[]
                    : <Widget>[
                        SubtitleRematchWindowSlider(
                          value: _searchWindow,
                          onChanged: (v) => setState(() => _searchWindow = v),
                        ),
                        SubtitleRematchThresholdSlider(
                          value: _similarityThreshold,
                          onChanged: (v) =>
                              setState(() => _similarityThreshold = v),
                        ),
                      ],
              ),
            ),
          ],
          if (importing) ...[
            const SizedBox(height: importDialogRhythm),
            ImportProgressCard(progress: progress, message: progressMsg),
          ],
        ],
      ),
    );
  }

  /// 只选了音频（没书、没字幕）时的出路：本机能转录就提醒直接转录生成书籍，
  /// 否则提醒选字幕文件生成书籍。此前这一步只有点「导入」后的一句报错。
  AudioOnlyImportHint get _audioOnlyHint => audioOnlyImportHint(
    hasBook: _epubPath != null,
    hasSubtitle: _hasSubtitles,
    hasAudio: _audioPaths.isNotEmpty,
    asrSupported: isAsrSupported,
  );

  Widget _audioOnlyNotice(AudioOnlyImportHint hint) {
    final bool transcribe = hint == AudioOnlyImportHint.transcribeToBook;
    return FushiInlineNotice(
      title: t.book_import_no_book_notice_title,
      message: transcribe
          ? t.book_import_no_book_transcribe_hint
          : t.book_import_no_book_subtitle_hint,
      icon: transcribe ? FushiIcons.voice : FushiIcons.subtitles,
      actions: <Widget>[
        FushiTextButton(
          onPressed: importing
              ? null
              : (transcribe ? _transcribeSubtitleFromAudio : _pickSubtitle),
          child: Text(
            transcribe
                ? t.book_import_no_book_transcribe_action
                : t.srt_import_pick_subtitle_files,
          ),
        ),
      ],
    );
  }

  /// ① 书籍文件主色块：未选时标题是动作、副行是格式行；已选时标题是文件名
  /// （可清除）。
  Widget _epubRow() {
    final String? path = _epubPath;
    return ImportPickBlock(
      key: ValueKey<String>(
        path == null ? 'book-import-pick-block' : 'book-import-selected-card',
      ),
      tone: ImportTone.coral,
      icon: FushiIcons.books,
      title: path == null
          ? t.srt_import_pick_epub
          : (_epubName ?? p.basename(path)),
      subtitle: path == null ? _bookFormatsLine : t.srt_import_pick_epub,
      dropHint: t.book_import_drop_hint,
      selected: path != null,
      enabled: !importing,
      onTap: _pickEpub,
      onClear: () => setState(() {
        _epubPath = null;
        _epubName = null;
      }),
    );
  }

  /// 书籍文件行的格式行：「支持 n 种格式 · EPUB · PDF · TXT …」。漫画载体
  /// （mokuro / cbz / zip）虽在选择器里，选中后转交漫画流程，不算书籍格式。
  String get _bookFormatsLine {
    final List<String> formats = <String>[
      'epub',
      'pdf',
      ...TextToEpub.supportedExtensions,
    ];
    final String head = formats
        .take(3)
        .map((String e) => e.toUpperCase())
        .join(' · ');
    return '${t.import_formats_supported_count(n: formats.length)} · $head …';
  }

  /// ② 书名 / 作者：M3E 填充式字段。自动填入的字段在 helper 行写明来源。
  Widget _bookDetails() {
    final String? titleNote = _titleCtrl.text.trim().isEmpty
        ? null
        : switch (_titleSource) {
            ImportTitleSource.epub => t.book_import_field_from_book,
            ImportTitleSource.subtitle => t.book_import_field_from_subtitle,
            ImportTitleSource.metadata => t.book_import_field_from_audio,
            ImportTitleSource.none || ImportTitleSource.user => null,
          };
    // 与上面的选择块同一色系的表单色块（字段填充 / 指示线取块色）。
    return ImportSectionBlock(
      tone: ImportTone.coral,
      children: <Widget>[
        FushiTextField(
          controller: _titleCtrl,
          labelText: t.srt_import_title_hint,
          helperText: titleNote,
          enabled: !importing,
          // 用户一旦在标题框手打即锁定来源为 user，此后重选文件不再覆盖（TODO-1362）。
          // Flutter 不会为程序化的 controller.text= 触发 onChanged，故仅真实用户输入
          // （含屏幕键盘/粘贴，经 FushiTextField 转发）才置 user。
          onChanged: (String _) {
            if (_titleSource != ImportTitleSource.user) {
              setState(() => _titleSource = ImportTitleSource.user);
            }
          },
        ),
        FushiTextField(
          controller: _authorCtrl,
          labelText: t.srt_import_author_hint,
          helperText: _authorAutoFilled ? t.book_import_field_from_audio : null,
          enabled: !importing,
          onChanged: (String _) {
            if (_authorAutoFilled) setState(() => _authorAutoFilled = false);
          },
        ),
      ],
    );
  }

  Widget _subtitleRow() {
    final String? path = _subtitlePath;
    // 转录回填的显示名固定是结果名（见 _transcribeSubtitleFromAudio）。
    final bool transcribed =
        path != null && _subtitleName == t.audiobook_transcribe_result_name;
    return ImportPickTile(
      tone: ImportTone.coral,
      icon: FushiIcons.subtitles,
      title: t.srt_import_pick_subtitle_files,
      // 未选时副行说明这一格能做什么（能转录的平台点明麦克风钮的意思）；
      // 已选时是文件名（转录回填的显示名固定是结果名）。
      subtitle: path == null
          ? (isAsrSupported
                ? t.book_import_subtitle_row_hint
                : t.book_import_subtitle_row_hint_plain)
          : _subtitleName ?? p.basename(path),
      selected: path != null,
      enabled: !importing,
      droppable: true,
      // 点格子本身 = 选文件；转录是下方常显的带字动作（用户 2026-11：「这样
      // 看不出能够转录」——原先只是右上角一枚靠 tooltip 解释的图标）。
      onTap: _pickSubtitle,
      onClear: () => setState(() {
        _subtitlePath = null;
        _subtitleName = null;
      }),
      // 点格子本身 = 选文件（标题就写着「选择字幕文件」）；转录是格内唯一的
      // 额外来源，一枚带字小片（不再「本地文件 / 转录」两枚竖叠撑高整排）。
      below: !isAsrSupported
          ? null
          : ImportTileActions(
              colors: ImportPickTile.colorsOf(context, ImportTone.coral),
              // 转录要先有音频：不藏按钮，置灰并用一行小字写出原因。
              note: _audioPaths.isEmpty
                  ? t.audiobook_transcribe_needs_audio
                  : null,
              actions: <ImportTileAction>[
                ImportTileAction(
                  icon: FushiIcons.voice,
                  label: t.import_subtitle_source_transcribe,
                  selected: transcribed,
                  enabled: !importing && _audioPaths.isNotEmpty,
                  onTap: _transcribeSubtitleFromAudio,
                ),
              ],
            ),
    );
  }

  /// 点字幕行：本机能转录且已选音频时先问来源（选文件 / 转录），否则直进选择器。
  /// 同目录自动带入的字幕不阻止走这里——选「转录」就是替换它。
  Future<void> _onSubtitleRowTap() async {
    if (importing) return;
    if (!shouldOfferSubtitleSourceChooser(
      asrSupported: isAsrSupported,
      hasAudio: _audioPaths.isNotEmpty,
    )) {
      await _pickSubtitle();
      return;
    }
    final SubtitleSourceChoice? choice = await showSubtitleSourceChooser(
      context: context,
    );
    if (choice == null || !mounted) return;
    switch (choice) {
      case SubtitleSourceChoice.pickFile:
        await _pickSubtitle();
      case SubtitleSourceChoice.transcribe:
        await _transcribeSubtitleFromAudio();
    }
  }

  /// 已选但尚未导入的书的语言 → 转录语言初值。只有 EPUB 载体带 OPF 元数据；
  /// txt / pdf / 漫画没有语言可读，直接 null。读取在后台 isolate 做（zip 解码 +
  /// 两份 XML，大书也就几十毫秒，但不占 UI 线程）；文件坏了按 null 处理并记日志，
  /// 不让「猜个初值」这种锦上添花的事挡住转录入口。
  Future<AsrLanguage?> _asrLanguageHintFromPendingBook() async {
    final String? path = _epubPath;
    if (path == null || await _classifyCarrier(path) != ImportCarrier.epub) {
      return null;
    }
    try {
      final String? language = await Isolate.run(
        () => EpubParser.readLanguageSync(path),
      );
      return asrLanguageHintFromBookLanguage(language);
    } catch (error, stack) {
      developer.log(
        'read EPUB language for ASR hint failed: $path',
        name: 'fushi.import',
        error: error,
        stackTrace: stack,
      );
      return null;
    }
  }

  /// 选中的书是 EPUB 时，把文件名派生的书名换成 OPF `dc:title`（BUG-3774）。
  /// 入库书名本来就取 OPF（[EpubImporter] 只在 OPF 没写书名时退回文件名），标题框
  /// 却一直显示文件名，用户看到的和最终入库的不一致。走 [_autoFillTitle] 的同一
  /// 来源（epub）：用户手打过的标题不动；读取期间重选了别的文件也不回写。读取在
  /// 后台 isolate；包坏了照旧保留文件名并记日志，真正的失败交给导入那一步报。
  Future<void> _fillTitleFromEpubMetadata(String path) async {
    if (await _classifyCarrier(path) != ImportCarrier.epub) return;
    final String? title;
    try {
      title = await readEpubTitleInBackground(path);
    } catch (error, stack) {
      developer.log(
        'read EPUB title for import dialog failed: $path',
        name: 'fushi.import',
        error: error,
        stackTrace: stack,
      );
      return;
    }
    if (!mounted || title == null || _epubPath != path) return;
    final String metadataTitle = title;
    setState(() => _autoFillTitle(metadataTitle, ImportTitleSource.epub));
  }

  /// 没有 .srt 时用设备端语音模型从已选音频生成一份，回填到字幕位；之后的导入
  /// 路径与用户自带 SRT 完全相同（解析 → 匹配 → 落库）。
  Future<void> _transcribeSubtitleFromAudio() async {
    if (_audioPaths.isEmpty) {
      FushiToast.show(
        msg: t.audiobook_transcribe_needs_audio,
        severity: ToastSeverity.warning,
      );
      return;
    }
    // 语言初值跟随书本身的语言；此时书还没导入，只能从文件上读 OPF 元数据。
    final AsrLanguage? languageHint = await _asrLanguageHintFromPendingBook();
    if (!mounted) return;
    final String? srtPath = await showAsrTranscribeSheet(
      tone: ImportTone.coral,
      context: context,
      audioPaths: List<String>.of(_audioPaths),
      languageHint: languageHint,
    );
    if (srtPath == null || !mounted) return;
    setState(() {
      _subtitlePath = srtPath;
      _subtitleName = t.audiobook_transcribe_result_name;
      // ASR 文本有听写差，匹配阈值按实测放宽（用户仍可在滑条上改）。
      _similarityThreshold = kAsrSuggestedSimilarityThreshold;
    });
  }

  Widget _audioRow() {
    return ImportPickTile(
      tone: ImportTone.coral,
      icon: FushiIcons.audio,
      title: t.srt_import_pick_audio_files,
      subtitle: _audioPaths.isEmpty
          ? t.book_import_audio_row_hint
          : _audioPaths.length == 1
          ? p.basename(_audioPaths.first)
          : t.file_count(count: _audioPaths.length),
      selected: _audioPaths.isNotEmpty,
      enabled: !importing,
      droppable: true,
      onTap: _pickAudio,
      onClear: () => setState(() {
        _audioPaths = [];
        _audioCoverPath = null;
      }),
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
    // 装着一批书的压缩包（拍板 83Fe7zQbhv）：选中后 [_handoffIfNotSingleBook] 按包里装的
    // 是什么转交整批导入（或漫画流程）。`001` 是分卷包的第一卷（`book.7z.001`）。
    '7z',
    'rar',
    '001',
    ...TextToEpub.supportedExtensions,
  ];

  Future<void> _pickEpub({bool anyFile = false}) async {
    if (_pickerActive) return;
    _pickerActive = true;
    try {
      final FilePickerResult? result = await pickFilesByExtensions(
        context: context,
        allowedExtensions: anyFile ? null : _bookExtensions,
      );
      final PlatformFile? file = result?.files.single;
      final String? path = file?.path;
      if (path != null && file != null && mounted) {
        // 选中的其实是一包书 / 漫画载体 → 转交对应流程，不再静默按一本书导入。
        final int generation = ++_selectionGeneration;
        if (await _handoffIfNotSingleBook(path, generation)) return;
        setState(() {
          _epubPath = path;
          _epubName = file.name;
          _autoFillTitle(
            file.name.replaceAll(
              RegExp(
                r'\.(epub|pdf|mokuro|cbz|zip|txt|html?|xhtml|md|markdown|rst|org|csv|tsv|log|json|xml)$',
                caseSensitive: false,
              ),
              '',
            ),
            ImportTitleSource.epub,
          );
        });
        unawaited(_fillTitleFromEpubMetadata(path));
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
      FushiToast.show(msg: parts.join(' · '), severity: ToastSeverity.info);
    }
  }

  static const Set<String> _subtitleExtensions = kAudiobookSubtitleExtensions;

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
        FushiToast.show(
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
        _autoFillTitle(
          dot > 0 ? name.substring(0, dot) : name,
          ImportTitleSource.subtitle,
        );
      });
    } finally {
      _pickerActive = false;
    }
  }

  Future<void> _pickAudio() async {
    if (_pickerActive) return;
    _pickerActive = true;
    try {
      final AppModel appModel = ProviderScope.containerOf(
        context,
        listen: false,
      ).read(appProvider);
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
      final AudioMetadata? meta = await TtsChannel.instance
          .extractAudioMetadata(audioPath: audioPath);
      if (meta == null) continue;
      if (!mounted) return;
      final bool fillAuthor = _authorCtrl.text.isEmpty && meta.author != null;
      if (meta.title != null || fillAuthor) {
        setState(() {
          if (meta.title != null) {
            _autoFillTitle(meta.title!, ImportTitleSource.metadata);
          }
          if (fillAuthor) {
            _authorCtrl.text = meta.author!;
            _authorAutoFilled = true;
          }
        });
      }
      // 找到首个含可用 tag 的文件即停（多文件有声书用第一段的容器 tag）。
      if (meta.title != null || meta.author != null) return;
    }
  }

  /// 封面格：手选封面优先，其次音频内嵌封面（副行「取自音频」）；有封面时
  /// glyph 位换成缩略图。
  Widget _coverRow() {
    final String? effectiveCover = _coverPath ?? _audioCoverPath;
    final bool fromAudio = _coverPath == null && _audioCoverPath != null;
    return ImportPickTile(
      tone: ImportTone.coral,
      icon: FushiIcons.addImage,
      title: t.srt_import_pick_cover,
      subtitle: effectiveCover == null
          ? t.book_import_cover_row_hint
          : (fromAudio
                ? t.book_import_cover_from_audio
                : p.basename(effectiveCover)),
      thumbnail: effectiveCover == null
          ? null
          : ImportCoverThumbnail(path: effectiveCover),
      selected: effectiveCover != null,
      enabled: !importing,
      onTap: _pickCover,
      onClear: () => setState(() {
        _coverPath = null;
        _audioCoverPath = null;
      }),
    );
  }

  Future<void> _pickCover() async {
    if (_pickerActive) return;
    _pickerActive = true;
    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        // file_picker 安卓默认在裸线程里重压缩 image/*，Android 9/10 缺存储写权限
        // 或解码失败时直接杀进程（BUG-3601 复查 / WkL9BvD7Z9），一律关掉。
        allowCompression: false,
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
    if (!await _writeCoverOrSkip(source: source, destPath: dest)) return;
    await (widget.db.update(widget.db.epubBooks)
          ..where((tbl) => tbl.bookKey.equals(bookKey)))
        .write(EpubBooksCompanion(coverPath: Value('cover$ext')));
  }

  /// 封面落盘的唯一出口（EPUB 包内 `cover.*` 与字幕书 `persistDir/cover.*` 共用）。
  ///
  /// BUG-2496：收口会拒收非图片 / 截断图片（改过扩展名的 HTML、ffmpeg 抽到一半的
  /// 内嵌封面）。封面坏了不能让整本书导入失败——记诊断、返回 false，调用方不写
  /// `coverPath`，书照常入库、书架回落占位图。其它 IO 异常照旧向上抛。
  Future<bool> _writeCoverOrSkip({
    required String source,
    required String destPath,
  }) async {
    try {
      await MediaCoverService.applyCoverFile(
        source: File(source),
        destPath: destPath,
      );
      return true;
    } on CoverImageInvalidException catch (e) {
      ErrorLogService.instance.logDiagnostic('BookImportDialog.cover', e);
      return false;
    }
  }

  Future<bool> _epubHasCover(String bookKey) async {
    final row = await (widget.db.select(
      widget.db.epubBooks,
    )..where((tbl) => tbl.bookKey.equals(bookKey))).getSingleOrNull();
    return row?.coverPath != null;
  }

  // ── 导入 ────────────────────────────────────────────────────────────────

  /// 同名书弹窗回调，喂给 [EpubImporter]。是→加后缀，否/关闭→取消这本书。
  Future<DuplicateChoice> _askOnDuplicate(String proposedTitle) async {
    if (!mounted) return DuplicateChoice.cancel;
    final bool? keep = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => FushiAlertDialog(
        title: Text(t.book_import_duplicate_title),
        content: Text(t.book_import_duplicate_message(name: proposedTitle)),
        actions: <Widget>[
          FushiTextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.book_import_duplicate_cancel),
          ),
          FushiFilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.book_import_duplicate_keep),
          ),
        ],
      ),
    );
    return keep == true ? DuplicateChoice.suffix : DuplicateChoice.cancel;
  }

  Future<void> _doImport() async {
    // 重入闸：按键已按 [_classifyingCount] / importing 禁用，这里再守一次（键盘默认
    // 动作、递归重入都经此处）。
    if (importing || _classifyingCount > 0) return;
    if (widget.requireBook && _epubPath == null) {
      await _pickEpub();
      if (!mounted || _epubPath == null) return;
    }
    final AudioOnlyImportHint audioOnly = _audioOnlyHint;
    if (audioOnly == AudioOnlyImportHint.transcribeToBook) {
      // 只有音频：没有书也能导入——转录出字幕后接着走字幕书路径自动生成书籍，
      // 不再停在「请至少选择书籍或字幕文件」（与下方 EPUB+音频 的 BUG-2266 同口径）。
      await _transcribeSubtitleFromAudio();
      if (!mounted || !_hasSubtitles) return;
      return _doImport();
    }
    if (audioOnly == AudioOnlyImportHint.pickSubtitleToBook) {
      FushiToast.show(
        msg: t.book_import_no_book_subtitle_hint,
        severity: ToastSeverity.error,
      );
      return;
    }
    if (_epubPath == null && !_hasSubtitles) {
      FushiToast.show(
        msg: t.srt_import_missing_input,
        severity: ToastSeverity.error,
      );
      return;
    }
    // 兜底闸门：选/拖两条入口在收下路径时就已过 [_handoffIfManga]，但 initialEpubPath
    // 是构造参数直接塞进来的（书架拖入决策层刻意不为每个 EPUB 开包，图片型 .epub 会
    // 以 books 身份到达这里）。同一个闸门在此再守一次，漫画绝不会走进书籍导入分支。
    final String? epubPath = _epubPath;
    if (epubPath != null &&
        await _handoffIfManga(epubPath, _selectionGeneration)) {
      return;
    }
    if (!mounted) return;
    if (_epubPath != null && !_hasSubtitles && _audioPaths.isNotEmpty) {
      // 有音频没字幕：本机能转录就直接问字幕来源（选文件 / 转录），拿到字幕后接着
      // 导入；只有不能转录的平台才提示。转录入口只是字幕行尾一枚无字图标，用户
      // 「下载了语音模型 → 选 EPUB + 音频 → 点导入」走到这里，若只给一句「音频需要
      // 配合字幕使用」就是死胡同（BUG-2266）。
      if (shouldOfferSubtitleSourceChooser(
        asrSupported: isAsrSupported,
        hasAudio: true,
      )) {
        await _onSubtitleRowTap();
        if (!mounted || !_hasSubtitles) return;
        return _doImport();
      }
      FushiToast.show(
        msg: t.srt_import_audio_needs_subtitle,
        severity: ToastSeverity.error,
      );
      return;
    }
    final String title = _titleCtrl.text.trim();
    if (title.isEmpty) {
      FushiToast.show(
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
          FushiToast.show(
            msg: t.book_import_duplicate_cancelled,
            severity: ToastSeverity.info,
          );
          Navigator.pop(context, false);
        }
      },
      action: () async {
        reportProgress(0, '');
        final String? authorText = _authorCtrl.text.trim().isEmpty
            ? null
            : _authorCtrl.text.trim();

        debugPrint(
          '[fushi-import] route: epub=$_epubPath sub=$_subtitlePath audio=${_audioPaths.length} files',
        );
        String? tail;
        if (_epubPath != null && _hasSubtitles) {
          tail = await _importEpubWithAlignment(title: title);
        } else if (_hasSubtitles) {
          await _importSubtitleBook(title: title, author: authorText);
        } else {
          await _importEpubOnly(title: title);
        }

        if (mounted) {
          final String msg = tail == null
              ? t.srt_import_success
              : '${t.srt_import_success} · $tail';
          FushiToast.show(msg: msg, severity: ToastSeverity.success);
          Navigator.pop(context, true);
        }
      },
    );
  }

  Future<void> _importSubtitleBook({
    required String title,
    required String? author,
  }) async {
    // TODO-935 ①A：引用模式（仅桌面）直接存原始绝对路径，不复制（仿 VideoBooks）。
    final bool referenceAudio = _referenceOriginal && isDesktopPlatform;
    await importStandaloneSubtitleBook(
      db: widget.db,
      repo: widget.repo,
      title: title,
      author: author,
      subtitlePath: _subtitlePath!,
      audioPaths: _audioPaths,
      copyAudio: !referenceAudio,
      policy: DuplicatePolicy.ask(_askOnDuplicate),
      tempDir: await getTemporaryDirectory(),
      persistCover: (Directory persistDir) async {
        // TODO-1034：与主路径同根因——读 _audioCoverPath 前必须先等内嵌封面抽取
        // 落定，否则用户在 ffmpeg probe 未返回时点「导入」会把封面吞掉。
        await _awaitCoverExtraction();
        final String? coverSource = _coverPath ?? _audioCoverPath;
        if (coverSource == null) return null;
        final String dest = p.join(
          persistDir.path,
          'cover${p.extension(coverSource)}',
        );
        return await _writeCoverOrSkip(source: coverSource, destPath: dest)
            ? dest
            : null;
      },
      onProgress:
          (
            double fraction,
            StandaloneSubtitleBookStep step,
            String? fileName,
          ) => reportProgress(fraction, switch (step) {
            StandaloneSubtitleBookStep.parsing => t.import_step_parsing,
            StandaloneSubtitleBookStep.buildingEpub =>
              t.import_step_building_epub,
            StandaloneSubtitleBookStep.importingEpub =>
              t.import_step_importing_epub,
            StandaloneSubtitleBookStep.persisting => t.import_step_persisting,
            StandaloneSubtitleBookStep.copyingFile =>
              t.import_step_copying_file(name: fileName ?? ''),
            StandaloneSubtitleBookStep.saving => t.import_step_saving,
            StandaloneSubtitleBookStep.done => t.import_step_done,
          }),
    );
  }

  Future<void> _importEpubOnly({required String title}) async {
    final File file = File(_epubPath!);

    reportProgress(0.2, t.import_step_reading);

    // 载体身份此前是在这里靠 4 个 if（含一次真读包）现场嗅出来的；现在它在**选中
    // 文件那一刻**就已由 [classifyImportCarrier] 定死，且漫画载体根本进不来（三个
    // 入口都过 [_handoffIfManga]）。这里只剩书籍侧的三种去向。
    final ImportCarrier carrier = await _classifyCarrier(_epubPath!);

    // PDF 阅读器 Phase 1：.pdf 走独立 PdfImporter（pdfrx 真渲染 + 落库 format='pdf'）。
    // PDF 封面在 PdfImporter 内栅格化首页得到，故不走 _applyBestCoverToEpub。
    if (carrier == ImportCarrier.pdf) {
      // PDF 完全不经 EPUB 管线（pdfrx 直接渲染、落库 format='pdf'），所以这里报的是
      // 中性的「导入书籍…」。用户看到「导入 EPUB…」卡住时会以为是 EPUB 转换出了问题，
      // 而真正卡住的是 PDFium——错误的文案会把排查引向错误的方向（BUG-2419）。
      reportProgress(0.5, t.import_step_importing_book);
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
      final Uint8List bytes = await TextToEpub.convert(
        file: file,
        title: title,
      );
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
    // PDF + 字幕 + 音频：PDF 走自己的导入器（落库 format='pdf'），对齐时引擎按
    // format 取 PDF 文本层逐页全文（`loadBookTextSections`），PDF 阅读器播放 + 高亮。
    // 以前这里只认 EPUB / 文本，PDF 被塞进 EpubImporter 当 zip 解包直接失败。
    final bool isPdf = await _classifyCarrier(_epubPath!) == ImportCarrier.pdf;
    if (isPdf) {
      reportProgress(0.2, t.import_step_importing_book);
      bookKey = await PdfImporter.importFromPath(
        db: widget.db,
        filePath: _epubPath!,
        fileName: _epubName ?? p.basename(_epubPath!),
        title: title,
        policy: DuplicatePolicy.ask(_askOnDuplicate),
      );
    } else if (TextToEpub.isSupported(_epubPath!)) {
      reportProgress(0.1, t.import_step_converting_epub);
      final Uint8List importBytes = await TextToEpub.convert(
        file: epubFile,
        title: title,
      );
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

    // PDF 封面由 PdfImporter 栅格化首页得到，不走 EPUB 的封面择优。
    if (!isPdf) await _applyBestCoverToEpub(bookKey);

    // EPUB 导入之后的对齐落库下沉到非 UI 的 alignAndPersistAudiobook：解析章节、
    // 解析 cue、跑 matcher、持久字幕/音频、写 Audiobooks + 配对 SrtBook + cue +
    // health overlay。对话框只把进度/文案/字段透传给 service，行为逐字节等价。
    final AudiobookAlignmentResult result = await alignAndPersistAudiobook(
      db: widget.db,
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
}

@visibleForTesting
class BookImportDialogFrame extends StatelessWidget {
  const BookImportDialogFrame({
    required this.title,
    required this.content,
    required this.actions,
    this.subtitle,
    super.key,
  });

  /// 2026-10 体验优化：标题交给 [ImportDialogFrame] 的固定页头（与有声书导入
  /// 一致），不再塞进可滚动 body——此前表单一长，标题就跟着滚出视口。
  final String title;

  /// 标题下的一行说明（对话框 supporting text）。
  final String? subtitle;
  final Widget content;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    // 宽屏放宽到 600：文件组的副行（格式行 / 文件名）不必折行。
    return ImportDialogFrame(
      tone: ImportTone.coral,
      title: title,
      subtitle: subtitle,
      body: content,
      actions: actions,
      maxWidth: 600,
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

/// 后台 isolate 里读 EPUB 的 OPF `dc:title`（[EpubParser.readTitleSync]）。
///
/// 必须是顶层函数：写在 State 方法里的 `Isolate.run` 闭包会和同一方法里引用 `this`
/// 的闭包（如 `setState`）共享捕获上下文，把整个 State 带过 isolate 边界、发送失败。
Future<String?> readEpubTitleInBackground(String path) =>
    Isolate.run(() => EpubParser.readTitleSync(path));

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

/// 文件选择行行首的封面缩略图（2:3，小圆角）：换图时淡入切换，解码失败回退
/// 成图标占位。
class ImportCoverThumbnail extends StatelessWidget {
  const ImportCoverThumbnail({required this.path, super.key});

  final String path;

  @override
  Widget build(BuildContext context) {
    final FushiMotionScheme motion = context.fushiMotion;
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);
    return ClipRRect(
      borderRadius: FushiM3eShape.smallRadius,
      child: SizedBox(
        width: 34,
        height: 48,
        child: AnimatedSwitcher(
          duration: motion.effectsDefault.duration,
          switchInCurve: motion.effectsDefault.curve,
          switchOutCurve: motion.effectsFast.curve,
          transitionBuilder: (Widget child, Animation<double> animation) =>
              FadeTransition(
                opacity: fushiUnitClamped(animation),
                child: child,
              ),
          child: Image(
            key: ValueKey<String>(path),
            image: resizedFileImage(File(path)),
            fit: BoxFit.cover,
            width: 34,
            height: 48,
            errorBuilder: (BuildContext _, Object _, StackTrace? _) =>
                ColoredBox(
                  color: tokens.surfaces.group,
                  child: Center(
                    child: FushiIcon(
                      FushiIcons.image,
                      color: tokens.surfaces.onVariant,
                    ),
                  ),
                ),
          ),
        ),
      ),
    );
  }
}

/// 匹配 / 对齐选项的分段卡：可选的「自动选择搜索窗口」开关行 + 两条滑条，各占
/// 一段（M3E 分段列表，首尾大圆角、行间 2）。滑条显隐走弹簧高度过渡。
class ImportMatchOptionsCard extends StatelessWidget {
  const ImportMatchOptionsCard({
    required this.sliders,
    this.autoToggle,
    super.key,
  });

  final Widget? autoToggle;
  final List<Widget> sliders;

  @override
  Widget build(BuildContext context) {
    final FushiMotionScheme motion = context.fushiMotion;
    final Widget? toggle = autoToggle;
    return AnimatedSize(
      duration: motion.spatialDefault.duration,
      curve: motion.spatialDefault.curve,
      alignment: Alignment.topCenter,
      child: AdaptiveSettingsSection(
        children: <Widget>[
          if (toggle != null) toggle,
          for (final Widget slider in sliders)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: slider,
            ),
        ],
      ),
    );
  }
}

/// 导入进度卡（M3E）：secondaryContainer 色块 + 等宽大号百分比 + 波浪线性进度
/// + 当前步骤文案；挂载时弹簧上浮进场。读 [ImportFlowMixin] 的两个 notifier。
class ImportProgressCard extends StatelessWidget {
  const ImportProgressCard({
    required this.progress,
    required this.message,
    super.key,
  });

  final ValueListenable<double> progress;
  final ValueListenable<String> message;

  @override
  Widget build(BuildContext context) {
    final FushiTypography type = context.fushiType;
    final FushiMotionScheme motion = context.fushiMotion;
    // 色块上的字跟卡片配对前景（fushiType 自带页面前景，HBK-AUDIT-022）。
    final Color? onCard = fushiCardToneColors(
      context,
      FushiCardTone.secondary,
    )?.onContainer;
    final Widget card = FushiCard(
      tone: FushiCardTone.secondary,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (BuildContext context, double value, Widget? _) => Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  '${(value.clamp(0.0, 1.0) * 100).round()}%',
                  style: type.headlineSmallEmphasized.tabular.copyWith(
                    color: onCard,
                  ),
                ),
                const SizedBox(height: 8),
                FushiLinearProgressIndicator(value: value),
              ],
            ),
          ),
          const SizedBox(height: 8),
          ValueListenableBuilder<String>(
            valueListenable: message,
            builder: (BuildContext context, String msg, Widget? _) => Text(
              msg,
              style: type.bodyMedium.copyWith(color: onCard),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
    if (motion.spatialDefault.duration == Duration.zero) return card;
    return TweenAnimationBuilder<double>(
      tween: Tween<double>(begin: 0, end: 1),
      duration: motion.spatialDefault.duration,
      curve: motion.spatialDefault.curve,
      child: card,
      builder: (BuildContext context, double v, Widget? child) => Opacity(
        opacity: v.clamp(0.0, 1.0),
        child: Transform.translate(
          offset: Offset(0, (1 - v) * 16),
          child: child,
        ),
      ),
    );
  }
}

/// 「这看起来是漫画」确认框的三种答复。
enum _MangaDetectedChoice { cancel, asBook, asManga }
