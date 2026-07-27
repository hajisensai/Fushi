import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/media/manga/manga_json_writeback.dart';
import 'package:hibiki/src/media/manga/manga_ocr_provider.dart';
import 'package:hibiki/src/media/manga/manga_overlay_html.dart';
import 'package:hibiki/src/media/manga/manga_reading_mode.dart';
import 'package:hibiki/src/media/manga/manga_rescan_result_sheet.dart';
import 'package:hibiki/src/media/manga/manga_spread_model.dart';
import 'package:hibiki/src/media/manga/mokuro_payload.dart';
import 'package:hibiki/src/ocr/cloud_ocr_client.dart';
import 'package:hibiki/src/ocr/manga_box_rescan.dart';
import 'package:hibiki/src/ocr/ocr_inference_ort.dart'
    show isLocalOnnxRuntimeAvailable;
import 'package:hibiki/src/ocr/manga_ocr_service.dart';
import 'package:hibiki/src/ocr/ocr_types.dart';
import 'package:hibiki/src/pages/base_source_page.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/src/pages/implementations/stat_activity.dart';
import 'package:hibiki/src/reader/reader_selection_data.dart';
import 'package:hibiki/src/reader/reader_selection_scripts.dart';
import 'package:hibiki/src/startup/exit_flush_registry.dart';
import 'package:hibiki/utils.dart';

/// 选区 payload → 弹窗锚点视口矩形。
///
/// 漫画 WebView 以 scale 1.0、零 inset 渲染（[HibikiAppUiScaleNeutralizer] 中和层），
/// JS `getClientRects` 的视口坐标可直接当屏幕坐标用（恒等映射）。payload 不带 `rect`
/// 时（块级兜底命中）锚到屏幕中心 1x1 矩形，镜像阅读器的回退。
Rect mangaSelectionRectFromPayload(
  ReaderSelectionData data, {
  required Size fallbackScreen,
}) {
  final Map<String, double>? rect = data.rect;
  if (rect != null) {
    return Rect.fromLTWH(
      rect['x'] ?? 0,
      rect['y'] ?? 0,
      rect['width'] ?? 0,
      rect['height'] ?? 0,
    );
  }
  return Rect.fromCenter(
    center: Offset(fallbackScreen.width / 2, fallbackScreen.height / 2),
    width: 1,
    height: 1,
  );
}

/// 漫画选区 payload 的纯分发核心。页面方法 `processMangaSelection` 接真实回调
/// （setCurrentSentence / searchDictionaryResult）；这个接缝让词/句/矩形契约可以在
/// 无 WebView、无 AppModel 的纯单测里验证。
///
/// 语义：[ReaderSelectionData.text] 是扫描出的查询词；[ReaderSelectionData.sentence]
/// 是框内句子（C1 边界修复保证不跨 `<p class="ocr-box">`），作为 Anki 句子。
/// text 为空是 no-op。
Future<void> dispatchMangaSelection(
  ReaderSelectionData data, {
  required Size fallbackScreen,
  required void Function(String sentence) setSentence,
  required Future<void> Function(String term, Rect selectionRect) search,
}) async {
  if (data.text.isEmpty) {
    return;
  }
  setSentence(data.sentence);
  final Rect rect =
      mangaSelectionRectFromPayload(data, fallbackScreen: fallbackScreen);
  await search(data.text, rect);
}

/// 保证交给 [AnkiMiningContext.coverPath] 的路径以合法图片扩展名结尾（两个 Anki
/// 后端都用 `filePath.split('.').last` 推导媒体扩展名）。
///
/// - 已是 `.png` → 原样返回。
/// - 其它图片扩展名 → 原样返回（本就合法）。
/// - 无扩展名（裁剪输出 `.../cropped` 之类）→ 拷贝成同名 `<name>.png` 返回。
Future<String> ensureMangaCoverPng(String sourcePath) async {
  if (p.extension(sourcePath).isNotEmpty) {
    return sourcePath;
  }
  final String dir = p.dirname(sourcePath);
  final String stem = p.basenameWithoutExtension(sourcePath);
  final String pngPath = p.join(dir, '$stem.png');
  await File(sourcePath).copy(pngPath);
  return pngPath;
}

/// 漫画阅读器页面（漫画 OCR P1：L5 媒体源路由 / L6 渲染 / L7 查词+制卡）。
///
/// 与 EPUB 的 [ReaderHibikiPage]、PDF 的 [ReaderPdfPage] 平行的「第三种书」：mokuro
/// 页图 + 透明 OCR 覆盖层在 WebView 里渲染（文档由 [mangaWindowDocument] 生成），
/// 汇入同一批共享设施：[BaseSourcePageState.searchDictionaryResult]（查词弹窗）、
/// [ReaderPositionRepository]（阅读位置，sectionIndex=0-based 页码）、
/// [ReadingTimeTracker]（时长统计，charsRead 恒 0）、[AnkiMiningContext]（制卡，
/// 卡图=当前页图文件路径）。
///
/// 身份统一 `hoshi://book/<bookKey>`（无漫画专属 scheme 特例），关书自动同步天然工作。
/// 存储契约：`p.join(row.extractDir, row.epubPath)` 指向 `manga.json`；页图在
/// `<书目录>/images/<manga.json 里 url 的相对路径>`（url 恒正斜杠，落盘按平台分隔符）。
///
/// 页面拥有专属虚拟域 [kMangaHost]（`manga.local`，与阅读器 `hoshi.local` 互异，两个
/// 拦截器绝不混叠），经带路径穿越守卫的拦截器 serve 本地页图。spread 模式窗口化
/// loadData-per-window + translateX 翻页；webtoon 整本单文档竖滚（不窗口化）。
///
/// 选词接线（防串框契约 ERRATA H2/C1）：本页注册**恰好一个**
/// `onTextSelected` Dart handler；全工程唯一的 pointerup 选词监听内嵌在
/// [mangaWindowDocument]（调 `hoshiSelection.selectText(x, y, 40, false)` 四参，
/// 漏 maxLength 会让扫描 gate 恒假、查词全程哑火），本页绝不再注册第二个。
class MangaHibikiPage extends BaseSourcePage {
  const MangaHibikiPage({
    super.key,
    required super.item,
    required this.bookKey,
  });

  /// `EpubBooks` 主键（净化后的标题），由 `hoshi://book/<bookKey>` 解析而来。
  final String bookKey;

  /// 漫画拦截器专属虚拟域。必须与阅读器的 `hoshi.local` 互异。
  static const String kMangaHost = 'manga.local';

  /// 阅读方向（spread flex 排序 + 翻页语义）。mokuro 漫画绝大多数是日漫 RTL；
  /// 方向配置列未入 schema，先取业界默认。
  static const String kSpreadDirection = 'rtl';

  /// 纯路径解析 + 穿越守卫。[relative] 在 [imagesRoot] 内解析到存在的文件时返回
  /// 规范绝对路径，否则 null（越界/缺文件都不 serve）。从 WebView 路径抽出，安全
  /// 边界无需 WebView 后端即可单测。
  static String? resolveMangaResource(String imagesRoot, String relative) {
    final String canonicalRoot = p.canonicalize(imagesRoot);
    final String decoded = Uri.decodeComponent(relative);
    final String filePath = p.canonicalize(p.join(canonicalRoot, decoded));
    if (!p.isWithin(canonicalRoot, filePath)) return null;
    final File file = File(filePath);
    if (!file.existsSync()) return null;
    return filePath;
  }

  /// 纯函数：`manga.local` 图片 URL → 树内文件路径；host 不对/越界/缺文件 → null。
  static String? resolveImageUrlToFile(String imagesRoot, String imgUrl) {
    final Uri? uri = Uri.tryParse(imgUrl);
    if (uri == null || uri.host != kMangaHost) return null;
    if (!uri.path.startsWith('/img/')) return null;
    final String relative = uri.path.substring('/img/'.length);
    return resolveMangaResource(imagesRoot, relative);
  }

  /// 纯函数：manga.json 的相对 url → WebView 可加载的拦截器 URL。逐段
  /// percent-encode（保留 `/` 结构），与拦截器侧 `Uri.decodeComponent` 对称
  /// （镜像 epubUrl 的 HBK-AUDIT-127 编解码对称纪律）。
  static String mangaImageUrl(String relativeUrl) {
    final String encoded =
        relativeUrl.split('/').map(Uri.encodeComponent).join('/');
    return 'https://$kMangaHost/img/$encoded';
  }

  /// 纯函数：围绕 [current]、半径 [radius] 的连续 spread 窗口，clamp 到
  /// [0, spreadCount)。驱动单文档窗口化（哪些 spread 的 <img>/OCR 节点存活）。
  static List<int> mangaWindowRange({
    required int spreadCount,
    required int current,
    required int radius,
  }) {
    if (spreadCount <= 0) return const <int>[];
    final int lo = (current - radius).clamp(0, spreadCount - 1);
    final int hi = (current + radius).clamp(0, spreadCount - 1);
    return <int>[for (int i = lo; i <= hi; i++) i];
  }

  /// 纯函数：[spreadIndex] 的首页页码（越界回 0）。
  static int firstPageOfSpread(
      List<MangaSpreadEntry> spreads, int spreadIndex) {
    if (spreadIndex < 0 || spreadIndex >= spreads.length) return 0;
    return spreads[spreadIndex].pageIndices.first;
  }

  /// 纯函数：包含 [page] 的 spread 序号（无命中回 0）。
  static int spreadIndexForPage(List<MangaSpreadEntry> spreads, int page) {
    for (int i = 0; i < spreads.length; i++) {
      if (spreads[i].pageIndices.contains(page)) return i;
    }
    return 0;
  }

  /// 纯函数：[spreadIndex] 要持久化的 (页码, 页内 fraction)。spread 模式 fraction
  /// 钉 0；webtoon 带页内归一化偏移。
  static (int, double) mangaProgressForSpread(
    List<MangaSpreadEntry> spreads,
    int spreadIndex, {
    required double webtoonFraction,
    required bool isWebtoon,
  }) {
    final int page = firstPageOfSpread(spreads, spreadIndex);
    return (page, isWebtoon ? webtoonFraction : 0.0);
  }

  /// 纯函数：持久化页码 → 恢复的 spread 序号（clamp 越界存档）。
  static int restoreSpreadFromProgress(
      List<MangaSpreadEntry> spreads, int lastPage) {
    if (spreads.isEmpty) return 0;
    final int clamped = lastPage.clamp(0, _maxPage(spreads));
    return spreadIndexForPage(spreads, clamped);
  }

  static int _maxPage(List<MangaSpreadEntry> spreads) {
    int m = 0;
    for (final MangaSpreadEntry s in spreads) {
      for (final int page in s.pageIndices) {
        if (page > m) m = page;
      }
    }
    return m;
  }

  /// 纯函数：页内阅读模式切换。
  static MangaReadingMode toggleMangaMode(MangaReadingMode mode) {
    return mode == MangaReadingMode.spread
        ? MangaReadingMode.webtoon
        : MangaReadingMode.spread;
  }

  /// 纯函数：[MangaReadingMode] → 持久化的 `EpubBooks.mangaReadingMode` 字符串。
  static String modeToDbString(MangaReadingMode mode) {
    return mode == MangaReadingMode.webtoon ? 'webtoon' : 'spread';
  }

  /// 纯函数：持久化字符串 → [MangaReadingMode]（未知取 spread）。
  static MangaReadingMode modeFromDbString(String s) {
    return s == 'webtoon' ? MangaReadingMode.webtoon : MangaReadingMode.spread;
  }

  /// 大书的 manga.json 解析下放 isolate（不卡 UI）。
  ///
  /// 必须是**静态**方法：闭包在实例方法里创建时，Dart VM 的作用域上下文可能把
  /// `this`（整个 State → binding）一并塞进闭包 context，`Isolate.run` 发送消息时
  /// 直接炸 "object is unsendable"。静态方法的 context 只含 [jsonStr]，恒可发送。
  static Future<MokuroPayload> parseMangaJsonOffUi(String jsonStr) {
    return Isolate.run<MokuroPayload>(() => parseMangaJson(jsonStr));
  }

  /// 纯函数：`EpubBooks.mangaReadingMode` 列值 → 用户覆盖模式。null/空 = 未覆盖
  /// （调用方回落 [detectReadingMode] 自动判定）。
  static MangaReadingMode? modeOverrideFromDb(String? s) {
    if (s == null || s.isEmpty) return null;
    return modeFromDbString(s);
  }

  /// 纯函数：webtoon 页内 fraction（0..1）→ `ReaderPositions.charOffset` 千分比
  /// 整数（0..1000）。漫画无章内字符偏移，charOffset 被复用为滚动位置存储。
  static int webtoonFractionToCharOffset(double fraction) {
    return (fraction.clamp(0.0, 1.0) * 1000).round();
  }

  /// [webtoonFractionToCharOffset] 的逆：charOffset（可空/脏值容错）→ fraction。
  static double charOffsetToWebtoonFraction(int? charOffset) {
    if (charOffset == null || charOffset <= 0) return 0;
    return (charOffset / 1000).clamp(0.0, 1.0);
  }

  @override
  BaseSourcePageState<MangaHibikiPage> createState() => _MangaHibikiPageState();
}

class _MangaHibikiPageState extends BaseSourcePageState<MangaHibikiPage>
    with WidgetsBindingObserver {
  InAppWebViewController? _controller;
  EpubBookRow? _bookRow;

  /// `<书目录>/images`（页图根，拦截器/封面解析的穿越守卫边界）。
  String? _imagesDir;
  MokuroPayload? _payload;
  MangaReadingMode _mode = MangaReadingMode.spread;
  List<MangaSpreadEntry> _spreads = <MangaSpreadEntry>[];
  bool _loadFailed = false;

  /// 双页布局偏好：页内菜单运行时切换，不持久化，默认自动（横屏双页/竖屏单页）。
  MangaSpreadPreference _spreadPreference = MangaSpreadPreference.auto;

  /// 最近一次实际生效的布局（由 [_buildSpreadsFor] 记账），didChangeMetrics
  /// 只在解析结果真变时才重建 spread 序列，避免键盘弹出等无关 metrics 抖动。
  MangaPageLayout _pageLayout = MangaPageLayout.single;

  int _currentSpread = 0;
  int _currentPage = 0;
  double _currentFraction = 0;
  Timer? _progressDebounce;
  int _lastSavedPage = -1;
  double _lastSavedFraction = -1;

  /// 页码指示器专用（避免 webtoon 滚动高频 setState 重建整棵 Stack/WebView）。
  final ValueNotifier<int> _pageNotifier = ValueNotifier<int>(0);

  /// 当前窗口文档里物化的 spread 集合。落在集合内的翻页只需 JS translateX（不重载）；
  /// 越出集合的翻页围绕新 spread 重 loadData 一个新窗口（loadData-per-window）。
  Set<int> _loadedSpreads = <int>{};

  /// 窗口重载在飞守卫：重载是异步的，快速连滑/按住方向键会交叠 loadData，让
  /// `_loadedSpreads` 与活文档失配（translateX 目标 `data-spread` 不存在 → transform
  /// 归 0 → 显示错页）。在飞期间丢弃后续翻页（用户重发即可，不排队避免滑动风暴）。
  bool _navigating = false;

  /// 制卡卡图：当前 spread 首页图的绝对文件路径（加载/翻页/滚动/切模式全路径更新，
  /// 否则封面恒 null——ERRATA C2）。文件缺失/解析失败时为 null（卡图省略而非坏引用）。
  String? _currentPageImagePath;

  /// 最近一次查词的句子与词在句中偏移，喂制卡（[AnkiMiningContext]）。
  String _lastSentence = '';
  int _lastSentenceOffset = 0;

  ReadingTimeTracker? _readingTimeTracker;
  DateTime _sessionStartTime = DateTime.now();

  // ── 单框补扫（P4）状态 ──
  /// 识别三件套是否就绪（gating 只看模型、不看 isSupportedPlatform——那是整卷
  /// 开关；单框移动端也可用）。
  bool _rescanModelReady = false;

  /// 补扫框选模式是否激活（与 JS 侧 `__mangaSetRescanMode` 同步）。
  bool _rescanModeActive = false;

  /// 一次只跑一个识别（重复框选丢弃，识别很快、用户重发即可）。
  bool _rescanBusy = false;

  /// 补扫服务：懒建 + 页面生命周期内复用（isolate/会话缓存），dispose 释放。
  MangaBoxRescanService? _rescanService;

  static const int _kWindowRadius = 1;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 进程退出兜底：把未落盘的页码 flush 掉（与 EPUB/PDF 阅读器同纪律）。
    ExitFlushRegistry.instance.register(_flushPosition);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadBook());
  }

  @override
  void dispose() {
    ExitFlushRegistry.instance.unregister(_flushPosition);
    WidgetsBinding.instance.removeObserver(this);
    _progressDebounce?.cancel();
    // dispose 里只能 fire-and-forget；正常退出走 onSourcePagePop 的 await 路径，
    // 这里是崩溃/异常拆栈时的兜底。
    unawaited(_flushPosition());
    final MangaBoxRescanService? rescanService = _rescanService;
    if (rescanService != null) {
      _rescanService = null;
      unawaited(rescanService.dispose());
    }
    _readingTimeTracker?.dispose();
    _pageNotifier.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      unawaited(_flushPosition());
      _readingTimeTracker?.stop();
    } else if (state == AppLifecycleState.resumed) {
      // BUG-892 同款纪律：回前台重锚会话起点，否则整段后台时长被计入。
      _sessionStartTime = DateTime.now();
      _readingTimeTracker?.start();
    }
  }

  @override
  Future<void> onSourcePagePop() async {
    // 返回书架的正常路径：await 落盘，保证书架 recency/进度立刻正确。
    await _flushPosition();
    _readingTimeTracker?.stop();
  }

  @override
  void didChangeMetrics() {
    super.didChangeMetrics();
    // 旋转/窗口尺寸变化：自动布局可能在单页↔双页间翻转。didChangeMetrics 触发时
    // MediaQuery 可能尚未反映新尺寸，推迟到帧后再解析；只有解析结果真变才重建。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_applySpreadLayoutIfChanged());
    });
  }

  /// 若视口/偏好解析出的布局与当前生效布局不同，重建 spread 序列并保持当前页。
  Future<void> _applySpreadLayoutIfChanged() async {
    final MokuroPayload? payload = _payload;
    if (payload == null || _mode != MangaReadingMode.spread) return;
    if (_resolveLayout(_mode) == _pageLayout) return;
    await _rebuildSpreadsPreservingPage(payload);
  }

  /// 以新布局重建 spread 序列：保持当前 spread 首页所在页，重挂窗口文档并
  /// 落一次进度（sectionIndex 仍是 spread 首页页码，语义不变）。
  Future<void> _rebuildSpreadsPreservingPage(MokuroPayload payload) async {
    final int currentPage =
        MangaHibikiPage.firstPageOfSpread(_spreads, _currentSpread);
    final List<MangaSpreadEntry> spreads = _buildSpreadsFor(payload, _mode);
    setState(() {
      _spreads = spreads;
      _currentSpread = MangaHibikiPage.spreadIndexForPage(spreads, currentPage);
      _currentPage = MangaHibikiPage.firstPageOfSpread(spreads, _currentSpread);
    });
    _pageNotifier.value = _currentPage;
    await _loadInitialWindow();
    _updateCurrentPageImagePath();
    _recordProgress();
  }

  /// 页内菜单切换布局偏好（自动/单页/双页；运行时状态，不落库）。
  Future<void> _setSpreadPreference(MangaSpreadPreference preference) async {
    if (preference == _spreadPreference) return;
    setState(() => _spreadPreference = preference);
    final MokuroPayload? payload = _payload;
    if (payload == null || _mode != MangaReadingMode.spread) return;
    if (_resolveLayout(_mode) != _pageLayout) {
      await _rebuildSpreadsPreservingPage(payload);
    }
  }

  // ── 加载 / 恢复 ───────────────────────────────────────────────────────

  Future<void> _loadBook() async {
    final HibikiDatabase db = appModel.database;
    final EpubBookRow? row = await db.getEpubBook(widget.bookKey);
    if (!mounted) return;
    if (row == null) {
      setState(() => _loadFailed = true);
      return;
    }
    // 存储契约（与 PDF 同构）：extractDir/epubPath 指向 manga.json；页图在
    // 同目录的 images/ 下（manga.json 里的 url 是 images/ 内正斜杠相对路径）。
    final String mangaJsonPath = p.join(row.extractDir, row.epubPath);
    final File jsonFile = File(mangaJsonPath);
    if (!jsonFile.existsSync()) {
      setState(() {
        _bookRow = row;
        _loadFailed = true;
      });
      return;
    }
    final String imagesDir = p.join(p.dirname(mangaJsonPath), 'images');

    final String jsonStr = await jsonFile.readAsString();
    final MokuroPayload payload =
        await MangaHibikiPage.parseMangaJsonOffUi(jsonStr);
    if (!mounted) return;

    // 阅读模式：用户覆盖优先，null 走自动判定（页图长宽比中位数）。
    final MangaReadingMode mode =
        MangaHibikiPage.modeOverrideFromDb(row.mangaReadingMode) ??
            detectReadingMode(payload);
    final List<MangaSpreadEntry> spreads = _buildSpreadsFor(payload, mode);

    // 恢复进度：sectionIndex=0-based 页码；webtoon 的页内 fraction 从 charOffset
    // （千分比 0..1000）换算回来。
    int restoredPage = 0;
    double restoredFraction = 0;
    ReaderPosition? saved;
    try {
      saved = await ReaderPositionRepository(db).findByBookKey(widget.bookKey);
    } catch (e, stack) {
      ErrorLogService.instance.log('MangaHibikiPage.restore', e, stack);
    }
    if (!mounted) return;
    if (saved != null &&
        saved.sectionIndex >= 0 &&
        saved.sectionIndex < payload.images.length) {
      restoredPage = saved.sectionIndex;
      if (mode == MangaReadingMode.webtoon) {
        restoredFraction =
            MangaHibikiPage.charOffsetToWebtoonFraction(saved.charOffset);
      }
    }

    _readingTimeTracker ??= ReadingTimeTracker(db)..start();
    _sessionStartTime = DateTime.now();

    final int restoredSpread =
        MangaHibikiPage.restoreSpreadFromProgress(spreads, restoredPage);
    setState(() {
      _bookRow = row;
      _imagesDir = imagesDir;
      _payload = payload;
      _mode = mode;
      _spreads = spreads;
      _currentSpread = restoredSpread;
      _currentPage = MangaHibikiPage.firstPageOfSpread(spreads, restoredSpread);
      _currentFraction = restoredFraction;
      _lastSavedPage = saved != null ? restoredPage : -1;
      _lastSavedFraction = saved != null ? restoredFraction : -1;
    });
    _pageNotifier.value = _currentPage;
    // 补扫入口 gating：只看识别模型就绪（recognizerReady），失败静默（按钮点击
    // 时会再查一次并给引导提示）。
    unawaited(_refreshRescanModelReady());
  }

  /// 当前视口是否横屏（宽 > 高）。自动布局的唯一判据。
  bool get _viewportIsLandscape {
    final Size size = MediaQuery.sizeOf(context);
    return size.width > size.height;
  }

  /// 解析当前应生效的页布局：webtoon 恒单页（竖滚流布局与双页互斥）；spread 按
  /// 偏好 + 视口横竖（[resolveMangaPageLayout] 纯函数）。
  MangaPageLayout _resolveLayout(MangaReadingMode mode) {
    if (mode == MangaReadingMode.webtoon) {
      return MangaPageLayout.single;
    }
    return resolveMangaPageLayout(
      preference: _spreadPreference,
      isLandscape: _viewportIsLandscape,
    );
  }

  /// 构建 spread 序列。webtoon 每页独立；spread 模式按解析出的布局配对（双页
  /// 两两配对，奇数尾页独占；RTL 左右排序由覆盖层 direction:rtl 落实——DOM 序
  /// 前一页序在右，符合日漫右开本）。spreadOffset 恒 1：日漫惯例封面独占单页，
  /// 正文从第 2 页起两两配对（自定义偏移列未入 schema，需要时再加）。
  List<MangaSpreadEntry> _buildSpreadsFor(
    MokuroPayload payload,
    MangaReadingMode mode,
  ) {
    final MangaPageLayout layout = _resolveLayout(mode);
    _pageLayout = layout;
    return buildMangaSpreads(
      payload.images.length,
      layout: layout,
      spreadOffset: 1,
    );
  }

  // ── 拦截器（manga.local）──────────────────────────────────────────────

  static WebResourceResponse _notFound(String reason) {
    debugPrint('[MangaHibiki] 404: $reason');
    return WebResourceResponse(
      contentType: 'text/plain',
      statusCode: 404,
      reasonPhrase: 'Not Found',
      headers: <String, String>{'Access-Control-Allow-Origin': '*'},
      data: Uint8List(0),
    );
  }

  static WebResourceResponse _forbidden(String reason) {
    debugPrint('[MangaHibiki] 403: $reason');
    return WebResourceResponse(
      contentType: 'text/plain',
      statusCode: 403,
      reasonPhrase: 'Forbidden',
      headers: <String, String>{'Access-Control-Allow-Origin': '*'},
      data: Uint8List(0),
    );
  }

  Future<WebResourceResponse?> _interceptRequest(WebUri url) async {
    if (url.host != MangaHibikiPage.kMangaHost) return null;
    final String? imagesDir = _imagesDir;
    if (imagesDir == null) {
      return _notFound('imagesDir not ready: ${url.path}');
    }
    final String path = url.path;
    if (!path.startsWith('/img/')) return _notFound('unknown path: $path');
    final String relative = path.substring('/img/'.length);
    final String? filePath =
        MangaHibikiPage.resolveMangaResource(imagesDir, relative);
    if (filePath == null) {
      // 区分穿越（403）与缺文件（404）：规范化 join 后越界即穿越企图。
      final String canonicalRoot = p.canonicalize(imagesDir);
      final String candidate =
          p.canonicalize(p.join(canonicalRoot, Uri.decodeComponent(relative)));
      if (!p.isWithin(canonicalRoot, candidate)) {
        return _forbidden('path traversal blocked: $relative');
      }
      return _notFound('resource not found: $relative');
    }
    final Uint8List data = await File(filePath).readAsBytes();
    return WebResourceResponse(
      contentType: _mangaMimeForPath(filePath),
      statusCode: 200,
      reasonPhrase: 'OK',
      headers: <String, String>{
        'Access-Control-Allow-Origin': '*',
        'Cache-Control': 'max-age=3600',
      },
      data: data,
    );
  }

  static String _mangaMimeForPath(String path) {
    final String ext = p.extension(path).toLowerCase();
    switch (ext) {
      case '.png':
        return 'image/png';
      case '.webp':
        return 'image/webp';
      case '.gif':
        return 'image/gif';
      case '.jpg':
      case '.jpeg':
      default:
        return 'image/jpeg';
    }
  }

  // ── 单文档窗口化 ─────────────────────────────────────────────────────

  /// 生成当前窗口文档 HTML。
  ///
  /// spread（loadData-per-window）：只物化 [_currentSpread] 附近窗口内的 spread，
  /// flex-row + overflow:hidden 视口 + translateX 到当前 spread；翻出窗口才重
  /// loadData。webtoon：**整本**一次性渲染进单文档（窗口化只是 spread 的优化），
  /// 靠文档竖滚翻页，滚动绝不重载（否则在手指下抹掉重建/抢滚）。
  String _buildWindowDocument(String inlineSelectionJs) {
    final MokuroPayload payload = _payload!;
    final bool isWebtoon = _mode == MangaReadingMode.webtoon;

    final List<int> keptSpreads = isWebtoon
        ? <int>[for (int i = 0; i < _spreads.length; i++) i]
        : MangaHibikiPage.mangaWindowRange(
            spreadCount: _spreads.length,
            current: _currentSpread,
            radius: _kWindowRadius,
          );
    _loadedSpreads = keptSpreads.toSet();
    final Set<int> keptPages = <int>{
      for (final int s in keptSpreads) ..._spreads[s].pageIndices,
    };
    final List<MokuroImage> pages = <MokuroImage>[];
    final List<String> imgSrcs = <String>[];
    final List<int> pageSpreadIndices = <int>[];
    final List<int> pagesPerSpread = <int>[];
    final List<int> pageNumbers = <int>[];
    for (final int page in keptPages.toList()..sort()) {
      if (page < 0 || page >= payload.images.length) continue;
      final MokuroImage image = payload.images[page];
      pages.add(image);
      imgSrcs.add(MangaHibikiPage.mangaImageUrl(image.url));
      final int spreadIndex =
          MangaHibikiPage.spreadIndexForPage(_spreads, page);
      pageSpreadIndices.add(spreadIndex);
      pagesPerSpread.add(spreadIndex >= 0 && spreadIndex < _spreads.length
          ? _spreads[spreadIndex].pageIndices.length
          : 1);
      // 真实整卷页码（data-page，补扫模式回传的 pageIndex 语义）。
      pageNumbers.add(page);
    }
    return mangaWindowDocument(
      pages,
      imgSrcs,
      mode: _mode,
      spreadDirection: MangaHibikiPage.kSpreadDirection,
      inlineSelectionJs: inlineSelectionJs,
      pageSpreadIndices: pageSpreadIndices,
      pagesPerSpread: pagesPerSpread,
      pageNumbers: pageNumbers,
      currentSpread: _currentSpread,
      restoreFraction: isWebtoon ? _currentFraction : 0,
    );
  }

  /// （重）加载当前 spread 的窗口文档。设置在飞守卫，让并发翻页不能交叠 loadData；
  /// `_loadedSpreads`（在 [_buildWindowDocument] 内同步赋值）只在本次成功后生效，
  /// 失败回滚为旧文档的集合（否则 translateX 目标缺失、transform 归 0）。
  Future<void> _loadInitialWindow() async {
    if (_payload == null || _controller == null) return;
    _navigating = true;
    final Set<int> previousLoaded = Set<int>.of(_loadedSpreads);
    try {
      final String doc = _buildWindowDocument(ReaderSelectionScripts.source());
      await _controller!.loadData(
        data: doc,
        baseUrl: WebUri('https://${MangaHibikiPage.kMangaHost}/'),
        mimeType: 'text/html',
        encoding: 'utf-8',
      );
      // 首窗图作为制卡卡图（ERRATA C2）；在 _spreads/_currentSpread 定型后解析。
      _updateCurrentPageImagePath();
      // 窗口重载换了新文档，JS 侧补扫模式状态清零；Dart 态仍激活则续上，
      // 否则按钮态与 JS 态失配（按钮亮着但拖不出框）。
      if (_rescanModeActive) {
        await _controller!.evaluateJavascript(
          source: 'window.__mangaSetRescanMode && '
              'window.__mangaSetRescanMode(true);',
        );
      }
    } catch (_) {
      _loadedSpreads = previousLoaded;
      rethrow;
    } finally {
      _navigating = false;
    }
  }

  // ── 翻页导航 ─────────────────────────────────────────────────────────

  /// 按 [dir] 推进当前 spread（'next' = 页序 +1 / 'prev' = -1，clamp 到书范围）。
  /// 新 spread 仍在已加载窗口内 → 只 JS translateX；越出 → 围绕它重 loadData 新窗口。
  /// 同步更新制卡卡图（ERRATA C2）并记进度。
  Future<void> _onMangaTurn(String dir) async {
    if (_spreads.isEmpty) return;
    if (_navigating) return;
    final int delta = dir == 'next' ? 1 : -1;
    final int target =
        (_currentSpread + delta).clamp(0, _spreads.length - 1).toInt();
    if (target == _currentSpread) return;
    _currentSpread = target;
    if (_loadedSpreads.contains(target)) {
      await _controller?.evaluateJavascript(
        source: 'window.__mangaApplyTranslate && '
            'window.__mangaApplyTranslate($target);',
      );
      // 窗口边缘再滑窗，让下一次翻页有预加载邻页。
      final int lo = _loadedSpreads.reduce((int a, int b) => a < b ? a : b);
      final int hi = _loadedSpreads.reduce((int a, int b) => a > b ? a : b);
      final bool atEdge = (target == lo && lo > 0) ||
          (target == hi && hi < _spreads.length - 1);
      if (atEdge) {
        await _loadInitialWindow();
      } else {
        _updateCurrentPageImagePath();
      }
    } else {
      await _loadInitialWindow();
    }
    _recordProgress();
  }

  /// 桌面键盘翻页（webtoon 交 WebView 原生竖滚，方向键一律 ignored）。
  ///
  /// - 只认 KeyDownEvent；KeyRepeatEvent（按住）丢弃，按住方向键不堆翻页风暴。
  /// - 查词弹窗显示时 return ignored，让方向键/空格到弹窗（词典导航/关闭）。
  KeyEventResult _handleReaderKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    if (isDictionaryShown) {
      return KeyEventResult.ignored;
    }
    // 补扫模式：Escape 退出（其余键不当翻页，避免框选中翻走当前页）。
    if (_rescanModeActive) {
      if (event.logicalKey == LogicalKeyboardKey.escape) {
        unawaited(_setRescanMode(false));
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }
    // webtoon 是纵向单列滚动——纵向键属于 WebView 原生滚动，绝不当翻页：webtoon 里
    // 每页 width:100vw、offsetLeft≈0，__mangaApplyTranslate 是 no-op，把键路由到
    // _onMangaTurn 只会推进 _currentSpread 并落一个零可见位移的假进度。
    if (_mode == MangaReadingMode.webtoon) {
      return KeyEventResult.ignored;
    }
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowRight ||
        key == LogicalKeyboardKey.arrowDown ||
        key == LogicalKeyboardKey.space ||
        key == LogicalKeyboardKey.pageDown) {
      unawaited(_onMangaTurn('next'));
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft ||
        key == LogicalKeyboardKey.arrowUp ||
        key == LogicalKeyboardKey.pageUp) {
      unawaited(_onMangaTurn('prev'));
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// webtoon 滚动报告：从 JS 量得的视口更新页内 fraction + 当前页/spread。
  /// 整本单文档，滚动**绝不**重载——只更新进度与制卡卡图。[fraction] 是视口顶
  /// 所在页的**页内**归一化偏移（与 `__mangaScrollToSpread` 恢复口径一致）。
  Future<void> _onMangaScroll(String payloadJson) async {
    if (_mode != MangaReadingMode.webtoon || _spreads.isEmpty) return;
    final Object? decoded = jsonDecode(payloadJson);
    if (decoded is! Map) return;
    final double fraction = (decoded['fraction'] as num?)?.toDouble() ?? 0;
    final int topSpread =
        ((decoded['topPage'] as num?)?.toInt() ?? _currentSpread)
            .clamp(0, _spreads.length - 1)
            .toInt();
    _currentFraction = fraction.clamp(0.0, 1.0);
    final bool spreadChanged = topSpread != _currentSpread;
    _currentSpread = topSpread;
    if (spreadChanged) {
      _updateCurrentPageImagePath();
    }
    _recordProgress();
  }

  /// 解析当前 spread 首页图的绝对文件路径，作为 Anki 卡图（ERRATA C2——
  /// [onMineFromPopup] 经 [_currentPageImagePath] 读回）。加载/翻页/滚动/切模式
  /// 全路径调用；缺文件/解析失败置 null（卡图省略而非坏引用）。
  void _updateCurrentPageImagePath() {
    final MokuroPayload? payload = _payload;
    final String? imagesDir = _imagesDir;
    if (payload == null || imagesDir == null || _spreads.isEmpty) {
      _currentPageImagePath = null;
      return;
    }
    final int page =
        MangaHibikiPage.firstPageOfSpread(_spreads, _currentSpread);
    if (page < 0 || page >= payload.images.length) {
      _currentPageImagePath = null;
      return;
    }
    _currentPageImagePath = MangaHibikiPage.resolveMangaResource(
        imagesDir, payload.images[page].url);
  }

  // ── 单框补扫（P4 生产者 D）────────────────────────────────────────────

  /// 刷新识别模型就绪位（只看 recognizerReady——单框不需要检测器；也不看
  /// isSupportedPlatform——那是整卷开关，单框移动端可用）。
  Future<void> _refreshRescanModelReady() async {
    try {
      final MangaOcrModelStatus status =
          await ref.read(mangaOcrServiceProvider).modelStatus();
      if (!mounted) return;
      setState(() => _rescanModelReady = status.recognizerReady);
    } catch (e, stack) {
      ErrorLogService.instance.log('MangaHibikiPage.rescanStatus', e, stack);
    }
  }

  /// chrome「框选识别」按钮：模式内再点 = 退出；未就绪点击给引导去设置下载的
  /// 提示（点击时再查一次，用户可能刚下载完）。
  Future<void> _onRescanButtonPressed() async {
    if (_rescanModeActive) {
      await _setRescanMode(false);
      return;
    }
    if (!isLocalOnnxRuntimeAvailable) {
      // Apple 无内置 ONNX OCR：单框补扫依赖云端（Gemini）。云端未启用则提示不支持，
      // 已启用则直接进补扫模式（不要求下载对 Apple 无用的本地识别模型）。
      if (!isCloudOcrAvailable(
        enabled: appModel.mangaCloudOcrEnabled,
        apiKey: appModel.mangaCloudOcrApiKey,
      )) {
        HibikiToast.show(msg: t.manga_ocr_unsupported);
        return;
      }
      await _setRescanMode(true);
      return;
    }
    if (!_rescanModelReady) {
      await _refreshRescanModelReady();
      if (!_rescanModelReady) {
        HibikiToast.show(msg: t.manga_rescan_model_missing);
        return;
      }
    }
    await _setRescanMode(true);
  }

  /// Dart/JS 双侧同步进入/退出补扫模式。
  Future<void> _setRescanMode(bool on) async {
    if (!mounted) return;
    setState(() => _rescanModeActive = on);
    await _controller?.evaluateJavascript(
      source: 'window.__mangaSetRescanMode && '
          'window.__mangaSetRescanMode(${on ? 'true' : 'false'});',
    );
    if (on) {
      HibikiToast.show(msg: t.manga_rescan_mode_hint);
    }
  }

  /// JS 框选回传（`onMangaBoxSelected`）：payload 是
  /// `{pageIndex, left, top, right, bottom}`——pageIndex 为 0-based 整卷页码，
  /// 坐标为**该页页图像素**（跨页 spread 已在 JS 侧按框中心落页并 clamp）。
  /// JS 发出有效框即自动退出模式，这里同步复位按钮态。
  Future<void> _onMangaBoxSelected(String payloadJson) async {
    if (mounted && _rescanModeActive) {
      setState(() => _rescanModeActive = false);
    }
    final MokuroPayload? payload = _payload;
    final String? imagesDir = _imagesDir;
    if (payload == null || imagesDir == null || _rescanBusy) return;
    Object? decoded;
    try {
      decoded = jsonDecode(payloadJson);
    } catch (_) {
      return;
    }
    if (decoded is! Map) return;
    final int pageIndex = (decoded['pageIndex'] as num?)?.toInt() ?? -1;
    if (pageIndex < 0 || pageIndex >= payload.images.length) return;
    final OcrRect box = OcrRect(
      left: (decoded['left'] as num?)?.toDouble() ?? 0,
      top: (decoded['top'] as num?)?.toDouble() ?? 0,
      right: (decoded['right'] as num?)?.toDouble() ?? 0,
      bottom: (decoded['bottom'] as num?)?.toDouble() ?? 0,
    );
    // JS 侧已按视口 8px 过滤；这里按页图像素二次防御（畸形 payload）。
    if (box.width < 8 || box.height < 8) return;
    final String? imagePath = MangaHibikiPage.resolveMangaResource(
        imagesDir, payload.images[pageIndex].url);
    if (imagePath == null) {
      HibikiToast.show(msg: t.manga_rescan_failed);
      return;
    }
    if (!isLocalOnnxRuntimeAvailable) {
      // Apple：本地 OCR 不可用，单框直接走云端（若已启用），否则提示不支持。
      // 不崩、不阻塞——契约与 ocr_inference_ort.dart isLocalOnnxRuntimeAvailable 一致。
      if (isCloudOcrAvailable(
        enabled: appModel.mangaCloudOcrEnabled,
        apiKey: appModel.mangaCloudOcrApiKey,
      )) {
        await _rescanCloudRetry(
          pageIndex: pageIndex,
          box: box,
          imagePath: imagePath,
          vertical: mangaBoxIsVertical(box),
        );
      } else {
        HibikiToast.show(msg: t.manga_ocr_unsupported);
      }
      return;
    }
    _rescanBusy = true;
    HibikiToast.show(msg: t.manga_rescan_running);
    try {
      final MangaBoxRescanService service =
          _rescanService ??= MangaBoxRescanService();
      final MangaBoxRescanResult result =
          await service.rescan(imagePath: imagePath, box: box);
      if (!mounted) return;
      await _showRescanResult(
        pageIndex: pageIndex,
        box: box,
        imagePath: imagePath,
        text: result.text.trim(),
        vertical: result.vertical,
        fromCloud: false,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('MangaHibikiPage.rescan', e, stack);
      if (mounted) HibikiToast.show(msg: t.manga_rescan_failed);
    } finally {
      _rescanBusy = false;
    }
  }

  /// 结果底部卡片：文本 + 来源标注 + 动作（查词 / 回写本页 / 云端重试）。
  /// 「云端重试」只在开关开 + key 非空时显示（红线：默认关、手动触发）。
  Future<void> _showRescanResult({
    required int pageIndex,
    required OcrRect box,
    required String imagePath,
    required String text,
    required bool vertical,
    required bool fromCloud,
  }) async {
    if (!mounted) return;
    final bool cloudAvailable = isCloudOcrAvailable(
      enabled: appModel.mangaCloudOcrEnabled,
      apiKey: appModel.mangaCloudOcrApiKey,
    );
    final MangaRescanAction? action =
        await showModalBottomSheet<MangaRescanAction>(
      context: context,
      builder: (BuildContext ctx) => MangaRescanResultSheet(
        text: text,
        fromCloud: fromCloud,
        showCloudRetry: cloudAvailable,
      ),
    );
    if (!mounted || action == null) return;
    switch (action) {
      case MangaRescanAction.lookup:
        await _rescanLookup(text);
      case MangaRescanAction.writeBack:
        await _rescanWriteBack(
          pageIndex: pageIndex,
          box: box,
          vertical: vertical,
          text: text,
        );
      case MangaRescanAction.cloudRetry:
        await _rescanCloudRetry(
          pageIndex: pageIndex,
          box: box,
          imagePath: imagePath,
          vertical: vertical,
        );
    }
  }

  /// 以识别文本为 searchTerm 走既有词典查询管线（弹窗锚屏幕中心，镜像块级
  /// 兜底路径）；句子上下文 = 识别文本本身（气泡即句子）。
  Future<void> _rescanLookup(String text) async {
    if (text.isEmpty || !mounted) return;
    _lastSentence = text;
    _lastSentenceOffset = 0;
    appModel.currentMediaSource?.setCurrentSentence(
      selection: HibikiTextSelection(text: text),
    );
    final Size screen = MediaQuery.of(context).size;
    prunePopupStack(0);
    await searchDictionaryResult(
      searchTerm: text,
      selectionRect: Rect.fromCenter(
        center: Offset(screen.width / 2, screen.height / 2),
        width: 1,
        height: 1,
      ),
    );
  }

  /// 把识别块回写进本书 manga.json 对应页（读-改-写，文件级锁），再重读文件
  /// 刷新内存 payload 并重载当前窗口，让新框立即可查词。
  Future<void> _rescanWriteBack({
    required int pageIndex,
    required OcrRect box,
    required bool vertical,
    required String text,
  }) async {
    final EpubBookRow? row = _bookRow;
    if (row == null || text.isEmpty) return;
    final String mangaJsonPath = p.join(row.extractDir, row.epubPath);
    try {
      await appendMangaBlockToMangaJson(
        mangaJsonPath: mangaJsonPath,
        pageIndex: pageIndex,
        box: Rect.fromLTRB(box.left, box.top, box.right, box.bottom),
        vertical: vertical,
        text: text,
      );
      final String jsonStr = await File(mangaJsonPath).readAsString();
      final MokuroPayload payload =
          await MangaHibikiPage.parseMangaJsonOffUi(jsonStr);
      if (!mounted) return;
      setState(() => _payload = payload);
      await _loadInitialWindow();
      HibikiToast.show(msg: t.manga_rescan_writeback_done);
    } catch (e, stack) {
      ErrorLogService.instance.log('MangaHibikiPage.rescanWrite', e, stack);
      if (mounted) HibikiToast.show(msg: t.manga_rescan_writeback_failed);
    }
  }

  /// 云端重试：裁框 PNG →（明示上云的）Gemini 转写 → 以云端结果重开结果卡片。
  /// 只有用户点按钮才会走到这里（不做自动路由）；[CloudOcrService] 内还有
  /// 开关闸门（关着时零网络调用）。
  Future<void> _rescanCloudRetry({
    required int pageIndex,
    required OcrRect box,
    required String imagePath,
    required bool vertical,
  }) async {
    HibikiToast.show(msg: t.manga_rescan_running);
    try {
      final Uint8List png = await MangaBoxRescanService.cropBoxPng(
        imagePath: imagePath,
        box: box,
      );
      final CloudOcrService cloud = CloudOcrService(
        enabled: appModel.mangaCloudOcrEnabled,
        apiKey: appModel.mangaCloudOcrApiKey,
        model: appModel.mangaCloudOcrModel,
      );
      final String text = (await cloud.transcribePng(png)).trim();
      if (!mounted) return;
      await _showRescanResult(
        pageIndex: pageIndex,
        box: box,
        imagePath: imagePath,
        text: text,
        vertical: vertical,
        fromCloud: true,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('MangaHibikiPage.rescanCloud', e, stack);
      if (mounted) HibikiToast.show(msg: t.manga_cloud_ocr_failed);
    }
  }

  // ── 查词（L7）────────────────────────────────────────────────────────

  /// 注册**全工程唯一**的 `onTextSelected` Dart handler（ERRATA H2）。触发它的
  /// pointerup 监听内嵌且仅存在于 [mangaWindowDocument]（L3），本方法绝不注册第二个
  /// pointerup。payload 解码成 [ReaderSelectionData] 转发 [processMangaSelection]，
  /// 镜像 reader_hibiki 的现代形态（webview.part.dart）。
  void _registerSelectionHandlers(InAppWebViewController controller) {
    controller.addJavaScriptHandler(
      handlerName: 'onTextSelected',
      callback: (List<dynamic> args) async {
        if (args.isEmpty) return;
        try {
          final Map<String, dynamic> payload =
              jsonDecode(args[0] as String) as Map<String, dynamic>;
          await processMangaSelection(ReaderSelectionData.fromJson(payload));
        } catch (e, stack) {
          ErrorLogService.instance.log('MangaHibiki.onTextSelected', e, stack);
          debugPrint('[MangaHibiki] onTextSelected error: $e');
        }
      },
    );
  }

  /// 处理框内 tap 选词 payload：记录框内句子（喂制卡/收藏）并在选区矩形上开查词
  /// 弹窗。词/句/矩形契约由纯函数 [dispatchMangaSelection] 承担（可单测）。
  Future<void> processMangaSelection(ReaderSelectionData data) async {
    if (!mounted) return;
    final Size screen = MediaQuery.of(context).size;
    await dispatchMangaSelection(
      data,
      fallbackScreen: screen,
      setSentence: (String sentence) {
        // TODO-956 下限兜底：句子派生不出时退回词本身，绝不让收藏/制卡拿到空句。
        final String resolved =
            ReaderSelectionScripts.resolveCurrentSentenceText(
                sentence, data.text);
        _lastSentence = resolved;
        _lastSentenceOffset = data.sentenceOffset;
        appModel.currentMediaSource?.setCurrentSentence(
          selection: HibikiTextSelection(text: resolved),
        );
      },
      search: (String term, Rect selectionRect) async {
        prunePopupStack(0);
        await searchDictionaryResult(
          searchTerm: term,
          selectionRect: selectionRect,
        );
      },
    );
  }

  // ── 制卡（L7）────────────────────────────────────────────────────────

  /// 查词弹窗里点「+」制卡。句子 = 最近一次查词的框内句（气泡即句子）；卡图 =
  /// **当前页图的文件路径**（页图本就在盘上，直接传路径经 [AnkiMiningContext.coverPath]
  /// 走 `{book-cover}`/`{card-image}` 通道）。漫画无音轨，sasayaki 音频字段恒 null。
  @override
  Future<MinePopupResult> onMineFromPopup(Map<String, String> fields) async {
    final BaseAnkiRepository repo = ref.read(ankiRepositoryProvider);
    try {
      final String sentence =
          _lastSentence.isNotEmpty ? _lastSentence : (fields['sentence'] ?? '');

      String? coverPath;
      final String? pageImage = _currentPageImagePath;
      if (pageImage != null && File(pageImage).existsSync()) {
        // mokuro 页图自带合法图片扩展名；仅无扩展名的裁剪输出需要补 .png（M2）。
        coverPath = await ensureMangaCoverPng(pageImage);
      }

      final AnkiMiningContext miningContext = AnkiMiningContext(
        sentence: sentence,
        documentTitle: _bookRow?.title,
        coverPath: coverPath,
        sentenceOffset: _lastSentenceOffset,
        source: AnkiMiningSource.book,
        bookTitleTag: appModel.autoAddBookNameToTags
            ? BaseAnkiRepository.sanitizeTitleTag(_bookRow?.title)
            : null,
      );

      HibikiToast.showMine(
        msg: t.card_mining_pending,
        status: MineToastStatus.pending,
      );
      final MineOutcome outcome = await repo.mineEntry(
        rawPayloadJson: jsonEncode(fields),
        context: miningContext,
      );
      final String deckName = outcome.result == MineResult.success
          ? (await repo.loadSettings()).selectedDeckName ?? ''
          : '';
      final described = describeMineOutcome(outcome, deckName: deckName);
      if (described.record) {
        unawaited(_recordMinedCount());
      }
      HibikiToast.showMine(msg: described.message, status: described.status);
      if (described.success) {
        return MinePopupResult(ankiConnect: true, noteId: outcome.noteId);
      }
      return const MinePopupResult();
    } catch (e, stack) {
      ErrorLogService.instance.log('MangaHibikiPage.onMineFromPopup', e, stack);
      return const MinePopupResult();
    }
  }

  Future<void> _recordMinedCount() async {
    try {
      await appModel.database.addMiningCount(
        sourceType: kStatSourceBook,
        dateKey: statDateKey(DateTime.now()),
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('MangaHibikiPage.recordMined', e, stack);
    }
  }

  // ── 阅读模式覆盖 ─────────────────────────────────────────────────────

  /// 页内切换 spread/webtoon，并把用户覆盖写进 `EpubBooks.mangaReadingMode`
  /// （之后开书恒用覆盖值，不再自动判定）。跨布局保当前页。
  Future<void> _toggleReadingMode() async {
    final MokuroPayload? payload = _payload;
    if (_bookRow == null || payload == null) return;
    final MangaReadingMode next = MangaHibikiPage.toggleMangaMode(_mode);
    final int currentPage =
        MangaHibikiPage.firstPageOfSpread(_spreads, _currentSpread);
    final HibikiDatabase db = appModel.database;
    try {
      await (db.update(db.epubBooks)
            ..where(($EpubBooksTable t) => t.bookKey.equals(widget.bookKey)))
          .write(EpubBooksCompanion(
        mangaReadingMode: Value<String?>(MangaHibikiPage.modeToDbString(next)),
      ));
    } catch (e, stack) {
      ErrorLogService.instance.log('MangaHibikiPage.toggleMode', e, stack);
    }
    if (!mounted) return;
    final List<MangaSpreadEntry> spreads = _buildSpreadsFor(payload, next);
    setState(() {
      _mode = next;
      _spreads = spreads;
      _currentSpread = MangaHibikiPage.spreadIndexForPage(spreads, currentPage);
      _currentPage = currentPage;
      _currentFraction = 0;
    });
    _pageNotifier.value = _currentPage;
    await _loadInitialWindow();
    // 布局变化会换掉当前 spread 背后的页（ERRATA C2）。
    _updateCurrentPageImagePath();
    HibikiToast.show(
      msg: next == MangaReadingMode.webtoon
          ? t.manga_reading_mode_webtoon
          : t.manga_reading_mode_spread,
    );
  }

  // ── 页码进度持久化 ───────────────────────────────────────────────────

  void _recordProgress() {
    final (int page, double fraction) = MangaHibikiPage.mangaProgressForSpread(
      _spreads,
      _currentSpread,
      webtoonFraction: _currentFraction,
      isWebtoon: _mode == MangaReadingMode.webtoon,
    );
    _currentPage = page;
    _pageNotifier.value = page;
    // 600ms debounce：连续翻页/滚动只落最后一次。
    _progressDebounce?.cancel();
    _progressDebounce = Timer(const Duration(milliseconds: 600), () {
      unawaited(_persistPosition(page, fraction));
    });
  }

  Future<void> _persistPosition(int page, double fraction) async {
    _lastSavedPage = page;
    _lastSavedFraction = fraction;
    final HibikiDatabase db = appModel.database;
    final bool isWebtoon = _mode == MangaReadingMode.webtoon;
    try {
      await ReaderPositionRepository(db).save(
        bookKey: widget.bookKey,
        sectionIndex: page,
        normCharOffset: 0,
        // 漫画无章内字符偏移。**必须显式传值**（传 null 会掉进 EPUB 专用的「跨
        // section 精确锚失效」启发式）：spread 恒 0；webtoon 复用 charOffset 存
        // 页内滚动千分比（0..1000），恢复时换算回 fraction。
        charOffset: isWebtoon
            ? MangaHibikiPage.webtoonFractionToCharOffset(fraction)
            : 0,
      );
    } catch (e, stack) {
      ErrorLogService.instance
          .log('MangaHibikiPage._persistPosition', e, stack);
    }
    // 翻到最后一页 → 幂等写「已读完」（判据用总页数）。
    final int pageCount = _payload?.images.length ?? 0;
    final bool completed = pageCount > 0 && page >= pageCount - 1;
    if (completed) {
      try {
        await db.markEpubBookCompletedIfUnset(widget.bookKey, DateTime.now());
      } catch (e, stack) {
        ErrorLogService.instance.log('MangaHibikiPage.markCompleted', e, stack);
      }
    }
    // 漫画没有 Bangumi 的“页”进度：自动映射会按卷记录，只有翻到最后一页才入队；
    // 若用户手工选择了“话”，则 page+1 仍作为其明确选择下的本地进度来源。
    // 部分页面测试用轻量 AppModel 覆写 database getter，但不会走完整 initialise；
    // 此时只保留原有本地页码写入，不触碰依赖正式数据库生命周期的自动记录服务。
    if (!appModel.isDatabaseReady) return;
    await appModel.mediaTrackingService.recordBookProgress(
      bookKey: widget.bookKey,
      completedChapterCount: page + 1,
      completed: completed,
    );
  }

  Future<void> _flushPosition() async {
    _progressDebounce?.cancel();
    if (_bookRow == null || _payload == null) return;
    if (_currentPage != _lastSavedPage ||
        (_mode == MangaReadingMode.webtoon &&
            _currentFraction != _lastSavedFraction)) {
      await _persistPosition(_currentPage, _currentFraction);
    }
    await _flushReadingStats();
  }

  /// 落本次会话的阅读时长 + 首页「学习活动」事件。
  ///
  /// 与 PDF 同款纪律、刻意不复用 EPUB 的实现：EPUB 那条以 `charsRead <= 0` 早退，
  /// 漫画无字数会整段被丢。这里以**时长**为触发条件，`charsRead` 恒 0——「页数」
  /// 绝不塞进 charsRead，否则污染统计页「字数」口径与派生指标。
  Future<void> _flushReadingStats() async {
    final EpubBookRow? row = _bookRow;
    if (row == null) return;
    final DateTime now = DateTime.now();
    final int elapsedMs = now.difference(_sessionStartTime).inMilliseconds;
    _sessionStartTime = now;
    if (elapsedMs < 1000) return;
    if (!isContinuousReadingGap(
        now.subtract(Duration(milliseconds: elapsedMs)), now)) {
      return;
    }
    final String dateKey = statDateKey(now);
    try {
      await appModel.database.addReadingStatistic(
        title: row.title,
        dateKey: dateKey,
        charsRead: 0,
        timeMs: elapsedMs,
      );
      await appModel.database.addActivityEvent(
        eventType: kActivityRead,
        mediaType: kActivityMediaBook,
        title: row.title,
        mediaKey: widget.bookKey,
        dateKey: dateKey,
        timestampMs: now.millisecondsSinceEpoch,
        durationMs: elapsedMs,
        charsDelta: 0,
      );
    } catch (e, stack) {
      ErrorLogService.instance
          .log('MangaHibikiPage._flushReadingStats', e, stack);
    }
  }

  // ── 图片放大（独立全屏路由）──────────────────────────────────────────

  void _openMangaImageViewer(String imgUrl) {
    final String? imagesDir = _imagesDir;
    if (imagesDir == null) return;
    final String? filePath =
        MangaHibikiPage.resolveImageUrlToFile(imagesDir, imgUrl);
    if (filePath == null) return;
    final File file = File(filePath);
    if (!file.existsSync()) return;
    Navigator.push(
      context,
      PageRouteBuilder<void>(
        opaque: false,
        barrierColor:
            Theme.of(context).colorScheme.scrim.withValues(alpha: 0.87),
        barrierDismissible: true,
        pageBuilder: (_, __, ___) => GestureDetector(
          onTap: () => Navigator.pop(context),
          child: InteractiveViewer(
            minScale: 0.5,
            maxScale: 10,
            child: Center(child: Image.file(file, fit: BoxFit.contain)),
          ),
        ),
      ),
    );
  }

  // ── UI ───────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) return;
        // 在 await 前拿住 navigator：onWillPop 是异步长操作（落位置 + closeMedia）。
        final NavigatorState navigator = Navigator.of(context);
        final bool shouldPop = await onWillPop();
        if (!mounted || !shouldPop) return;
        navigator.pop();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        resizeToAvoidBottomInset: false,
        // 屏幕尺寸 Stack：WebView 以 scale 1.0、inset 0 渲染，buildDictionary() 是
        // 全出血 sibling，calcPopupPosition 才能把 JS getClientRects 视口坐标直接
        // 当屏幕坐标（弹窗坐标契约）。buildDictionary() 绝不嵌进有 padding/偏移/
        // 滚动的子树。
        body: Stack(
          fit: StackFit.expand,
          children: <Widget>[
            // 桌面键盘/焦点兜底翻页：WebView JS 手势机管触摸/鼠标滑动，这里给方向键。
            Positioned.fill(
              child: Focus(
                autofocus: true,
                onKeyEvent: _handleReaderKey,
                child: _buildBody(),
              ),
            ),
            // 顶部 chrome：页码指示 + 阅读模式切换。
            if (_bookRow != null && !_loadFailed)
              Positioned(
                top: 0,
                right: 0,
                child: SafeArea(child: _buildTopChrome()),
              ),
            // 查词弹窗层：必须在树里，否则查到结果也不显示。
            Positioned.fill(
              key: const ValueKey<String>('manga_dictionary_host'),
              child: buildDictionary(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopChrome() {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ValueListenableBuilder<int>(
          valueListenable: _pageNotifier,
          builder: (BuildContext context, int page, Widget? child) {
            final int pageCount = _payload?.images.length ?? 0;
            if (pageCount <= 0) return const SizedBox.shrink();
            // 双页 spread 显示页码区间（如 3-4 / 40）；单页保持原样。
            final int spreadIndex =
                MangaHibikiPage.spreadIndexForPage(_spreads, page);
            final MangaSpreadEntry? entry =
                (spreadIndex >= 0 && spreadIndex < _spreads.length)
                    ? _spreads[spreadIndex]
                    : null;
            final String label = (entry != null && entry.isSpread)
                ? '${entry.pageIndices.first + 1}-'
                    '${entry.pageIndices.last + 1} / $pageCount'
                : '${page + 1} / $pageCount';
            return Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                label,
                style: Theme.of(context)
                    .textTheme
                    .labelLarge
                    ?.copyWith(color: Colors.white70),
              ),
            );
          },
        ),
        // 补扫「框选识别」入口（P4）：常显；模型未就绪时点击给引导提示（gating
        // 只看识别模型就绪，移动端同样可用）。激活时高亮。
        Tooltip(
          message: t.manga_rescan_button,
          child: IconButton(
            key: const ValueKey<String>('manga_rescan_button'),
            icon: Icon(
              Icons.highlight_alt_outlined,
              color: _rescanModeActive
                  ? Theme.of(context).colorScheme.primary
                  : Colors.white,
            ),
            onPressed: () => unawaited(_onRescanButtonPressed()),
          ),
        ),
        // 布局偏好菜单（自动/单页/双页）：只对 spread 模式有意义，webtoon 恒单页。
        if (_mode == MangaReadingMode.spread)
          PopupMenuButton<MangaSpreadPreference>(
            tooltip: t.spread_mode,
            icon: const Icon(Icons.menu_book_outlined, color: Colors.white),
            initialValue: _spreadPreference,
            onSelected: (MangaSpreadPreference preference) =>
                unawaited(_setSpreadPreference(preference)),
            itemBuilder: (BuildContext context) =>
                <PopupMenuEntry<MangaSpreadPreference>>[
              CheckedPopupMenuItem<MangaSpreadPreference>(
                value: MangaSpreadPreference.auto,
                checked: _spreadPreference == MangaSpreadPreference.auto,
                child: Text(t.spread_auto),
              ),
              CheckedPopupMenuItem<MangaSpreadPreference>(
                value: MangaSpreadPreference.single,
                checked: _spreadPreference == MangaSpreadPreference.single,
                child: Text(t.spread_off),
              ),
              CheckedPopupMenuItem<MangaSpreadPreference>(
                value: MangaSpreadPreference.double,
                checked: _spreadPreference == MangaSpreadPreference.double,
                child: Text(t.spread_on),
              ),
            ],
          ),
        Tooltip(
          message: t.manga_mode_toggle,
          child: IconButton(
            icon: Icon(
              _mode == MangaReadingMode.webtoon
                  ? Icons.view_day_outlined
                  : Icons.auto_stories_outlined,
              color: Colors.white,
            ),
            onPressed: () => unawaited(_toggleReadingMode()),
          ),
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (_loadFailed) {
      return Center(
        child: Text(
          t.book_file_not_found,
          style: const TextStyle(color: Colors.white70),
        ),
      );
    }
    if (_bookRow == null || _imagesDir == null || _payload == null) {
      return buildLoading();
    }
    // 平台无关的「内容已加载」标记：非 Linux 是原生 WebView，Linux 是无后端占位
    // （`manga_webview` key 仅存在于前者，随宿主平台变化）。加载成功的普适可观察
    // 契约挂这里，widget 测试三端（含 Linux CI）一致命中，不再依赖平台门控的
    // WebView key。
    return KeyedSubtree(
      key: const ValueKey<String>('manga_content_ready'),
      child: _buildWebView(),
    );
  }

  /// 只在有 WebView 后端的平台构造原生 WebView（Linux 无 flutter_inappwebview
  /// 后端；widget 测试宿主的加载早退路径也永不触达这里）。
  Widget _buildWebView() {
    if (Platform.isLinux) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            t.book_file_not_found,
            style: const TextStyle(color: Colors.white70),
          ),
        ),
      );
    }
    return InAppWebView(
      key: const ValueKey<String>('manga_webview'),
      initialSettings: InAppWebViewSettings(
        verticalScrollBarEnabled: false,
        horizontalScrollBarEnabled: false,
        scrollbarFadingEnabled: false,
        databaseEnabled: false,
        domStorageEnabled: false,
        useShouldInterceptRequest: true,
        transparentBackground: true,
      ),
      onWebViewCreated: (InAppWebViewController controller) {
        _controller = controller;
        // ERRATA H2/C1：唯一的 onTextSelected 注册点。
        _registerSelectionHandlers(controller);
        // 框间裸图 tap → 独立全屏放大路由。
        controller.addJavaScriptHandler(
          handlerName: 'onImageTap',
          callback: (List<dynamic> args) {
            if (args.isEmpty) return;
            _openMangaImageViewer(args[0] as String);
          },
        );
        // 空白 tap 是 no-op（记录 sink 让手势机契约可观察）。
        controller.addJavaScriptHandler(
          handlerName: 'onTapEmpty',
          callback: (List<dynamic> args) {},
        );
        // 翻页：JS 手势机报方向（'next'/'prev'，页序语义），Dart 推进 spread。
        controller.addJavaScriptHandler(
          handlerName: 'onMangaTurn',
          callback: (List<dynamic> args) {
            if (args.isEmpty) return;
            unawaited(_onMangaTurn(args[0] as String));
          },
        );
        // webtoon 滚动报告：更新 fraction/页码（绝不重载）。
        controller.addJavaScriptHandler(
          handlerName: 'onMangaScroll',
          callback: (List<dynamic> args) {
            if (args.isEmpty) return;
            unawaited(_onMangaScroll(args[0] as String));
          },
        );
        // 补扫框选回传（P4，唯一注册点）：页图像素坐标 + 0-based 页码。
        controller.addJavaScriptHandler(
          handlerName: 'onMangaBoxSelected',
          callback: (List<dynamic> args) {
            if (args.isEmpty) return;
            unawaited(_onMangaBoxSelected(args[0] as String));
          },
        );
        unawaited(_loadInitialWindow());
      },
      shouldInterceptRequest:
          (InAppWebViewController controller, WebResourceRequest request) =>
              _interceptRequest(request.url),
      onReceivedError: (InAppWebViewController controller,
          WebResourceRequest request, WebResourceError error) async {
        if (!(request.isForMainFrame ?? false)) return;
        // Windows WebView2 对未解析虚拟域的主帧导航报错，即使 shouldInterceptRequest
        // 已提供文档。视作加载完成（镜像 reader_hibiki 的同款处理）。
        if (Platform.isWindows &&
            request.url.host == MangaHibikiPage.kMangaHost) {
          _markWindowReady();
        }
      },
      onLoadStop: (InAppWebViewController controller, WebUri? url) async {
        _markWindowReady();
      },
    );
  }

  /// 当前窗口加载完成：记录当前页位置（onLoadStop 与 Windows 的
  /// onReceivedError-as-success 分支共用）。
  void _markWindowReady() {
    if (!mounted) return;
    _recordProgress();
  }
}
