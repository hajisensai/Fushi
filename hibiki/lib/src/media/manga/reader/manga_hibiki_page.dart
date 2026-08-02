import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;

import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/media/manga/manga_json_writeback.dart';
import 'package:hibiki/src/media/manga/manga_module.dart';
import 'package:hibiki/src/media/manga/manga_ocr_background_job.dart';
import 'package:hibiki/src/media/manga/manga_ocr_provider.dart';
import 'package:hibiki/src/ocr/manga_ocr_folder_job.dart'
    show kMangaOcrOutDirName;
import 'package:hibiki/src/ocr/manga_ocr_service.dart';
import 'package:hibiki/src/ocr/ocr_types.dart' show OcrRect;
import 'package:hibiki/src/media/manga/manga_overlay_html.dart';
import 'package:hibiki/src/media/manga/manga_reading_mode.dart';
import 'package:hibiki/src/media/manga/manga_reading_stats.dart';
import 'package:hibiki/src/media/manga/manga_spread_model.dart';
import 'package:hibiki/src/media/manga/mihon/manga_page_provider.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_library.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_manager.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_models.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_online_ocr.dart';
import 'package:hibiki/src/media/manga/mihon/mihon_reader_chapter.dart';
import 'package:hibiki/src/media/manga/mokuro_payload.dart';
import 'package:hibiki/src/media/manga/ocr/google_lens_disclosure.dart';
import 'package:hibiki/src/media/manga/ocr/manga_box_rescan.dart';
import 'package:hibiki/src/media/manga/ocr/manga_ocr_engine.dart';
import 'package:hibiki/src/media/manga/ocr/manga_ocr_cache_recovery.dart';
import 'package:hibiki/src/media/manga/reader/manga_rescan_result_sheet.dart';
import 'package:hibiki/src/focus/page_focus_ownership.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart'
    show InputBinding, ModifierKey, MouseBinding, activeModifierKeys;
import 'package:hibiki/src/shortcuts/manga_arrow_override.dart';
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/shortcut_registry.dart';
import 'package:hibiki/src/focus/webview_key_bridge.dart';
import 'package:hibiki/src/media/manga/reader/manga_window_load_gate.dart';
import 'package:hibiki/src/pages/base_source_page.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:hibiki/src/pages/implementations/stat_activity.dart';
import 'package:hibiki/src/reader/reader_selection_data.dart';
import 'package:hibiki/src/reader/reader_selection_scripts.dart';
import 'package:hibiki/src/startup/exit_flush_registry.dart';
import 'package:hibiki/src/webview/webview_death_guard.dart';
import 'package:hibiki/utils.dart';

/// Manga reader implementation owned by the standalone manga module.
///
/// Public navigation exports this page through `pages.dart`; generic reader
/// code does not own manga rendering, interaction, or OCR overlay behavior.
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

enum MangaReaderInputAction { previous, next, dismissDictionary }

enum _MangaReaderInputSource { flutter, nativeWebView }

/// Serializes burst page-turn input across asynchronous WebView window loads.
///
/// While one step is awaiting `loadData`, later inputs are reduced to a net
/// delta instead of being discarded. Once the in-flight step finishes, the
/// same drain continues until the accumulated intent reaches zero.
class MangaTurnQueue {
  int _pendingDelta = 0;
  bool _draining = false;

  @visibleForTesting
  int get pendingDelta => _pendingDelta;

  @visibleForTesting
  bool get isDraining => _draining;

  Future<void> enqueue(
    int delta, {
    required int maxMagnitude,
    required bool Function() canApply,
    required Future<void> Function(int step) applyStep,
  }) async {
    if (delta == 0 || maxMagnitude <= 0) return;
    _pendingDelta =
        (_pendingDelta + delta).clamp(-maxMagnitude, maxMagnitude).toInt();
    await drain(canApply: canApply, applyStep: applyStep);
  }

  Future<void> drain({
    required bool Function() canApply,
    required Future<void> Function(int step) applyStep,
  }) async {
    if (_draining || !canApply()) return;
    _draining = true;
    try {
      while (_pendingDelta != 0 && canApply()) {
        final int step = _pendingDelta > 0 ? 1 : -1;
        _pendingDelta -= step;
        await applyStep(step);
      }
    } finally {
      _draining = false;
    }
  }
}

/// 窗口文档 generation 闸门（BUG-1153）。
///
/// WebView2 的 `loadData` Future 只证明导航被受理，旧文档可能还要多显示一帧、
/// 或迟到一次 `onLoadStop`。每份窗口文档都嵌了一个单调递增的 generation
/// （`window.__mangaDocumentGeneration`），收尾回调必须先用它证明「这份文档就是
/// 我刚请求的那一份」，否则整套解锁/平移/记进度都会作用在错的文档上。
///
/// 这里是纯函数，是为了让「旧 generation 被丢弃」这条不变量能被真正断言，而不是
/// 只断言 HTML 里写了个数字。
class MangaWindowGeneration {
  const MangaWindowGeneration._();

  /// 把 JS 回报的 `window.__mangaDocumentGeneration` 解析成 int。
  ///
  /// WebView 桥在不同平台上分别回 num / String，解析不出一律 null（fail-closed，
  /// 后续比较必然不等，回调被丢弃）。
  static int? parse(Object? raw) => switch (raw) {
        final num value => value.round(),
        final String value => int.tryParse(value),
        _ => null,
      };

  /// 回报值与 [current] 严格相等才放行。
  ///
  /// 严格相等而不是 `>=`：既要丢掉迟到的旧文档（更小），也要丢掉解析失败与任何
  /// 对不上号的值。
  static bool isCurrent(Object? rawGeneration, int current) =>
      parse(rawGeneration) == current;
}

/// 漫画选区 payload 的纯分发核心。页面方法 `processMangaSelection` 接真实回调
/// （setCurrentSentence / searchDictionaryResult）；这个接缝让词/句/矩形契约可以在
/// 无 WebView、无 AppModel 的纯单测里验证。
///
/// 语义：[ReaderSelectionData.text] 是扫描出的查询词；[ReaderSelectionData.sentence]
/// 是 OCR 几何重建出的完整句子，作为 Anki 句子；[ReaderSelectionData.verticalWriting]
/// 决定根弹窗从文字左右还是上下避让；[ReaderSelectionData.mangaPageIndex] 把
/// OCR 命中的精确页交给制卡图片解析，不能退化成双页 spread 的首页。
/// text 为空是 no-op。
Future<void> dispatchMangaSelection(
  ReaderSelectionData data, {
  required Size fallbackScreen,
  required Future<void> Function(int? pageIndex) selectPageForMining,
  required void Function(String sentence) setSentence,
  required Future<void> Function(
    String term,
    Rect selectionRect,
    bool verticalWriting,
  ) search,
}) async {
  if (data.text.isEmpty) {
    return;
  }
  await selectPageForMining(data.mangaPageIndex);
  setSentence(data.sentence);
  final Rect rect =
      mangaSelectionRectFromPayload(data, fallbackScreen: fallbackScreen);
  await search(data.text, rect, data.verticalWriting);
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

enum _MangaContextAction {
  previous,
  next,
  jump,
  direction,
  zoomIn,
  zoomOut,
}

Future<int?> showMangaPageJumpDialog(
  BuildContext context, {
  required int currentPage,
  required int total,
}) {
  String input = '$currentPage';
  return showAppDialog<int>(
    context: context,
    builder: (BuildContext dialogContext) => AlertDialog(
      title: Text(t.manga_jump_to_page),
      content: TextFormField(
        initialValue: input,
        autofocus: true,
        keyboardType: TextInputType.number,
        inputFormatters: <TextInputFormatter>[
          FilteringTextInputFormatter.digitsOnly,
        ],
        decoration: InputDecoration(
          labelText: t.manga_page_number_hint(total: total),
        ),
        onFieldSubmitted: (String value) => Navigator.pop(
          dialogContext,
          int.tryParse(value),
        ),
        onChanged: (String value) => input = value,
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(t.dialog_cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(
            dialogContext,
            int.tryParse(input),
          ),
          child: Text(t.dialog_ok),
        ),
      ],
    ),
  );
}

/// 漫画阅读器页面（漫画 OCR P1：L5 媒体源路由 / L6 渲染 / L7 查词+制卡）。
///
/// 与 EPUB 的 [ReaderHibikiPage]、PDF 的 [ReaderPdfPage] 平行的「第三种书」：mokuro
/// 页图 + 透明 OCR 覆盖层在 WebView 里渲染（文档由 [mangaWindowDocument] 生成），
/// 汇入同一批共享设施：[BaseSourcePageState.searchDictionaryResult]（查词弹窗）、
/// [ReaderPositionRepository]（阅读位置，sectionIndex=0-based 页码）、
/// [ReadingTimeTracker]（时长统计；v60 起同时落 OCR 字数与页数，见
/// [mangaAccumulateReadingStats]）、[AnkiMiningContext]（制卡，
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
/// [mangaWindowDocument]（调 `hoshiSelection.selectFromPosition(node, 0, 40, x, y)`，
/// 第三参 maxLength 漏传会让扫描 gate 恒假、查词全程哑火），本页绝不再注册第二个。
class MangaHibikiPage extends BaseSourcePage {
  const MangaHibikiPage({
    super.key,
    required super.item,
    required this.bookKey,
    this.onlineChapter,
  });

  /// `EpubBooks` 主键（净化后的标题），由 `hoshi://book/<bookKey>` 解析而来。
  final String bookKey;

  /// A directly selected Mihon chapter. Shelf launches leave this null and
  /// restore the chapter from the restart descriptor in `sourceMetadata`.
  final MihonReaderChapter? onlineChapter;

  /// 漫画拦截器专属虚拟域。必须与阅读器的 `hoshi.local` 互异。
  static const String kMangaHost = 'manga.local';

  static String horizontalKeyTurn({
    required String direction,
    required bool rightKey,
  }) {
    final bool rtl = direction == 'rtl';
    return rightKey == rtl ? 'prev' : 'next';
  }

  /// 把注册表解析出的 [ShortcutAction] 落成本页的输入动作。
  ///
  /// 键位本身由 `ShortcutRegistry`（`ShortcutScope.manga`）解析，左右方向键的朝向
  /// 再由 [resolveMangaArrowPageTurn] 按跨页方向校正——两步都在调用侧完成，本函数
  /// 只负责「拿到动作之后，当前上下文该不该执行它」这层门控。
  ///
  /// [horizontalArrow] = 触发键是否为左/右方向键。它们是**跨页步进**语义，两道
  /// 门控都不适用：webtoon 的纵向滚动不影响左右翻页；词典弹窗可见时也要「关弹窗
  /// 并翻页」（本页与阅读器的关键差异）。其余前进/后退键则要让位——弹窗可见时空格
  /// 归词典自己，webtoon 模式下纵向键归 WebView 原生滚动。
  static MangaReaderInputAction? inputActionForShortcut({
    required ShortcutAction? action,
    required bool horizontalArrow,
    required bool dictionaryShown,
    required MangaReadingMode mode,
  }) {
    if (action == null) return null;
    if (action == ShortcutAction.mangaDismissDict) {
      return dictionaryShown ? MangaReaderInputAction.dismissDictionary : null;
    }
    if (!horizontalArrow) {
      if (dictionaryShown) return null;
      if (mode == MangaReadingMode.webtoon) return null;
    }
    return switch (action) {
      ShortcutAction.mangaPageForward => MangaReaderInputAction.next,
      ShortcutAction.mangaPageBackward => MangaReaderInputAction.previous,
      _ => null,
    };
  }

  static MangaReaderInputAction? wheelInputAction(Offset delta) {
    final double dominant =
        delta.dy.abs() >= delta.dx.abs() ? delta.dy : delta.dx;
    if (dominant.abs() < 2) return null;
    return dominant > 0
        ? MangaReaderInputAction.next
        : MangaReaderInputAction.previous;
  }

  /// Native WebView2 owns keyboard focus while the user is reading. Forward
  /// navigation keys from the manga document to Dart so page turns do not
  /// depend on the platform view bubbling key events through Flutter.
  /// 走共享生成器而非自写一份：手写版少了「放行修饰键组合 / IME 组字 / 输入框」
  /// 三条放行判据，会吞掉 Ctrl+方向键，以及词典搜索框里的方向键。
  ///
  /// `forwardRepeats: false` 保留本页既有语义（按住方向键不堆翻页风暴）；
  /// `stopPropagation: true` 保留独占（这些键必须只给 Dart）。`'Esc'` 与
  /// `'Escape'` 都列进键表，旧浏览器归一由 [_handleNativeNavigationKey] 完成。
  @visibleForTesting
  static final String navigationKeyBridgeScript = webViewKeyBridgeScript(
    handlerName: 'onMangaNavigationKey',
    keys: const <String>['ArrowLeft', 'ArrowRight', 'Escape', 'Esc'],
    forwardRepeats: false,
    stopPropagation: true,
  );

  /// 纯路径解析 + 穿越守卫。[relative] 在 [imagesRoot] 内解析到存在的文件时返回
  /// 规范绝对路径（**保留磁盘上的真实大小写**），否则 null（越界/缺文件都不 serve）。
  /// 从 WebView 路径抽出，安全边界无需 WebView 后端即可单测。
  ///
  /// BUG-1221：**越界校验**与**真实读写路径**必须用同一条路径的两种不同形式——
  /// - 校验用 `p.canonicalize`（在 Windows 上整体小写化，见 `path` 包
  ///   `style/windows.dart:181`，正好让 `../` 逃逸判定不被大小写差异绕过）；
  /// - 返回值用 `p.absolute` + `p.normalize`（同样绝对化并折叠 `.`/`..` 段，但
  ///   **保留大小写**）。
  ///
  /// 此前返回的是 canonicalize 的结果：漫画包里 `Vol1/P001.JPG` 这类混合大小写的
  /// 条目被记成 `vol1/p001.jpg`。Windows 文件系统不区分大小写所以侥幸能读，但这个
  /// 返回值会流出本次读取——`_updateCurrentPageImagePath` 把它存进
  /// `_currentPageImagePath`，制卡时经 `ensureMangaCoverPng` 直接当作 Anki 封面
  /// 源路径，媒体名因此被小写化；在大小写敏感平台上更是 `existsSync` 直接为 false
  /// （页图 404、制卡无封面）。与 `EpubParser._resolveWithinExtract`（BUG-1218）
  /// 及 `_safeArchivePath`（TODO-739）同款做法。
  ///
  /// 注意比 EPUB 侧多一个 `p.absolute`：本函数的契约是返回**绝对**路径，而
  /// `p.normalize` 与 `canonicalize` 不同、**不会**绝对化。
  static String? resolveMangaResource(String imagesRoot, String relative) {
    final String decoded = Uri.decodeComponent(relative);
    final String joined = p.join(imagesRoot, decoded);
    if (!p.isWithin(p.canonicalize(imagesRoot), p.canonicalize(joined))) {
      return null;
    }
    final String filePath = p.normalize(p.absolute(joined));
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

  /// 将 manga.json 中相对漫画根目录的 `images/foo.jpg` 转为相对
  /// [_imagesDir]（其本身已经是 `<book>/images`）的 `foo.jpg`。旧版
  /// `.mokuro` 直接保存 `foo.jpg`，因此两种格式都要兼容。
  static String mangaImageRelativePath(String storedUrl) {
    String normalized = storedUrl.replaceAll(r'\', '/');
    while (normalized.startsWith('./')) {
      normalized = normalized.substring(2);
    }
    if (normalized.toLowerCase().startsWith('images/')) {
      return normalized.substring('images/'.length);
    }
    return normalized;
  }

  /// Resolve the exact image for a 0-based manga [pageIndex].
  ///
  /// Keeping this separate from spread navigation prevents mining a selection
  /// on the second page of a two-page spread with the spread's first image.
  static String? resolveMangaPageImage(
    MokuroPayload payload,
    String imagesRoot,
    int pageIndex,
  ) {
    if (pageIndex < 0 || pageIndex >= payload.images.length) return null;
    return resolveMangaResource(
      imagesRoot,
      mangaImageRelativePath(payload.images[pageIndex].url),
    );
  }

  /// 纯函数：manga.json 的相对 url → WebView 可加载的拦截器 URL。逐段
  /// percent-encode（保留 `/` 结构），与拦截器侧 `Uri.decodeComponent` 对称
  /// （镜像 epubUrl 的 HBK-AUDIT-127 编解码对称纪律）。
  static String mangaImageUrl(String relativeUrl) {
    final String normalized = mangaImageRelativePath(relativeUrl);
    final String encoded =
        normalized.split('/').map(Uri.encodeComponent).join('/');
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
  MangaReaderSession? _pageSession;
  Map<String, int> _localPageIndices = const <String, int>{};
  MihonReaderChapter? _onlineChapter;
  bool _persistProgress = true;
  MokuroPayload? _payload;
  MangaReadingMode _mode = MangaReadingMode.spread;
  List<MangaSpreadEntry> _spreads = <MangaSpreadEntry>[];
  bool _loadFailed = false;

  /// 双页布局偏好：页内菜单运行时切换，不持久化，默认自动（横屏双页/竖屏单页）。
  MangaSpreadPreference _spreadPreference = MangaSpreadPreference.auto;
  String _spreadDirection = 'rtl';
  int _zoomPercent = 100;

  /// 最近一次实际生效的布局（由 [_buildSpreadsFor] 记账），didChangeMetrics
  /// 只在解析结果真变时才重建 spread 序列，避免键盘弹出等无关 metrics 抖动。
  MangaPageLayout _pageLayout = MangaPageLayout.single;

  int _currentSpread = 0;
  int _currentPage = 0;
  double _currentFraction = 0;
  Timer? _progressDebounce;
  Timer? _onlineGeometryPersistDebounce;
  int _lastSavedPage = -1;
  double _lastSavedFraction = -1;

  /// 页码指示器专用（避免 webtoon 滚动高频 setState 重建整棵 Stack/WebView）。
  final ValueNotifier<int> _pageNotifier = ValueNotifier<int>(0);

  /// 当前稳定文档里物化了 OCR 字符节点的 spread 集合。所有图片页始终留在同一份
  /// lazy-loaded 文档里；这里只跟踪受控的密集命中层。
  Set<int> _loadedSpreads = <int>{};

  /// 首次文档加载守卫。之后所有翻页只移动稳定 strip 并替换当前 OCR 层；所有输入
  /// 仍经 [_turnQueue] 串行化，避免快速反向操作交叠 DOM 更新。
  bool _navigating = false;
  final MangaTurnQueue _turnQueue = MangaTurnQueue();

  /// 窗口文档加载的所有权闸门：generation 与 ready 锁只能经它读写，迟到的旧回调
  /// 不能解开新窗口的锁（BUG-1170），页面销毁时在飞加载被显式放弃（BUG-1171）。
  final MangaWindowLoadGate _windowGate = MangaWindowLoadGate();

  /// renderer 死亡处置（救命动作 = 下面 [InAppWebView.onRenderProcessGone] 传了
  /// 非 null 回调，否则 Android 会连坐杀掉整个 app）。
  ///
  /// 抢救三件事，缺一都会在重建后出错：
  /// - `_flushPosition()`：600ms debounce（[_recordProgress]）里还没落盘的页码；
  /// - `_windowGate.abandon()`：renderer 死时若有 `loadData` 在飞，它的 ready 锁
  ///   永远等不到 `onLoadStop`，会挂满 10s 超时再从 `unawaited` 调用点抛未捕获
  ///   异步异常（BUG-1171 同源），并且 `_navigating` 会卡 true 让重建后的
  ///   `_loadInitialWindow()` 直接早退成白屏；
  /// - `_controller = null`：报废的 controller 上 `evaluateJavascript` 只会抛。
  ///
  /// 重建安全性：恢复锚是 `_currentSpread` / `_currentFraction`，它们由 JS 的
  /// `onMangaScroll` / `onMangaTurn` 实时更新，永远是**当前真实位置**，不是进入
  /// 本章时的快照 —— 所以重建后 `onWebViewCreated → _loadInitialWindow() →
  /// _markWindowReady()` 把同一个 spread 重新应用回去，不会写回退的进度。
  late final WebViewDeathGuard _webViewDeathGuard = WebViewDeathGuard(
    surface: 'manga_reader',
    flushBeforeRebuild: () async {
      _windowGate.abandon();
      _controller = null;
      await _flushPosition();
    },
    afterRebuild: () {
      if (mounted) setState(() {});
    },
  );

  /// 旧选区 payload 的制卡卡图回退：当前 spread 首页图的绝对文件路径。新 payload
  /// 会以 [_miningPageIndex] 精确定位 OCR 命中的页，不能用此值覆盖。
  String? _currentPageImagePath;

  /// 最近一次非空 OCR 选区所在的精确页及其卡图。页码非 null 而路径为 null 表示
  /// 精确页不可用，此时宁可不附图，也不能静默回退到双页 spread 的另一页。
  int? _miningPageIndex;
  String? _miningPageImagePath;
  int _miningPageGeneration = 0;

  /// 整卷 OCR 向导防重入。识别进度与取消由向导持有，阅读器只负责完成后热刷新。
  bool _wholeVolumeOcrOpen = false;
  bool _wholeVolumeOcrRunning = false;
  int _wholeVolumeOcrDone = 0;
  int _wholeVolumeOcrTotal = 0;

  /// 本次整卷 OCR 实际生效的推理加速状态（BUG-1163：降级必须看得见）。
  MangaOcrAcceleration? _wholeVolumeOcrAcceleration;

  /// 降级提示只弹一次，避免逐页事件刷屏。
  bool _wholeVolumeOcrDegradeNotified = false;

  /// 框选识别：识别三件套是否已下载（只看 recognizerReady，不看 detector）。
  bool _rescanModelReady = false;

  /// 框选识别：模式激活位。JS 侧同名门控由 `__mangaSetRescanMode` 同步。
  bool _rescanModeActive = false;

  /// 框选识别：单飞闸门（一次只跑一个框，避免连点堆满 isolate 队列）。
  bool _rescanBusy = false;

  /// 框选识别服务（常驻识别 isolate 的持有者，页面 dispose 时释放）。
  MangaBoxRescanService? _rescanService;
  StreamSubscription<void>? _wholeVolumeOcrSubscription;
  String? _debugOcrHitOrientation;
  String? _debugOcrHitCharacter;
  String? _debugOcrSelectedText;

  /// 最近一次查词的句子与词在句中偏移，喂制卡（[AnkiMiningContext]）。
  String _lastSentence = '';
  int _lastSentenceOffset = 0;

  /// 漫画同一页会混排竖排对白、横排拟声/标题，不能像 EPUB 一样从整页设置
  /// 推导。每次 OCR 命中都从 payload 更新，根弹窗据此左右/上下避让。
  bool _popupVerticalWriting = false;

  @override
  bool get popupVerticalWriting => _popupVerticalWriting;

  ReadingTimeTracker? _readingTimeTracker;
  DateTime _sessionStartTime = DateTime.now();

  /// 本次会话尚未落库的 OCR 字符数与页数，以及已记账过的页（同一页只计一次，来回
  /// 翻页刷不出数）。字数口径与 EPUB 同源，见 [mangaAccumulateReadingStats]。
  int _sessionCharsRead = 0;
  int _sessionPagesRead = 0;
  final Set<int> _sessionCountedPages = <int>{};

  // 密集 OCR 命中层只保留当前 spread；图片页本身全部留在稳定的 lazy strip。
  static const int _kWindowRadius = 0;

  /// 漫画正文的键盘焦点节点（本页唯一持有者）。
  final FocusNode _focusNode = FocusNode(debugLabel: 'mangaKeyboard');

  /// 本页键盘焦点的单一所有者：所有回收走它，判据集中在 [_canOwnMangaFocus]。
  ///
  /// 统一前漫画页**一处焦点回收都没有**（视频页 29 处、阅读器页 28 处），而它同样
  /// 把正文交给原生 WebView 渲染——桌面上用户在漫画 WebView 里点/拖一次，OS 焦点
  /// 就归了 WebView2，整页 `autofocus: true` 只在首帧生效、之后再没有任何路径把
  /// 焦点要回来，方向键翻页从此失效且**无自愈**。
  late final PageFocusOwnership _focusOwnership = PageFocusOwnership(
    node: _focusNode,
    canOwn: _canOwnMangaFocus,
  );

  /// 「漫画正文此刻应当持有键盘」的统一判据。
  bool _canOwnMangaFocus(FocusReclaimCause cause) {
    if (!mounted) return false;
    switch (cause) {
      // 与阅读器**相反**：阅读器在词典弹窗可见时让位（弹窗自持焦点，BUG-136），
      // 漫画不能让——[MangaHibikiPage.keyInputAction] 规定弹窗可见时左右键仍要
      // 「关弹窗并翻页」、Escape 要关弹窗，这些键必须抵达 [_handleReaderKey]。
      // 词典弹窗是纯原生 WebView、没有 Flutter 焦点节点，不主动收回就全部落空。
      // 这也正是本页覆写 [capturesDictionaryPopupNavigationKeys] 的同一诉求。
      case FocusReclaimCause.popupRendered:
        return isDictionaryShown;
      case FocusReclaimCause.gesture:
      case FocusReclaimCause.popupDismissed:
      case FocusReclaimCause.contentReady:
      case FocusReclaimCause.overlayClosed:
      case FocusReclaimCause.surfaceRemounted:
      // 本页顶部 chrome（页码 + 阅读模式切换）是常驻的，不参与焦点遍历，
      // 显隐后重新确认焦点仍在正文即可。
      case FocusReclaimCause.chromeToggled:
        return true;
      // 回前台是全局生命周期回调，本页上方可能压着全屏看图路由 / 对话框；
      // 此时抢焦点会夺走它们的键盘（Never break userspace）。
      case FocusReclaimCause.appResumed:
        final ModalRoute<Object?>? owner = ModalRoute.of(context);
        return owner == null || owner.isCurrent;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // 进程退出兜底：把未落盘的页码 flush 掉（与 EPUB/PDF 阅读器同纪律）。
    ExitFlushRegistry.instance.register(_flushPosition);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadBook());
    unawaited(_refreshRescanModelReady());
  }

  @override
  void dispose() {
    ExitFlushRegistry.instance.unregister(_flushPosition);
    final MangaBoxRescanService? rescanService = _rescanService;
    _rescanService = null;
    if (rescanService != null) {
      unawaited(rescanService.dispose());
    }
    WidgetsBinding.instance.removeObserver(this);
    // 加载中的窗口必须以明确状态收尾：否则 _loadInitialWindow 会挂满 10s 超时，
    // 再从 unawaited 调用点抛出未捕获异步异常（BUG-1171）。
    _windowGate.abandon();
    _progressDebounce?.cancel();
    _onlineGeometryPersistDebounce?.cancel();
    _dictionaryTurnDismissTimer?.cancel();
    unawaited(_wholeVolumeOcrSubscription?.cancel());
    _wholeVolumeOcrSubscription = null;
    final MangaReaderSession? pageSession = _pageSession;
    _pageSession = null;
    if (pageSession != null) {
      unawaited(_closePageSession(pageSession));
    }
    // dispose 里只能 fire-and-forget；正常退出走 onSourcePagePop 的 await 路径，
    // 这里是崩溃/异常拆栈时的兜底。
    unawaited(_flushPosition());
    _readingTimeTracker?.dispose();
    _pageNotifier.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _closePageSession(MangaReaderSession session) async {
    await session.close();
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
      // OS 层焦点丢失后 Flutter 不保证归还到原节点：切窗回来若不收回，翻页键全死。
      _focusOwnership.reclaim(FocusReclaimCause.appResumed);
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
    unawaited(appModel.setMangaSpreadPreference(preference.key));
    final MokuroPayload? payload = _payload;
    if (payload == null || _mode != MangaReadingMode.spread) return;
    if (_resolveLayout(_mode) != _pageLayout) {
      await _rebuildSpreadsPreservingPage(payload);
    }
  }

  // ── 加载 / 恢复 ───────────────────────────────────────────────────────

  Future<void> _loadBook() async {
    final HibikiDatabase db = appModel.database;
    final MihonReaderChapter? directOnlineChapter = widget.onlineChapter;
    if (directOnlineChapter != null) {
      final EpubBookRow? persisted = directOnlineChapter.persistProgress
          ? await db.getEpubBook(widget.bookKey)
          : null;
      await _loadOnlineChapter(
        directOnlineChapter,
        persistedRow: persisted,
      );
      return;
    }
    final EpubBookRow? row = await db.getEpubBook(widget.bookKey);
    if (!mounted) return;
    if (row == null) {
      setState(() => _loadFailed = true);
      return;
    }
    final MihonLibraryEntry? onlineEntry =
        MihonLibraryEntry.tryParse(row.sourceMetadata);
    if (onlineEntry != null) {
      await _loadOnlineBookFromShelf(row, onlineEntry);
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

    _spreadPreference = MangaSpreadPreferenceKey.fromKey(
      appModel.mangaSpreadPreference,
    );
    _spreadDirection = appModel.mangaReadingDirection == 'ltr' ? 'ltr' : 'rtl';
    _zoomPercent = appModel.mangaZoomPercent.clamp(50, 200);

    // 阅读模式：用户覆盖优先，null 走自动判定（页图长宽比中位数）。
    final MangaReadingMode mode =
        MangaHibikiPage.modeOverrideFromDb(row.mangaReadingMode) ??
            detectReadingMode(payload);
    final List<MangaSpreadEntry> spreads = _buildSpreadsFor(payload, mode);
    final List<String> relativePagePaths = payload.images
        .map(
          (MokuroImage image) =>
              MangaHibikiPage.mangaImageRelativePath(image.url),
        )
        .toList(growable: false);
    final MangaReaderSession localPageSession = await LocalMangaPageProvider(
      imagesRoot: Directory(imagesDir),
      relativePaths: relativePagePaths,
    ).open();
    if (!mounted) {
      await localPageSession.close();
      return;
    }

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

    _readingTimeTracker ??= ReadingTimeTracker(db, format: BookFormat.manga)
      ..start();
    _sessionStartTime = DateTime.now();

    final int restoredSpread =
        MangaHibikiPage.restoreSpreadFromProgress(spreads, restoredPage);
    final MangaReaderSession? previousLocalPageSession = _pageSession;
    _pageSession = localPageSession;
    _localPageIndices = <String, int>{
      for (int index = 0; index < relativePagePaths.length; index++)
        _localPageKey(relativePagePaths[index]): index,
    };
    if (previousLocalPageSession != null) {
      unawaited(previousLocalPageSession.close());
    }
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
    // 首屏页也要进字数/页数账：开书直接停在恢复位置时不会再有 _recordProgress。
    _countVisiblePages();
    // A cancelled/background task intentionally does not replace manga.json,
    // but every atomic page cache is already safe to use. Restore those pages
    // after the first paint so opening a large book stays fast and both local
    // ONNX and Lens results remain queryable across reader restarts.
    unawaited(_recoverIncrementalOcrCache(row.extractDir, payload));
  }

  Future<void> _loadOnlineBookFromShelf(
    EpubBookRow row,
    MihonLibraryEntry entry,
  ) async {
    try {
      final MihonManager manager = appModel.mihonManager;
      await manager.initialise();
      final MangaOnlineSourceRow source = manager.sources.firstWhere(
        (MangaOnlineSourceRow value) =>
            value.extensionPackage == entry.extensionPackage &&
            value.sourceId == entry.sourceId &&
            value.enabled,
        orElse: () => throw const MihonRuntimeException(
          'SOURCE_DISABLED',
          'The manga source is missing or disabled',
        ),
      );
      final MihonSourceContext sourceContext =
          await manager.contextForSource(source);
      int chapterIndex = MihonLibraryService.initialChapterIndex(entry);
      if (chapterIndex < 0) {
        throw const MihonRuntimeException(
          'CHAPTERS_EMPTY',
          'The manga has no chapters',
        );
      }
      if (entry.currentChapterIndex == null) {
        entry = await MihonLibraryService(manager).selectChapter(
          bookKey: row.bookKey,
          entry: entry,
          chapterIndex: chapterIndex,
        );
        chapterIndex = entry.currentChapterIndex!;
      }
      final MihonChapter chapter = entry.chapters[chapterIndex];
      final List<MihonPage> pages = await manager.runtime.getPages(
        sourceContext.extension,
        sourceContext.source,
        chapter,
        preferences: sourceContext.preferences,
      );
      await _loadOnlineChapter(
        MihonReaderChapter(
          manager: manager,
          sourceContext: sourceContext,
          manga: entry.manga,
          chapter: chapter,
          pages: pages,
          managedDirectory: MihonLibraryService(manager)
              .chapterDirectory(row.bookKey, chapter),
          persistProgress: true,
        ),
        persistedRow: row,
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance
          .log('MangaHibikiPage.loadOnlineShelf', error, stack);
      if (mounted) {
        setState(() {
          _bookRow = row;
          _loadFailed = true;
        });
      }
    }
  }

  Future<void> _loadOnlineChapter(
    MihonReaderChapter input, {
    required EpubBookRow? persistedRow,
  }) async {
    final Directory directory = input.managedDirectory;
    final Directory imagesDirectory =
        Directory(p.join(directory.path, 'images'));
    await imagesDirectory.create(recursive: true);
    final List<String> pageIdentities = <String>[
      for (final MihonPage page in input.pages)
        mihonPageCacheIdentity(input.sourceContext, page),
    ];
    final File identityFile =
        File(p.join(directory.path, '.mihon-chapter.json'));
    final bool sameChapterPages =
        await _onlineChapterIdentityMatches(identityFile, pageIdentities);
    if (!sameChapterPages) {
      await _invalidateOnlineChapterPayload(directory, imagesDirectory);
    }
    await _writeOnlineChapterIdentity(identityFile, pageIdentities);

    final List<String> relativePagePaths = <String>[
      for (int index = 0; index < input.pages.length; index++)
        'page-${(index + 1).toString().padLeft(6, '0')}.jpg',
    ];
    final File mangaJson = File(p.join(directory.path, 'manga.json'));
    MokuroPayload? payload;
    bool rewriteMangaJson = !await mangaJson.exists();
    if (await mangaJson.exists()) {
      try {
        final MokuroPayload stored = await MangaHibikiPage.parseMangaJsonOffUi(
          await mangaJson.readAsString(),
        );
        if (stored.images.length == input.pages.length) {
          payload = stored;
        } else {
          rewriteMangaJson = true;
        }
      } on Object {
        payload = null;
        rewriteMangaJson = true;
      }
    }
    payload ??= MokuroPayload(
      images: <MokuroImage>[
        for (final String path in relativePagePaths)
          MokuroImage(
            url: path,
            // Mihon does not expose dimensions before fetching the page. This
            // neutral portrait ratio is only used until OCR decodes the real
            // dimensions; image rendering itself keeps the source aspect.
            size: const Size(1000, 1400),
            blocks: const <MokuroBlock>[],
          ),
      ],
    );
    if (rewriteMangaJson) {
      // 与几何 debounce 同一 State、可交叠，且共用同一个 `<manga.json>.tmp`：
      // 必须同锁，否则两个写者互相踩临时文件。
      final MokuroPayload bootstrapped = payload;
      await runExclusiveOnMangaJson<void>(
        mangaJson.path,
        () => writeMangaJsonAtomically(mangaJson.path, bootstrapped),
      );
    }

    final MangaReaderSession pageSession = await MihonMangaPageProvider(
      runtime: input.manager.runtime,
      context: input.sourceContext,
      pages: input.pages,
      cacheRoot: Directory(
        p.join(
          input.manager.rootDirectory.path,
          'reader-cache',
          'pages',
        ),
      ),
    ).open();
    if (!mounted) {
      await pageSession.close();
      return;
    }

    _spreadPreference = MangaSpreadPreferenceKey.fromKey(
      appModel.mangaSpreadPreference,
    );
    _spreadDirection = appModel.mangaReadingDirection == 'ltr' ? 'ltr' : 'rtl';
    _zoomPercent = appModel.mangaZoomPercent.clamp(50, 200);
    final EpubBookRow row = persistedRow != null
        ? persistedRow.copyWith(
            epubPath: p.basename(mangaJson.path),
            extractDir: directory.path,
            chapterCount: input.pages.length,
          )
        : EpubBookRow(
            bookKey: widget.bookKey,
            title: input.manga.title,
            author: input.manga.author ?? input.manga.artist,
            epubPath: p.basename(mangaJson.path),
            extractDir: directory.path,
            chapterCount: input.pages.length,
            chaptersJson: '[]',
            importedAt: DateTime.now().millisecondsSinceEpoch,
            format: 'manga',
          );
    final MangaReadingMode mode =
        MangaHibikiPage.modeOverrideFromDb(row.mangaReadingMode) ??
            detectReadingMode(payload);
    final List<MangaSpreadEntry> spreads = _buildSpreadsFor(payload, mode);

    int restoredPage = input.initialPage ?? 0;
    double restoredFraction = 0;
    ReaderPosition? saved;
    if (input.persistProgress && input.initialPage == null) {
      try {
        saved = await ReaderPositionRepository(appModel.database)
            .findByBookKey(widget.bookKey);
      } on Object catch (error, stack) {
        ErrorLogService.instance
            .log('MangaHibikiPage.restoreOnline', error, stack);
      }
      if (saved != null &&
          saved.sectionIndex >= 0 &&
          saved.sectionIndex < payload.images.length) {
        restoredPage = saved.sectionIndex;
        if (mode == MangaReadingMode.webtoon) {
          restoredFraction = MangaHibikiPage.charOffsetToWebtoonFraction(
            saved.charOffset,
          );
        }
      }
    }
    restoredPage =
        restoredPage.clamp(0, math.max(0, payload.images.length - 1));

    _readingTimeTracker ??=
        ReadingTimeTracker(appModel.database, format: BookFormat.manga)
          ..start();
    _sessionStartTime = DateTime.now();
    final MangaReaderSession? previousSession = _pageSession;
    _pageSession = pageSession;
    _localPageIndices = <String, int>{
      for (int index = 0; index < relativePagePaths.length; index++)
        _localPageKey(relativePagePaths[index]): index,
    };
    _onlineChapter = input;
    _persistProgress = input.persistProgress;
    if (previousSession != null) unawaited(previousSession.close());

    final int restoredSpread =
        MangaHibikiPage.restoreSpreadFromProgress(spreads, restoredPage);
    setState(() {
      _bookRow = row;
      _imagesDir = imagesDirectory.path;
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
    _countVisiblePages();
    unawaited(_primeOnlinePages(restoredPage));
    unawaited(_recoverIncrementalOcrCache(directory.path, payload));
  }

  Future<bool> _onlineChapterIdentityMatches(
    File file,
    List<String> expected,
  ) async {
    try {
      final Object? decoded = jsonDecode(await file.readAsString());
      if (decoded is! Map<Object?, Object?> ||
          decoded['schema_version'] != 1 ||
          decoded['pages'] is! List<Object?>) {
        return false;
      }
      final List<String> stored = (decoded['pages'] as List<Object?>)
          .map((Object? value) => value?.toString() ?? '')
          .toList(growable: false);
      if (stored.length != expected.length) return false;
      for (int index = 0; index < expected.length; index++) {
        if (stored[index] != expected[index]) return false;
      }
      return true;
    } on Object {
      return false;
    }
  }

  Future<void> _invalidateOnlineChapterPayload(
    Directory directory,
    Directory imagesDirectory,
  ) async {
    // 删也要进锁：无锁 delete 可能落在别的写者的读-改-写之间，让它把刚删掉的
    // 内容又原样写回去（或反过来，让新写的内容被这次删除抹掉）。
    final File payload = File(p.join(directory.path, 'manga.json'));
    await runExclusiveOnMangaJson<void>(payload.path, () async {
      if (await payload.exists()) await payload.delete();
    });
    final File materializedManifest =
        File(p.join(imagesDirectory.path, '.mihon-pages.json'));
    if (await materializedManifest.exists()) {
      await materializedManifest.delete();
    }
    final Directory ocr =
        Directory(p.join(imagesDirectory.path, kMangaOcrOutDirName));
    if (await ocr.exists()) await ocr.delete(recursive: true);
    if (await imagesDirectory.exists()) {
      await for (final FileSystemEntity entity in imagesDirectory.list()) {
        if (entity is File &&
            RegExp(r'^page-\d{6}\.jpg$').hasMatch(p.basename(entity.path))) {
          await entity.delete();
        }
      }
    }
  }

  Future<void> _writeOnlineChapterIdentity(
    File target,
    List<String> identities,
  ) async {
    final File temporary = File('${target.path}.tmp');
    await temporary.writeAsString(
      jsonEncode(<String, Object?>{
        'schema_version': 1,
        'pages': identities,
      }),
      flush: true,
    );
    if (await target.exists()) await target.delete();
    await temporary.rename(target.path);
  }

  Future<void> _primeOnlinePages(int pageIndex) async {
    final MangaReaderSession? session = _pageSession;
    if (session == null || _onlineChapter == null) return;
    try {
      final MangaPageBytes page = await session.page(pageIndex);
      await _synchronizeOnlinePageGeometry(pageIndex, page);
      await session.prefetchAround(pageIndex);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaHibikiPage.onlinePrefetch',
        error,
        stack,
      );
    }
  }

  Future<void> _synchronizeOnlinePageGeometry(
    int pageIndex,
    MangaPageBytes page,
  ) async {
    final int? width = page.width;
    final int? height = page.height;
    final MokuroPayload? current = _payload;
    if (width == null ||
        height == null ||
        width <= 0 ||
        height <= 0 ||
        current == null ||
        pageIndex < 0 ||
        pageIndex >= current.images.length) {
      return;
    }
    final MokuroImage previous = current.images[pageIndex];
    if (previous.size.width != width || previous.size.height != height) {
      final List<MokuroImage> images = List<MokuroImage>.of(current.images);
      images[pageIndex] = MokuroImage(
        url: previous.url,
        size: Size(width.toDouble(), height.toDouble()),
        blocks: previous.blocks,
      );
      _payload = MokuroPayload(images: images, ocr: current.ocr);
      _onlineGeometryPersistDebounce?.cancel();
      _onlineGeometryPersistDebounce = Timer(
        const Duration(milliseconds: 500),
        () => unawaited(_persistOnlinePayloadGeometry()),
      );
    }
    await _controller?.evaluateJavascript(
      source: 'window.__mangaUpdatePageGeometry && '
          'window.__mangaUpdatePageGeometry($pageIndex, $width, $height);',
    );
  }

  Future<void> _persistOnlinePayloadGeometry() async {
    final EpubBookRow? row = _bookRow;
    final MokuroPayload? payload = _payload;
    if (row == null ||
        payload == null ||
        _onlineChapter == null ||
        _wholeVolumeOcrRunning) {
      return;
    }
    final String target = p.join(row.extractDir, row.epubPath);
    try {
      // 与框选回写共用同一把 per-path 写锁：两者都是整份读-改-写，交叠会丢更新。
      // `.tmp` 残渣清理必须在**锁内**：`.tmp` 是 per-path 固定名，锁外删等于删掉
      // 下一个写者正在写的临时文件。
      await runExclusiveOnMangaJson<void>(target, () async {
        try {
          await writeMangaJsonAtomically(target, payload);
        } on Object {
          final File temporary = File('$target.tmp');
          if (await temporary.exists()) {
            try {
              await temporary.delete();
            } on FileSystemException {
              // Best-effort cleanup; the managed target remains intact.
            }
          }
          rethrow;
        }
      });
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaHibikiPage.persistOnlineGeometry',
        error,
        stack,
      );
    }
  }

  Future<void> _recoverIncrementalOcrCache(
    String managedDirectory,
    MokuroPayload loadedPayload,
  ) async {
    try {
      final MangaOcrCacheRecovery recovery = await recoverCachedMangaOcr(
        managedDirectory: managedDirectory,
        basePayload: loadedPayload,
      );
      final MokuroPayload? current = _payload;
      if (!mounted ||
          recovery.recoveredPageIndices.isEmpty ||
          current == null ||
          current.images.length != recovery.payload.images.length ||
          _bookRow?.extractDir != managedDirectory) {
        return;
      }
      final List<MokuroImage> merged = List<MokuroImage>.of(current.images);
      for (final int pageIndex in recovery.recoveredPageIndices) {
        final MokuroImage recovered = recovery.payload.images[pageIndex];
        final MokuroImage existing = merged[pageIndex];
        merged[pageIndex] = MokuroImage(
          url: existing.url,
          size: recovered.size,
          blocks: recovered.blocks,
        );
      }
      final MokuroPayload recoveredPayload = MokuroPayload(
        images: merged,
        ocr: recovery.payload.ocr ?? current.ocr,
      );
      setState(() => _payload = recoveredPayload);

      final Set<int> visiblePages = <int>{
        for (final int spreadIndex in _loadedSpreads)
          if (spreadIndex >= 0 && spreadIndex < _spreads.length)
            ..._spreads[spreadIndex].pageIndices,
      };
      for (final int pageIndex in recovery.recoveredPageIndices) {
        if (visiblePages.contains(pageIndex)) {
          await _replacePageOcrOverlay(
            pageIndex,
            recoveredPayload.images[pageIndex],
          );
        }
      }
    } catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaHibikiPage.recoverIncrementalOcrCache',
        error,
        stack,
      );
    }
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
    final String path = url.path;
    if (!path.startsWith('/img/')) return _notFound('unknown path: $path');
    final String relative = path.substring('/img/'.length);
    final String decodedRelative = Uri.decodeComponent(relative);
    final MangaReaderSession? pageSession = _pageSession;
    final int? pageIndex = _localPageIndices[_localPageKey(decodedRelative)];
    if (pageSession != null && pageIndex != null) {
      try {
        final MangaPageBytes page = await pageSession.page(pageIndex);
        if (_onlineChapter != null) {
          await _synchronizeOnlinePageGeometry(pageIndex, page);
        }
        return WebResourceResponse(
          contentType: page.contentType,
          statusCode: 200,
          reasonPhrase: 'OK',
          headers: <String, String>{
            'Access-Control-Allow-Origin': '*',
            'Cache-Control': 'private, max-age=3600',
          },
          data: page.bytes,
        );
      } on MihonRuntimeException catch (error, stackTrace) {
        ErrorLogService.instance.log(
          'MangaHibikiPage.page',
          error,
          stackTrace,
        );
        return WebResourceResponse(
          contentType: 'text/plain',
          statusCode: 502,
          reasonPhrase: 'Bad Gateway',
          data: Uint8List(0),
        );
      }
    }
    final String? imagesDir = _imagesDir;
    if (imagesDir == null) {
      return _notFound('imagesDir not ready: ${url.path}');
    }
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
    return WebResourceResponse(
      contentType: _mangaMimeForPath(filePath),
      statusCode: 200,
      reasonPhrase: 'OK',
      headers: <String, String>{
        'Access-Control-Allow-Origin': '*',
        'Cache-Control': 'max-age=3600',
      },
      data: await File(filePath).readAsBytes(),
    );
  }

  static String _localPageKey(String path) =>
      p.normalize(path.replaceAll(r'\', '/')).replaceAll(r'\', '/');

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
  String _buildWindowDocument(
    String inlineSelectionJs, {
    required int documentGeneration,
  }) {
    final MokuroPayload payload = _payload!;
    final bool isWebtoon = _mode == MangaReadingMode.webtoon;

    final List<int> keptSpreads = MangaHibikiPage.mangaWindowRange(
      spreadCount: _spreads.length,
      current: _currentSpread,
      // Continuous mode keeps the immediately adjacent pages queryable while
      // they enter the viewport; spread mode only needs the visible spread.
      radius: isWebtoon ? 1 : _kWindowRadius,
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
    for (int page = 0; page < payload.images.length; page++) {
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
      spreadDirection: _spreadDirection,
      zoomPercent: _zoomPercent,
      inlineSelectionJs: inlineSelectionJs,
      pageSpreadIndices: pageSpreadIndices,
      pagesPerSpread: pagesPerSpread,
      pageNumbers: pageNumbers,
      currentSpread: _currentSpread,
      restoreFraction: isWebtoon ? _currentFraction : 0,
      documentGeneration: documentGeneration,
      ocrPageIndices: keptPages,
    );
  }

  /// （重）加载当前 spread 的窗口文档。设置在飞守卫，让并发翻页不能交叠 loadData；
  /// `_loadedSpreads`（在 [_buildWindowDocument] 内同步赋值）只在本次成功后生效，
  /// 失败回滚为旧文档的集合（否则 translateX 目标缺失、transform 归 0）。
  Future<void> _loadInitialWindow() async {
    if (_payload == null || _controller == null || _navigating) return;
    _navigating = true;
    final Set<int> previousLoaded = Set<int>.of(_loadedSpreads);
    final MangaWindowLoadTicket ticket = _windowGate.begin();
    try {
      final String doc = _buildWindowDocument(
        ReaderSelectionScripts.source(),
        documentGeneration: ticket.generation,
      );
      await _controller!.loadData(
        data: doc,
        baseUrl: WebUri('https://${MangaHibikiPage.kMangaHost}/'),
        mimeType: 'text/html',
        encoding: 'utf-8',
      );
      // WebView2's loadData Future only confirms navigation was accepted. The
      // old document can remain visible for another event-loop turn (or a
      // stale onLoadStop can arrive), so keep navigation locked until the
      // loaded document proves it owns this exact generation.
      final MangaWindowLoadOutcome outcome =
          await ticket.outcome.timeout(const Duration(seconds: 10));
      if (outcome == MangaWindowLoadOutcome.abandoned) {
        // 页面已在加载途中销毁（dispose 显式收尾）：不再碰 State，也不把它当
        // 失败上抛——调用方全是 unawaited，抛出等于未捕获异步异常（BUG-1171）。
        return;
      }
      // 首窗图作为制卡卡图（ERRATA C2）；在 _spreads/_currentSpread 定型后解析。
      _updateCurrentPageImagePath();
      // 新文档的 JS 侧框选门控从零开始；Dart 态仍激活就续上，否则按钮亮着却
      // 拖不出框（回写后重载窗口是这条路径最常见的触发者）。
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
      _windowGate.finish(ticket);
      _navigating = false;
      if (mounted && _spreads.isNotEmpty) {
        unawaited(_turnQueue.drain(
          canApply: () => mounted && !_navigating,
          applyStep: _applyMangaTurnStep,
        ));
      }
    }
  }

  // ── 翻页导航 ─────────────────────────────────────────────────────────

  /// 按 [dir] 推进当前 spread（'next' = 页序 +1 / 'prev' = -1，clamp 到书范围）。
  /// 新 spread 仍在已加载窗口内 → 只 JS translateX；越出 → 围绕它重 loadData 新窗口。
  /// 同步更新制卡卡图（ERRATA C2）并记进度。
  Future<void> _onMangaTurn(String dir) async {
    if (_spreads.isEmpty) return;
    final int delta = dir == 'next' ? 1 : -1;
    await _turnQueue.enqueue(
      delta,
      maxMagnitude: _spreads.length,
      canApply: () => mounted && !_navigating,
      applyStep: _applyMangaTurnStep,
    );
  }

  Future<void> _applyMangaTurnStep(int delta) async {
    final int target =
        (_currentSpread + delta).clamp(0, _spreads.length - 1).toInt();
    if (target == _currentSpread) return;
    _currentSpread = target;
    await _controller?.evaluateJavascript(
      source: 'window.__mangaApplyTranslate && '
          'window.__mangaApplyTranslate($target);',
    );
    await _replaceSpreadOcr(target);
    _updateCurrentPageImagePath();
    _recordProgress();
    if (_onlineChapter != null) {
      unawaited(_primeOnlinePages(_currentPage));
    }
  }

  /// Keep one spread worth of precise OCR hit targets in the stable manga
  /// document. All page images stay in the same lazy-loaded strip, so changing
  /// spreads never destroys the WebView document (and therefore never creates
  /// a keyboard-input gap). Dense magazines remain bounded because character
  /// nodes from the previous spread are removed before the new ones are added.
  Future<void> _replaceSpreadOcr(int spreadIndex) async {
    final InAppWebViewController? controller = _controller;
    if (controller == null ||
        spreadIndex < 0 ||
        spreadIndex >= _spreads.length) {
      return;
    }
    final Set<int> spreadIndices = MangaHibikiPage.mangaWindowRange(
      spreadCount: _spreads.length,
      current: spreadIndex,
      radius: _mode == MangaReadingMode.webtoon ? 1 : _kWindowRadius,
    ).toSet();
    final Set<int> pageIndices = <int>{
      for (final int index in spreadIndices) ..._spreads[index].pageIndices,
    };
    final Map<String, String> htmlByPage = <String, String>{
      for (final int pageIndex in pageIndices)
        if (pageIndex >= 0 && pageIndex < _payload!.images.length)
          '$pageIndex': mangaOcrBoxesHtml(_payload!.images[pageIndex]),
    };
    await controller.evaluateJavascript(
      source: '''
(function(){
  var keep = new Set(${jsonEncode(pageIndices.toList())});
  var htmlByPage = ${jsonEncode(htmlByPage)};
  document.querySelectorAll('.manga-page').forEach(function(page){
    var index = Number(page.getAttribute('data-page'));
    if (!keep.has(index)) {
      if (page.getAttribute('data-ocr-loaded') === '1') {
        page.querySelectorAll('.ocr-box').forEach(function(node){ node.remove(); });
        page.setAttribute('data-ocr-loaded', '0');
      }
      return;
    }
    if (page.getAttribute('data-ocr-loaded') === '1') return;
    page.insertAdjacentHTML('beforeend', htmlByPage[String(index)] || '');
    page.setAttribute('data-ocr-loaded', '1');
  });
})();
''',
    );
    _loadedSpreads = spreadIndices;
  }

  Future<void> _jumpToPageAnchor(String dir) async {
    if (_spreads.isEmpty || _navigating) return;
    final int delta = dir == 'next' ? 1 : -1;
    final int target =
        (_currentSpread + delta).clamp(0, _spreads.length - 1).toInt();
    if (target == _currentSpread) return;
    _currentSpread = target;
    _currentFraction = 0;
    await _controller?.evaluateJavascript(
      source: 'window.__mangaScrollToSpread && '
          'window.__mangaScrollToSpread($target, 0);',
    );
    await _replaceSpreadOcr(target);
    _updateCurrentPageImagePath();
    _recordProgress();
    if (_onlineChapter != null) {
      unawaited(_primeOnlinePages(_currentPage));
    }
  }

  /// 桌面键盘翻页（webtoon 交 WebView 原生竖滚，方向键一律 ignored）。
  ///
  /// - 只认 KeyDownEvent；KeyRepeatEvent（按住）丢弃，按住方向键不堆翻页风暴。
  /// - 查词弹窗显示时，左右键关闭弹窗并翻页，Escape 只关闭弹窗；避免原生词典
  ///   WebView 持焦后把翻页键吞掉或让 Escape 落到外层退书。
  KeyEventResult _handleReaderKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) {
      return KeyEventResult.ignored;
    }
    final MangaReaderInputAction? action = _resolveMangaKeyAction(
      event.logicalKey,
      activeModifierKeys(),
    );
    if (action == null) return KeyEventResult.ignored;
    _executeReaderInputAction(
      action,
      source: _MangaReaderInputSource.flutter,
    );
    return KeyEventResult.handled;
  }

  MangaReaderInputAction? _lastReaderInputAction;
  _MangaReaderInputSource? _lastReaderInputSource;
  DateTime? _lastReaderInputAt;
  Timer? _dictionaryTurnDismissTimer;

  void _executeReaderInputAction(
    MangaReaderInputAction action, {
    required _MangaReaderInputSource source,
  }) {
    // 框选识别模式独占键盘：关词典键（默认 Escape）退出模式，翻页键一律吞掉——
    // 框选途中翻走当前页会让松手时算出的 pageIndex 指向另一页，回写就落错页。
    // 放在去抖之前：两条输入源（Flutter / 原生 WebView 桥）共用这一个闸门。
    if (_rescanModeActive) {
      if (action == MangaReaderInputAction.dismissDictionary) {
        unawaited(_setRescanMode(false));
      }
      return;
    }
    final DateTime now = DateTime.now();
    if (_lastReaderInputAction == action &&
        _lastReaderInputSource != source &&
        _lastReaderInputAt != null &&
        now.difference(_lastReaderInputAt!) <
            const Duration(milliseconds: 60)) {
      return;
    }
    _lastReaderInputAction = action;
    _lastReaderInputSource = source;
    _lastReaderInputAt = now;
    if (action == MangaReaderInputAction.dismissDictionary) {
      _dictionaryTurnDismissTimer?.cancel();
      clearDictionaryResult();
      return;
    }
    if (isDictionaryShown) {
      // Keep the native dictionary WebView focused through a key burst. Removing
      // it on the first arrow creates a short HWND focus hand-off in which the
      // immediately following real key can be lost. The page turn is queued
      // now; only the visual popup dismissal waits for the burst to settle.
      _dictionaryTurnDismissTimer?.cancel();
      _dictionaryTurnDismissTimer = Timer(
        const Duration(milliseconds: 180),
        () {
          if (mounted) clearDictionaryResult();
        },
      );
    }
    final String turn = action == MangaReaderInputAction.next ? 'next' : 'prev';
    unawaited(_mode == MangaReadingMode.webtoon
        ? _jumpToPageAnchor(turn)
        : _onMangaTurn(turn));
  }

  @override
  ShortcutScope? get dictionaryPopupInputScope => ShortcutScope.manga;

  /// 漫画在弹窗可见时**仍要**处理翻页与关词典：左右键关弹窗并翻页、关词典键只关
  /// 弹窗。旧桥把这三个键硬编码成 `ArrowLeft/ArrowRight/Escape`，用户改键后弹窗
  /// 持焦的路径仍按老键位响应；现在 token 表由注册表当前绑定导出，改键自动跟随。
  @override
  Set<ShortcutAction> get dictionaryPopupForwardedActions =>
      const <ShortcutAction>{
        ShortcutAction.mangaPageForward,
        ShortcutAction.mangaPageBackward,
        ShortcutAction.mangaDismissDict,
      };

  @override
  void onDictionaryPopupInputToken(String token) {
    // 鼠标 token 不参与「跨页方向校正」（那是方向键专属语义），交回基类按注册表
    // 动作直接执行（关词典）。
    if (MouseBinding.deserialize(token) != null) {
      super.onDictionaryPopupInputToken(token);
      return;
    }
    _handleNativeNavigationKey(token);
  }

  /// 词典弹窗渲染完成（指针唤出路径）：把 Flutter 焦点收回正文。
  ///
  /// 弹窗是纯原生 WebView，指针唤出它时 OS 焦点落在弹窗上。漫画在弹窗可见时
  /// **仍要**处理左右键（关弹窗并翻页）与 Escape（关弹窗），不收回这些键就全部
  /// 落空——[onDictionaryPopupNavigationKey] 的转发只覆盖弹窗自己收到的键，
  /// 覆盖不了「焦点悬空」的情况。
  @override
  void onDictionaryPopupRendered(int index) {
    super.onDictionaryPopupRendered(index);
    _focusOwnership.reclaim(FocusReclaimCause.popupRendered);
  }

  /// 整条查词弹窗栈关闭：键盘所有权无条件回到正文，否则用户被困死（收不到任何键）。
  @override
  void onAllPopupsDismissed() {
    super.onAllPopupsDismissed();
    _focusOwnership.reclaim(FocusReclaimCause.popupDismissed);
  }

  /// 注册表解析 → 跨页方向校正 → 上下文门控。键盘路径与 WebView 桥回传路径共用，
  /// 保证「改键」对两条路径同时生效（否则改了键，WebView 持焦时又变回默认键位）。
  MangaReaderInputAction? _resolveMangaKeyAction(
    LogicalKeyboardKey key,
    Set<ModifierKey> modifiers,
  ) {
    final HibikiShortcutRegistry registry = appModel.shortcutRegistry;
    final ShortcutAction? bound = registry.resolveKeyboard(
      key,
      modifiers: modifiers,
      scope: ShortcutScope.manga,
    );
    final ShortcutAction? corrected = resolveMangaArrowPageTurn(
          key: key,
          modifiers: modifiers,
          rtl: _spreadDirection == 'rtl',
          boundAction: bound,
        ) ??
        bound;
    return MangaHibikiPage.inputActionForShortcut(
      action: corrected,
      horizontalArrow: key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight,
      dictionaryShown: isDictionaryShown,
      mode: _mode,
    );
  }

  void _handleNativeNavigationKey(String key) {
    // token 按 [InputBinding.serialize] 解析：正文 WebView 的桥发裸 `event.key`
    // （`ArrowLeft`），弹窗桥发注册表 token（可能是任意键名、可能带修饰键前缀），
    // 两者都能被同一个 deserialize 吃下——旧的三分支 switch 只认硬编码的方向键与
    // Escape，用户把翻页/关词典改绑到别的键后，WebView 持焦的这条路径就整个失效。
    // `Esc` 是旧浏览器对 Escape 的别名，不在注册表键名表里，单独归一。
    final InputBinding? binding = key == 'Esc'
        ? const InputBinding(key: LogicalKeyboardKey.escape)
        : InputBinding.deserialize(key);
    if (binding == null) return;
    final MangaReaderInputAction? action = _resolveMangaKeyAction(
      binding.key,
      binding.modifiers,
    );
    if (action != null) {
      _executeReaderInputAction(
        action,
        source: _MangaReaderInputSource.nativeWebView,
      );
    }
  }

  @override
  void onDismissBarrierPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final MangaReaderInputAction? action =
        MangaHibikiPage.wheelInputAction(event.scrollDelta);
    if (action == null) return;
    clearDictionaryResult();
    final String turn = action == MangaReaderInputAction.next ? 'next' : 'prev';
    unawaited(_mode == MangaReadingMode.webtoon
        ? _jumpToPageAnchor(turn)
        : _onMangaTurn(turn));
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
      await _replaceSpreadOcr(topSpread);
      _updateCurrentPageImagePath();
    }
    _recordProgress();
    if (spreadChanged && _onlineChapter != null) {
      unawaited(_primeOnlinePages(_currentPage));
    }
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
      imagesDir,
      MangaHibikiPage.mangaImageRelativePath(payload.images[page].url),
    );
    if (_currentPageImagePath == null && _onlineChapter != null) {
      unawaited(_resolveOnlineCurrentPageFile(page));
    }
  }

  Future<void> _resolveOnlineCurrentPageFile(int page) async {
    final MangaReaderSession? session = _pageSession;
    if (session == null || page < 0 || page >= session.pageCount) return;
    try {
      final File? file = await session.localFile(page);
      if (!mounted ||
          page !=
              MangaHibikiPage.firstPageOfSpread(
                _spreads,
                _currentSpread,
              )) {
        return;
      }
      _currentPageImagePath = file?.path;
    } on Object catch (error, stack) {
      ErrorLogService.instance
          .log('MangaHibikiPage.onlineCardImage', error, stack);
    }
  }

  /// 直接运行非模态全页/整卷 OCR。选好引擎后向导立即关闭，任务由阅读器持有；
  /// Lens 从当前页扫到末页后再补首页，每完成一页就热替换该页透明文字层。
  Future<void> _openWholeVolumeOcr() async {
    final EpubBookRow? row = _bookRow;
    if (row == null || _wholeVolumeOcrOpen || _wholeVolumeOcrRunning) {
      return;
    }
    setState(() => _wholeVolumeOcrOpen = true);
    try {
      final MihonReaderChapter? online = _onlineChapter;
      final MangaOcrBackgroundJob? job;
      if (online != null) {
        if (!await ensureGoogleLensDisclosure(context) || !mounted) return;
        final MangaReaderSession? session = _pageSession;
        final MokuroPayload? payload = _payload;
        if (session == null || payload == null) return;
        _onlineGeometryPersistDebounce?.cancel();
        await _persistOnlinePayloadGeometry();
        job = MangaOcrBackgroundJob(
          bookKey: widget.bookKey,
          managedDirectory: online.managedDirectory.path,
          engine: MangaOcrEngineId.googleLens,
          events: MihonOnlineMangaOcr(
            session: session,
            managedDirectory: online.managedDirectory,
            initialPayload: payload,
            startPage: _currentPage,
          ).run(),
        );
      } else {
        job = await MangaModule.openBookOcr(
          context: context,
          db: appModel.database,
          book: row,
          startPage: _currentPage,
        );
      }
      if (!mounted || job == null) return;
      setState(() {
        _wholeVolumeOcrRunning = true;
        _wholeVolumeOcrDone = 0;
        _wholeVolumeOcrTotal = 0;
        _wholeVolumeOcrAcceleration = null;
        _wholeVolumeOcrDegradeNotified = false;
      });
      _wholeVolumeOcrSubscription =
          job.events.asyncMap(_handleWholeVolumeOcrEvent).listen(
        (_) {},
        onError: (Object error, StackTrace stack) {
          ErrorLogService.instance.log(
            'MangaHibikiPage.wholeVolumeOcr',
            error,
            stack,
          );
          if (!mounted) return;
          setState(() => _wholeVolumeOcrRunning = false);
          HibikiToast.show(msg: '${t.manga_ocr_wizard_failed}: $error');
        },
        onDone: () {
          _wholeVolumeOcrSubscription = null;
          if (mounted && _wholeVolumeOcrRunning) {
            setState(() => _wholeVolumeOcrRunning = false);
          }
        },
      );
    } catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaHibikiPage.wholeVolumeOcr',
        error,
        stack,
      );
      if (mounted) {
        HibikiToast.show(msg: '${t.manga_ocr_wizard_failed}: $error');
      }
    } finally {
      if (mounted) setState(() => _wholeVolumeOcrOpen = false);
    }
  }

  Future<void> _handleWholeVolumeOcrEvent(
    MangaOcrBackgroundEvent event,
  ) async {
    if (!mounted) return;
    _observeWholeVolumeOcrAcceleration(event.acceleration);
    if (event.finished) {
      await _finishWholeVolumeOcr(event);
      return;
    }
    setState(() {
      _wholeVolumeOcrDone = event.pagesDone;
      _wholeVolumeOcrTotal = event.pagesTotal;
    });
    final int? pageIndex = event.pageIndex;
    final MokuroImage? page = event.page;
    final MokuroPayload? current = _payload;
    if (pageIndex == null ||
        page == null ||
        current == null ||
        pageIndex < 0 ||
        pageIndex >= current.images.length) {
      return;
    }
    final List<MokuroImage> images = List<MokuroImage>.of(current.images);
    images[pageIndex] = page;
    setState(() {
      _payload = MokuroPayload(images: images, ocr: current.ocr);
    });
    await _replacePageOcrOverlay(pageIndex, page);
  }

  /// 记录并（首次）提示本次任务真正生效的执行后端。
  ///
  /// BUG-1163：GPU EP 被插件拒绝时实现会静默重建 CPU 会话；不提示的话用户在
  /// 整卷 OCR 上只会觉得「怎么这么慢」，无从判断自己根本没在用 GPU。
  void _observeWholeVolumeOcrAcceleration(
    MangaOcrAcceleration? acceleration,
  ) {
    if (acceleration == null) return;
    if (identical(acceleration, _wholeVolumeOcrAcceleration)) return;
    setState(() => _wholeVolumeOcrAcceleration = acceleration);
    if (!acceleration.degraded || _wholeVolumeOcrDegradeNotified) return;
    _wholeVolumeOcrDegradeNotified = true;
    HibikiToast.show(
      msg: t.manga_ocr_acceleration_degraded(
        engine: acceleration.label,
        reason: acceleration.degradeReasons.join('; '),
      ),
    );
  }

  Future<void> _replacePageOcrOverlay(
    int pageIndex,
    MokuroImage page,
  ) async {
    final String boxes = mangaOcrBoxesHtml(page);
    await _controller?.evaluateJavascript(
      source: 'window.__mangaReplaceOcr && '
          'window.__mangaReplaceOcr($pageIndex, ${jsonEncode(boxes)});',
    );
  }

  Future<void> _finishWholeVolumeOcr(
    MangaOcrBackgroundEvent event,
  ) async {
    final EpubBookRow? row = _bookRow;
    final String? resultPath = event.resultPath;
    if (row == null || resultPath == null) return;
    final String source = await File(resultPath).readAsString();
    final MokuroPayload payload =
        event.external ? parseMokuro(source) : parseMangaJson(source);
    if (payload.images.isEmpty) {
      throw StateError('OCR result has no pages');
    }
    // 整卷落盘与框选回写、在线几何回填共用同一把 per-path 写锁：三者都是整份
    // 读-改-写，交叠会互相覆盖。
    final String target = p.join(row.extractDir, row.epubPath);
    await runExclusiveOnMangaJson<void>(
      target,
      () => writeMangaJsonAtomically(target, payload),
    );
    if (!mounted) return;
    setState(() {
      _payload = payload;
      _wholeVolumeOcrDone = event.pagesTotal;
      _wholeVolumeOcrTotal = event.pagesTotal;
      _wholeVolumeOcrRunning = false;
    });
    final Set<int> visiblePages = <int>{
      for (final int spread in _loadedSpreads)
        if (spread >= 0 && spread < _spreads.length)
          ..._spreads[spread].pageIndices,
    };
    for (final int pageIndex in visiblePages) {
      if (pageIndex >= 0 && pageIndex < payload.images.length) {
        await _replacePageOcrOverlay(pageIndex, payload.images[pageIndex]);
      }
    }
    HibikiToast.show(msg: t.manga_ocr_wizard_done);
  }

  void _cancelWholeVolumeOcr() {
    unawaited(_wholeVolumeOcrSubscription?.cancel());
    _wholeVolumeOcrSubscription = null;
    if (mounted) {
      setState(() {
        _wholeVolumeOcrRunning = false;
        _wholeVolumeOcrDone = 0;
        _wholeVolumeOcrTotal = 0;
      });
    }
  }

  // ── 框选识别 ─────────────────────────────────────────────────────────
  //
  // 三段链：JS 框选 → `onMangaBoxSelected` → 本地识别 → 结果卡片 →（查词 |
  // 回写 manga.json）。识别服务在 `media/manga/ocr/manga_box_rescan.dart`，回写在
  // `media/manga/manga_json_writeback.dart`，卡片在 `reader/manga_rescan_result_sheet.dart`；
  // 本页只做编排与状态同步。

  /// 刷新识别模型就绪位。只看 `recognizerReady`——单框不需要检测器；也不看
  /// `isSupportedPlatform`，那是整卷重活的闸门。
  Future<void> _refreshRescanModelReady() async {
    try {
      final MangaOcrModelStatus status =
          await ref.read(mangaOcrServiceProvider).modelStatus();
      if (!mounted) return;
      setState(() => _rescanModelReady = status.recognizerReady);
    } on Object catch (error, stack) {
      ErrorLogService.instance
          .log('MangaHibikiPage.rescanStatus', error, stack);
    }
  }

  /// chrome「框选识别」按钮：模式内再点 = 退出；未就绪时点击再查一次（用户可能
  /// 刚下载完），仍未就绪才给引导提示。
  Future<void> _onRescanButtonPressed() async {
    if (_rescanModeActive) {
      await _setRescanMode(false);
      return;
    }
    final MangaBoxRescanService service =
        _rescanService ??= MangaBoxRescanService();
    if (!service.isLocalRescanSupported) {
      HibikiToast.show(msg: t.manga_ocr_unsupported);
      return;
    }
    if (!_rescanModelReady) {
      await _refreshRescanModelReady();
      if (!mounted) return;
      if (!_rescanModelReady) {
        HibikiToast.show(msg: t.manga_rescan_model_missing);
        return;
      }
    }
    await _setRescanMode(true);
  }

  /// Dart/JS 双侧同步进入/退出框选模式。
  Future<void> _setRescanMode(bool on) async {
    if (!mounted) return;
    setState(() => _rescanModeActive = on);
    await _controller?.evaluateJavascript(
      source: 'window.__mangaSetRescanMode && '
          'window.__mangaSetRescanMode(${on ? 'true' : 'false'});',
    );
    if (on) HibikiToast.show(msg: t.manga_rescan_hint);
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
    final Object? decoded = _tryDecodeJson(payloadJson);
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
      imagesDir,
      MangaHibikiPage.mangaImageRelativePath(payload.images[pageIndex].url),
    );
    if (imagePath == null) {
      HibikiToast.show(msg: t.manga_rescan_failed);
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
        text: result.text.trim(),
        vertical: result.vertical,
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaHibikiPage.rescan', error, stack);
      if (mounted) HibikiToast.show(msg: t.manga_rescan_failed);
    } finally {
      _rescanBusy = false;
    }
  }

  static Object? _tryDecodeJson(String source) {
    try {
      return jsonDecode(source);
    } catch (_) {
      return null;
    }
  }

  /// 结果卡片：识别文本 + 来源标注 + 采纳入口（查词 / 回写本页）。
  Future<void> _showRescanResult({
    required int pageIndex,
    required OcrRect box,
    required String text,
    required bool vertical,
  }) async {
    if (!mounted) return;
    final MangaRescanAction? action =
        await showModalBottomSheet<MangaRescanAction>(
      context: context,
      builder: (BuildContext sheetContext) =>
          MangaRescanResultSheet(text: text),
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
    }
  }

  /// 以识别文本走既有词典管线（弹窗锚屏幕中心）；句子上下文 = 识别文本本身
  /// （气泡即句子）。
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

  /// 回写本页：把识别块追加进本书 manga.json 的对应页（读-改-写，文件级锁 +
  /// 原子落盘），再重读文件刷新内存 payload 并重载窗口，让新框立即可查词。
  Future<void> _rescanWriteBack({
    required int pageIndex,
    required OcrRect box,
    required bool vertical,
    required String text,
  }) async {
    final EpubBookRow? row = _bookRow;
    if (row == null || text.isEmpty) return;
    final String mangaJsonPath = p.join(row.extractDir, row.epubPath);
    // 在线几何 debounce 到期时会把当时的 `_payload` 整份写回。它若插在「追加落盘」
    // 与下面的 setState 之间，写的就是**不含新块**的旧快照，刚回写的框当场被吞。
    // 先取消它；几何本来就会在下次翻页/滚动时重新排程。
    _onlineGeometryPersistDebounce?.cancel();
    try {
      // 锁内已经产出了落盘后的 payload，直接用——锁外重读会读到别的写者的版本。
      final MokuroPayload payload = await appendMangaBlockToMangaJson(
        mangaJsonPath: mangaJsonPath,
        pageIndex: pageIndex,
        box: Rect.fromLTRB(box.left, box.top, box.right, box.bottom),
        vertical: vertical,
        text: text,
      );
      if (!mounted) return;
      setState(() => _payload = payload);
      await _loadInitialWindow();
      HibikiToast.show(msg: t.manga_rescan_writeback_done);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaHibikiPage.rescanWrite', error, stack);
      if (mounted) HibikiToast.show(msg: t.manga_rescan_writeback_failed);
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
          final ReaderSelectionData data =
              ReaderSelectionData.fromJson(payload);
          if (kDebugMode && mounted) {
            setState(() => _debugOcrSelectedText = data.text);
          }
          await processMangaSelection(data);
        } catch (e, stack) {
          ErrorLogService.instance.log('MangaHibiki.onTextSelected', e, stack);
          debugPrint('[MangaHibiki] onTextSelected error: $e');
        }
      },
    );
  }

  /// Capture the exact OCR page for subsequent mining. Local imports resolve
  /// synchronously; online chapters materialise that one page through the
  /// session cache. A generation guard prevents a slow old selection from
  /// overwriting a newer click.
  Future<void> _selectPageForMining(int? pageIndex) async {
    final int generation = ++_miningPageGeneration;
    _miningPageIndex = pageIndex;
    _miningPageImagePath = null;
    if (pageIndex == null) return;

    final MokuroPayload? payload = _payload;
    final String? imagesDir = _imagesDir;
    if (payload == null ||
        imagesDir == null ||
        pageIndex < 0 ||
        pageIndex >= payload.images.length) {
      return;
    }

    final String? local = MangaHibikiPage.resolveMangaPageImage(
      payload,
      imagesDir,
      pageIndex,
    );
    if (local != null) {
      _miningPageImagePath = local;
      return;
    }

    final MangaReaderSession? session = _pageSession;
    if (session == null || pageIndex >= session.pageCount) return;
    try {
      final File? file = await session.localFile(pageIndex);
      if (!mounted || generation != _miningPageGeneration) return;
      _miningPageImagePath =
          file != null && await file.exists() ? file.path : null;
    } on Object catch (error, stack) {
      ErrorLogService.instance
          .log('MangaHibikiPage.selectedCardImage', error, stack);
    }
  }

  /// 处理 OCR 文字命中后的选词 payload：记录所在句子（喂制卡/收藏）并在选区矩形上开查词
  /// 弹窗。词/句/矩形契约由纯函数 [dispatchMangaSelection] 承担（可单测）。
  Future<void> processMangaSelection(ReaderSelectionData data) async {
    if (!mounted) return;
    final Size screen = MediaQuery.of(context).size;
    await dispatchMangaSelection(
      data,
      fallbackScreen: screen,
      selectPageForMining: _selectPageForMining,
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
      search: (
        String term,
        Rect selectionRect,
        bool verticalWriting,
      ) async {
        _popupVerticalWriting = verticalWriting;
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
  /// **本次 OCR 命中页的文件路径**（旧 payload 才回退当前 spread 首页），直接传路径
  /// 经 [AnkiMiningContext.coverPath] 走 `{book-cover}`/`{card-image}` 通道。漫画无
  /// 音轨，sasayaki 音频字段恒 null。
  @override
  Future<MinePopupResult> onMineFromPopup(Map<String, String> fields) async {
    final BaseAnkiRepository repo = ref.read(ankiRepositoryProvider);
    try {
      final String sentence =
          _lastSentence.isNotEmpty ? _lastSentence : (fields['sentence'] ?? '');

      String? coverPath;
      final String? pageImage = _miningPageIndex == null
          ? _currentPageImagePath
          : _miningPageImagePath;
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
    // 唯一收口：本方法写 _pageNotifier 并新建 debounce Timer，两者都在 dispose
    // 里被释放/取消。所有调用点都在若干 await 之后（翻页/滚动/窗口就绪），迟到的
    // 回调必须在这里被挡掉，否则 ValueNotifier used after being disposed，并留下
    // dispose 之后才触发的泄漏定时器（BUG-1171）。
    if (!mounted) return;
    final (int page, double fraction) = MangaHibikiPage.mangaProgressForSpread(
      _spreads,
      _currentSpread,
      webtoonFraction: _currentFraction,
      isWebtoon: _mode == MangaReadingMode.webtoon,
    );
    _currentPage = page;
    _pageNotifier.value = page;
    _countVisiblePages();
    // 600ms debounce：连续翻页/滚动只落最后一次。
    _progressDebounce?.cancel();
    _progressDebounce = Timer(const Duration(milliseconds: 600), () {
      unawaited(_persistPosition(page, fraction));
    });
  }

  /// 把当前可见页记进本会话的字数/页数账（每页只记一次）。
  ///
  /// spread 模式当前 entry 的两页都算看过；webtoon 整本单文档竖滚，只有真正成为
  /// 「当前页」的那页算读过（快速滚过没停留的页不计，宁可少算不虚高）。
  void _countVisiblePages() {
    final MokuroPayload? payload = _payload;
    if (payload == null) return;
    final bool isWebtoon = _mode == MangaReadingMode.webtoon;
    final List<int> pages =
        !isWebtoon && _currentSpread >= 0 && _currentSpread < _spreads.length
            ? _spreads[_currentSpread].pageIndices
            : <int>[_currentPage];
    final ({int chars, int pages}) added = mangaAccumulateReadingStats(
      payload: payload,
      pageIndices: pages,
      counted: _sessionCountedPages,
    );
    _sessionCharsRead += added.chars;
    _sessionPagesRead += added.pages;
  }

  Future<void> _persistPosition(int page, double fraction) async {
    _lastSavedPage = page;
    _lastSavedFraction = fraction;
    if (!_persistProgress) return;
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
    if (pageCount > 0 && page >= pageCount - 1) {
      try {
        await db.markEpubBookCompletedIfUnset(widget.bookKey, DateTime.now());
      } catch (e, stack) {
        ErrorLogService.instance.log('MangaHibikiPage.markCompleted', e, stack);
      }
    }
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

  /// 落本次会话的阅读时长 + OCR 字数 + 页数 + 首页「学习活动」事件。
  ///
  /// 与 PDF 同款纪律、刻意不复用 EPUB 的实现：EPUB 那条以 `charsRead <= 0` 早退，
  /// 漫画只有时长没字数的那些段会整段被丢。这里仍以**时长**为触发条件。
  ///
  /// v60 起漫画同时落两个独立量纲：`charsRead` = 已读页的 OCR 实义字符数（口径与
  /// EPUB 同源），`pagesRead` = 已读页数。页数仍然绝不塞进 charsRead——那会污染
  /// 字数口径与阅读速度；两者分列，统计页分别展示。
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
    // 未落库的字数/页数先取走再清零：落库失败时不重复计（下一段仍会记新翻的页），
    // 也不会因异常把同一批重复写进 DB。
    final int charsRead = _sessionCharsRead;
    final int pagesRead = _sessionPagesRead;
    _sessionCharsRead = 0;
    _sessionPagesRead = 0;
    final String dateKey = statDateKey(now);
    try {
      await appModel.database.addReadingStatistic(
        title: row.title,
        dateKey: dateKey,
        charsRead: charsRead,
        timeMs: elapsedMs,
        pagesRead: pagesRead,
      );
      await appModel.database.addActivityEvent(
        eventType: kActivityRead,
        mediaType: kActivityMediaBook,
        title: row.title,
        mediaKey: widget.bookKey,
        dateKey: dateKey,
        timestampMs: now.millisecondsSinceEpoch,
        durationMs: elapsedMs,
        charsDelta: charsRead,
      );
    } catch (e, stack) {
      ErrorLogService.instance
          .log('MangaHibikiPage._flushReadingStats', e, stack);
    }
  }

  Future<void> _setSpreadDirection(String direction) async {
    final String normalized = direction == 'ltr' ? 'ltr' : 'rtl';
    if (_spreadDirection == normalized) return;
    setState(() => _spreadDirection = normalized);
    await appModel.setMangaReadingDirection(normalized);
    if (_mode == MangaReadingMode.spread) {
      await _loadInitialWindow();
    }
  }

  Future<void> _setZoomPercent(int value) async {
    final int normalized = value.clamp(50, 200);
    if (_zoomPercent == normalized) return;
    setState(() => _zoomPercent = normalized);
    await appModel.setMangaZoomPercent(normalized);
    await _controller?.evaluateJavascript(
      source: 'window.__mangaSetZoom && '
          'window.__mangaSetZoom($normalized);',
    );
  }

  Future<void> _jumpToPage(int oneBasedPage) async {
    final MokuroPayload? payload = _payload;
    if (payload == null || payload.images.isEmpty) return;
    final int page = (oneBasedPage - 1).clamp(0, payload.images.length - 1);
    final int target = MangaHibikiPage.spreadIndexForPage(_spreads, page);
    _currentSpread = target;
    _currentFraction = 0;
    if (_mode == MangaReadingMode.webtoon) {
      await _controller?.evaluateJavascript(
        source: 'window.__mangaScrollToSpread && '
            'window.__mangaScrollToSpread($target, 0);',
      );
      await _replaceSpreadOcr(target);
    } else {
      await _controller?.evaluateJavascript(
        source: 'window.__mangaApplyTranslate && '
            'window.__mangaApplyTranslate($target);',
      );
      await _replaceSpreadOcr(target);
    }
    _updateCurrentPageImagePath();
    _recordProgress();
  }

  Future<void> _showPageJumpDialog() async {
    final int total = _payload?.images.length ?? 0;
    if (total <= 0) return;
    final int? page = await showMangaPageJumpDialog(
      context,
      currentPage: _currentPage + 1,
      total: total,
    );
    if (page != null) {
      await _jumpToPage(page);
    }
  }

  Future<void> _showReaderContextMenu(String payloadJson) async {
    Object? decoded;
    try {
      decoded = jsonDecode(payloadJson);
    } on FormatException {
      return;
    }
    if (decoded is! Map || !mounted) return;
    final double x = (decoded['x'] as num?)?.toDouble() ?? 0;
    final double y = (decoded['y'] as num?)?.toDouble() ?? 0;
    final Size size = MediaQuery.of(context).size;
    final _MangaContextAction? action = await showMenu<_MangaContextAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        x,
        y,
        math.max(0, size.width - x),
        math.max(0, size.height - y),
      ),
      items: <PopupMenuEntry<_MangaContextAction>>[
        PopupMenuItem<_MangaContextAction>(
          value: _MangaContextAction.previous,
          child: Text(t.manga_previous_page),
        ),
        PopupMenuItem<_MangaContextAction>(
          value: _MangaContextAction.next,
          child: Text(t.manga_next_page),
        ),
        PopupMenuItem<_MangaContextAction>(
          value: _MangaContextAction.jump,
          child: Text(t.manga_jump_to_page),
        ),
        PopupMenuItem<_MangaContextAction>(
          value: _MangaContextAction.direction,
          child: Text(
            _spreadDirection == 'rtl'
                ? t.manga_direction_ltr
                : t.manga_direction_rtl,
          ),
        ),
        PopupMenuItem<_MangaContextAction>(
          value: _MangaContextAction.zoomIn,
          enabled: _zoomPercent < 200,
          child: Text('${t.manga_zoom} + ($_zoomPercent%)'),
        ),
        PopupMenuItem<_MangaContextAction>(
          value: _MangaContextAction.zoomOut,
          enabled: _zoomPercent > 50,
          child: Text('${t.manga_zoom} − ($_zoomPercent%)'),
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case _MangaContextAction.previous:
        await (_mode == MangaReadingMode.webtoon
            ? _jumpToPageAnchor('prev')
            : _onMangaTurn('prev'));
        return;
      case _MangaContextAction.next:
        await (_mode == MangaReadingMode.webtoon
            ? _jumpToPageAnchor('next')
            : _onMangaTurn('next'));
        return;
      case _MangaContextAction.jump:
        await _showPageJumpDialog();
        return;
      case _MangaContextAction.direction:
        await _setSpreadDirection(
          _spreadDirection == 'rtl' ? 'ltr' : 'rtl',
        );
        return;
      case _MangaContextAction.zoomIn:
        await _setZoomPercent(_zoomPercent + 10);
        return;
      case _MangaContextAction.zoomOut:
        await _setZoomPercent(_zoomPercent - 10);
        return;
    }
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
        // 键盘兜底必须包住正文、chrome 和词典弹层。旧结构只包正文 WebView，
        // 词典 WebView 获得焦点后变成 sibling，左右键/Escape 不再经过本处理器。
        body: Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: _handleReaderKey,
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              Positioned.fill(child: _buildBody()),
              // 顶部 chrome：页码指示 + 阅读模式切换。
              if (_bookRow != null && !_loadFailed)
                Positioned(
                  top: 0,
                  right: 0,
                  child: SafeArea(child: _buildTopChrome()),
                ),
              // 查词弹窗层：必须在同一个键盘 Focus 子树里，否则原生词典
              // WebView 持焦后会吞掉翻页键。
              Positioned.fill(
                key: const ValueKey<String>('manga_dictionary_host'),
                child: buildDictionary(),
              ),
            ],
          ),
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
            return TextButton(
              key: const ValueKey<String>('manga_page_jump_button'),
              onPressed: () => unawaited(_showPageJumpDialog()),
              child: Text(
                label,
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                      color: Colors.white70,
                    ),
              ),
            );
          },
        ),
        // 框选识别入口：OCR 漏框或遇手写气泡时就地重识别一块，不必整卷重跑。
        // 常显；模型未就绪时点击给引导提示（gating 只看识别三件套）。激活时高亮。
        Tooltip(
          message: t.manga_rescan_run,
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
        // Niratan 风格整页 OCR：直接选择引擎并识别整卷，不进入框选模式。
        Tooltip(
          message: _wholeVolumeOcrRunning && _wholeVolumeOcrTotal > 0
              ? <String>[
                  t.manga_ocr_wizard_page_progress(
                    done: _wholeVolumeOcrDone,
                    total: _wholeVolumeOcrTotal,
                  ),
                  if (_wholeVolumeOcrAcceleration != null)
                    t.manga_ocr_acceleration_status(
                      engine: _wholeVolumeOcrAcceleration!.label,
                    ),
                ].join('\n')
              : t.manga_ocr_wizard_run,
          child: IconButton(
            key: const ValueKey<String>('manga_full_ocr_button'),
            icon: _wholeVolumeOcrOpen || _wholeVolumeOcrRunning
                ? const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(
                    Icons.document_scanner_outlined,
                    color: Colors.white,
                  ),
            onPressed: _wholeVolumeOcrOpen
                ? null
                : _wholeVolumeOcrRunning
                    ? _cancelWholeVolumeOcr
                    : () => unawaited(_openWholeVolumeOcr()),
          ),
        ),
        if (_wholeVolumeOcrRunning && _wholeVolumeOcrTotal > 0)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Text(
              '$_wholeVolumeOcrDone/$_wholeVolumeOcrTotal',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Colors.white70,
                  ),
            ),
          ),
        // BUG-1163：当前真正生效的执行后端常驻显示，降级时标红。
        if (_wholeVolumeOcrRunning && _wholeVolumeOcrAcceleration != null)
          Padding(
            padding: const EdgeInsets.only(right: 4),
            child: Text(
              _wholeVolumeOcrAcceleration!.label,
              key: const ValueKey<String>('manga_ocr_acceleration_label'),
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: _wholeVolumeOcrAcceleration!.degraded
                        ? Colors.amberAccent
                        : Colors.white70,
                  ),
            ),
          ),
        if (kDebugMode && _debugOcrHitOrientation != null)
          Container(
            key: const ValueKey<String>('manga_ocr_hit_debug'),
            margin: const EdgeInsets.only(right: 6),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: Colors.black87,
              border: Border.all(color: Colors.lightGreenAccent),
              borderRadius: HibikiBorderRadius.chip,
            ),
            child: Text(
              '${_debugOcrHitOrientation == 'vertical' ? '竖排' : '横排'}'
              ' · ${_debugOcrHitCharacter ?? ''}'
              ' · ${_debugOcrSelectedText ?? ''}'
              ' · $_zoomPercent%',
              style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Colors.lightGreenAccent,
                  ),
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
      return const Center(child: CircularProgressIndicator());
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
    // 重建 key 挂在 WebView **之上**：`manga_webview` 这个 ValueKey 是集成测试
    // finder 的锚点，不能随代次变化。
    return KeyedSubtree(
      key: _webViewDeathGuard.rebuildKey,
      child: _buildWebViewSurface(),
    );
  }

  Widget _buildWebViewSurface() {
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
        // 空白 tap 是 no-op（记录 sink 让手势机契约可观察）。
        controller.addJavaScriptHandler(
          handlerName: 'onTapEmpty',
          callback: (List<dynamic> args) {
            // 空白 tap 本身是 no-op，但指针已让原生 WebView 夺走 OS 焦点，
            // 必须把 Flutter 焦点收回，否则此后方向键翻页全部失效。
            _focusOwnership.reclaim(FocusReclaimCause.gesture);
          },
        );
        controller.addJavaScriptHandler(
          handlerName: 'onMangaOcrHitDebug',
          callback: (List<dynamic> args) {
            if (!kDebugMode || args.isEmpty || args[0] is! String) return;
            try {
              final Map<String, dynamic> data =
                  jsonDecode(args[0] as String) as Map<String, dynamic>;
              if (!mounted) return;
              setState(() {
                _debugOcrHitOrientation = data['orientation']?.toString() ?? '';
                _debugOcrHitCharacter = data['text']?.toString() ?? '';
              });
            } catch (_) {
              // Debug-only evidence must never affect lookup.
            }
          },
        );
        // 翻页：JS 手势机报方向（'next'/'prev'，页序语义），Dart 推进 spread。
        controller.addJavaScriptHandler(
          handlerName: 'onMangaTurn',
          callback: (List<dynamic> args) {
            if (args.isEmpty) return;
            // 手势/滚轮翻页经原生 WebView 触发，指针已夺焦：翻完把键盘收回，
            // 否则「滑一下之后方向键就不灵了」（与阅读器 BUG-136 同源）。
            _focusOwnership.reclaim(FocusReclaimCause.gesture);
            unawaited(_onMangaTurn(args[0] as String));
          },
        );
        controller.addJavaScriptHandler(
          handlerName: 'onMangaNavigationKey',
          callback: (List<dynamic> args) {
            if (args.isEmpty || args[0] is! String) return;
            _handleNativeNavigationKey(args[0] as String);
          },
        );
        controller.addJavaScriptHandler(
          handlerName: 'onMangaContextMenu',
          callback: (List<dynamic> args) {
            if (args.isEmpty || args[0] is! String) return;
            unawaited(_showReaderContextMenu(args[0] as String));
          },
        );
        controller.addJavaScriptHandler(
          handlerName: 'onMangaBoxSelected',
          callback: (List<dynamic> args) {
            if (args.isEmpty || args[0] is! String) return;
            unawaited(_onMangaBoxSelected(args[0] as String));
          },
        );
        controller.addJavaScriptHandler(
          handlerName: 'onMangaZoomChanged',
          callback: (List<dynamic> args) {
            if (args.isEmpty) return;
            final int? value = switch (args[0]) {
              final num number => number.round(),
              final String text => int.tryParse(text),
              _ => null,
            };
            if (value == null) return;
            final int normalized = value.clamp(50, 200);
            if (_zoomPercent == normalized) return;
            if (mounted) {
              setState(() => _zoomPercent = normalized);
            } else {
              _zoomPercent = normalized;
            }
            unawaited(appModel.setMangaZoomPercent(normalized));
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
          unawaited(_markWindowReady(controller));
        }
      },
      onLoadStop: (InAppWebViewController controller, WebUri? url) async {
        await _markWindowReady(controller);
      },
      // 非 null 本身就是救命动作：Java 侧据此 `return true`，不再连坐杀 app。
      onRenderProcessGone:
          (InAppWebViewController _, RenderProcessGoneDetail detail) =>
              unawaited(_webViewDeathGuard.handleDeath(
        didCrash: detail.didCrash,
        rendererPriorityAtExit: detail.rendererPriorityAtExit,
      )),
    );
  }

  /// 当前窗口加载完成：记录当前页位置（onLoadStop 与 Windows 的
  /// onReceivedError-as-success 分支共用）。
  Future<void> _markWindowReady(InAppWebViewController controller) async {
    if (!mounted) return;
    Object? rawGeneration;
    try {
      rawGeneration = await controller.evaluateJavascript(
        source: 'window.__mangaDocumentGeneration',
      );
    } catch (_) {
      return;
    }
    // 入口闸门（BUG-1153）：这份文档必须自证就是当前 generation。
    if (!MangaWindowGeneration.isCurrent(
        rawGeneration, _windowGate.generation)) {
      return;
    }
    // 但入口比一次远远不够（BUG-1170）：下面三个 await 期间窗口可能被换掉
    // （10s 超时放弃旧窗口 → 新一轮 begin() 递增 generation 并换新锁），迟到的旧
    // 回调会解开**新**窗口的锁，导航锁被错误解除，WebView 还在加载旧内容就被判定
    // 就绪。所以这里取本次加载的凭据，每个 await 之后再复问一次归属。
    final MangaWindowLoadTicket? ticket =
        _windowGate.ticketFor(MangaWindowGeneration.parse(rawGeneration));
    if (ticket == null) {
      return;
    }
    await controller.evaluateJavascript(
      source: MangaHibikiPage.navigationKeyBridgeScript,
    );
    if (!mounted || !_windowGate.owns(ticket)) {
      return;
    }
    if (_mode == MangaReadingMode.webtoon) {
      await controller.evaluateJavascript(
        source: 'window.__mangaScrollToSpread && '
            'window.__mangaScrollToSpread($_currentSpread, $_currentFraction);',
      );
    } else {
      await controller.evaluateJavascript(
        source: 'window.__mangaApplyTranslate && '
            'window.__mangaApplyTranslate($_currentSpread);',
      );
    }
    if (!mounted || !_windowGate.owns(ticket)) {
      return;
    }
    _windowGate.complete(ticket, MangaWindowLoadOutcome.ready);
    _recordProgress();
    // 正文就绪的确定性落焦：整页 autofocus 会抢在 WebView 内容就绪之前，焦点落在
    // 表面层；换窗（翻到下一个加载窗口）同样会重挂平台视图。这里在每个就绪落点
    // 补一次，让首开/换窗后第一次按方向键就作用在漫画上。
    _focusOwnership.reclaim(FocusReclaimCause.contentReady);
  }
}
