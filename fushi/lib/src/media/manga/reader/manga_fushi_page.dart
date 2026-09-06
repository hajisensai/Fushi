import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:drift/drift.dart' show Value;
import 'package:flutter/foundation.dart' show immutable, kDebugMode;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:path/path.dart' as p;
import 'package:window_manager/window_manager.dart';

import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/media/manga/manga_json_writeback.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/media/manga/manga_module.dart';
import 'package:fushi/src/media/manga/manga_ocr_background_job.dart';
import 'package:fushi/src/ocr/manga_ocr_folder_job.dart'
    show kMangaOcrOutDirName;
import 'package:fushi/src/ocr/manga_ocr_service.dart';
import 'package:fushi/src/ocr/system_ocr_channel.dart'
    show SystemOcrUnavailableException;
import 'package:fushi/src/media/manga/manga_overlay_html.dart';
import 'package:fushi/src/media/manga/manga_reading_mode.dart';
import 'package:fushi/src/media/manga/manga_reading_stats.dart';
import 'package:fushi/src/media/manga/manga_view_prefs.dart';
import 'package:fushi/src/media/manga/manga_spread_model.dart';
import 'package:fushi/src/media/manga/mihon/manga_page_provider.dart';
import 'package:fushi/src/media/manga/library/manga_chapter_list.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_entry.dart';
import 'package:fushi/src/media/manga/library/online_manga_library_service.dart';
import 'package:fushi/src/media/manga/library/online_manga_runtime_adapter.dart';
import 'package:fushi/src/media/manga/mihon/mihon_online_ocr.dart';
import 'package:fushi/src/media/manga/mihon/mihon_reader_chapter.dart';
import 'package:fushi/src/media/manga/mokuro_payload.dart';
import 'package:fushi/src/media/manga/ocr/google_lens_protocol.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_auto_start.dart';
import 'package:fushi/src/media/manga/ocr/manga_ocr_cache_recovery.dart';
import 'package:fushi/src/media/manga/ocr/manga_region_rescan.dart';
import 'package:fushi/src/media/manga/reader/manga_volume_key_paging_controller.dart';
import 'package:fushi/src/media/manga/reader/manga_zoom_preference_debouncer.dart';
import 'package:fushi/src/focus/page_focus_ownership.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart'
    show contextMenuButtonNumberMatches;
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent;
import 'package:fushi/src/shortcuts/global_navigation.dart'
    show
        desktopWindowFullscreenSupported,
        readDesktopWindowFullscreen,
        setDesktopWindowFullscreen;
import 'package:fushi/src/shortcuts/window_fullscreen_hosts.dart'
    show WindowFullscreenHost;
import 'package:fushi/src/shortcuts/input_binding.dart'
    show
        GamepadButton,
        InputBinding,
        ModifierKey,
        MouseBinding,
        activeModifierKeys,
        domMouseButtonFromPointerButtons;
import 'package:fushi/src/shortcuts/mouse_binding_dispatch.dart'
    show dispatchClaimedMouseAction, resolveMouseBindingActionForButton;
import 'package:fushi/src/shortcuts/manga_arrow_override.dart';
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/shortcuts/shortcut_registry.dart';
import 'package:fushi/src/focus/webview_key_bridge.dart';
import 'package:fushi/src/media/manga/reader/manga_window_load_gate.dart';
import 'package:fushi/src/pages/base_source_page.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart';
import 'package:fushi/src/reader/reader_selection_data.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/startup/exit_flush_registry.dart';
import 'package:fushi/src/stats/read_unit_ledger.dart';
import 'package:fushi/src/webview/webview_death_guard.dart';
import 'package:fushi/utils.dart';

/// Manga reader implementation owned by the standalone manga module.
///
/// Public navigation exports this page through `pages.dart`; generic reader
/// code does not own manga rendering, interaction, or OCR overlay behavior.
/// 选区 payload → 弹窗锚点视口矩形。
///
/// 漫画 WebView 以 scale 1.0、零 inset 渲染（[FushiAppUiScaleNeutralizer] 中和层），
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

enum MangaReaderInputAction {
  previous,
  next,
  dismissDictionary,

  /// 「返回上一级」在本页没有更内层可退时的落点：退出漫画（走 maybePop，页面自己的
  /// [PopScope] 闸门照跑）。与 [dismissDictionary] 是同一个键（默认 Esc）的两级——
  /// 弹窗可见先关弹窗，没弹窗才退出，判据在 [MangaFushiPage.inputActionForShortcut]。
  backOrExit,

  /// 键盘平移（默认 Ctrl+方向键）：在放大后的页面上把**视野**朝该方向挪一步。
  ///
  /// 与 [previous]/[next] 是不同语义——翻页换的是 spread，平移只动当前页的视野，
  /// 所以不吃「webtoon 让位原生滚动」「弹窗可见让位」那两道翻页门控（见
  /// [MangaFushiPage.inputActionForShortcut]）：webtoon 的上下平移本来就等于滚文档。
  panUp,
  panDown,
  panLeft,
  panRight,

  /// BUG-1888：切换界面（顶栏页码/工具按钮 + 左上返回键）。漫画此前**没有任何**
  /// 隐藏界面的方式，这两块恒挂在画面上遮住页图；移动端还联动系统栏沉浸，隐藏
  /// 界面即真全屏。
  toggleChrome,

  /// Toggle the desktop window's fullscreen presentation without rebuilding
  /// the manga WebView or losing its current OCR/selection state.
  toggleFullscreen,
}

/// 一次键盘平移移动的视口比例。按比例而非像素，1080p 与 4K 手感一致。
const double kMangaPanStepFraction = 0.15;

enum _MangaReaderInputSource {
  flutter,
  nativeWebView,
  volumeKey,
  gamepad,
  mouse,
}

/// 漫画页 **Flutter 侧**鼠标通道的解析阶梯：只有 manga 自己的 scope。
///
/// `universal`（返回上一级）/ `global`（全屏、整页滚动）由 app 根的
/// `_handleGlobalPointerDown` 统一兜底并执行——与键盘「页面没接就冒泡到最外层」同构。
/// 页面再解析一遍就会与根兜底对同一次按下各派发一次（一键退两级）。
/// BUG-2031 修正：Flutter 腿与 JS 腿**共用这一条**，且与键盘那条
/// `_resolveMangaKeyAction` 逐段一致。第一版 Flutter 侧只放 `manga`，于是
/// `globalBack` 在页内解析不到 —— 而 [MangaFushiPage.inputActionForShortcut] 早就
/// 把它映成逐级的 [MangaReaderInputAction.backOrExit]（弹窗可见先关弹窗，没弹窗才
/// 退出漫画）。够不着它的结果是侧键退出直接落到 app 根的平 `maybePop()`，比键盘
/// Esc 少了一级。防双派发靠 [MouseBindingDispatch] 认领，不靠把阶梯修窄。
const List<ShortcutScope> _kMangaMouseLadder = <ShortcutScope>[
  ShortcutScope.manga,
  ShortcutScope.universal,
  ShortcutScope.global,
];

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
    _pendingDelta = (_pendingDelta + delta)
        .clamp(-maxMagnitude, maxMagnitude)
        .toInt();
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
  )
  search,
}) async {
  if (data.text.isEmpty) {
    return;
  }
  await selectPageForMining(data.mangaPageIndex);
  setSentence(data.sentence);
  final Rect rect = mangaSelectionRectFromPayload(
    data,
    fallbackScreen: fallbackScreen,
  );
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

enum _MangaContextAction { previous, next, jump, direction, zoomIn, zoomOut }

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
        onFieldSubmitted: (String value) =>
            Navigator.pop(dialogContext, int.tryParse(value)),
        onChanged: (String value) => input = value,
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: Text(t.dialog_cancel),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(dialogContext, int.tryParse(input)),
          child: Text(t.dialog_ok),
        ),
      ],
    ),
  );
}

/// 漫画阅读器页面（漫画 OCR P1：L5 媒体源路由 / L6 渲染 / L7 查词+制卡）。
///
/// 与 EPUB 的 [ReaderFushiPage]、PDF 的 [ReaderPdfPage] 平行的「第三种书」：mokuro
/// 页图 + 透明 OCR 覆盖层在 WebView 里渲染（文档由 [mangaWindowDocument] 生成），
/// 汇入同一批共享设施：[BaseSourcePageState.searchDictionaryResult]（查词弹窗）、
/// [ReaderPositionRepository]（阅读位置，sectionIndex=0-based 页码）、
/// [StudyClock]（时长 / OCR 字数 / 页数统计，「读过」判据见 [ReadUnitLedger]、
/// 换算见 [mangaStatsForPages]）、[AnkiMiningContext]（制卡，
/// 卡图=当前页图文件路径）。
///
/// 身份统一 `hoshi://book/<bookKey>`（无漫画专属 scheme 特例），关书自动同步天然工作。
/// 存储契约：`p.join(row.extractDir, row.epubPath)` 指向 `manga.json`；页图在
/// `<书目录>/images/<manga.json 里 url 的相对路径>`（url 恒正斜杠，落盘按平台分隔符）。
///
/// 页面拥有专属虚拟域 [kMangaHost]（`manga.local`，与阅读器 `fushi.local` 互异，两个
/// 拦截器绝不混叠），经带路径穿越守卫的拦截器 serve 本地页图。spread 模式窗口化
/// loadData-per-window + translateX 翻页；webtoon 整本单文档竖滚（不窗口化）。
///
/// 选词接线（防串框契约 ERRATA H2/C1）：本页注册**恰好一个**
/// `onTextSelected` Dart handler；全工程唯一的 pointerup 选词监听内嵌在
/// [mangaWindowDocument]（调 `fushiSelection.selectFromPosition(node, 0, 40, x, y)`，
/// 第三参 maxLength 漏传会让扫描 gate 恒假、查词全程哑火），本页绝不再注册第二个。
class MangaFushiPage extends BaseSourcePage {
  const MangaFushiPage({
    super.key,
    required super.item,
    required this.bookKey,
    this.onlineChapter,
  });

  /// `EpubBooks` 主键（净化后的标题），由 `hoshi://book/<bookKey>` 解析而来。
  final String bookKey;

  /// A directly selected online chapter. Shelf launches leave this null and
  /// restore the Mihon chapter from the restart descriptor in `sourceMetadata`.
  final OnlineMangaReaderChapter? onlineChapter;

  /// 漫画拦截器专属虚拟域。必须与阅读器的 `fushi.local` 互异。
  static const String kMangaHost = 'manga.local';

  /// WKWebView 不支持用 `shouldInterceptRequest` 接管 http(s) 子资源；Apple
  /// 平台必须通过 WKURLSchemeHandler 注册一个非标准 scheme。
  static const String kMangaResourceScheme = 'fushi-manga';

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
  /// [crossPageStep] = 触发键是否为**跨页步进**语义（左/右方向键、D-pad 左右与
  /// 手柄翻页键 RB/LB），两道门控都不适用：webtoon 的纵向滚动不影响跨页步进
  /// （手柄没有原生滚动路径，webtoon 也用锚点跳页）；词典弹窗可见时也要「关弹窗
  /// 并翻页」（本页与阅读器的关键差异）。其余前进/后退键则要让位——弹窗可见时空格
  /// 归词典自己，webtoon 模式下纵向键归 WebView 原生滚动。
  static MangaReaderInputAction? inputActionForShortcut({
    required ShortcutAction? action,
    required bool crossPageStep,
    required bool dictionaryShown,
    required MangaReadingMode mode,
  }) {
    if (action == null) return null;
    if (action == ShortcutAction.globalToggleFullscreen) {
      return MangaReaderInputAction.toggleFullscreen;
    }
    if (action == ShortcutAction.mangaDismissDict) {
      return dictionaryShown ? MangaReaderInputAction.dismissDictionary : null;
    }
    // 「返回上一级」（universal，默认 Esc / 手柄 B）的两级阶梯：弹窗可见先关弹窗，
    // 没弹窗才退出漫画。此前本页**根本没有退出动作**——Esc 只绑 mangaDismissDict，
    // 无弹窗时解析成 null 就地丢弃；而正文是原生 WebView，键经 JS 桥
    // （`stopPropagation: true`）转进 Dart，丢弃后也不会再冒泡到全局 Esc 兜底，
    // 于是漫画里按 Esc 是**死键**、退不出去。这一支就是那个 bug 的根因修复。
    if (action == ShortcutAction.globalBack) {
      return dictionaryShown
          ? MangaReaderInputAction.dismissDictionary
          : MangaReaderInputAction.backOrExit;
    }
    // BUG-1888：切换界面。与平移同理排在两道翻页门控**之前**——它既不翻页也不动
    // 视野，「webtoon 让位原生滚动」与「弹窗可见让位」对它都不适用：正在查词时
    // 想把顶栏收掉看清页图，是完全合理的操作。
    if (action == ShortcutAction.mangaToggleChrome) {
      return MangaReaderInputAction.toggleChrome;
    }
    // 平移排在两道翻页门控**之前**：它动的是当前页的视野、不是 spread，所以
    // 「webtoon 让位原生滚动」与「弹窗可见让位」都不适用——webtoon 的上下平移本身
    // 就是滚文档，弹窗开着时也该能挪画面去看被挡住的部分。
    final MangaReaderInputAction? pan = switch (action) {
      ShortcutAction.mangaPanUp => MangaReaderInputAction.panUp,
      ShortcutAction.mangaPanDown => MangaReaderInputAction.panDown,
      ShortcutAction.mangaPanLeft => MangaReaderInputAction.panLeft,
      ShortcutAction.mangaPanRight => MangaReaderInputAction.panRight,
      _ => null,
    };
    if (pan != null) return pan;
    if (!crossPageStep) {
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
    final double dominant = delta.dy.abs() >= delta.dx.abs()
        ? delta.dy
        : delta.dx;
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
    keys: const <String>['ArrowLeft', 'ArrowRight', 'Escape', 'Esc', 'F11'],
    forwardRepeats: false,
    stopPropagation: true,
  );

  /// 键盘平移专用的第二座桥。
  ///
  /// 单独一座而不是往 [navigationKeyBridgeScript] 的键表里加：翻页那座是
  /// `forwardRepeats: false`（本页有意「按住方向键不堆翻页风暴」），而平移恰恰要连发
  /// ——按住 Ctrl+↓ 应该持续挪画面。生成器按 handlerName 派生独立闭包与安装守卫，
  /// 同一 document 里多座桥共存互不干扰（见 webViewKeyBridgeScript 文档）。
  ///
  /// 键表是**默认键位**的 token。回传后仍走 [_handleNativeNavigationKey] →
  /// 注册表解析，所以改键在 Flutter 持焦路径立即生效；但 WebView2 持焦时只有列在
  /// 这张表里的键会被截获——这是翻页桥既有的同款限制（它的表同样是硬编码的
  /// ArrowLeft/ArrowRight），不是本次新引入的，要根治得让两座桥的 token 表都从
  /// 注册表实时生成，单独立项。
  @visibleForTesting
  static final String panKeyBridgeScript = webViewKeyBridgeScript(
    handlerName: 'onMangaPanKey',
    keys: const <String>[
      'Ctrl+ArrowUp',
      'Ctrl+ArrowDown',
      'Ctrl+ArrowLeft',
      'Ctrl+ArrowRight',
    ],
    forwardRepeats: true,
    stopPropagation: true,
  );

  /// 第三座桥：**鼠标按钮**。
  ///
  /// 与前两座（键盘）分开的两个理由，都不是风格问题：
  ///   · 按钮表必须**按当前绑定实时生成**——桥只回传列在表里的按钮号，硬编码就等于
  ///     「改了绑定，WebView 持有指针时还按老按钮响应」；
  ///   · 复用键盘那两座的 handlerName 会连带把它们的**键表覆盖成空**（脚本每次注入
  ///     都重写 `window[keysVar]`），翻页键当场失效。
  ///
  /// 只在**指针归 WebView** 的平台安装（[hostOwnsWebViewPointerInput] 为 false）。
  /// Windows 上指针先到 Flutter，页面根 [Listener] 已经接住，再装一份 JS 监听会让
  /// 中键/右键各触发两次（翻页会翻两页）。
  @visibleForTesting
  static String mouseBridgeScript(List<int> buttons) => webViewKeyBridgeScript(
    handlerName: 'onMangaMouseButton',
    mouseButtons: buttons,
    installMouseListeners: true,
    stopPropagation: true,
  );

  /// 本页鼠标桥要拦截的按钮号：manga / universal / global 三段阶梯上**所有**已绑
  /// 按钮的并集（与 [_kMangaMouseLadder] 同源）。
  ///
  /// 取并集而不是只取 manga：桥不做解析，它只决定「哪些按钮值得回传」，解析仍由
  /// Dart 侧的 [_handleNativeNavigationKey] 按完整阶梯做。漏一个按钮号，那个绑定在
  /// WebView 持有指针时就是死的。
  @visibleForTesting
  static List<int> mouseBridgeButtons(FushiShortcutRegistry registry) {
    final List<int> buttons = <int>[];
    for (final ShortcutScope scope in _kMangaMouseLadder) {
      for (final ShortcutAction action in ShortcutAction.actionsForScope(
        scope,
      )) {
        for (final MouseBinding binding
            in registry.bindingsFor(action).mouseBindings) {
          if (!buttons.contains(binding.button)) buttons.add(binding.button);
        }
      }
    }
    return buttons;
  }

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
  static String mangaImageUrl(
    String relativeUrl, {
    bool useCustomScheme = false,
  }) {
    final String normalized = mangaImageRelativePath(relativeUrl);
    final String encoded = normalized
        .split('/')
        .map(Uri.encodeComponent)
        .join('/');
    final String scheme = useCustomScheme ? kMangaResourceScheme : 'https';
    return '$scheme://$kMangaHost/img/$encoded';
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
    List<MangaSpreadEntry> spreads,
    int spreadIndex,
  ) {
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
    List<MangaSpreadEntry> spreads,
    int lastPage,
  ) {
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
  BaseSourcePageState<MangaFushiPage> createState() => _MangaFushiPageState();
}

class _MangaFushiPageState extends BaseSourcePageState<MangaFushiPage>
    with WidgetsBindingObserver, WindowListener {
  InAppWebViewController? _controller;
  EpubBookRow? _bookRow;

  // ── 书架在线条目的「章」上下文 ──────────────────────────────────────
  //
  // 只在从书架打开一条在线漫画时非空（`widget.onlineChapter` 直给的预览路径没有
  // 书架身份，也就没有上一章/下一章可言）。三个字段一起构成「我现在读的是这本
  // 书的第几章」，是换章、每章进度落库和读完标记的唯一依据。
  OnlineMangaLibraryService? _shelfLibraryService;
  OnlineMangaLibraryEntry? _shelfEntry;
  int _shelfChapterIndex = -1;

  /// 正在换章：挡住换章期间的翻页与重复触发。
  bool _switchingChapter = false;

  /// 「已经是最新/第一章了」这一章内是否已经提示过。开新章时归零。
  bool _edgeToastShown = false;

  /// 当前章在书架体系里的身份；非书架在线条目为 null。
  String? get _shelfChapterKey {
    final OnlineMangaLibraryEntry? entry = _shelfEntry;
    if (entry == null ||
        _shelfChapterIndex < 0 ||
        _shelfChapterIndex >= entry.chapters.length) {
      return null;
    }
    return entry.chapters[_shelfChapterIndex].key;
  }

  /// P4 写侧收敛：查词 / 制卡计数归属本书（此前漫画漏覆写，全落 '' 汇总桶）。
  /// 口径照抄 EPUB 阅读器（reader_fushi_page 的同名覆写）：[bookKey] 存书身份
  /// （在线阅读的兜底行同样以 widget.bookKey 为身份键），title 恒 raw
  /// （`_bookRow?.title`，统计聚合键不过 display-title 门面）。
  @override
  ({String? bookKey, String? title})? get lookupBookIdentity =>
      (bookKey: widget.bookKey, title: _bookRow?.title);

  /// v82：阅读位置子表键（= **持久化**书行的 `uid`）。与 [_bookRow] 分开存：
  /// 在线阅读无持久行时 [_bookRow] 是现造 uid 的内存兜底行（v81，仅供 UI 元数据），
  /// 那个随机 uid 不在库里、绝不能拿去写 reader_positions（每次会话都变，写了就是
  /// 永远 JOIN 不上的孤儿行）。null = 无持久行/旧行空 uid → 位置读写跳过。
  String? _bookUid;

  /// `<书目录>/images`（页图根，拦截器/封面解析的穿越守卫边界）。
  String? _imagesDir;
  MangaReaderSession? _pageSession;
  Map<String, int> _localPageIndices = const <String, int>{};
  OnlineMangaReaderChapter? _onlineChapter;
  bool _persistProgress = true;
  MokuroPayload? _payload;
  MangaReadingMode _mode = MangaReadingMode.spread;
  List<MangaSpreadEntry> _spreads = <MangaSpreadEntry>[];
  bool _loadFailed = false;

  /// BUG-1888：界面（顶栏 + 左上返回键）是否可见。隐藏态下右上角仍留一个半透明
  /// 「显示界面」按钮——漫画正文是原生 WebView，空白点击手势全在注入的 JS 里且
  /// 已被翻页占用，没有这个按钮的话触屏设备再没有第二条通道能把界面唤回来。
  bool _chromeVisible = true;

  bool _isWindowFullscreen = false;
  bool _ownsWindowFullscreen = false;
  bool _fullscreenTransitioning = false;

  /// 双页布局偏好：页内菜单运行时切换，不持久化，默认自动（横屏双页/竖屏单页）。
  MangaSpreadPreference _spreadPreference = MangaSpreadPreference.auto;
  String _spreadDirection = 'rtl';
  int _zoomPercent = 100;

  /// 观看偏好快照（打开书时从 [AppModel] 读一次，随文档注入 WebView）。
  /// 与 [_zoomPercent] 不同，这三项没有页内切换入口，只在设置里改。
  int _zoomSensitivity = kMangaZoomSensitivityDefault;
  MangaPageAnimation _pageAnimation = MangaPageAnimation.slide;
  bool _tapZonePaging = true;

  /// 最近一次实际生效的布局（由 [_buildSpreadsFor] 记账），didChangeMetrics
  /// 只在解析结果真变时才重建 spread 序列，避免键盘弹出等无关 metrics 抖动。
  MangaPageLayout _pageLayout = MangaPageLayout.single;

  int _currentSpread = 0;
  int _currentPage = 0;
  double _currentFraction = 0;
  Timer? _progressDebounce;
  Timer? _onlineGeometryPersistDebounce;
  MangaZoomPreferenceDebouncer? _zoomPreferenceDebouncer;
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

  /// 框选区域重识别：模式激活位。JS 侧同名门控由 `__mangaSetRescanMode` 同步。
  bool _rescanModeActive = false;

  /// 框选区域重识别：单飞闸门（一次只跑一个框；两个框同时写同一页会互相覆盖）。
  bool _rescanBusy = false;

  /// 「点击即识别」：本页文字层落地后要回放的那一次点击（视口坐标）。
  ///
  /// 存的是**视口**坐标而不是页内像素：回放要交回 JS 的 `_selectOcrChar`，它吃的
  /// 就是视口坐标。中途翻页/缩放会让这个点失效——那没关系，回放找不到字就静默，
  /// 反正用户注意力早就不在那儿了。
  _MangaTapLookup? _pendingTapLookup;

  /// 「点击即识别」的起任务闸门（弹说明、探测引擎期间挡住连点）。
  bool _tapOcrStarting = false;

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

  /// v92：本页唯一的阅读时钟兼累计器（时长 / OCR 字数 / 页数同一段同一 uid），同
  /// EPUB / PDF 侧。页面不再持有任何会话时长 / 字数 / 页数字段。（守卫
  /// manga_stats_dwell_guard_test 钉死旧的会话累计器 / 停留门形态不得回潮。）
  StudyClock? _studyClock;

  /// 「读过」判据的唯一账本（2026-09-06 裁定，三域共用，见
  /// `docs/plans/2026-09-06-read-unit-ledger.md`）：**翻走即计 + 会话覆盖并集**。
  /// 单元 = 页号半开区间——webtoon `[page, page+1)`、spread 模式按当前 entry 覆盖的
  /// 页（单页 `[p, p+1)`、双页 `[p, p+2)`）。离开单元那一刻把其中本会话未覆盖的页
  /// 交给 [_creditPages]；没有停留门（BUG-1761 的 1.5s 到达停留裁定已推翻）、
  /// 没有存档预置（重开这卷续读，存档页是当前单元，翻走时计一次）。
  late final ReadUnitLedger _readLedger = ReadUnitLedger(
    onCredit: _creditPages,
    onRetract: _retractPages,
  );

  /// 位置落定：喂空闲门（翻页 / 页内滚动 = 用户输入）并把当前可见页交给账本。
  /// 与当前单元相同的重复落定（webtoon 页内滚动）在账本里是 no-op。
  void _noteVisiblePages() {
    _studyClock?.touch();
    final (int start, int end) = _visiblePageRange();
    _readLedger.arrive(start, end);
  }

  /// 当前可见页的页号半开区间：spread 模式取当前 entry 的页（升序、连续），
  /// webtoon 只有真正成为「当前页」的那页。
  (int, int) _visiblePageRange() {
    final bool isWebtoon = _mode == MangaReadingMode.webtoon;
    if (!isWebtoon && _currentSpread >= 0 && _currentSpread < _spreads.length) {
      final List<int> pages = _spreads[_currentSpread].pageIndices;
      return (pages.first, pages.last + 1);
    }
    return (_currentPage, _currentPage + 1);
  }

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
      // 漫画不能让——[MangaFushiPage.keyInputAction] 规定弹窗可见时左右键仍要
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
    _volumeKeyPagingController = MangaVolumeKeyPagingController(
      onPrevious: () => _executeReaderInputAction(
        MangaReaderInputAction.previous,
        source: _MangaReaderInputSource.volumeKey,
      ),
      onNext: () => _executeReaderInputAction(
        MangaReaderInputAction.next,
        source: _MangaReaderInputSource.volumeKey,
      ),
    );
    WidgetsBinding.instance.addObserver(this);
    if (Platform.isWindows || Platform.isLinux) {
      windowManager.addListener(this);
    }
    if (desktopWindowFullscreenSupported) {
      unawaited(_readInitialFullscreenState());
    }
    // 进程退出兜底：把未落盘的页码 flush 掉（与 EPUB/PDF 阅读器同纪律）。
    ExitFlushRegistry.instance.register(_flushPosition);
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadBook());
    // TODO-2936：应用「漫画」媒体类型 / 本书 book 级的 Profile 绑定（与 EPUB/
    // 视频阅读器同范式：非致命、与开书链并行；漫画的 bookKey 就是 Profile 的
    // book 级 entryKey，见 book_format_convert.dart 的身份说明）。
    unawaited(
      ref
          .read(profileViewModelProvider.notifier)
          .autoApplyBinding(
            bookUid: widget.bookKey,
            mediaType: ProfileMediaKind.manga,
          ),
    );
  }

  @override
  void dispose() {
    if (Platform.isWindows || Platform.isLinux) {
      windowManager.removeListener(this);
    }
    if (_ownsWindowFullscreen) {
      _ownsWindowFullscreen = false;
      unawaited(_restoreOwnedFullscreenAfterDispose());
    }
    // 交还音量键所有权：必须早于其它拆栈，且无条件执行。
    _volumeKeyPagingController.dispose();
    ExitFlushRegistry.instance.unregister(_flushPosition);
    WidgetsBinding.instance.removeObserver(this);
    // 加载中的窗口必须以明确状态收尾：否则 _loadInitialWindow 会挂满 10s 超时，
    // 再从 unawaited 调用点抛出未捕获异步异常（BUG-1171）。
    _windowGate.abandon();
    _progressDebounce?.cancel();
    _onlineGeometryPersistDebounce?.cancel();
    final MangaZoomPreferenceDebouncer? zoomDebouncer =
        _zoomPreferenceDebouncer;
    _zoomPreferenceDebouncer = null;
    if (zoomDebouncer != null) unawaited(zoomDebouncer.dispose());
    _dictionaryTurnDismissTimer?.cancel();
    unawaited(_wholeVolumeOcrSubscription?.cancel());
    _wholeVolumeOcrSubscription = null;
    final MangaReaderSession? pageSession = _pageSession;
    _pageSession = null;
    if (pageSession != null) {
      unawaited(_closePageSession(pageSession));
    }
    // 离开当前页：账本结算最后一个单元（翻走即计），必须早于 flush / 时钟 dispose。
    _readLedger.leave();
    // dispose 里只能 fire-and-forget；正常退出走 onSourcePagePop 的 await 路径，
    // 这里是崩溃/异常拆栈时的兜底。
    unawaited(_flushPosition());
    _studyClock?.dispose();
    _pageNotifier.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _readInitialFullscreenState() async {
    final bool? fullscreen = await readDesktopWindowFullscreen();
    if (!mounted || fullscreen == null || fullscreen == _isWindowFullscreen) {
      return;
    }
    setState(() => _isWindowFullscreen = fullscreen);
  }

  Future<void> _changeMangaFullscreen({bool? requested}) async {
    if (!desktopWindowFullscreenSupported || _fullscreenTransitioning) return;
    _fullscreenTransitioning = true;
    try {
      final bool fullscreen =
          requested ??
          !((await readDesktopWindowFullscreen()) ?? _isWindowFullscreen);
      if (!mounted) return;
      // Claim ownership before the native transition starts. If the route is
      // removed while the platform call is in flight, dispose can still issue
      // the matching exit instead of leaking a borderless fullscreen window.
      if (fullscreen) {
        _ownsWindowFullscreen = true;
      }
      final bool? applied = await setDesktopWindowFullscreen(fullscreen);
      if (!mounted) {
        if (fullscreen && _ownsWindowFullscreen) {
          _ownsWindowFullscreen = false;
          await _restoreOwnedFullscreenAfterDispose();
        }
        return;
      }
      if (applied == null) {
        if (fullscreen) _ownsWindowFullscreen = false;
        return;
      }
      _ownsWindowFullscreen = applied;
      if (_isWindowFullscreen != applied) {
        setState(() => _isWindowFullscreen = applied);
      }
    } finally {
      _fullscreenTransitioning = false;
    }
  }

  Future<void> _setMangaFullscreen(bool fullscreen) =>
      _changeMangaFullscreen(requested: fullscreen);

  Future<void> _toggleMangaFullscreen() => _changeMangaFullscreen();

  /// 「返回上一级」在漫画页的一级：全屏中先退全屏，返回 true 吞掉这次返回。
  ///
  /// 判据不再只认 [_ownsWindowFullscreen]（「这次全屏是我进的」）：用户用快捷键
  /// （默认 F11）进的全屏不会置那个标志，可他眼里那和按全屏按钮进的是同一个全屏，
  /// Esc 都该先把它退掉，而不是连人带全屏一起退出漫画。所有权标志仍然保留——它管的是
  /// 另一件事（页面在 native 往返途中被拆掉时由谁负责把全屏还回去）。
  ///
  /// 非全屏时只多读一次窗口状态，随后照常退页。
  Future<bool> _exitOwnedFullscreenBeforePop() async {
    if (!_ownsWindowFullscreen &&
        (await readDesktopWindowFullscreen()) != true) {
      return false;
    }
    if (!mounted) return false;
    await _setMangaFullscreen(false);
    return true;
  }

  Future<void> _restoreOwnedFullscreenAfterDispose() async {
    await setDesktopWindowFullscreen(false);
  }

  @override
  void onWindowEnterFullScreen() {
    if (!mounted || _isWindowFullscreen) return;
    setState(() => _isWindowFullscreen = true);
  }

  @override
  void onWindowLeaveFullScreen() {
    _ownsWindowFullscreen = false;
    if (!mounted || !_isWindowFullscreen) return;
    setState(() => _isWindowFullscreen = false);
  }

  Future<void> _closePageSession(MangaReaderSession session) async {
    await session.close();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      // 切屏 / 进后台自动暂停阅读计时（BUG-892）：stop 先结算部分窗口再封段落库。
      unawaited(_studyClock?.stop());
      unawaited(_flushPosition());
    } else if (state == AppLifecycleState.resumed) {
      // BUG-892 同款纪律：start() 只重锚 tick 起点并开新段，后台时长不会被计入。
      _studyClock?.start();
      // OS 层焦点丢失后 Flutter 不保证归还到原节点：切窗回来若不收回，翻页键全死。
      _focusOwnership.reclaim(FocusReclaimCause.appResumed);
    }
  }

  @override
  Future<void> onSourcePagePop() async {
    if (_ownsWindowFullscreen) {
      await _setMangaFullscreen(false);
    }
    // 离开当前页：账本结算最后一个单元（翻走即计），再落盘。
    _readLedger.leave();
    // 返回书架的正常路径：await 落盘，保证书架 recency/进度立刻正确。
    await _flushPosition();
    await _studyClock?.stop();
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
    final int currentPage = MangaFushiPage.firstPageOfSpread(
      _spreads,
      _currentSpread,
    );
    final List<MangaSpreadEntry> spreads = _buildSpreadsFor(payload, _mode);
    // 同一页换单元边界（单页↔双页）不是翻页：下一次 arrive 只替换边界、不结算。
    _readLedger.rebaseOnNextArrive();
    setState(() {
      _spreads = spreads;
      _currentSpread = MangaFushiPage.spreadIndexForPage(spreads, currentPage);
      _currentPage = MangaFushiPage.firstPageOfSpread(spreads, _currentSpread);
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
    final FushiDatabase db = appModel.database;
    final OnlineMangaReaderChapter? directOnlineChapter = widget.onlineChapter;
    if (directOnlineChapter != null) {
      final EpubBookRow? persisted = directOnlineChapter.persistProgress
          ? await db.getEpubBook(widget.bookKey)
          : null;
      await _loadOnlineChapter(directOnlineChapter, persistedRow: persisted);
      return;
    }
    final EpubBookRow? row = await db.getEpubBook(widget.bookKey);
    if (!mounted) return;
    if (row == null) {
      setState(() => _loadFailed = true);
      return;
    }
    final OnlineMangaLibraryEntry? onlineEntry =
        OnlineMangaLibraryEntry.tryParse(row.sourceMetadata);
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
    final MokuroPayload payload = await MangaFushiPage.parseMangaJsonOffUi(
      jsonStr,
    );
    if (!mounted) return;

    _spreadPreference = MangaSpreadPreferenceKey.fromKey(
      appModel.mangaSpreadPreference,
    );
    _spreadDirection = appModel.mangaReadingDirection == 'ltr' ? 'ltr' : 'rtl';
    _zoomPercent = appModel.mangaZoomPercent.clamp(
      kMangaZoomMinPercent,
      kMangaZoomMaxPercent,
    );
    _zoomSensitivity = appModel.mangaZoomSensitivity.clamp(
      kMangaZoomSensitivityMin,
      kMangaZoomSensitivityMax,
    );
    _pageAnimation = MangaPageAnimationKey.fromKey(appModel.mangaPageAnimation);
    _tapZonePaging = appModel.mangaTapZonePaging;
    _applyVolumeKeyPaging(appModel.mangaVolumeKeyPaging);

    // 阅读模式：用户覆盖优先，null 走自动判定（页图长宽比中位数）。
    final MangaReadingMode mode =
        MangaFushiPage.modeOverrideFromDb(row.mangaReadingMode) ??
        detectReadingMode(payload);
    final List<MangaSpreadEntry> spreads = _buildSpreadsFor(payload, mode);
    final List<String> relativePagePaths = payload.images
        .map(
          (MokuroImage image) =>
              MangaFushiPage.mangaImageRelativePath(image.url),
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
    // （千分比 0..1000）换算回来。v82：键 = 书行 uid（行在手直接取）。
    _bookUid = row.uid.isEmpty ? null : row.uid;
    int restoredPage = 0;
    double restoredFraction = 0;
    ReaderPosition? saved;
    try {
      if (_bookUid != null) {
        saved = await ReaderPositionRepository(db).findByBookUid(_bookUid!);
      }
    } catch (e, stack) {
      ErrorLogService.instance.log('MangaFushiPage.restore', e, stack);
    }
    if (!mounted) return;
    if (saved != null &&
        saved.sectionIndex >= 0 &&
        saved.sectionIndex < payload.images.length) {
      restoredPage = saved.sectionIndex;
      if (mode == MangaReadingMode.webtoon) {
        restoredFraction = MangaFushiPage.charOffsetToWebtoonFraction(
          saved.charOffset,
        );
      }
    }

    _ensureStudyClock(db);

    final int restoredSpread = MangaFushiPage.restoreSpreadFromProgress(
      spreads,
      restoredPage,
    );
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
      _currentPage = MangaFushiPage.firstPageOfSpread(spreads, restoredSpread);
      _currentFraction = restoredFraction;
      _lastSavedPage = saved != null ? restoredPage : -1;
      _lastSavedFraction = saved != null ? restoredFraction : -1;
    });
    _pageNotifier.value = _currentPage;
    // 首屏页成为当前单元：开书直接停在恢复位置时不会再有 _recordProgress，
    // 翻走时才入账（存档页不预置，续读也计一次）。
    _noteVisiblePages();
    // A cancelled/background task intentionally does not replace manga.json,
    // but every atomic page cache is already safe to use. Restore those pages
    // after the first paint so opening a large book stays fast and both local
    // ONNX and Lens results remain queryable across reader restarts.
    unawaited(_recoverIncrementalOcrCache(row.extractDir, payload));
  }

  Future<void> _loadOnlineBookFromShelf(
    EpubBookRow row,
    OnlineMangaLibraryEntry entry,
  ) async {
    try {
      final OnlineMangaLibraryService service = appModel
          .onlineMangaLibraryService(entry.runtime);
      int chapterIndex = OnlineMangaLibraryService.initialChapterIndex(entry);
      if (chapterIndex < 0) {
        throw const OnlineMangaUnavailable(
          OnlineMangaUnavailableReason.runtimeFailure,
          'The manga has no chapters',
        );
      }
      if (entry.currentChapterIndex == null) {
        entry = await service.selectChapter(
          bookKey: row.bookKey,
          entry: entry,
          chapterIndex: chapterIndex,
        );
        chapterIndex = entry.currentChapterIndex!;
      }
      await _openShelfChapter(
        row: row,
        service: service,
        entry: entry,
        chapterIndex: chapterIndex,
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaFushiPage.loadOnlineShelf',
        error,
        stack,
      );
      if (mounted) {
        setState(() {
          _bookRow = row;
          _loadFailed = true;
        });
      }
    }
  }

  /// 打开书架条目的第 [chapterIndex] 章。
  ///
  /// 首次进入和「换章」共用这一条路径，所以换章不会走出任何首次进入没走过的
  /// 分支——章节缓存失效、OCR 重建、进度恢复全部一致。
  Future<void> _openShelfChapter({
    required EpubBookRow row,
    required OnlineMangaLibraryService service,
    required OnlineMangaLibraryEntry entry,
    required int chapterIndex,
  }) async {
    final OnlineMangaChapter chapter = entry.chapters[chapterIndex];
    // 每章进度：切回读过一半的旧章要落回原页，而不是从头开始（v88 前
    // selectChapter 会把唯一那行 reader_positions 清零，上一章位置永久丢失）。
    //
    // 书架在线章**一律显式给页码**（读到一半给 lastPage，其余给 0），不能留
    // null：`_loadOnlineChapter` 在 `initialPage == null` 时会回落到整本**唯一
    // 那行** `reader_positions`，而那一行装的是**上一章**读到哪。读完第 3 话第
    // 20 页 → 自动换到未读的第 4 话 → 第 4 话从第 20 页开始，整章整章跳过内容。
    // 每章进度的真相源是 `manga_chapter_states`；书级那行只服务单章 / 本地条目。
    int initialPage = 0;
    if (row.uid.isNotEmpty) {
      final MangaChapterStateRow? state = await appModel.database
          .getMangaChapterState(bookUid: row.uid, chapterKey: chapter.key);
      // 读完的章重新打开时从头看，而不是停在最后一页——「重读」是明确意图。
      if (state != null && state.readAt == null && state.lastPage > 0) {
        initialPage = state.lastPage;
      }
    }
    final OnlineMangaReaderChapter resolved = await service.openChapter(
      bookKey: row.bookKey,
      entry: entry,
      chapter: chapter,
      initialPage: initialPage,
    );
    _shelfLibraryService = service;
    _shelfEntry = entry;
    _shelfChapterIndex = chapterIndex;
    _edgeToastShown = false;
    await _loadOnlineChapter(resolved, persistedRow: row);
  }

  Future<void> _loadOnlineChapter(
    OnlineMangaReaderChapter input, {
    required EpubBookRow? persistedRow,
  }) async {
    final Directory directory = input.managedDirectory;
    final Directory imagesDirectory = Directory(
      p.join(directory.path, 'images'),
    );
    await imagesDirectory.create(recursive: true);
    final List<String> pageIdentities = input.pageIdentities;
    final File identityFile = File(
      p.join(directory.path, input.identityFileName),
    );
    final bool sameChapterPages = await _onlineChapterIdentityMatches(
      identityFile,
      pageIdentities,
    );
    if (!sameChapterPages) {
      await _invalidateOnlineChapterPayload(directory, imagesDirectory);
    }
    await _writeOnlineChapterIdentity(identityFile, pageIdentities);

    final List<String> relativePagePaths = <String>[
      for (int index = 0; index < input.pageCount; index++)
        'page-${(index + 1).toString().padLeft(6, '0')}.jpg',
    ];
    final File mangaJson = File(p.join(directory.path, 'manga.json'));
    MokuroPayload? payload;
    bool rewriteMangaJson = !await mangaJson.exists();
    if (await mangaJson.exists()) {
      try {
        final MokuroPayload stored = await MangaFushiPage.parseMangaJsonOffUi(
          await mangaJson.readAsString(),
        );
        if (stored.images.length == input.pageCount) {
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

    final MangaReaderSession pageSession = await input.openPageSession();
    if (!mounted) {
      await pageSession.close();
      return;
    }

    _spreadPreference = MangaSpreadPreferenceKey.fromKey(
      appModel.mangaSpreadPreference,
    );
    _spreadDirection = appModel.mangaReadingDirection == 'ltr' ? 'ltr' : 'rtl';
    _zoomPercent = appModel.mangaZoomPercent.clamp(
      kMangaZoomMinPercent,
      kMangaZoomMaxPercent,
    );
    _zoomSensitivity = appModel.mangaZoomSensitivity.clamp(
      kMangaZoomSensitivityMin,
      kMangaZoomSensitivityMax,
    );
    _pageAnimation = MangaPageAnimationKey.fromKey(appModel.mangaPageAnimation);
    _tapZonePaging = appModel.mangaTapZonePaging;
    _applyVolumeKeyPaging(appModel.mangaVolumeKeyPaging);
    final EpubBookRow row = persistedRow != null
        ? persistedRow.copyWith(
            epubPath: p.basename(mangaJson.path),
            extractDir: directory.path,
            chapterCount: input.pageCount,
          )
        : EpubBookRow(
            bookKey: widget.bookKey,
            // v81：无持久行的内存兜底行——身份生成一次;真正落库仍经
            // insertEpubBook 单点(见其 doc)。
            uid: generateEpubBookUid(),
            title: input.title,
            author: input.author,
            epubPath: p.basename(mangaJson.path),
            extractDir: directory.path,
            chapterCount: input.pageCount,
            chaptersJson: '[]',
            importedAt: DateTime.now().millisecondsSinceEpoch,
            format: 'manga',
          );
    final MangaReadingMode mode =
        MangaFushiPage.modeOverrideFromDb(row.mangaReadingMode) ??
        detectReadingMode(payload);
    final List<MangaSpreadEntry> spreads = _buildSpreadsFor(payload, mode);

    // v82：持久位置键 = **持久化**行的 uid；内存兜底行的现造 uid 不参与位置
    // 读写（见 [_bookUid] doc）。
    final String? persistedUid =
        (persistedRow != null && persistedRow.uid.isNotEmpty)
        ? persistedRow.uid
        : null;
    _bookUid = persistedUid;
    int restoredPage = input.initialPage ?? 0;
    double restoredFraction = 0;
    ReaderPosition? saved;
    if (input.persistProgress &&
        input.initialPage == null &&
        persistedUid != null) {
      try {
        saved = await ReaderPositionRepository(
          appModel.database,
        ).findByBookUid(persistedUid);
      } on Object catch (error, stack) {
        ErrorLogService.instance.log(
          'MangaFushiPage.restoreOnline',
          error,
          stack,
        );
      }
      if (saved != null &&
          saved.sectionIndex >= 0 &&
          saved.sectionIndex < payload.images.length) {
        restoredPage = saved.sectionIndex;
        if (mode == MangaReadingMode.webtoon) {
          restoredFraction = MangaFushiPage.charOffsetToWebtoonFraction(
            saved.charOffset,
          );
        }
      }
    }
    restoredPage = restoredPage.clamp(
      0,
      math.max(0, payload.images.length - 1),
    );

    _ensureStudyClock(appModel.database);
    // 同一 State 内换章 = 页号坐标系重用（新章页号从 0 起）：先结算离开的旧章
    // 末页（翻走即计），再清并集；首次打开两步都是 no-op。
    _readLedger
      ..leave()
      ..reset();
    final MangaReaderSession? previousSession = _pageSession;
    _pageSession = pageSession;
    _localPageIndices = <String, int>{
      for (int index = 0; index < relativePagePaths.length; index++)
        _localPageKey(relativePagePaths[index]): index,
    };
    _onlineChapter = input;
    _persistProgress = input.persistProgress;
    if (previousSession != null) unawaited(previousSession.close());

    final int restoredSpread = MangaFushiPage.restoreSpreadFromProgress(
      spreads,
      restoredPage,
    );
    setState(() {
      _bookRow = row;
      _imagesDir = imagesDirectory.path;
      _payload = payload;
      _mode = mode;
      _spreads = spreads;
      _currentSpread = restoredSpread;
      _currentPage = MangaFushiPage.firstPageOfSpread(spreads, restoredSpread);
      _currentFraction = restoredFraction;
      _lastSavedPage = saved != null ? restoredPage : -1;
      _lastSavedFraction = saved != null ? restoredFraction : -1;
    });
    _pageNotifier.value = _currentPage;
    _noteVisiblePages();
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
    final File materializedManifest = File(
      p.join(imagesDirectory.path, '.mihon-pages.json'),
    );
    if (await materializedManifest.exists()) {
      await materializedManifest.delete();
    }
    final Directory ocr = Directory(
      p.join(imagesDirectory.path, kMangaOcrOutDirName),
    );
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
      jsonEncode(<String, Object?>{'schema_version': 1, 'pages': identities}),
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
        'MangaFushiPage.onlinePrefetch',
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
      source:
          'window.__mangaUpdatePageGeometry && '
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
        'MangaFushiPage.persistOnlineGeometry',
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
        'MangaFushiPage.recoverIncrementalOcrCache',
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
    debugPrint('[MangaFushi] 404: $reason');
    return WebResourceResponse(
      contentType: 'text/plain',
      statusCode: 404,
      reasonPhrase: 'Not Found',
      headers: <String, String>{'Access-Control-Allow-Origin': '*'},
      data: Uint8List(0),
    );
  }

  static WebResourceResponse _forbidden(String reason) {
    debugPrint('[MangaFushi] 403: $reason');
    return WebResourceResponse(
      contentType: 'text/plain',
      statusCode: 403,
      reasonPhrase: 'Forbidden',
      headers: <String, String>{'Access-Control-Allow-Origin': '*'},
      data: Uint8List(0),
    );
  }

  Future<WebResourceResponse?> _interceptRequest(WebUri url) async {
    if (url.host != MangaFushiPage.kMangaHost) return null;
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
      } on Object catch (error, stackTrace) {
        ErrorLogService.instance.log('MangaFushiPage.page', error, stackTrace);
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
    final String? filePath = MangaFushiPage.resolveMangaResource(
      imagesDir,
      relative,
    );
    if (filePath == null) {
      // 区分穿越（403）与缺文件（404）：规范化 join 后越界即穿越企图。
      final String canonicalRoot = p.canonicalize(imagesDir);
      final String candidate = p.canonicalize(
        p.join(canonicalRoot, Uri.decodeComponent(relative)),
      );
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

  Future<CustomSchemeResponse?> _loadMangaCustomScheme(
    WebResourceRequest request,
  ) async {
    if (request.url.scheme != MangaFushiPage.kMangaResourceScheme) {
      return null;
    }
    final WebResourceResponse? response = await _interceptRequest(request.url);
    if (response == null) return null;
    return CustomSchemeResponse(
      data: response.data ?? Uint8List(0),
      contentType: response.contentType ?? 'application/octet-stream',
      contentEncoding: response.contentEncoding ?? 'binary',
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

    final List<int> keptSpreads = MangaFushiPage.mangaWindowRange(
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
      imgSrcs.add(
        MangaFushiPage.mangaImageUrl(
          image.url,
          useCustomScheme: Platform.isMacOS || Platform.isIOS,
        ),
      );
      final int spreadIndex = MangaFushiPage.spreadIndexForPage(_spreads, page);
      pageSpreadIndices.add(spreadIndex);
      pagesPerSpread.add(
        spreadIndex >= 0 && spreadIndex < _spreads.length
            ? _spreads[spreadIndex].pageIndices.length
            : 1,
      );
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
      zoomSensitivity: _zoomSensitivity,
      pageAnimation: _pageAnimation,
      tapZonePaging: _tapZonePaging,
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
        baseUrl: WebUri('https://${MangaFushiPage.kMangaHost}/'),
        mimeType: 'text/html',
        encoding: 'utf-8',
      );
      // WebView2's loadData Future only confirms navigation was accepted. The
      // old document can remain visible for another event-loop turn (or a
      // stale onLoadStop can arrive), so keep navigation locked until the
      // loaded document proves it owns this exact generation.
      final MangaWindowLoadOutcome outcome = await ticket.outcome.timeout(
        const Duration(seconds: 10),
      );
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
          source:
              'window.__mangaSetRescanMode && '
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
        unawaited(
          _turnQueue.drain(
            canApply: () => mounted && !_navigating,
            applyStep: _applyMangaTurnStep,
          ),
        );
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
      // 换章期间必须停止 drain：换章是在 applyStep 里 await 的，队列里剩下的
      // step 会在新章上继续消费。长按翻页撞到章尾时，那意味着一次按键连跳好几
      // 章。加上这一条，换章期间排队的 step 直接被丢掉。
      canApply: () => mounted && !_navigating && !_switchingChapter,
      applyStep: _applyMangaTurnStep,
    );
  }

  Future<void> _applyMangaTurnStep(int delta) async {
    final int target = (_currentSpread + delta)
        .clamp(0, _spreads.length - 1)
        .toInt();
    if (target == _currentSpread) {
      // 到头了。v88 前这里就是死钳位直接 return——于是在线漫画读完最后一页就
      // 走不动了，既不翻章也没有任何提示，配合「书架永远开同一章」构成了
      // 「加入书架后只能看第一章」。现在到头 = 换章信号。
      await _onReachedChapterEdge(delta);
      return;
    }
    _currentSpread = target;
    await _controller?.evaluateJavascript(
      source:
          'window.__mangaApplyTranslate && '
          'window.__mangaApplyTranslate($target);',
    );
    await _replaceSpreadOcr(target);
    _updateCurrentPageImagePath();
    _recordProgress();
    if (_onlineChapter != null) {
      unawaited(_primeOnlinePages(_currentPage));
    }
  }

  // ── 换章 ───────────────────────────────────────────────────────────

  /// 章节列表里「下一章」的下标偏移。
  ///
  /// 源按**新→旧**返回（列表 0 = 最新一话），所以「读下一话」是下标 **-1**。
  /// 这个方向反直觉，是本文件里最容易写反的一处，因此收成一个具名常量而不是
  /// 散落在各处的 `-1`。
  static const int _kNextChapterStep = -1;

  /// 读到当前章的边界（[delta] > 0 = 想往后翻）。
  Future<void> _onReachedChapterEdge(int delta) async {
    final OnlineMangaLibraryEntry? entry = _shelfEntry;
    if (entry == null || _switchingChapter) return;
    final bool forward = delta > 0;
    if (forward) {
      // 翻到最后一页 = 这一章读完了。先落已读标记再考虑换章：即使没有下一章
      // （追到最新话），「读完了」也必须记上，否则作品页永远显示未读。
      await _markCurrentChapterRead();
    }
    final int step = forward ? _kNextChapterStep : -_kNextChapterStep;
    final int target = _shelfChapterIndex + step;
    if (target < 0 || target >= entry.chapters.length) {
      // 一章只提示一次。队列会把长按攒下的 pendingDelta 一步步喂进来，每一步都
      // 撞在同一个边界上——不去重就是一串一模一样的 toast 糊住屏幕。
      if (mounted && !_edgeToastShown) {
        _edgeToastShown = true;
        FushiToast.show(
          msg: forward
              ? t.manga_series_last_chapter_reached
              : t.manga_series_first_chapter_reached,
        );
      }
      return;
    }
    await _switchToChapter(target, landOnLastPage: !forward);
  }

  /// 切到第 [index] 章。
  ///
  /// [landOnLastPage]：往回翻时应该落在上一章的**最后**一页，否则「往回翻一页」
  /// 会诡异地跳到上一章开头。
  Future<void> _switchToChapter(
    int index, {
    bool landOnLastPage = false,
  }) async {
    final OnlineMangaLibraryService? service = _shelfLibraryService;
    final OnlineMangaLibraryEntry? entry = _shelfEntry;
    final EpubBookRow? row = _bookRow;
    if (service == null ||
        entry == null ||
        row == null ||
        _switchingChapter ||
        index < 0 ||
        index >= entry.chapters.length) {
      return;
    }
    setState(() => _switchingChapter = true);
    try {
      // 换章前把当前章的进度落库，否则「翻到下一章再翻回来」会丢掉刚读的位置。
      await _saveCurrentChapterState();
      final OnlineMangaLibraryEntry selected = await service.selectChapter(
        bookKey: row.bookKey,
        entry: entry,
        chapterIndex: index,
      );
      await _openShelfChapter(
        row: row,
        service: service,
        entry: selected,
        chapterIndex: index,
      );
      final int pageCount = _payload?.images.length ?? 0;
      if (landOnLastPage && mounted && pageCount > 0) {
        await _jumpToPage(pageCount);
      }
    } on OnlineMangaUnavailable catch (error) {
      if (mounted) {
        FushiToast.show(msg: error.message, severity: ToastSeverity.error);
      }
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaFushiPage.switchChapter',
        error,
        stack,
      );
      if (mounted) {
        FushiToast.show(msg: '$error', severity: ToastSeverity.error);
      }
    } finally {
      if (mounted) setState(() => _switchingChapter = false);
    }
  }

  /// 把当前页码写进 `manga_chapter_states`。
  Future<void> _saveCurrentChapterState({int? readAt}) async {
    final EpubBookRow? row = _bookRow;
    final String? chapterKey = _shelfChapterKey;
    if (row == null || chapterKey == null || row.uid.isEmpty) return;
    await appModel.database.saveMangaChapterState(
      bookUid: row.uid,
      chapterKey: chapterKey,
      lastPage: _currentPage,
      lastFraction: _mode == MangaReadingMode.webtoon
          ? MangaFushiPage.webtoonFractionToCharOffset(_currentFraction)
          : -1,
      pageCount: _payload?.images.length,
      readAt: readAt,
    );
  }

  Future<void> _markCurrentChapterRead() =>
      _saveCurrentChapterState(readAt: DateTime.now().millisecondsSinceEpoch);

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
    final Set<int> spreadIndices = MangaFushiPage.mangaWindowRange(
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
      source:
          '''
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
    final int target = (_currentSpread + delta)
        .clamp(0, _spreads.length - 1)
        .toInt();
    if (target == _currentSpread) return;
    _currentSpread = target;
    _currentFraction = 0;
    await _controller?.evaluateJavascript(
      source:
          'window.__mangaScrollToSpread && '
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
    // 长按连发**只放给平移**：按住方向键持续挪画面是正常操作，而翻页恒不连发
    // （本页既有语义，与 navigationKeyBridgeScript 的 forwardRepeats:false 同口径，
    // 两条输入路径必须一致，否则 WebView 持焦与否手感不同）。
    final bool repeat = event is KeyRepeatEvent;
    if (event is! KeyDownEvent && !repeat) {
      return KeyEventResult.ignored;
    }
    final MangaReaderInputAction? action = _resolveMangaKeyAction(
      event.logicalKey,
      activeModifierKeys(),
    );
    if (action == null) return KeyEventResult.ignored;
    if (repeat && _panStepFor(action) == null) {
      return KeyEventResult.ignored;
    }
    _executeReaderInputAction(action, source: _MangaReaderInputSource.flutter);
    return KeyEventResult.handled;
  }

  MangaReaderInputAction? _lastReaderInputAction;
  _MangaReaderInputSource? _lastReaderInputSource;
  DateTime? _lastReaderInputAt;
  Timer? _dictionaryTurnDismissTimer;

  /// 是否已接管音量键。
  ///
  /// [VolumeKeyChannel] 是**进程级单例**，EPUB 阅读器也会往同一个 handler 槽里写
  /// （`audiobook.part.dart` 的 `_setupVolumeKeyHandlers` 无条件覆盖）。漫画页接管后
  /// 必须在 dispose 里交还——清 handler 并关掉原生拦截，否则退出漫画后音量键继续被
  /// `MainActivity.dispatchKeyEvent` 吞掉，用户调不动系统音量（BUG-196 的老坑）。
  late final MangaVolumeKeyPagingController _volumeKeyPagingController;

  void _applyVolumeKeyPaging(bool enabled) {
    // 只有 Android 侧 dispatchKeyEvent 会转发音量键；其它平台连通道都没有。
    _volumeKeyPagingController.apply(
      enabled: enabled,
      platformSupported: Platform.isAndroid,
    );
  }

  /// 平移动作 → 传给 `window.__mangaPanBy` 的**视口比例**步长；非平移动作返回 null。
  ///
  /// 符号按「视野怎么动」给（与滚动条直觉一致，JS 侧再翻成内容位移）：
  /// dx>0 视野右移，dy>0 视野下移。
  static Offset? _panStepFor(MangaReaderInputAction action) {
    const double s = kMangaPanStepFraction;
    return switch (action) {
      MangaReaderInputAction.panLeft => const Offset(-s, 0),
      MangaReaderInputAction.panRight => const Offset(s, 0),
      MangaReaderInputAction.panUp => const Offset(0, -s),
      MangaReaderInputAction.panDown => const Offset(0, s),
      _ => null,
    };
  }

  void _executeReaderInputAction(
    MangaReaderInputAction action, {
    required _MangaReaderInputSource source,
  }) {
    if (action == MangaReaderInputAction.toggleFullscreen) {
      unawaited(_toggleMangaFullscreen());
      return;
    }
    // 框选识别模式独占键盘：「返回上一级」/ 关词典键（默认都是 Escape）退出模式，
    // 翻页键一律吞掉——框选途中翻走当前页会让松手时算出的 pageIndex 指向另一页，
    // 回写就落错页。放在去抖之前：两条输入源（Flutter / 原生 WebView 桥）共用这一个
    // 闸门。框选模式是本页最内的一层，故「返回」在这里只退出模式、绝不退出漫画。
    if (_rescanModeActive) {
      if (action == MangaReaderInputAction.dismissDictionary ||
          action == MangaReaderInputAction.backOrExit) {
        unawaited(_setRescanMode(false));
      }
      return;
    }
    // 平移在这里就地返回：它不翻页、不关词典、也不该被翻页的跨源去抖吃掉（按住
    // 方向键连续挪画面是正常操作，而翻页去抖正是为了压掉连发）。
    final Offset? panStep = _panStepFor(action);
    if (panStep != null) {
      unawaited(
        _controller?.evaluateJavascript(
              source:
                  'window.__mangaPanBy && '
                  'window.__mangaPanBy(${panStep.dx}, ${panStep.dy});',
            ) ??
            Future<void>.value(),
      );
      return;
    }
    // BUG-1888：切换界面与平移同理就地返回——它不翻页、不关词典，也不该被翻页的
    // 跨源去抖吃掉（那道去抖压的是「同一次翻页被 Flutter 与 WebView 桥各报一次」，
    // 与本动作无关）。
    if (action == MangaReaderInputAction.toggleChrome) {
      _toggleMangaChrome();
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
    if (action == MangaReaderInputAction.backOrExit) {
      // 退出漫画：走 maybePop 让本页 [PopScope] 闸门照常跑（落库 / 收尾），与顶栏
      // 返回按钮同一条路，不直接 pop。
      unawaited(Navigator.of(context).maybePop());
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
    unawaited(
      _mode == MangaReadingMode.webtoon
          ? _jumpToPageAnchor(turn)
          : _onMangaTurn(turn),
    );
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
        // 「返回上一级」（默认 Esc）：弹窗持焦时也要能关弹窗。它在 universal scope，
        // [resolveDictionaryPopupInputToken] 会在 manga 未命中后回落到 universal。
        ShortcutAction.globalBack,
        ShortcutAction.globalToggleFullscreen,
      };

  @override
  bool onDictionaryPopupInputToken(String token) {
    // 鼠标 token 不参与「跨页方向校正」（那是方向键专属语义），交回基类按注册表
    // 动作直接执行（关词典）。
    if (MouseBinding.deserialize(token) != null) {
      return super.onDictionaryPopupInputToken(token);
    }
    return _handleNativeNavigationKey(token);
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
    final FushiShortcutRegistry registry = appModel.shortcutRegistry;
    final ShortcutAction? bound =
        registry.resolveKeyboard(
          key,
          modifiers: modifiers,
          scope: ShortcutScope.manga,
        ) ??
        // 兜底「返回上一级」（universal，默认 Esc）。排在 manga scope 之后：本页专属
        // 键永远优先。跨页方向校正只作用于翻页动作，globalBack 原样穿过。
        registry.resolveKeyboard(
          key,
          modifiers: modifiers,
          scope: ShortcutScope.universal,
        ) ??
        registry.resolveKeyboard(
          key,
          modifiers: modifiers,
          scope: ShortcutScope.global,
        );
    final ShortcutAction? corrected =
        resolveMangaArrowPageTurn(
          key: key,
          modifiers: modifiers,
          rtl: _spreadDirection == 'rtl',
          boundAction: bound,
        ) ??
        bound;
    return MangaFushiPage.inputActionForShortcut(
      action: corrected,
      crossPageStep:
          key == LogicalKeyboardKey.arrowLeft ||
          key == LogicalKeyboardKey.arrowRight,
      dictionaryShown: isDictionaryShown,
      mode: _mode,
    );
  }

  /// 手柄按钮 → 本页输入动作（桌面轮询 [GamepadButtonIntent] 与 Android 原生
  /// gameButton* 键事件汇合到同一入口，与阅读器 `_handleGamepadButton` 同构）。
  ///
  /// 解析阶梯与键盘路径一致：manga scope 优先，未命中兜底 universal（「返回上一
  /// 级」，默认手柄 B）——所以手柄 B 走的是与 Esc 相同的两级阶梯（弹窗可见先关
  /// 弹窗、没弹窗才退出漫画），而不是 GamepadService 的全局 maybePop 兜底直接退页。
  /// D-pad 左/右经 [resolveMangaDpadPageTurn] 按跨页方向（日漫默认 rtl）校正。
  ///
  /// 手柄翻页键一律**跨页步进**语义（crossPageStep: true）：手柄没有原生滚动路径，
  /// webtoon 模式下也该用锚点跳页；弹窗可见时关弹窗并翻页。
  MangaReaderInputAction? _resolveMangaGamepadAction(GamepadButton button) {
    final FushiShortcutRegistry registry = appModel.shortcutRegistry;
    final ShortcutAction? bound =
        registry.resolveGamepad(button, scope: ShortcutScope.manga) ??
        registry.resolveGamepad(button, scope: ShortcutScope.universal) ??
        registry.resolveGamepad(button, scope: ShortcutScope.global);
    final ShortcutAction? corrected =
        resolveMangaDpadPageTurn(
          button: button,
          rtl: _spreadDirection == 'rtl',
          boundAction: bound,
        ) ??
        bound;
    return MangaFushiPage.inputActionForShortcut(
      action: corrected,
      crossPageStep: true,
      dictionaryShown: isDictionaryShown,
      mode: _mode,
    );
  }

  /// 消费一枚手柄按钮；false 交回 GamepadService 的兜底（A=激活、dpad=移焦）。
  bool _handleGamepadButton(GamepadButton button) {
    final MangaReaderInputAction? action = _resolveMangaGamepadAction(button);
    if (action == null) return false;
    _executeReaderInputAction(action, source: _MangaReaderInputSource.gamepad);
    return true;
  }

  /// 鼠标按钮 → 本页动作。与 [_resolveMangaKeyAction] 共用同一个上下文门控
  /// [MangaFushiPage.inputActionForShortcut]，所以「弹窗可见时让位 / webtoon 纵向让位
  /// 原生滚动」两条既有语义对鼠标一并成立。
  ///
  /// `crossPageStep: false`：跨页步进语义是**方向键专属**（左右方向键要按 rtl 校正
  /// 朝向），鼠标按钮没有方向可言，与空格/PageDown 这类前进键同类。
  MangaReaderInputAction? _resolveMangaMouseAction(
    int button,
    List<ShortcutScope> ladder,
  ) {
    final ShortcutAction? bound = resolveMouseBindingActionForButton(
      registry: appModel.shortcutRegistry,
      button: button,
      ladder: ladder,
    );
    return MangaFushiPage.inputActionForShortcut(
      action: bound,
      crossPageStep: false,
      dictionaryShown: isDictionaryShown,
      mode: _mode,
    );
  }

  /// 漫画页 Flutter 侧的鼠标绑定入口（挂在 build 的页面根 [Listener] 上）。
  void _handleMangaPointerDown(PointerDownEvent event) {
    // BUG-2031 审查②：两条腿的互斥必须是**构造性**的，不能只门控一侧。
    //
    // 原先只有 JS 那条腿带 [hostOwnsWebViewPointerInput] 门控，本 Flutter 腿是**无条件
    // 挂载**的，注释却写着「两条路按平台互斥」。那个判据是从查词弹窗那边提上来的——
    // 弹窗在 Android 上是独立 Activity，确实在 Flutter 命中树之外；但本页正文的 WebView
    // 是**树内 platform view**，祖先 [Listener] 照样收得到指针（同一条「opaque 只排除
    // 兄弟、不排除祖先」的事实）。于是非 Windows 上同一次按下可能被 Flutter 腿与 JS 腿
    // 各执行一次，而 JS 腿没有 pointer id、无法参与认领协议。
    //
    // 补上这道门后，任一平台恒只有一条腿活着。代价是非 Windows 上**页面外壳**（正文
    // WebView 之外）的鼠标绑定不生效——那恰是本轮之前的行为（本页当时根本没有 Flutter
    // 侧鼠标腿），故不是回归；正文区照常由 JS 腿覆盖完整阶梯。
    if (!hostOwnsWebViewPointerInput) return;
    final int? button = domMouseButtonFromPointerButtons(event.buttons);
    if (button == null) return;
    final MangaReaderInputAction? action = _resolveMangaMouseAction(
      button,
      _kMangaMouseLadder,
    );
    if (action == null) return;
    dispatchClaimedMouseAction(event, () {
      _executeReaderInputAction(action, source: _MangaReaderInputSource.mouse);
      return true;
    });
  }

  /// 返回**本次是否真的执行了**动作。BUG-2031：查词弹窗 barrier 那条路要靠这个
  /// 回答决定要不要向 `MouseBindingDispatch` 认领这次鼠标按下。
  bool _handleNativeNavigationKey(String key) {
    // 鼠标桥回传的是 `Mouse<n>`（与键盘 token 取值域天然不相交：
    // `InputBinding.deserialize('Mouse3')` 与 `MouseBinding.deserialize('Escape')`
    // 都是 null），故先试鼠标、再试键盘，不需要额外的类型标记位。与查词弹窗桥
    // [resolveDictionaryPopupInputToken] 同一范式。
    final MouseBinding? mouse = MouseBinding.deserialize(key);
    if (mouse != null) {
      final MangaReaderInputAction? mouseAction = _resolveMangaMouseAction(
        mouse.button,
        _kMangaMouseLadder,
      );
      if (mouseAction == null) return false;
      _executeReaderInputAction(
        mouseAction,
        source: _MangaReaderInputSource.nativeWebView,
      );
      return true;
    }
    // token 按 [InputBinding.serialize] 解析：正文 WebView 的桥发裸 `event.key`
    // （`ArrowLeft`），弹窗桥发注册表 token（可能是任意键名、可能带修饰键前缀），
    // 两者都能被同一个 deserialize 吃下——旧的三分支 switch 只认硬编码的方向键与
    // Escape，用户把翻页/关词典改绑到别的键后，WebView 持焦的这条路径就整个失效。
    // `Esc` 是旧浏览器对 Escape 的别名，不在注册表键名表里，单独归一。
    final InputBinding? binding = key == 'Esc'
        ? const InputBinding(key: LogicalKeyboardKey.escape)
        : InputBinding.deserialize(key);
    if (binding == null) return false;
    final MangaReaderInputAction? action = _resolveMangaKeyAction(
      binding.key,
      binding.modifiers,
    );
    if (action == null) return false;
    _executeReaderInputAction(
      action,
      source: _MangaReaderInputSource.nativeWebView,
    );
    return true;
  }

  @override
  void onDismissBarrierPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    final MangaReaderInputAction? action = MangaFushiPage.wheelInputAction(
      event.scrollDelta,
    );
    if (action == null) return;
    clearDictionaryResult();
    final String turn = action == MangaReaderInputAction.next ? 'next' : 'prev';
    unawaited(
      _mode == MangaReadingMode.webtoon
          ? _jumpToPageAnchor(turn)
          : _onMangaTurn(turn),
    );
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
    final int page = MangaFushiPage.firstPageOfSpread(_spreads, _currentSpread);
    if (page < 0 || page >= payload.images.length) {
      _currentPageImagePath = null;
      return;
    }
    _currentPageImagePath = MangaFushiPage.resolveMangaResource(
      imagesDir,
      MangaFushiPage.mangaImageRelativePath(payload.images[page].url),
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
          page != MangaFushiPage.firstPageOfSpread(_spreads, _currentSpread)) {
        return;
      }
      _currentPageImagePath = file?.path;
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaFushiPage.onlineCardImage',
        error,
        stack,
      );
    }
  }

  /// 直接运行非模态全页/整卷 OCR。选好引擎后向导立即关闭，任务由阅读器持有；
  /// Lens 从当前页扫到末页后再补首页，每完成一页就热替换该页透明文字层。
  Future<void> _openWholeVolumeOcr() async {
    final EpubBookRow? row = _bookRow;
    if (row == null || _wholeVolumeOcrOpen || _wholeVolumeOcrRunning) {
      return;
    }
    // 框选区域重识别在飞：整卷收尾是拿结果文件整份覆写 manga.json，会把它刚落盘
    // 的区域吞掉。等它写完再开整卷。
    if (_rescanBusy) {
      FushiToast.show(
        msg: t.manga_rescan_running,
        severity: ToastSeverity.info,
      );
      return;
    }
    setState(() => _wholeVolumeOcrOpen = true);
    try {
      final OnlineMangaReaderChapter? online = _onlineChapter;
      final MangaOcrBackgroundJob? job;
      if (online != null) {
        final MangaOcrAutoStartResult result = await _buildOnlineOcrJob(online);
        if (!mounted) return;
        if (!result.started) {
          if (!result.cancelled) {
            FushiToast.show(
              msg: result.unavailableReason ?? t.manga_ocr_engine_none,
              severity: ToastSeverity.warning,
            );
          }
          return;
        }
        job = result.job;
      } else {
        job = await MangaModule.openBookOcr(
          context: context,
          db: appModel.database,
          book: row,
          startPage: _currentPage,
        );
      }
      if (!mounted || job == null) return;
      _attachWholeVolumeOcrJob(job);
    } catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaFushiPage.wholeVolumeOcr',
        error,
        stack,
      );
      if (mounted) {
        FushiToast.show(
          msg: '${t.manga_ocr_wizard_failed}: $error',
          severity: ToastSeverity.error,
        );
      }
    } finally {
      if (mounted) setState(() => _wholeVolumeOcrOpen = false);
    }
  }

  // ── 点击即识别 ───────────────────────────────────────────────────────
  //
  // 用户的原话是：安装完不用下模型、也不用先点识别模式，在漫画对话框上点一下
  // 就该弹查词。这条路径就是那个「点一下」——它不是第三个 OCR 引擎，只是把
  // 「当前页优先的整卷任务」接到空白点击上，并在该页文字层落地的那一刻把用户
  // 原来点的位置重放一次。
  //
  // 框选识别按钮和整卷按钮都保留：它们解决的是别的问题（漏框修补、整卷预跑）。

  /// 空白点击回传：该页还没有文字层时，按用户设置的引擎就地开跑。
  Future<void> _onTapEmpty(List<dynamic> args) async {
    if (args.isEmpty || args.first is! String) return;
    final Map<String, dynamic> data;
    try {
      final Object? decoded = jsonDecode(args.first as String);
      if (decoded is! Map<String, dynamic>) return;
      data = decoded;
    } catch (_) {
      return;
    }
    final Object? rawPage = data['pageIndex'];
    // 点在页与页之间的留白上：没有「哪一页」可言，什么都不做。
    if (rawPage is! int) return;
    // 这一页已经有文字层了，用户点的就是真空白（气泡间隙、画面），不该再开跑。
    if (data['hasOcr'] == true) return;
    final Object? rawX = data['x'];
    final Object? rawY = data['y'];
    if (rawX is! num || rawY is! num) return;
    await _startTapOcr(
      pageIndex: rawPage,
      x: rawX.toDouble(),
      y: rawY.toDouble(),
    );
  }

  Future<void> _startTapOcr({
    required int pageIndex,
    required double x,
    required double y,
  }) async {
    if (!appModel.mangaTapToOcr) return;
    // 框选模式下指针归框选所有；向导开着时用户正在自己选引擎，别抢。
    if (_rescanModeActive || _wholeVolumeOcrOpen) return;
    // 框选区域重识别在飞：这里起的整卷任务收尾会整份覆写 manga.json，吞掉它刚
    // 落盘的区域。同一条「正在识别」提示，等它写完再点。
    if (_rescanBusy) {
      FushiToast.show(
        msg: t.manga_rescan_running,
        severity: ToastSeverity.info,
      );
      return;
    }

    // JS 只能看见 DOM：一页没有 .ocr-box，既可能是「还没识别」，也可能是「识别
    // 过、这页本来就没字」（纯画面页、扉页）。后者点一下就重跑一次任务纯属白费。
    // 真相源是识别元数据——这一卷跑过 OCR，那这页的空就是真的空。
    final MokuroPayload? payload = _payload;
    if (payload?.ocr != null &&
        pageIndex >= 0 &&
        pageIndex < (payload?.images.length ?? 0) &&
        payload!.images[pageIndex].blocks.isEmpty) {
      return;
    }

    // 无论要不要起新任务，先记下这一点：任务已经在跑时，用户点的往往正是他想
    // 查的那个气泡，等该页轮到就回放。
    _pendingTapLookup = _MangaTapLookup(pageIndex: pageIndex, x: x, y: y);

    if (_wholeVolumeOcrRunning || _tapOcrStarting) {
      FushiToast.show(
        msg: t.manga_tap_ocr_running,
        severity: ToastSeverity.info,
      );
      return;
    }

    _tapOcrStarting = true;
    try {
      if (!appModel.mangaTapToOcrNoticeShown) {
        final bool proceed = await _showTapOcrNotice();
        if (!proceed || !mounted) {
          _pendingTapLookup = null;
          return;
        }
        await appModel.setMangaTapToOcrNoticeShown(true);
        if (!mounted) return;
      }

      final OnlineMangaReaderChapter? online = _onlineChapter;
      if (online != null) {
        final MangaOcrAutoStartResult result = await _buildOnlineOcrJob(online);
        if (!mounted) return;
        if (!result.started) {
          _pendingTapLookup = null;
          if (result.cancelled) return;
          FushiToast.show(
            msg: result.unavailableReason ?? t.manga_ocr_engine_none,
            severity: ToastSeverity.warning,
          );
          return;
        }
        _attachWholeVolumeOcrJob(result.job!);
        return;
      }

      final EpubBookRow? row = _bookRow;
      if (row == null) {
        _pendingTapLookup = null;
        return;
      }
      final MangaOcrAutoStartResult result =
          await startMangaOcrWithPreferredEngine(
            context: context,
            db: appModel.database,
            bookKey: widget.bookKey,
            imageDirPath: row.extractDir,
            startPage: _currentPage,
            lensLanguage: appModel.mangaOcrLensLanguage,
          );
      if (!mounted) return;
      if (!result.started) {
        _pendingTapLookup = null;
        // 用户自己在 Lens 告知里点了取消：不该再弹一句报错骂他一遍。
        if (result.cancelled) return;
        FushiToast.show(
          msg: result.unavailableReason ?? t.manga_ocr_engine_none,
          severity: ToastSeverity.warning,
        );
        return;
      }
      _attachWholeVolumeOcrJob(result.job!);
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaFushiPage.tapOcr', error, stack);
      _pendingTapLookup = null;
      if (mounted) {
        FushiToast.show(
          msg: '${t.manga_ocr_wizard_failed}: $error',
          severity: ToastSeverity.error,
        );
      }
    } finally {
      _tapOcrStarting = false;
    }
  }

  /// 首次说明：这一点会触发一次识别，用的是设置里选的哪个引擎，去哪儿改。
  ///
  /// 只弹一次。它与 Lens 的上传告知是两件事——那条只讲「图片会发给 Google」，
  /// 这条讲「你点一下就会开始跑」，在 Lens 引擎下两条会前后脚出现，各说各的。
  Future<bool> _showTapOcrNotice() async {
    final bool? ok = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(t.manga_tap_ocr_notice_title),
        content: Text(t.manga_tap_ocr_notice_body),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.dialog_cancel),
          ),
          FilledButton(
            key: const ValueKey<String>('manga_tap_ocr_notice_confirm'),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.manga_tap_ocr_notice_confirm),
          ),
        ],
      ),
    );
    return ok == true;
  }

  /// 该页文字层刚落地：把用户原来点的位置回放一次，接上查词。
  Future<void> _replayPendingTapLookup(int pageIndex) async {
    final _MangaTapLookup? pending = _pendingTapLookup;
    if (pending == null || pending.pageIndex != pageIndex) return;
    _pendingTapLookup = null;
    await _controller?.evaluateJavascript(
      source:
          'window.__mangaTapLookupAt && '
          'window.__mangaTapLookupAt(${pending.x}, ${pending.y});',
    );
  }

  /// 在线章节的 OCR 任务（按用户偏好；在线页先物化成本地缓存供离线引擎读取）。
  ///
  /// 抽出来是因为「点一下就识别」和顶栏整卷按钮要的是同一个任务，只是入口不同。
  Future<MangaOcrAutoStartResult> _buildOnlineOcrJob(
    OnlineMangaReaderChapter online,
  ) async {
    final MangaReaderSession? session = _pageSession;
    final MokuroPayload? payload = _payload;
    if (session == null || payload == null) {
      return MangaOcrAutoStartResult.unavailable(t.manga_ocr_engine_none, null);
    }
    _onlineGeometryPersistDebounce?.cancel();
    await _persistOnlinePayloadGeometry();
    if (!mounted) {
      return const MangaOcrAutoStartResult.cancelled();
    }
    return startOnlineMangaOcrWithPreferredEngine(
      context: context,
      db: appModel.database,
      bookKey: widget.bookKey,
      session: session,
      managedDirectory: online.managedDirectory,
      initialPayload: payload,
      startPage: _currentPage,
      lensLanguage: normalizeLensLanguage(
        online.sourceLanguage,
        fallback: appModel.mangaOcrLensLanguage,
      ),
    );
  }

  /// 订阅一个已经构造好的 OCR 任务，接管进度态与逐页热替换。
  ///
  /// 向导入口和「点击即识别」共用：任务从哪来不影响它跑起来之后的样子。
  void _attachWholeVolumeOcrJob(MangaOcrBackgroundJob job) {
    setState(() {
      _wholeVolumeOcrRunning = true;
      _wholeVolumeOcrDone = 0;
      _wholeVolumeOcrTotal = 0;
      _wholeVolumeOcrAcceleration = null;
      _wholeVolumeOcrDegradeNotified = false;
    });
    _wholeVolumeOcrSubscription = job.events
        .asyncMap(_handleWholeVolumeOcrEvent)
        .listen(
          (_) {},
          onError: (Object error, StackTrace stack) {
            ErrorLogService.instance.log(
              'MangaFushiPage.wholeVolumeOcr',
              error,
              stack,
            );
            if (!mounted) return;
            setState(() => _wholeVolumeOcrRunning = false);
            _pendingTapLookup = null;
            FushiToast.show(
              msg: '${t.manga_ocr_wizard_failed}: $error',
              severity: ToastSeverity.error,
            );
          },
          onDone: () {
            _wholeVolumeOcrSubscription = null;
            _pendingTapLookup = null;
            if (mounted && _wholeVolumeOcrRunning) {
              setState(() => _wholeVolumeOcrRunning = false);
            }
          },
        );
  }

  Future<void> _handleWholeVolumeOcrEvent(MangaOcrBackgroundEvent event) async {
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
    // 文字层就位后才回放：早一步回放必然落空（那时页面上还没有可命中的字）。
    await _replayPendingTapLookup(pageIndex);
  }

  /// 记录并（首次）提示本次任务真正生效的执行后端。
  ///
  /// BUG-1163：GPU EP 被插件拒绝时实现会静默重建 CPU 会话；不提示的话用户在
  /// 整卷 OCR 上只会觉得「怎么这么慢」，无从判断自己根本没在用 GPU。
  void _observeWholeVolumeOcrAcceleration(MangaOcrAcceleration? acceleration) {
    if (acceleration == null) return;
    if (identical(acceleration, _wholeVolumeOcrAcceleration)) return;
    setState(() => _wholeVolumeOcrAcceleration = acceleration);
    if (!acceleration.degraded || _wholeVolumeOcrDegradeNotified) return;
    _wholeVolumeOcrDegradeNotified = true;
    FushiToast.show(
      msg: t.manga_ocr_acceleration_degraded(
        engine: acceleration.label,
        reason: acceleration.degradeReasons.join('; '),
      ),
      severity: ToastSeverity.warning,
    );
  }

  Future<void> _replacePageOcrOverlay(int pageIndex, MokuroImage page) async {
    final String boxes = mangaOcrBoxesHtml(page);
    await _controller?.evaluateJavascript(
      source:
          'window.__mangaReplaceOcr && '
          'window.__mangaReplaceOcr($pageIndex, ${jsonEncode(boxes)});',
    );
  }

  Future<void> _finishWholeVolumeOcr(MangaOcrBackgroundEvent event) async {
    final EpubBookRow? row = _bookRow;
    final String? resultPath = event.resultPath;
    if (row == null || resultPath == null) return;
    final String source = await File(resultPath).readAsString();
    final MokuroPayload payload = event.external
        ? parseMokuro(source)
        : parseMangaJson(source);
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
    // 整卷 OCR 只是就地重写已入库书的 manga.json，没有发生任何导入：这里必须用
    // OCR 语义的文案，不能复用向导的「漫画已导入」（用户在阅读器里跑完 OCR 却看到
    // 「导入已完成」）。
    FushiToast.show(msg: t.manga_ocr_done, severity: ToastSeverity.success);
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

  // ── 重新识别框选区域 ─────────────────────────────────────────────────
  //
  // 四段链：JS 框选 → `onMangaBoxSelected` → 裁框进临时目录、交给**设置里的引擎**
  // （与整卷 / 点击识别同一条 `startMangaOcrWithPreferredEngine` 链，五个引擎零
  // 分支）→ 结果块平移回页图坐标、替换该页区域内的旧块并回写 manga.json → 热替换
  // 该页文字层。能力层在 `media/manga/ocr/manga_region_ocr.dart`，写侧在
  // `media/manga/manga_json_writeback.dart`；本页只做编排与状态同步。
  //
  // 没有结果卡片、没有独立的模型闸门：识别出来就是文字层里的框，点一下即查词；
  // 引擎不可用的原因由引擎链给出（模型没下 / 系统 OCR 不可用 / 没有配对主机）。

  /// chrome「重新识别框选区域」按钮：模式内再点 = 退出，否则进入模式。
  Future<void> _onRescanButtonPressed() async {
    await _setRescanMode(!_rescanModeActive);
  }

  /// Dart/JS 双侧同步进入/退出框选模式。
  Future<void> _setRescanMode(bool on) async {
    if (!mounted) return;
    setState(() => _rescanModeActive = on);
    await _controller?.evaluateJavascript(
      source:
          'window.__mangaSetRescanMode && '
          'window.__mangaSetRescanMode(${on ? 'true' : 'false'});',
    );
    if (on) {
      FushiToast.show(msg: t.manga_rescan_hint, severity: ToastSeverity.info);
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
    final EpubBookRow? row = _bookRow;
    // `_wholeVolumeOcrOpen`（向导 modal 开着）也要显式挡：现在靠 modal 遮住 WebView
    // 让 JS 发不出框选，那是布局巧合不是不变量——向导一旦改成非模态就会漏进来，
    // 而向导落盘是**整份覆写**，途中回写的区域会被整段吞掉。
    if (payload == null ||
        imagesDir == null ||
        row == null ||
        _rescanBusy ||
        _wholeVolumeOcrOpen) {
      return;
    }
    // 整卷任务收尾时会拿结果文件整份覆写 manga.json，途中回写的区域会被吞掉；
    // 与「点击即识别」同一条闸门。
    if (_wholeVolumeOcrRunning) {
      FushiToast.show(
        msg: t.manga_tap_ocr_running,
        severity: ToastSeverity.info,
      );
      return;
    }
    final Object? decoded = _tryDecodeJson(payloadJson);
    if (decoded is! Map) return;
    final int pageIndex = (decoded['pageIndex'] as num?)?.toInt() ?? -1;
    if (pageIndex < 0 || pageIndex >= payload.images.length) return;
    final Rect box = Rect.fromLTRB(
      (decoded['left'] as num?)?.toDouble() ?? 0,
      (decoded['top'] as num?)?.toDouble() ?? 0,
      (decoded['right'] as num?)?.toDouble() ?? 0,
      (decoded['bottom'] as num?)?.toDouble() ?? 0,
    );
    // JS 侧已按视口 8px 过滤；这里按页图像素二次防御（畸形 payload）。
    if (box.width < 8 || box.height < 8) return;
    final String? imagePath = MangaFushiPage.resolveMangaResource(
      imagesDir,
      MangaFushiPage.mangaImageRelativePath(payload.images[pageIndex].url),
    );
    if (imagePath == null) {
      FushiToast.show(
        msg: t.manga_rescan_failed,
        severity: ToastSeverity.error,
      );
      return;
    }
    _rescanBusy = true;
    try {
      await _reocrRegion(
        row: row,
        payload: payload,
        pageIndex: pageIndex,
        imagePath: imagePath,
        box: box,
      );
    } on SystemOcrUnavailableException catch (error, stack) {
      // ML Kit 的 unbundled 模型在能力探测里报 available，真跑起来才发现 Play 服务
      // 里没装（`MODEL_UNAVAILABLE`）。冒成通用失败的话用户只会看到「重新识别框选
      // 区域失败」，拿不到「去装识别模型」这个可操作原因。
      ErrorLogService.instance.log('MangaFushiPage.rescan', error, stack);
      if (mounted) {
        FushiToast.show(
          msg: t.manga_ocr_engine_system_unavailable,
          severity: ToastSeverity.warning,
        );
      }
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaFushiPage.rescan', error, stack);
      if (mounted) {
        FushiToast.show(
          msg: t.manga_rescan_failed,
          severity: ToastSeverity.error,
        );
      }
    } finally {
      _rescanBusy = false;
    }
  }

  /// 裁框 → 偏好引擎 → 区域替换回写 → 热替换该页文字层 → 挂撤销。
  ///
  /// 编排本体在 `ocr/manga_region_rescan.dart`（`runMangaRegionRescan`，无 UI、可
  /// 直测）；这里只做「注入引擎选取」和「把终局翻译成 UI」。引擎链跑的是一个只装着
  /// 裁图的临时目录，所以在线章节也能用（裁图是本地字节，不必像整卷那样被迫走
  /// Lens）。
  Future<void> _reocrRegion({
    required EpubBookRow row,
    required MokuroPayload payload,
    required int pageIndex,
    required String imagePath,
    required Rect box,
  }) async {
    final String mangaJsonPath = p.join(row.extractDir, row.epubPath);
    final MangaRegionRescanOutcome outcome = await runMangaRegionRescan(
      imagePath: imagePath,
      mangaJsonPath: mangaJsonPath,
      pageIndex: pageIndex,
      box: box,
      pageBlocks: payload.images[pageIndex].blocks,
      startEngine: (String imageDirPath) async {
        // 裁框有 await（解码整页图），页面可能已经关了；拿死 context 去弹 Lens 告知
        // 等于替用户点了同意。
        if (!mounted) return const MangaOcrAutoStartResult.cancelled();
        return startMangaOcrWithPreferredEngine(
          context: context,
          db: appModel.database,
          bookKey: widget.bookKey,
          imageDirPath: imageDirPath,
          startPage: 0,
          lensLanguage: appModel.mangaOcrLensLanguage,
        );
      },
      onEngineStarted: () {
        if (!mounted) return;
        FushiToast.show(
          msg: t.manga_rescan_running,
          severity: ToastSeverity.info,
        );
      },
      // 在线几何 debounce 到期时会把当时的 `_payload` 整份写回。它若插在「区域落盘」
      // 与下面的 setState 之间，写的就是**不含新块**的旧快照，刚回写的区域当场被吞。
      // 几何本来就会在下次翻页/滚动时重新排程。
      onBeforeWriteback: () => _onlineGeometryPersistDebounce?.cancel(),
    );
    if (!mounted) return;
    switch (outcome.status) {
      // 用户自己在 Lens 告知里点了取消（或页面已关）：不该再弹一句报错骂他一遍。
      case MangaRegionRescanStatus.cancelled:
        return;
      case MangaRegionRescanStatus.unavailable:
        FushiToast.show(
          msg: outcome.unavailableReason ?? t.manga_ocr_engine_none,
          severity: ToastSeverity.warning,
        );
      case MangaRegionRescanStatus.empty:
        FushiToast.show(
          msg: t.manga_rescan_empty,
          severity: ToastSeverity.info,
        );
      case MangaRegionRescanStatus.replaced:
        // 锁内已经产出了落盘后的 payload，直接用——锁外重读会读到别的写者的版本。
        final MokuroPayload updated = outcome.payload!;
        setState(() => _payload = updated);
        await _replacePageOcrOverlay(pageIndex, updated.images[pageIndex]);
        if (!mounted) return;
        _offerRegionRescanUndo(
          mangaJsonPath: mangaJsonPath,
          pageIndex: pageIndex,
          previousPage: outcome.previousPage!,
        );
    }
  }

  /// 区域替换成功提示 + 撤销入口。
  ///
  /// 区域替换是**磁盘上的破坏性写**（旧文字块从 manga.json 里永久消失，外部 mokuro
  /// 工具与其它设备读的是同一份）。识别结果比原文差是常态，所以成功提示必须带一条
  /// 回头路，而不是只报一句「已回写」。没有 ScaffoldMessenger（理论上不该发生）时
  /// 降级为普通 toast，绝不静默。
  void _offerRegionRescanUndo({
    required String mangaJsonPath,
    required int pageIndex,
    required MokuroImage previousPage,
  }) {
    final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(
      context,
    );
    if (messenger == null) {
      FushiToast.show(
        msg: t.manga_rescan_region_updated,
        severity: ToastSeverity.success,
      );
      return;
    }
    messenger.clearSnackBars();
    messenger.showSnackBar(
      SnackBar(
        content: Text(t.manga_rescan_region_updated),
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: t.undo,
          onPressed: () => unawaited(
            _undoRegionRescan(
              mangaJsonPath: mangaJsonPath,
              pageIndex: pageIndex,
              previousPage: previousPage,
            ),
          ),
        ),
      ),
    );
  }

  /// 把该页整页还原成区域替换前的快照并热替换文字层。
  Future<void> _undoRegionRescan({
    required String mangaJsonPath,
    required int pageIndex,
    required MokuroImage previousPage,
  }) async {
    try {
      // 与回写同一条理由：几何 debounce 插在还原与 setState 之间会把还原吞掉。
      _onlineGeometryPersistDebounce?.cancel();
      final MokuroPayload restored = await restoreMangaPage(
        mangaJsonPath: mangaJsonPath,
        pageIndex: pageIndex,
        page: previousPage,
      );
      if (!mounted) return;
      setState(() => _payload = restored);
      await _replacePageOcrOverlay(pageIndex, restored.images[pageIndex]);
      if (!mounted) return;
      FushiToast.show(
        msg: t.manga_rescan_undone,
        severity: ToastSeverity.success,
      );
    } on Object catch (error, stack) {
      ErrorLogService.instance.log('MangaFushiPage.rescanUndo', error, stack);
      if (mounted) {
        FushiToast.show(
          msg: t.manga_rescan_undo_failed,
          severity: ToastSeverity.error,
        );
      }
    }
  }

  static Object? _tryDecodeJson(String source) {
    try {
      return jsonDecode(source);
    } catch (_) {
      return null;
    }
  }

  // ── 查词（L7）────────────────────────────────────────────────────────

  /// 注册**全工程唯一**的 `onTextSelected` Dart handler（ERRATA H2）。触发它的
  /// pointerup 监听内嵌且仅存在于 [mangaWindowDocument]（L3），本方法绝不注册第二个
  /// pointerup。payload 解码成 [ReaderSelectionData] 转发 [processMangaSelection]，
  /// 镜像 reader_fushi 的现代形态（webview.part.dart）。
  void _registerSelectionHandlers(InAppWebViewController controller) {
    controller.addJavaScriptHandler(
      handlerName: 'onTextSelected',
      callback: (List<dynamic> args) async {
        if (args.isEmpty) return;
        try {
          final Map<String, dynamic> payload =
              jsonDecode(args[0] as String) as Map<String, dynamic>;
          final ReaderSelectionData data = ReaderSelectionData.fromJson(
            payload,
          );
          if (kDebugMode && mounted) {
            setState(() => _debugOcrSelectedText = data.text);
          }
          await processMangaSelection(data);
        } catch (e, stack) {
          ErrorLogService.instance.log('MangaFushi.onTextSelected', e, stack);
          debugPrint('[MangaFushi] onTextSelected error: $e');
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

    final String? local = MangaFushiPage.resolveMangaPageImage(
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
      _miningPageImagePath = file != null && await file.exists()
          ? file.path
          : null;
    } on Object catch (error, stack) {
      ErrorLogService.instance.log(
        'MangaFushiPage.selectedCardImage',
        error,
        stack,
      );
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
              sentence,
              data.text,
            );
        _lastSentence = resolved;
        _lastSentenceOffset = data.sentenceOffset;
        appModel.currentMediaSource?.setCurrentSentence(
          selection: FushiTextSelection(text: resolved),
        );
      },
      search: (String term, Rect selectionRect, bool verticalWriting) async {
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
      final String sentence = _lastSentence.isNotEmpty
          ? _lastSentence
          : (fields['sentence'] ?? '');

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

      FushiToast.showMine(
        msg: t.card_mining_pending,
        status: MineToastStatus.pending,
      );
      final MineOutcome outcome = await repo.mineEntry(
        rawPayloadJson: jsonEncode(fields),
        context: miningContext,
      );
      final described = describeMineOutcome(outcome);
      if (described.record) {
        unawaited(_recordMinedCount());
      }
      FushiToast.showMine(msg: described.message, status: described.status);
      if (described.success) {
        return MinePopupResult(ankiConnect: true, noteId: outcome.noteId);
      }
      // BUG-1908/1915：重复 ≠ 没制成，见 MinePopupResult.duplicate；
      // 失败结局一律经 .failed(outcome) 这一个入口，别在各表面散写判据。
      return MinePopupResult.failed(outcome);
    } catch (e, stack) {
      ErrorLogService.instance.log('MangaFushiPage.onMineFromPopup', e, stack);
      return const MinePopupResult();
    }
  }

  Future<void> _recordMinedCount() async {
    // P4 写侧收敛：走 DB 复合入口（同事务全局汇总 + per-book 计数），并补上此前
    // 漏写的书身份（旧代码只写全局 addMiningCount，per-book 恒漏 → 恒等式单边偏差）。
    final ({String? bookKey, String? title})? identity = lookupBookIdentity;
    try {
      await appModel.database.recordMiningEvent(
        bookKey: identity?.bookKey,
        title: identity?.title ?? '',
        sourceType: kStatSourceBook,
        at: DateTime.now(),
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('MangaFushiPage.recordMined', e, stack);
    }
  }

  // ── 阅读模式覆盖 ─────────────────────────────────────────────────────

  /// 页内切换 spread/webtoon，并把用户覆盖写进 `EpubBooks.mangaReadingMode`
  /// （之后开书恒用覆盖值，不再自动判定）。跨布局保当前页。
  Future<void> _toggleReadingMode() async {
    final MokuroPayload? payload = _payload;
    if (_bookRow == null || payload == null) return;
    final MangaReadingMode next = MangaFushiPage.toggleMangaMode(_mode);
    final int currentPage = MangaFushiPage.firstPageOfSpread(
      _spreads,
      _currentSpread,
    );
    final FushiDatabase db = appModel.database;
    try {
      await (db.update(
        db.epubBooks,
      )..where(($EpubBooksTable t) => t.bookKey.equals(widget.bookKey))).write(
        EpubBooksCompanion(
          mangaReadingMode: Value<String?>(MangaFushiPage.modeToDbString(next)),
        ),
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('MangaFushiPage.toggleMode', e, stack);
    }
    if (!mounted) return;
    final List<MangaSpreadEntry> spreads = _buildSpreadsFor(payload, next);
    // 同一页换单元边界（spread↔webtoon）不是翻页：只替换当前单元边界、不结算。
    _readLedger.rebaseOnNextArrive();
    setState(() {
      _mode = next;
      _spreads = spreads;
      _currentSpread = MangaFushiPage.spreadIndexForPage(spreads, currentPage);
      _currentPage = currentPage;
      _currentFraction = 0;
    });
    _pageNotifier.value = _currentPage;
    _noteVisiblePages();
    await _loadInitialWindow();
    // 布局变化会换掉当前 spread 背后的页（ERRATA C2）。
    _updateCurrentPageImagePath();
    FushiToast.show(
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
    final (int page, double fraction) = MangaFushiPage.mangaProgressForSpread(
      _spreads,
      _currentSpread,
      webtoonFraction: _currentFraction,
      isWebtoon: _mode == MangaReadingMode.webtoon,
    );
    _currentPage = page;
    _pageNotifier.value = page;
    _noteVisiblePages();
    // 600ms debounce：连续翻页/滚动只落最后一次。
    _progressDebounce?.cancel();
    _progressDebounce = Timer(const Duration(milliseconds: 600), () {
      unawaited(_persistPosition(page, fraction));
    });
  }

  /// [_readLedger] 的结算回调：[fresh] 是刚离开的单元里本会话首次覆盖的页号子区间
  /// （并集去重后），展开成页号按 OCR 文本计字数、按页计页数，记进时钟当前段。
  void _creditPages(List<(int, int)> fresh) {
    final MokuroPayload? payload = _payload;
    if (payload == null) return;
    final List<int> pageIndices = <int>[
      for (final (int start, int end) in fresh)
        for (int page = start; page < end; page++) page,
    ];
    final ({int chars, int pages}) added = mangaStatsForPages(
      payload,
      pageIndices,
    );
    // v92：字数 / 页数直接记进当前打开段（与时长同一 uid 同一行）。
    _studyClock?.addChars(added.chars);
    _studyClock?.addPages(added.pages);
  }

  /// [_readLedger] 的撤回回调（回翻）：[retracted] 是不再位于当前位置之前的页号
  /// 子区间，按同一换算扣出时钟（会话级夹 0 由 `StudyClock` 保证）。
  void _retractPages(List<(int, int)> retracted) {
    final MokuroPayload? payload = _payload;
    if (payload == null) return;
    final List<int> pageIndices = <int>[
      for (final (int start, int end) in retracted)
        for (int page = start; page < end; page++) page,
    ];
    final ({int chars, int pages}) removed = mangaStatsForPages(
      payload,
      pageIndices,
    );
    _studyClock?.retractChars(removed.chars);
    _studyClock?.retractPages(removed.pages);
  }

  /// v92：建好并启动本页唯一的阅读时钟（幂等）。空闲门 + 生命周期前台门只对
  /// 阅读面生效（用户拍板：视频以播放态为准）。
  void _ensureStudyClock(FushiDatabase db) {
    _studyClock ??= StudyClock(
      database: db,
      mediaKind: kActivityMediaBook,
      mediaKey: widget.bookKey,
      title: _bookRow?.title ?? widget.bookKey,
      format: BookFormat.manga.dbValue,
      idleTimeout: appModel.readingIdleTimeout,
      onWriteError: (Object e, StackTrace st) =>
          ErrorLogService.instance.log('StudyClock.write(manga)', e, st),
    );
    _studyClock!.start();
  }

  Future<void> _persistPosition(int page, double fraction) async {
    _lastSavedPage = page;
    _lastSavedFraction = fraction;
    if (!_persistProgress) return;
    final FushiDatabase db = appModel.database;
    final bool isWebtoon = _mode == MangaReadingMode.webtoon;
    // v82：uid 缺失 = 库里没有这本书的持久行（内存兜底行不算），位置与「已读完」
    // 都无处可落，整段跳过——不拿 bookKey / 现造 uid 兜底写孤儿行。
    final String? bookUid = _bookUid;
    if (bookUid == null) return;
    try {
      await ReaderPositionRepository(db).save(
        bookUid: bookUid,
        sectionIndex: page,
        normCharOffset: 0,
        // 漫画无章内字符偏移。**必须显式传值**（传 null 会掉进 EPUB 专用的「跨
        // section 精确锚失效」启发式）：spread 恒 0；webtoon 复用 charOffset 存
        // 页内滚动千分比（0..1000），恢复时换算回 fraction。
        charOffset: isWebtoon
            ? MangaFushiPage.webtoonFractionToCharOffset(fraction)
            : 0,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('MangaFushiPage._persistPosition', e, stack);
    }
    // 翻到最后一页 → 幂等写「已读完」（判据用总页数）。
    final int pageCount = _payload?.images.length ?? 0;
    final bool atLastPage = pageCount > 0 && page >= pageCount - 1;
    if (atLastPage) {
      try {
        await db.markEpubBookCompletedIfUnset(widget.bookKey, DateTime.now());
      } catch (e, stack) {
        ErrorLogService.instance.log('MangaFushiPage.markCompleted', e, stack);
      }
    }
    // 每章状态跟着同一个收口走：位置写哪儿、章状态就写哪儿，不另开一条会漏的
    // 时机。书架在线条目才有「章」，本地卷 _shelfChapterKey 恒 null 自然跳过。
    final String? chapterKey = _shelfChapterKey;
    if (chapterKey == null) return;
    try {
      await db.saveMangaChapterState(
        bookUid: bookUid,
        chapterKey: chapterKey,
        lastPage: page,
        lastFraction: isWebtoon
            ? MangaFushiPage.webtoonFractionToCharOffset(fraction)
            : -1,
        pageCount: pageCount > 0 ? pageCount : null,
        readAt: atLastPage ? DateTime.now().millisecondsSinceEpoch : null,
      );
    } catch (e, stack) {
      ErrorLogService.instance.log('MangaFushiPage.saveChapterState', e, stack);
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

  /// 把「上一次 tick 到现在」的部分窗口结算并落库（不停表）。时长 / OCR 字数 / 页数
  /// 三个量纲在同一段同一行、绝对值写回：落库失败由时钟在下个 tick 重写，没有任何
  /// 计数器可清、也没有任何东西能重复累加。页数仍然绝不塞进字数口径。
  Future<void> _flushReadingStats() async {
    await _studyClock?.flushNow();
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
    final int normalized = value.clamp(
      kMangaZoomMinPercent,
      kMangaZoomMaxPercent,
    );
    if (_zoomPercent == normalized) return;
    setState(() => _zoomPercent = normalized);
    _zoomPreferenceDebouncer?.discard();
    await appModel.setMangaZoomPercent(normalized);
    await _controller?.evaluateJavascript(
      source:
          'window.__mangaSetZoom && '
          'window.__mangaSetZoom($normalized);',
    );
  }

  void _queueZoomPreferencePersist(int value) {
    (_zoomPreferenceDebouncer ??= MangaZoomPreferenceDebouncer(
      persist: appModel.setMangaZoomPercent,
    )).queue(value);
  }

  Future<void> _jumpToPage(int oneBasedPage) async {
    final MokuroPayload? payload = _payload;
    if (payload == null || payload.images.isEmpty) return;
    final int page = (oneBasedPage - 1).clamp(0, payload.images.length - 1);
    final int target = MangaFushiPage.spreadIndexForPage(_spreads, page);
    _currentSpread = target;
    _currentFraction = 0;
    if (_mode == MangaReadingMode.webtoon) {
      await _controller?.evaluateJavascript(
        source:
            'window.__mangaScrollToSpread && '
            'window.__mangaScrollToSpread($target, 0);',
      );
      await _replaceSpreadOcr(target);
    } else {
      await _controller?.evaluateJavascript(
        source:
            'window.__mangaApplyTranslate && '
            'window.__mangaApplyTranslate($target);',
      );
      await _replaceSpreadOcr(target);
    }
    _updateCurrentPageImagePath();
    _recordProgress();
  }

  /// 阅读器里的章节选择器。
  ///
  /// 列表复用作品页那一份 [MangaChapterList]：两处对「已读怎么显示、当前章怎么
  /// 高亮、排序默认哪个方向」的答案必须一致，各写一份必然漂移。
  Future<void> _showChapterPicker() async {
    final OnlineMangaLibraryEntry? entry = _shelfEntry;
    final EpubBookRow? row = _bookRow;
    if (entry == null || row == null) return;
    final Map<String, MangaChapterStateRow> states = row.uid.isEmpty
        ? const <String, MangaChapterStateRow>{}
        : await appModel.database.getMangaChapterStates(row.uid);
    if (!mounted) return;
    final int? target = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      builder: (BuildContext sheetContext) => FushiModalSheetFrame(
        title: t.mihon_chapters_title,
        scrollable: true,
        body: MangaChapterList(
          entry: entry,
          states: states,
          newestFirst: true,
          unreadOnly: false,
          currentChapterKey: _shelfChapterKey,
          showHeader: false,
          onChapterTap: (OnlineMangaChapter chapter) => Navigator.of(
            sheetContext,
          ).pop(entry.indexOfChapterKey(chapter.key)),
        ),
      ),
    );
    if (target != null && target >= 0) {
      await _switchToChapter(target);
    }
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
    // BUG-1438（与 BUG-129/261/381/781 同族）：JS 报的 clientX/clientY 是 **真实屏幕
    // 坐标**——漫画页整棵子树被 FushiAppUiScaleNeutralizer 中和回净缩放=1（见
    // manga_fushi_source.dart），WebView 全出血铺满真实视口。但 showMenu 的
    // RelativeRect 落在根 Navigator 的 Overlay 坐标系，而该 Overlay 在全局
    // FushiAppUiScale 的 FittedBox 之内（**缩放画布**空间，尺寸 = 真实视口 / scale）。
    //
    // 修复前把真实坐标直接当画布坐标喂进去，菜单实际渲染在「点击点 × scale」：
    // 界面大小 125% 时右键点在 (800,600) 菜单跑到 (1000,750)，越靠右下偏得越远；
    // 调小到 50% 则菜单缩向左上角。同理 MediaQuery.of(context).size 在中和层内是
    // **真实视口**尺寸（比 overlay.size 大 scale 倍），当作 RelativeRect 的 right/bottom
    // 会让贴边翻转判断一起失准。
    //
    // 修法与同族一致：不读 scale 数值逆算（自动模式下生效 scale ≠ appModel.appUiScale），
    // 而用 Overlay 的 RenderBox 沿真实渲染变换链把锚点映射到 Overlay 本地坐标——中间的
    // FittedBox 缩放被 render transform 自动吸收，对任意 scale 自洽；scale=1 时变换为
    // 单位阵，逐像素等价（向后兼容）。边界同步改用 overlay.size。
    final RenderBox overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final Offset anchor = overlay.globalToLocal(Offset(x, y));
    final _MangaContextAction? action = await showMenu<_MangaContextAction>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(anchor.dx, anchor.dy, 1, 1),
        Offset.zero & overlay.size,
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
          enabled: _zoomPercent < kMangaZoomMaxPercent,
          child: Text('${t.manga_zoom} + ($_zoomPercent%)'),
        ),
        PopupMenuItem<_MangaContextAction>(
          value: _MangaContextAction.zoomOut,
          enabled: _zoomPercent > kMangaZoomMinPercent,
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
        await _setSpreadDirection(_spreadDirection == 'rtl' ? 'ltr' : 'rtl');
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
    // 漫画页是**窗口全屏的合法宿主**之一：全屏键（默认 F11）只在小说 / 漫画 / 视频里
    // 能进入全屏，靠的就是下面那层 [WindowFullscreenHost] 声明。用局部变量而不是把
    // 整棵树往里缩一级，纯粹是为了不给这个文件制造一次全量重缩进的 diff。
    final Widget page = PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, dynamic result) async {
        if (didPop) return;
        // Cache the navigator before either async cleanup step; this callback
        // must not read BuildContext after an await.
        final NavigatorState navigator = Navigator.of(context);
        // Fullscreen is a presentation layer above the reader route. Back/Esc
        // leaves that layer first and keeps the current WebView/page intact.
        if (await _exitOwnedFullscreenBeforePop()) return;
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
        //
        // 手柄同理：桌面轮询路径把 GamepadButtonIntent 派给 primaryFocus 所在
        // 子树的 Actions，Android 的 gameButton* 键事件经全局 wrapper 转成同一
        // Intent——Actions 必须是正文 WebView 与词典弹层的共同祖先，词典 WebView
        // 持焦时手柄键才仍经过本页（先关弹窗再退页的两级阶梯，而非全局 maybePop）。
        body: Actions(
          actions: <Type, Action<Intent>>{
            GamepadButtonIntent: CallbackAction<GamepadButtonIntent>(
              onInvoke: (GamepadButtonIntent intent) =>
                  _handleGamepadButton(intent.button),
            ),
          },
          child: Focus(
            focusNode: _focusNode,
            autofocus: true,
            onKeyEvent: _handleReaderKey,
            // 鼠标通道与键盘/手柄挂在同一层，作用域同样是「正文 WebView + chrome +
            // 词典弹层」的共同祖先。`translucent` 让本层自己占住命中（默认
            // deferToChild 在空白区收不到按下）；[Listener] 不进手势竞技场也不消费
            // 事件，下层 WebView / 弹层照常收到同一次按下。
            //
            // ⚠️ 本 Listener 只覆盖**指针归 Flutter 的**那部分：原生 WebView（正文页图
            // 与 OCR 文本层）在 Windows 之外会把指针整个吃掉，那片区域由页内 JS 的鼠标
            // 桥回传（见注入处）。两条路按平台互斥，不会重复触发。
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _handleMangaPointerDown,
              child: Stack(
                fit: StackFit.expand,
                children: <Widget>[
                  Positioned.fill(child: _buildBody()),
                  // 查词弹窗层：必须在同一个键盘 Focus 子树里，否则原生词典
                  // WebView 持焦后会吞掉翻页键。
                  Positioned.fill(
                    key: const ValueKey<String>('manga_dictionary_host'),
                    child: buildDictionary(),
                  ),
                  // 返回键是本页**唯一**的出口，它的可见性只能由用户意图
                  // （[_chromeVisible]）决定，绝不能再挂内容状态门控。
                  //
                  // 旧条件是 `_bookRow != null && !_loadFailed && _chromeVisible`：
                  // 加载失败或一直没就绪时，正文区只剩一行「找不到书籍文件」，而
                  // 这颗按钮**跟着一起消失**。漫画正文是原生 WebView、空白点击已被
                  // 翻页占用，页内没有第二条退出通道；iOS 又没有系统返回键，
                  // `PopScope(canPop: false)` 还顺手关掉了侧滑返回——三者叠加的结果
                  // 是用户只能杀进程。出口不是内容的一部分，不随内容存亡。
                  if (_chromeVisible)
                    Positioned(
                      top: 0,
                      left: 0,
                      child: SafeArea(
                        child: IconButton(
                          key: const ValueKey<String>(
                            'manga_reader_back_button',
                          ),
                          tooltip: MaterialLocalizations.of(
                            context,
                          ).backButtonTooltip,
                          color: Colors.white,
                          icon: const Icon(Icons.arrow_back_ios_new),
                          onPressed: () => Navigator.of(context).maybePop(),
                        ),
                      ),
                    ),
                  // 顶部 chrome：页码指示 + 阅读模式切换。
                  if (_bookRow != null && !_loadFailed && _chromeVisible)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: SafeArea(child: _buildTopChrome()),
                    ),
                  // BUG-1888：隐藏态唯一的唤回入口（理由见 [_chromeVisible]）。
                  // 与返回键同理不挂内容门控——否则「隐藏界面后内容加载失败」会把
                  // 唤回按钮一并抹掉，连带返回键再也叫不回来。
                  if (!_chromeVisible)
                    Positioned(
                      top: 0,
                      right: 0,
                      child: SafeArea(
                        child: Opacity(
                          opacity: 0.35,
                          child: IconButton(
                            key: const ValueKey<String>(
                              'manga_chrome_show_button',
                            ),
                            tooltip: t.manga_interface_show,
                            iconSize: 20,
                            color: Colors.white,
                            icon: const Icon(Icons.visibility_outlined),
                            onPressed: _toggleMangaChrome,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
    return WindowFullscreenHost(child: page);
  }

  /// BUG-1888：切换界面可见性。移动端联动系统栏——隐藏界面即进入沉浸式全屏；
  /// 桌面的窗口级全屏走全局 F11（[ShortcutAction.globalToggleFullscreen]），
  /// 与本页无关，两者可叠加使用。
  void _toggleMangaChrome() {
    setState(() {
      _chromeVisible = !_chromeVisible;
    });
    _applyMangaImmersiveMode();
  }

  /// 移动端系统栏跟随界面可见性：隐藏 → immersiveSticky（连状态栏/导航栏一起
  /// 收掉，边缘滑动可临时唤出）；显示 → 回到 edgeToEdge，与 [AppModel.openMedia]
  /// 打开媒体后的常规形态一致。桌面无系统栏概念，直接返回。
  void _applyMangaImmersiveMode() {
    if (!Platform.isAndroid && !Platform.isIOS) return;
    SystemChrome.setEnabledSystemUIMode(
      _chromeVisible ? SystemUiMode.edgeToEdge : SystemUiMode.immersiveSticky,
      overlays: _chromeVisible
          ? SystemUiOverlay.values
          : const <SystemUiOverlay>[],
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
            final int spreadIndex = MangaFushiPage.spreadIndexForPage(
              _spreads,
              page,
            );
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
                style: Theme.of(
                  context,
                ).textTheme.labelLarge?.copyWith(color: Colors.white70),
              ),
            );
          },
        ),
        // 重新识别框选区域入口：OCR 漏框或认错的气泡就地用偏好引擎重跑一块，不必
        // 整卷重跑。常显；引擎不可用在框选松手后由引擎链给出原因。激活时高亮。
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
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: Colors.white70),
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
              borderRadius: FushiBorderRadius.chip,
            ),
            child: Text(
              '${_debugOcrHitOrientation == 'vertical' ? '竖排' : '横排'}'
              ' · ${_debugOcrHitCharacter ?? ''}'
              ' · ${_debugOcrSelectedText ?? ''}'
              ' · $_zoomPercent%',
              style: Theme.of(
                context,
              ).textTheme.labelSmall?.copyWith(color: Colors.lightGreenAccent),
            ),
          ),
        // 章节列表：只有书架里的在线条目才有「章」。本地卷（一卷一条目、无章节）
        // 和源浏览预览（没有书架身份）都不显示，免得给出一个点开必然是空的入口。
        if (_shelfEntry != null)
          Tooltip(
            message: t.manga_series_chapters_action,
            child: IconButton(
              key: const ValueKey<String>('manga_reader_chapters'),
              icon: const Icon(Icons.list_alt_outlined, color: Colors.white),
              onPressed: _switchingChapter
                  ? null
                  : () => unawaited(_showChapterPicker()),
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
        // BUG-1888：隐藏界面。与快捷键（默认 M / 手柄 Y）同一个执行体。
        Tooltip(
          message: t.manga_interface_hide,
          child: IconButton(
            key: const ValueKey<String>('manga_chrome_hide_button'),
            icon: const Icon(
              Icons.visibility_off_outlined,
              color: Colors.white,
            ),
            onPressed: _toggleMangaChrome,
          ),
        ),
        if (desktopWindowFullscreenSupported)
          Tooltip(
            message: t.shortcut_action_global_toggle_fullscreen,
            child: IconButton(
              key: const ValueKey<String>('manga_fullscreen_button'),
              icon: Icon(
                _isWindowFullscreen
                    ? Icons.fullscreen_exit_rounded
                    : Icons.fullscreen_rounded,
                color: Colors.white,
              ),
              // The method itself serializes native transitions. Keeping the
              // button enabled avoids rebuilding it as permanently disabled
              // when the final state update occurs before the transition's
              // finally block clears its guard.
              onPressed: () => unawaited(_toggleMangaFullscreen()),
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
        resourceCustomSchemes: const <String>[
          MangaFushiPage.kMangaResourceScheme,
        ],
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
            // 空白 tap 不再是纯 no-op，但指针已让原生 WebView 夺走 OS 焦点，
            // 焦点回收仍然必须最先做，否则此后方向键翻页全部失效。
            _focusOwnership.reclaim(FocusReclaimCause.gesture);
            unawaited(_onTapEmpty(args));
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
        // 平移桥（第二座，允许连发）。回调与翻页桥同一个——token 一律走
        // InputBinding.deserialize + 注册表解析，动作由绑定决定而不是由桥决定。
        controller.addJavaScriptHandler(
          handlerName: 'onMangaPanKey',
          callback: (List<dynamic> args) {
            if (args.isEmpty || args[0] is! String) return;
            _handleNativeNavigationKey(args[0] as String);
          },
        );
        // 鼠标桥（第三座，只在指针归 WebView 的平台安装）。回调同样汇进
        // [_handleNativeNavigationKey]——它按 token 先试 MouseBinding 再试
        // InputBinding，动作由绑定决定而不是由桥决定。
        controller.addJavaScriptHandler(
          handlerName: 'onMangaMouseButton',
          callback: (List<dynamic> args) {
            if (args.isEmpty || args[0] is! String) return;
            _handleNativeNavigationKey(args[0] as String);
          },
        );
        controller.addJavaScriptHandler(
          handlerName: 'onMangaContextMenu',
          callback: (List<dynamic> args) {
            if (args.isEmpty || args[0] is! String) return;
            // BUG-2111：页内 JS 那一路仍然硬判 `e.button === 2`，因为漫画的右键还兼着
            // 「缩放态下按住拖拽平移」（rightDrag），换键会牵连那半边。所以归属判据补在
            // 这里：右键若已经被别的漫画动作占用，菜单让位——否则一次右键既翻页又弹菜单，
            // 正是本 bug 在漫画页的形态。判据与 Flutter 那二十余处入口是同一个函数。
            if (!contextMenuButtonNumberMatches(
              registry: appModel.shortcutRegistry,
              button: 2,
              ladder: _kMangaMouseLadder,
            )) {
              return;
            }
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
            final int normalized = value.clamp(
              kMangaZoomMinPercent,
              kMangaZoomMaxPercent,
            );
            if (_zoomPercent == normalized) return;
            if (mounted) {
              setState(() => _zoomPercent = normalized);
            } else {
              _zoomPercent = normalized;
            }
            _queueZoomPreferencePersist(normalized);
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
      onLoadResourceWithCustomScheme:
          (InAppWebViewController controller, WebResourceRequest request) =>
              _loadMangaCustomScheme(request),
      onReceivedError:
          (
            InAppWebViewController controller,
            WebResourceRequest request,
            WebResourceError error,
          ) async {
            if (!(request.isForMainFrame ?? false)) return;
            // Windows WebView2 对未解析虚拟域的主帧导航报错，即使 shouldInterceptRequest
            // 已提供文档。视作加载完成（镜像 reader_fushi 的同款处理）。
            if (Platform.isWindows &&
                request.url.host == MangaFushiPage.kMangaHost) {
              unawaited(_markWindowReady(controller));
            }
          },
      onLoadStop: (InAppWebViewController controller, WebUri? url) async {
        await _markWindowReady(controller);
      },
      // 非 null 本身就是救命动作：Java 侧据此 `return true`，不再连坐杀 app。
      onRenderProcessGone:
          (InAppWebViewController _, RenderProcessGoneDetail detail) =>
              unawaited(
                _webViewDeathGuard.handleDeath(
                  didCrash: detail.didCrash,
                  rendererPriorityAtExit: detail.rendererPriorityAtExit,
                ),
              ),
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
      rawGeneration,
      _windowGate.generation,
    )) {
      return;
    }
    // 但入口比一次远远不够（BUG-1170）：下面三个 await 期间窗口可能被换掉
    // （10s 超时放弃旧窗口 → 新一轮 begin() 递增 generation 并换新锁），迟到的旧
    // 回调会解开**新**窗口的锁，导航锁被错误解除，WebView 还在加载旧内容就被判定
    // 就绪。所以这里取本次加载的凭据，每个 await 之后再复问一次归属。
    final MangaWindowLoadTicket? ticket = _windowGate.ticketFor(
      MangaWindowGeneration.parse(rawGeneration),
    );
    if (ticket == null) {
      return;
    }
    await controller.evaluateJavascript(
      source: MangaFushiPage.navigationKeyBridgeScript,
    );
    if (!mounted || !_windowGate.owns(ticket)) {
      return;
    }
    await controller.evaluateJavascript(
      source: MangaFushiPage.panKeyBridgeScript,
    );
    if (!mounted || !_windowGate.owns(ticket)) {
      return;
    }
    // 鼠标桥：只在**指针归 WebView** 的平台装。Windows 上指针先到 Flutter，页面根
    // [Listener]（[_handleMangaPointerDown]）已经接住，再装一份就会双触发。
    // 按钮表按当前绑定实时生成，改绑后换窗即生效。
    if (!hostOwnsWebViewPointerInput) {
      await controller.evaluateJavascript(
        source: MangaFushiPage.mouseBridgeScript(
          MangaFushiPage.mouseBridgeButtons(appModel.shortcutRegistry),
        ),
      );
      if (!mounted || !_windowGate.owns(ticket)) {
        return;
      }
    }
    if (_mode == MangaReadingMode.webtoon) {
      await controller.evaluateJavascript(
        source:
            'window.__mangaScrollToSpread && '
            'window.__mangaScrollToSpread($_currentSpread, $_currentFraction);',
      );
    } else {
      await controller.evaluateJavascript(
        source:
            'window.__mangaApplyTranslate && '
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

/// 「点击即识别」待回放的一次点击。
///
/// 只在页文字层落地的那一帧用一次，用完即弃——留着它跨页回放只会在别的页面上
/// 随机选中一个字。
@immutable
class _MangaTapLookup {
  const _MangaTapLookup({
    required this.pageIndex,
    required this.x,
    required this.y,
  });

  final int pageIndex;

  /// 视口坐标（JS 侧 `_selectOcrChar` 吃的就是这个坐标系）。
  final double x;
  final double y;
}
