import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/utils/misc/hibiki_toast.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:hibiki/pages.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/utils/adaptive/adaptive_widgets.dart';
import 'package:hibiki_core/hibiki_core.dart';
import 'package:hibiki/src/epub/epub_book.dart';
import 'package:hibiki/src/epub/epub_parser.dart';
import 'package:hibiki/src/epub/epub_spread_analyzer.dart';
import 'package:hibiki/src/epub/epub_spread_map.dart';
import 'package:hibiki/src/epub/epub_storage.dart';
import 'package:hibiki/src/media/audiobook/audiobook_bridge.dart';
import 'package:hibiki/src/media/audiobook/audiobook_session.dart';
import 'package:hibiki/src/media/audiobook/audiobook_session_launcher.dart';
import 'package:hibiki/src/media/audiobook/lyrics_mode_html.dart';
import 'package:hibiki_audio/hibiki_audio.dart';
import 'package:hibiki/src/media/audiobook/highlight_bridge.dart';
import 'package:hibiki/src/media/audiobook/audiobook_play_bar.dart';
import 'package:hibiki/src/media/audiobook/audiobook_import_dialog.dart';
import 'package:hibiki/src/media/audiobook/mining_audio_clip.dart';
import 'package:hibiki/src/media/audiobook/mining_sentence_draft.dart';
import 'package:hibiki/src/media/audiobook/reader_quick_settings_sheet.dart';
import 'package:hibiki/src/media/sources/reader_hibiki_source.dart';
import 'package:hibiki/src/pages/implementations/dictionary_popup_webview.dart'
    show DictionaryPopupWebViewState, MinePopupResult;
import 'package:hibiki/src/pages/implementations/stat_activity.dart';
import 'package:hibiki/src/profile/profile_repository.dart';
import 'package:hibiki/src/profile/profile_view_model.dart';
import 'package:hibiki/src/reader/reader_caret_scripts.dart';
import 'package:hibiki/src/reader/reader_chrome_scaler.dart';
import 'package:hibiki/src/reader/reader_lyrics_caret_scripts.dart';
import 'package:hibiki/src/reader/reader_content_styles.dart';
import 'package:hibiki/src/reader/reader_resource_sanitizer.dart';
import 'package:hibiki/src/reader/reader_pagination_scripts.dart';
import 'package:hibiki/src/reader/reader_selection_data.dart';
import 'package:hibiki/src/reader/reader_selection_scripts.dart';
import 'package:hibiki/src/reader/reader_gamepad_immersive.dart';
import 'package:hibiki/src/reader/reader_settings.dart';
import 'package:hibiki/src/reader/reader_top_progress.dart';
import 'package:hibiki/src/startup/exit_flush_registry.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';
import 'package:hibiki/src/media/audiobook/floating_lyric_channel.dart';
import 'package:hibiki/src/media/audiobook/pointer_seek.dart';
import 'package:hibiki_anki/hibiki_anki.dart';
import 'package:hibiki/src/anki/anki_view_model.dart';
import 'package:hibiki/src/utils/misc/error_log_service.dart';
import 'package:hibiki/src/utils/misc/debug_log_service.dart';
import 'package:hibiki/src/utils/misc/channel_constants.dart';
import 'package:hibiki/src/utils/misc/tts_channel.dart';
import 'package:hibiki/src/utils/misc/serial_task_queue.dart';
import 'package:hibiki/src/utils/misc/volume_key_channel.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:hibiki/src/utils/misc/platform_utils.dart';
import 'package:hibiki/src/utils/misc/hibiki_color.dart';
import 'package:hibiki/src/utils/components/hibiki_design_tokens.dart';
import 'package:hibiki/src/utils/components/hibiki_icon_button.dart';
import 'package:hibiki/src/utils/components/hibiki_material_components.dart';
import 'package:hibiki/src/utils/misc/show_app_dialog.dart';
import 'package:hibiki/src/shortcuts/input_binding.dart'
    show GamepadButton, ModifierKey;
import 'package:hibiki/src/shortcuts/gamepad_service.dart'
    show GamepadButtonIntent, GamepadLongPressIntent, focusedEditableText;
import 'package:hibiki/src/shortcuts/shortcut_action.dart';
import 'package:hibiki/src/shortcuts/reader_caret_router.dart';
import 'package:hibiki/src/shortcuts/dictionary_caret_controller.dart';
// Re-export so existing references to `CaretSurface` via the reader page,
// and the source-scan guards that read this file, still resolve the enum
// after its definition moved into the shared caret controller (TODO-387).
export 'package:hibiki/src/shortcuts/dictionary_caret_controller.dart'
    show CaretSurface;
import 'package:hibiki/src/shortcuts/reader_space_override.dart';
import 'package:hibiki/src/utils/app_ui_scale.dart';

part 'reader_hibiki/lyrics.part.dart';
part 'reader_hibiki/mining.part.dart';
part 'reader_hibiki/lookup.part.dart';
part 'reader_hibiki/navigation.part.dart';
part 'reader_hibiki/audiobook.part.dart';
part 'reader_hibiki/caret.part.dart';
part 'reader_hibiki/chrome.part.dart';
part 'reader_hibiki/webview.part.dart';

/// What the reader-surface caret move resolves to in Dart, given the physical
/// key direction and the `status` hoshiCaret.move returned.
enum ReaderCaretMoveOutcome {
  /// In-page move (status `moved`) or a benign block — nothing for Dart to do.
  none,
  paginateForward,
  paginateBackward,
}

/// Pure mapping from (physical direction, move status) → Dart action for the
/// reader caret. Extracted so the page-edge rule is unit-tested without a
/// WebView.
///
/// TODO-700 T8: the bottom chrome bar is now excluded from focus traversal
/// ([ExcludeFocus] in the reader chrome), so there is nowhere to "promote" the
/// caret to. A physical Down at the bottom edge therefore turns the page, the
/// same path as the logical `forward` reading advance — caret-active and plain
/// reading Down stay consistent and neither strands focus on an unfocusable bar.
ReaderCaretMoveOutcome readerCaretMoveOutcome(
    String physicalDir, String status) {
  // A physical Down off the bottom of the content reports either `pageForward`
  // (paged) or `blocked` (continuous, at the document end). Both turn the page.
  if (physicalDir == 'down' && status == 'blocked') {
    return ReaderCaretMoveOutcome.paginateForward;
  }
  if (status == 'pageForward') return ReaderCaretMoveOutcome.paginateForward;
  if (status == 'pageBackward') return ReaderCaretMoveOutcome.paginateBackward;
  return ReaderCaretMoveOutcome.none;
}

/// 桌面悬浮字幕条点词时，从整句文本与点击字符索引解析出真正要查的词
/// （TODO-376）。优先用语言分词器 [Language.wordFromIndex] 切出的 [word]；切不出
/// （空白 / 标点 / 引擎未就绪）则回退整句 [text]。两者皆空返回空串，调用方据此
/// no-op。提取成顶层纯函数便于单测，不必驱动整个阅读器页面。
String floatingLyricSearchTerm({
  required String text,
  required int index,
  required String word,
}) {
  final String trimmedWord = word.trim();
  if (trimmedWord.isNotEmpty) return trimmedWord;
  return text.trim();
}

/// Whether a handled reader-WebView pointer gesture (swipe / wheel / boundary
/// turn / tap-to-toggle-chrome) should reclaim Flutter keyboard focus for the
/// reading content. The native WebView captures the OS focus on any pointer
/// gesture, silently dropping the reader's [FocusNode]; without reclaiming it,
/// ESC and every reader shortcut stop reaching the page's key handler
/// (BUG-136 — same failure `onAllPopupsDismissed` repairs after a popup's
/// WebView steals focus). Returns false when another Flutter focus owner — a
/// visible dictionary popup, or the bottom chrome bar — legitimately holds it,
/// so reclaiming never yanks focus away from them.
bool shouldReclaimReaderFocusAfterGesture({
  required bool popupVisible,
  required bool chromeHasFocus,
}) =>
    !popupVisible && !chromeHasFocus;

/// 视口尺寸变化是否大到需要重排分页（BUG-210 / TODO-146）。
///
/// 桌面端用户报「翻页有时跳回章节开头」。根因不在 JS `paginate`（真实 Chromium
/// 引擎下逐页步进稳健，BUG-169 修复有效），而在 [_ReaderHibikiPageState._syncPageSize]
/// 的旧判定：宽度用**精确浮点不等** `w != _lastSyncedWidth`（零容差），高度才用
/// `(h - last).abs() >= 1`（1px 容差）。Windows 桌面（`flutter_inappwebview_windows`
/// fork 渲染 EPUB）在翻页/重绘时常报 sub-pixel 视口宽抖动，零容差让任意 0.x px 宽差
/// 都判 `widthChanged` → 走整章重载（`_navigateToChapter` 重新 load + 粗粒度 progress
/// 恢复）：progress 分辨率低 → 落到错误的、通常更靠前的页（progress<=0 时直接
/// `scrollToProgressPaged` 回 `contentFirstPageScroll` = 章节开头），即用户感知的
/// 「翻页跳回章节开头」。
///
/// 修复 = 让宽、高用**同一个 1px 容差**判定（消除「宽零容差」这个特例）。真正的
/// 旋转 / 窗口 resize 宽度大变（远 > 1px）仍照常重排，零破坏。返回 `(width, height)`
/// 两个布尔，调用方据此分别决定整章重载（宽变）或原地重排（高变）。
({bool width, bool height}) readerViewportNeedsRepaginate({
  required double width,
  required double height,
  required double lastWidth,
  required double lastHeight,
  double tolerancePx = 1.0,
}) {
  final bool widthChanged =
      lastWidth > 0 && (width - lastWidth).abs() >= tolerancePx;
  final bool heightChanged = (height - lastHeight).abs() >= tolerancePx;
  return (width: widthChanged, height: heightChanged);
}

/// TODO-690 / BUG-399：桌面窗口拖边框 resize 后阅读器文字渲染错乱、不自动重排，
/// 翻页才恢复。唯一 resize→重排入口是 [_ReaderHibikiPageState.didChangeMetrics]
/// → `_syncPageSize`，但 Windows 拖边框时 `didChangeMetrics` / `MediaQuery.size`
/// 更新滞后，JS 分页几何缓存（`--page-width/height` / `this.pageWidth` / `_contW`
/// / `paginationMetrics`）无人失效，导致错位。修复用阅读器树内的透明 `LayoutBuilder`
/// 监听约束变化作为更早更可靠的 resize 通道。
///
/// 本纯谓词决定一次新的布局约束相对上次已分页基线，是否大到需要触发尾沿防抖重排：
/// 复用 [readerViewportNeedsRepaginate] 的 1px 容差与 `lastWidth>0` 门控（不另写阈
/// 值），宽或高任一维度变化超阈值即返回 true。`LayoutBuilder` 的 `constraints` 与
/// `_syncPageSize` 读的 `MediaQuery.size` 同处 Neutralizer 反缩放还原后的坐标空间，
/// 数值等价，所以两条路径靠 `_lastSyncedWidth/Height` 基线天然去重幂等。
bool readerLayoutResizeNeedsRepaginate({
  required double width,
  required double height,
  required double lastWidth,
  required double lastHeight,
  double tolerancePx = 1.0,
}) {
  final ({bool width, bool height}) changed = readerViewportNeedsRepaginate(
    width: width,
    height: height,
    lastWidth: lastWidth,
    lastHeight: lastHeight,
    tolerancePx: tolerancePx,
  );
  return changed.width || changed.height;
}

/// 阅读器主题用的四个颜色角色：正文背景、正文字色、私语(振假名/sasayaki)叠色、
/// 是否暗色。preset 主题在 [_ReaderHibikiPageState._themeMap] 里手调，其余主题
/// （light-theme / system-theme / 任意未覆盖的 key）由 [resolveReaderThemeColors]
/// 回落到真实 ColorScheme 派生，避免再写死成白底（BUG-208 / TODO-143）。
typedef ReaderThemeColors = ({
  Color bg,
  Color fg,
  Color sasayaki,
  Color selection,
  Color link,
  bool dark,
});

/// 把当前主题 key 解析成阅读器的颜色角色（背景/字色/跟读高亮/选区高亮/链接）。
///
/// 关键修复（BUG-208 / TODO-143）：旧逻辑只查私有 [presetMap]，命中失败就硬编码
/// 白底/黑字/默认私语色。但 `themePresets` 里还有 `light-theme`，且**默认主题**是
/// `system-theme`，两者都不在 presetMap 中，于是阅读器背景永远是白色——无论系统
/// 强调色或明暗如何，「书籍背景没吃主题」。
///
/// BUG-396：sasayaki/selection/link 三个角色色过去只在 preset/custom 命中时生效，
/// system/light 主题落到 [ReaderContentStyles] 的硬编码默认（天蓝高亮/灰选区/蓝链接），
/// 不吃桌面强调色。现在本解析器是这五个角色色的**单一真相源**：system/light 也从真实
/// [scheme] 派生（sasayaki=primary、selection=tertiary 与跟读区分、link=primary），
/// 页面统一用本结果，不再各自回落硬编码。
///
/// 现在：
/// - `custom-theme`：用用户自定义色（与旧行为一致）。
/// - presetMap 命中（ecru/water/gray/dark/black）：用手调底色（向后兼容，零变化）。
/// - 其余（light-theme / system-theme / 未来新增 key）：从真实 [scheme] 派生，
///   让阅读器背景/高亮/选区/链接真正跟随当前主题（强调色）。
ReaderThemeColors resolveReaderThemeColors({
  required String themeKey,
  required Map<String, ReaderThemeColors> presetMap,
  required ColorScheme scheme,
  ReaderThemeColors? customColors,
}) {
  if (themeKey == 'custom-theme' && customColors != null) {
    return customColors;
  }
  final ReaderThemeColors? preset = presetMap[themeKey];
  if (preset != null) {
    return preset;
  }
  // light-theme / system-theme / 未覆盖的 key：跟随真实 ColorScheme。
  final bool dark = scheme.brightness == Brightness.dark;
  return (
    bg: scheme.surface,
    fg: scheme.onSurface,
    sasayaki: scheme.primary.withValues(alpha: dark ? 0.34 : 0.40),
    // selection 用 tertiary：与 sasayaki(primary) 错开色相，查词高亮 ≠ 跟读高亮。
    selection: scheme.tertiary.withValues(alpha: dark ? 0.35 : 0.40),
    link: scheme.primary,
    dark: dark,
  );
}

/// 本 session 阅读字数推进结果：[charsAdded] 本次新计入的字数（>=0），
/// [highWaterMark] 更新后的「本 session 历史最高已读绝对字符位置」（只升不降）。
typedef ReadProgressResult = ({int charsAdded, int highWaterMark});

/// TODO-147 / BUG-211：把「本 session 阅读字数推进」算成相对历史最高已读位置
/// （high-water mark）的增量，而不是相邻两次采样的正向差。
///
/// 旧逻辑（错）：每次进度回调 `charDiff = absolute - last; if(charDiff>0) chars+=charDiff;
/// last = absolute;`——`last` 无条件下移。日语精读常见的「读一句→往回看→再往前」
/// 往返翻页会把重叠区间反复计入，统计字数随往返次数倍增，呈现「字数明显非常高」。
///
/// 新逻辑（对）：只有当前绝对位置 [absoluteChars] **超过本 session 历史最高位置**
/// [highWaterMark] 时，才把超出部分计入，并抬高水位；回退、以及再前进经过旧区间都
/// 不重复计数。水位「只升不降」消除了往返重复这个特殊情况（导航/flush 时由调用方把
/// 水位重置到新 session 起点）。
///
/// 纯函数，无副作用，供单测锁定 high-water mark 语义（撤销修复 → 测试转红）。
ReadProgressResult accumulateSessionChars({
  required int absoluteChars,
  required int highWaterMark,
}) {
  if (absoluteChars > highWaterMark) {
    return (
      charsAdded: absoluteChars - highWaterMark,
      highWaterMark: absoluteChars,
    );
  }
  return (charsAdded: 0, highWaterMark: highWaterMark);
}

/// TODO-796：图片/封面页（纯 `<img>`，全章无可读文本）的进度 UI 兜底锚点。
///
/// 这类页 `paginationMetrics.totalChars==0` → JS `hoshiProgressDetails()` 返空串
/// → `parseReaderStableProgressDetails` 返 null → `_refreshProgress` 旧逻辑一律早
/// 退，顶部百分比沿用上一章旧值（导航到封面进度不变 = BUG-796 之一）。封面/插图
/// 没有章内文本进度可言，但它在全书里有确定位置——用该章在累计前缀里的章首绝对
/// 字数作 current、全书总字数作 total，百分比就落到正确值（封面≈全书 0%）。
///
/// 入参是已落定的累计前缀 [cumulativeChars]（每章起始累计字数）和每章字数
/// [charCounts]；列表为空 / 越界 / 全书零字数（计数尚未算完）时返回 null，让调用方
/// 维持现状不写脏值。纯函数，无副作用，供单测锁定兜底语义。
({int currentChars, int totalChars})? imagePageProgressAnchor({
  required int chapterIndex,
  required List<int> cumulativeChars,
  required List<int> charCounts,
}) {
  if (cumulativeChars.isEmpty ||
      charCounts.isEmpty ||
      cumulativeChars.length != charCounts.length ||
      chapterIndex < 0 ||
      chapterIndex >= cumulativeChars.length) {
    return null;
  }
  final int total = cumulativeChars.last + charCounts.last;
  if (total <= 0) return null;
  return (currentChars: cumulativeChars[chapterIndex], totalChars: total);
}

/// BUG-213：章内原生滚动回传（`onReaderScroll`）到来时，是否应刷新章内进度。
///
/// 章内进度 UI 字段只在 `_refreshProgress()` 里写；原生滚动（连续模式 window 滚动、
/// 分页模式触摸/trackpad/键盘箭头）此前没有任何刷新通道，进度条要等 10s 轮询或翻章才
/// 更新。setup 脚本新增的 scroll reporter 把滚动回传给这里，但必须在以下时机一律抑制，
/// 避免恢复期程序化滚动、歌词模式或控制器未就绪时误触发：
/// - [restoreInFlight]：章节恢复/重载期间 WebView 正被程序化滚动到锚点；
/// - [lyricsMode]：歌词模式不是正文阅读，无章内进度语义；
/// - !`readerContentReady`：内容尚未就绪，`hoshiProgressDetails` 可能算不出总数；
/// - !`controllerAvailable`：WebView 控制器已释放（dispose 竞态）。
///
/// 纯函数，无副作用，供单测锁定门控真值表（撤销任一守卫 → 对应用例转红）。
bool readerScrollProgressRefreshAllowed({
  required bool readerContentReady,
  required bool restoreInFlight,
  required bool lyricsMode,
  required bool controllerAvailable,
}) {
  return readerContentReady &&
      !restoreInFlight &&
      !lyricsMode &&
      controllerAvailable;
}

/// TODO-693: appUiScale 缩放重锚（连续模式）的门控真值表纯函数。
///
/// 仅**连续模式**中招（裸 `window.scrollY` 无分页模式的 snap/lock 保护，缩放 reflow 把
/// scrollY 归 0 后无机制拉回 → 弹回章首），故 `continuousMode==false`（分页）一律抑制。
/// 其余门控对齐 [readerScrollProgressRefreshAllowed] / `_syncPageSize` / `_applyChromeInsets`：
/// 控制器释放 / 内容未就绪 / 歌词模式 / 恢复期都不触发（这些状态下 WebView 正被程序化
/// 操作或不可用，重锚会与之竞态或读到瞬态位置）。
bool readerUiScaleReanchorAllowed({
  required bool controllerAvailable,
  required bool readerContentReady,
  required bool lyricsMode,
  required bool restoreInFlight,
  required bool continuousMode,
}) {
  return controllerAvailable &&
      readerContentReady &&
      !lyricsMode &&
      !restoreInFlight &&
      continuousMode;
}

/// TODO-718: 退出再进的**恢复完成重锚**门控真值表纯函数（连续模式）。
///
/// 根因（同 TODO-693 家族，693 修「运行中改缩放」、718 修「首次进入恢复」）：连续模式
/// 阅读位置是裸 `window.scrollY`，恢复脚本（`restoreToCharOffset`/`restoreProgress`）把
/// 视口滚到锚点后**没有任何抗归零保护**。`_onRestoreComplete` 已置 `_restoreInFlight=false`、
/// `_readerContentReady=true`，随后进入 WebView settle reflow 把 scrollY 瞬时归 0 → 此时
/// `_handleReaderScroll` 门控（[readerScrollProgressRefreshAllowed]）已全放行 → `_refreshProgress`
/// 把 progress≈0 落库 → 章首，下次进入也章首。存/读对称、恢复脚本也被调，只是被 reflow 冲掉。
///
/// 与 [readerUiScaleReanchorAllowed] 的差异：本门控在 `_onRestoreComplete` 内、`_restoreInFlight`
/// **刚被置 false** 那一刻触发，是「恢复完成」语义而非「运行中」，故**不含** restoreInFlight
/// 早返回（复用 [readerUiScaleReanchorAllowed] 会因 restoreInFlight 历史语义产生纠缠/误抑制）。
/// 其余门控对齐：控制器释放 / 内容未就绪 / 歌词模式 / 分页模式（分页有 snap/lock 保护）都抑制。
bool readerRestoreReanchorAllowed({
  required bool controllerAvailable,
  required bool readerContentReady,
  required bool lyricsMode,
  required bool continuousMode,
}) {
  return controllerAvailable &&
      readerContentReady &&
      !lyricsMode &&
      continuousMode;
}

/// TODO-736 B-1: 样式变更（字号/字体/主题）两阶段重锚的门控真值表纯函数。
///
/// 与 [readerUiScaleReanchorAllowed] / [readerRestoreReanchorAllowed] 的差异：样式重锚
/// **两种排版模式都要**（分页与连续切字号/主题都会 reflow 漂移），故**不含** continuousMode
/// 限制。分页模式 begin 调到分页 shell 的 `getFirstVisibleCharOffset`（带 page-stable hint），
/// 连续模式调连续 shell 的版本（含 A-2 全文扫描兜底）；JS `typeof` 守卫使 pagination 未就绪
/// 时 begin 返回 -1，编排自然 no-op（裸 CSS 兜底已在 `_applyStylesLive` 先行套上）。
/// 其余门控对齐：控制器释放 / 内容未就绪 / 歌词模式（歌词走 `_updateLyricsStyleLive` 另一路）
/// 都抑制。不含 restoreInFlight——样式变更只在运行中由用户触发，恢复期 UI 不可达此路径。
bool readerStyleReanchorAllowed({
  required bool controllerAvailable,
  required bool readerContentReady,
  required bool lyricsMode,
}) {
  return controllerAvailable && readerContentReady && !lyricsMode;
}

/// TODO-736 B-3: 样式重锚 settle 尾沿去抖纯函数。
///
/// 样式变更（字号/字体/主题）的两阶段重锚在 commit 清旗那一刻打 [reanchorClearedAt]。
/// 此后几帧 WebView 仍在 settle reflow，其间自发的瞬态归零 scroll 会经
/// `_handleReaderScroll` 回传。本函数判定「现在是否仍在 commit 后的 settle 去抖窗口内」：
/// 是 → 调用方直接 return 不落库（不把 reflow 尾沿的瞬态滚动量当真实滚动）。
///
/// 窗口 250ms：覆盖单帧 postFrame commit 之后的 WebView2 reflow settle 尾巴（实测改字号
/// 的 reflow 在 commit 后约 2-4 帧内落定），又短到不吞掉用户随即的真实滚动。[reanchorClearedAt]
/// 为 null（从未样式重锚）恒返 false。与 B-4 [readerProgressDropIsSpurious] 判据正交、
/// 各自独立单测、禁互兜底（B-3 看时间窗、B-4 看突降+输入）。
bool readerScrollWithinReanchorSettle({
  required DateTime? reanchorClearedAt,
  required DateTime now,
  int settleMs = 250,
}) {
  if (reanchorClearedAt == null) return false;
  final int sinceMs = now.difference(reanchorClearedAt).inMilliseconds;
  return sinceMs >= 0 && sinceMs < settleMs;
}

/// TODO-693 / TODO-697 / TODO-718: 连续模式两阶段重锚的编排核心（运行时序列）。
///
/// 从 `_reanchorContinuousForUiScale` 抽出的可注入编排核心：把门控、阶段1 begin
/// 求值（错误早返回）、`intResult` 解析、`<0` 早返回（不提交、不误清旗）、postFrame
/// 调度、阶段2 commit 求值（错误吞掉）这条**真实运行时序列**收敛到一个 top-level 函数，
/// 用回调注入 WebView 求值 / postFrame 调度 / 存活复检 / 错误上报，使其能在 headless
/// `flutter_test` 下真执行（而非源码字符串扫描），锁住「先 begin 后 commit、begin<0 不
/// commit、门控抑制不求值」的语义不被未来回归静默破坏。
///
/// 门控由调用方算好布尔结果经 [gateAllowed] 注入（不再硬编码单一门控函数）：appUiScale
/// 缩放重锚走 [readerUiScaleReanchorAllowed]（运行中、含 `!restoreInFlight` 早返回），
/// 退出再进的恢复完成重锚（TODO-718）走 [readerRestoreReanchorAllowed]（在 `_onRestoreComplete`
/// 已置 `_restoreInFlight=false` 之后那一刻触发，语义上 restoreInFlight 必为 false，故该门控
/// 不含 restoreInFlight 早返回）。两条触发路径共用同一两阶段 begin→commit 序列与
/// `_reanchorPending` 串行旗，差异只在门控真值表。
///
/// 各回调含义：
/// - [evalBegin]：求值 `beginUiScaleReanchorInvocation`，返回原始 JS 结果（同步采锚+置旗）。
/// - [evalCommit]：求值 `commitUiScaleReanchorInvocation`（settle 后滚回+清旗）。
/// - [schedulePostFrame]：把 commit 调度到过渡帧 settle 之后（生产用 addPostFrameCallback）。
/// - [stillAlive]：复检 `mounted && _controller != null`，dispose 竞态时中止。
/// - [onBeginError] / [onCommitError]：阶段1/阶段2 求值异常上报（吞掉异常不外抛）。
///
/// 行为与原方法逐句等价；纯编排无 Flutter 依赖（postFrame 经回调注入）。
Future<void> runUiScaleReanchorOrchestration({
  required bool gateAllowed,
  required Future<dynamic> Function() evalBegin,
  required Future<void> Function() evalCommit,
  required void Function(void Function()) schedulePostFrame,
  required bool Function() stillAlive,
  required void Function(Object error, StackTrace stack) onBeginError,
  required void Function(Object error, StackTrace stack) onCommitError,
}) async {
  if (!gateAllowed) {
    return;
  }
  // 阶段 1：同步采样锚 + 置旗。必须先于过渡帧落地，使后续 reflow 归零 scroll 被
  // _reanchorPending 守卫挡在落库之外。
  dynamic begin;
  try {
    begin = await evalBegin();
  } catch (e, stack) {
    onBeginError(e, stack);
    return;
  }
  if (!stillAlive()) return;
  final int charOffset = ReaderPaginationScripts.intResult(begin) ?? -1;
  // -1 = 无可用锚（caretRangeFromPoint 失败）或已有重锚在飞（既有序列接管）→ 本次不
  // 提交，旗由对应入口的 finally 负责清，不在此误清。
  if (charOffset < 0) return;
  // 阶段 2：等过渡帧 settle 后提交滚动并清旗（沿用 _syncPageSize 的 postFrame settle）。
  schedulePostFrame(() async {
    if (!stillAlive()) return;
    try {
      await evalCommit();
    } catch (e, stack) {
      onCommitError(e, stack);
    }
  });
}

typedef ReaderStableProgressDetails = ({
  int current,
  int total,
  double progress,
  int charOffset,
});

/// Parses `window.hoshiProgressDetails()` after the JS-side settled gate.
///
/// A stable `0,total,0` is a valid chapter-start position (manual chapter
/// jumps must still persist it). `null`/empty/invalid/zero-total results mean
/// the reader has not settled enough to make a durable position decision.
ReaderStableProgressDetails? parseReaderStableProgressDetails(dynamic result) {
  if (result == null) return null;
  final String str = result.toString().replaceAll('"', '').trim();
  if (str.isEmpty) return null;

  final List<String> parts = str.split(',');
  if (parts.length < 2) return null;
  final int? current = int.tryParse(parts[0]);
  final int? total = int.tryParse(parts[1]);
  if (current == null || total == null || total <= 0) return null;

  final int charOffset =
      parts.length >= 3 ? (int.tryParse(parts[2]) ?? -1) : -1;
  return (
    current: current,
    total: total,
    progress: (current / total).clamp(0.0, 1.0).toDouble(),
    charOffset: charOffset,
  );
}

/// 解析结果 + 每章字符数，一次 isolate 往返同时算好，避免把整本书
/// （含全部章节 HTML）二次序列化进新 isolate 只为数字符。
class ParsedBookData {
  const ParsedBookData(this.book, this.charCounts);
  final EpubBook book;
  final List<int> charCounts;
}

/// 逐章纯文本长度。成功路径在解析 isolate 内调用；fallback 路径经 compute()
/// 调用（书已在内存，但仍放后台 isolate，避免在 UI 线程跑 html 解析）。
List<int> countChapterChars(EpubBook book) {
  return List<int>.generate(
    book.chapters.length,
    (int i) => book.chapterPlainText(i).length,
  );
}

/// 在单个 isolate 内解析 EPUB 并计算每章纯文本长度。供 compute() 调用，
/// 也可直接调用做等价性校验。
///
/// TODO-131: 冷开书的首屏不需要逐章字符数（只进度/统计要）。开书路径优先用
/// [parseBookOnly] 拿渲染必需结构、再用 [charCountsFromChaptersJson] 复用导入时
/// 已落库的计数，整本 html_parser 计数仅在 DB 计数缺失时经 [countChapterChars]
/// 后台补算。此函数保留给等价性测试与不复用 DB 的旧路径。
ParsedBookData parseAndCountChapters(String extractDir) {
  final EpubBook book = EpubParser.parseFromExtracted(extractDir);
  return ParsedBookData(book, countChapterChars(book));
}

/// TODO-131: 只解析渲染必需结构（章节 href / spine / 资源 / TOC / spread），不在
/// isolate 里逐章跑 html_parser 计数。供 compute() 调用——开书首屏走这条，把每章
/// 纯文本计数从「整本 isolate 计数」降到「只解析必要项」。
EpubBook parseBookOnly(String extractDir) {
  return EpubParser.parseFromExtracted(extractDir);
}

/// TODO-131: 从 [EpubBooks.chaptersJson]（导入时由 EpubImporter 写入的
/// `characters` 字段，值即 `chapterPlainText().length`）复用每章字符数，避免开书时
/// 对整本 EPUB 重跑 html_parser。
///
/// 仅当**每一章**都带合法非负 `characters` int、且条目数与 [expectedChapters]
/// 严格一致时返回计数列表；任一缺失/类型错误/数量不符返回 null，调用方回退到
/// 后台 [countChapterChars] 重算。这样旧书（导入早于该字段）与异常数据都安全降级，
/// 不会用错的总字数破坏进度/统计正确性。
List<int>? charCountsFromChaptersJson(
  String chaptersJson,
  int expectedChapters,
) {
  if (expectedChapters <= 0) return null;
  final Object? decoded;
  try {
    decoded = jsonDecode(chaptersJson);
  } on FormatException {
    return null;
  }
  if (decoded is! List || decoded.length != expectedChapters) return null;
  final List<int> counts = <int>[];
  for (final Object? entry in decoded) {
    if (entry is! Map) return null;
    final Object? raw = entry['characters'];
    if (raw is! int || raw < 0) return null;
    counts.add(raw);
  }
  return counts;
}

/// TODO-575 批1: 把 reader 里散落的 5 处 `rgba(...)` 生成统一成一个纯函数。
///
/// 契约对齐（零行为变化）：通道一律 `(channel * 255.0).round().clamp(0, 255)`
/// （`Color.r/g/b` 在 [0,1]，clamp 仅作安全网，对合法颜色与旧的歌词闭包/caret
/// 不 clamp 版逐字符等价）；alpha 默认用 `c.a.toStringAsFixed(2)`，调用方可经
/// [alphaOverride] 钉死成硬编码值（caret 焦点环 0.98、custom 高亮 0.34）。
String readerColorToCssRgba(Color c, {double? alphaOverride}) {
  final int r = (c.r * 255.0).round().clamp(0, 255);
  final int g = (c.g * 255.0).round().clamp(0, 255);
  final int b = (c.b * 255.0).round().clamp(0, 255);
  final double alpha = alphaOverride ?? c.a;
  return 'rgba($r,$g,$b,${alpha.toStringAsFixed(2)})';
}

/// TODO-575 批1: 自定义字体文件头魔数校验（从 [_ReaderHibikiPageState._isValidFontData]
/// 凿出的纯逻辑）。读前 4 字节大端拼成签名，命中字体容器魔数表才放行。
///
/// 命中表（与旧内联实现逐项一致）：TrueType `0x00010000` / OpenType-CFF `OTTO`
/// (`0x4F54544F`) / WOFF `wOFF` (`0x774F4646`) / WOFF2 `wOF2` (`0x774F4632`) /
/// TTC `ttcf` (`0x74746366`)。少于 4 字节直接拒。
bool isValidFontData(Uint8List data) {
  if (data.length < 4) return false;
  final int sig = (data[0] << 24) | (data[1] << 16) | (data[2] << 8) | data[3];
  return sig == 0x00010000 || // TrueType
      sig == 0x4F54544F || // OpenType CFF ("OTTO")
      sig == 0x774F4646 || // WOFF ("wOFF")
      sig == 0x774F4632 || // WOFF2 ("wOF2")
      sig == 0x74746366; // TTC ("ttcf")
}

/// TODO-575 批1: 全局字符偏移 → (章节索引, 章内进度) 的纯查表核心，从
/// [_ReaderHibikiPageState._jumpToGlobalCharOffset] 凿出（原函数保留 navigate/JS
/// IO 壳调它，不整体上移）。
///
/// - [cumulativeChars]：每章起始的累积字符数（`_chapterCumulativeChars`）。
/// - [charCounts]：每章字符数（`_chapterCharCounts`）。
/// - 找最后一个起始累积 `<= globalOffset` 的章作为目标章；用 `(offset - 章起始)
///   / 章长` 得章内进度，章长为 0 时进度 0；进度 clamp 到 [0,1]。
/// 与旧内联实现逐字节一致：空表返回 (0, 0)（调用壳另行处理空表早退）。
ChapterProgressTarget resolveChapterProgressForGlobalOffset(
  List<int> cumulativeChars,
  List<int> charCounts,
  int globalOffset,
) {
  if (cumulativeChars.isEmpty) {
    return const ChapterProgressTarget(chapter: 0, progress: 0.0);
  }
  int targetChapter = 0;
  for (int i = 0; i < cumulativeChars.length; i++) {
    if (cumulativeChars[i] <= globalOffset) {
      targetChapter = i;
    } else {
      break;
    }
  }
  final int chapterStart = cumulativeChars[targetChapter];
  final int chapterLen = charCounts[targetChapter];
  final double progress =
      chapterLen > 0 ? (globalOffset - chapterStart) / chapterLen : 0;
  return ChapterProgressTarget(
    chapter: targetChapter,
    progress: progress.clamp(0.0, 1.0),
  );
}

/// [resolveChapterProgressForGlobalOffset] 的结果：目标章节索引 + 已 clamp 到
/// [0,1] 的章内进度。
class ChapterProgressTarget {
  const ChapterProgressTarget({required this.chapter, required this.progress});
  final int chapter;
  final double progress;
}

/// TODO-131: 书本磁盘定位结果。`_locateBookOnDisk` 与 profile/settings 链并行返回，
/// `bookRow` 携带 chaptersJson（供 DB 计数复用）；`exists` 为 false 时调用方提示
/// 文件丢失并退出。
class _BookLocateResult {
  const _BookLocateResult({
    required this.bookRow,
    required this.extractDir,
    required this.exists,
  });
  final EpubBookRow? bookRow;
  final String extractDir;
  final bool exists;
}

class ReaderHibikiPage extends BaseSourcePage {
  const ReaderHibikiPage({
    required this.bookKey,
    super.item,
    this.initialBookmarkJump,
    super.key,
  });

  /// EpubBooks primary key (= sanitized title). Identifies the book across all
  /// reading data (positions, bookmarks, audiobook, profile).
  final String bookKey;
  final Bookmark? initialBookmarkJump;

  /// Debug-only hook for integration tests to evaluate JS inside the reader
  /// WebView. Set when the controller is created, cleared on dispose. Guarded
  /// by `assert` so it is tree-shaken out of release builds.
  ///
  /// Assumes a single live reader at a time (the normal case — the reader is a
  /// full-screen route). The reentrancy `assert` in [onWebViewCreated] fires in
  /// debug if a second reader is created before the first disposes.
  @visibleForTesting
  static Future<dynamic> Function(String source)? debugEvaluateJavascript;

  /// Test hook: reports which surface the char cursor lives on
  /// (`none`/`reader`/`popup`). Set in build, cleared on dispose, asserted out of
  /// release builds. Lets integration tests observe the cursor↔popup transfer.
  @visibleForTesting
  static String Function()? debugCaretSurface;

  /// Test hook: evaluate JS on the top visible dictionary popup (resolved via
  /// `topPopupState`, the same path production uses). Null when no popup is up.
  @visibleForTesting
  static Future<dynamic> Function(String source)? debugEvaluateTopPopup;

  /// Test hook: inject the real audiobook bridge JS (`__hoshiHighlight`,
  /// image-pause helpers, sasayaki highlight) on demand. Lets integration tests
  /// drive the production highlight / image-pause reveal path on a plain
  /// (non-audiobook) book in the real paginated WebView, without seeding a full
  /// audiobook. Set in build, cleared on dispose.
  @visibleForTesting
  static Future<void> Function()? debugInjectAudiobookBridge;

  @override
  BaseSourcePageState<ReaderHibikiPage> createState() =>
      _ReaderHibikiPageState();
}

class _ReaderHibikiPageState extends BaseSourcePageState<ReaderHibikiPage>
    with WidgetsBindingObserver
    implements ReaderAudiobookView, DictionaryCaretHost {
  InAppWebViewController? _controller;

  /// GlobalKey on the reader [InAppWebView] so its [RenderBox] can map a global
  /// pointer position into the WebView's local (== CSS viewport) coordinate
  /// space — see [onDismissBarrierHover] (TODO-806). The WebView is inset within
  /// the page Stack by the chrome insets, so a position relative to the
  /// full-screen dismiss barrier is NOT the WebView's local coordinate.
  final GlobalKey _webViewKey = GlobalKey(debugLabel: 'reader_webview');
  EpubBook? _book;
  EpubSpreadMap? _spreadMap;
  ReaderSettings? _settings;
  String? _extractDir;

  /// 库内 part 文件（extension）改状态的入口：扩展不被视作 State 子类实例成员，
  /// 直接调 @protected 的 setState 会报 invalid_use_of_protected_member。由本 State
  /// 子类持有的这个转发器统一承接，零行为变化（仅转发）。
  void _rebuild(VoidCallback fn) => setState(fn);

  /// 同 [_rebuild] 的理由：part 扩展不被视作 State 子类实例成员，直接读写
  /// `BaseSourcePageState` 的 @protected 弹窗栈成员会报 invalid_use_of_protected_member。
  /// 由本 State 子类持有的下面三个转发器统一承接（仅转发，零行为变化），供 caret
  /// part 调用。
  DictionaryPopupWebViewState? get _caretTopPopupState => topPopupState;

  int get _caretTopVisiblePopupIndex => topVisiblePopupIndex;

  void _caretDismissTopPopup() => dismissTopPopup();

  /// 同 [_caretTopPopupState] / [_rebuild] 的理由：webview part 扩展不能直接调用
  /// `BaseSourcePageState` 的 @protected 弹窗栈成员（`prunePopupStack` /
  /// `topPopupState`，会报 invalid_use_of_protected_member）。由本 State 子类持有
  /// 这两个转发器统一承接（仅转发，零行为变化），供 [_buildWebView] 调用。
  void _webviewPrunePopupStack(int keepCount) => prunePopupStack(keepCount);

  DictionaryPopupWebViewState? get _webviewTopPopupState => topPopupState;

  // BUG-099: true for right-to-left reading (vertical-rl, the Japanese default),
  // which flips the bare Left/Right arrow page-turn direction.
  bool get _isRtlReading =>
      (_settings?.writingMode ?? 'vertical-rl') == 'vertical-rl';

  int _currentChapter = 0;
  bool _readerContentReady = false;
  bool _hasEverLoaded = false;
  bool _restoreInFlight = false;
  bool _isNavigatingToChapter = false;
  double _initialProgress = 0;
  // BUG-162: 退出再进的精确恢复锚（section 内绝对字符偏移）。-1 = 无精确锚（旧
  // 存档 / 书签跳转）→ 走粗粒度 restoreProgress 分数。
  int _initialCharOffset = -1;
  // _refreshProgress 算得的最新精确字符偏移，供退出 flush 与 debounce 保存共用。
  int _lastProgressCharOffset = -1;
  String? _initialFragment;

  double _stableTopInset = 0;
  double _stableBottomInset = 0;

  /// 底栏内容行的自然（未缩放）高度。
  static const double _readerChromeBaseHeight = 56;

  /// 查词弹窗顶部四按钮栏的自然（未缩放）高度。
  static const double _readerPopupHeaderBaseHeight = 48;

  /// 阅读器底栏的隐形界面缩放系数：取自全局 appUiScale（阅读器子树被中和器改写成
  /// 1.0，故不能用 HibikiAppUiScale.of）。在 build 里读 appModel 会随缩放变化重建。
  double get _readerChromeScale => appModel.appUiScale;

  /// 图片右键菜单由 Flutter PopupMenuRoute 承载，不在阅读器中和后的 chrome 子树内。
  /// 所以这里复用 reader chrome 的用户界面缩放口径，且只缩放菜单自身，不改鼠标锚点。
  double get _readerImageMenuScale =>
      HibikiAppUiScale.normalize(_readerChromeScale);

  /// 缩放后底栏在屏高度。所有把底栏高度喂给 WebView/光标/焦点环/正文预留的地方都
  /// 走这个 getter，保证视觉高度与预留高度恒等。
  double get _readerChromeHeight => ReaderChromeScaler.scaledHeight(
      _readerChromeBaseHeight, _readerChromeScale);
  static const double _infoFontSize = 12;

  int? _progressCurrentChars;
  int? _progressTotalChars;

  int _sessionCharsRead = 0;
  // TODO-147 / BUG-211：本 session 历史最高已读绝对字符位置（high-water mark，
  // 只升不降）。统计字数只在越过它时增量计入，往返翻页不重复累计。导航/后台
  // flush 起新 session 时由调用方重置到当前位置。
  int _sessionMaxAbsoluteChars = 0;
  DateTime _sessionStartTime = DateTime.now();

  List<int> _chapterCharCounts = [];
  List<int> _chapterCumulativeChars = [];

  final Map<String, Uint8List> _sanitizedCssCache = {};

  // BUG-270 (TODO-296 B): cross-chapter LRU cache of fully sanitized + style-
  // injected chapter HTML, keyed by absolute file path. The styleTag is baked
  // into each cached entry, so the cache MUST be dropped on every style
  // invalidation (see _invalidateStyleCache). Forward/back paging and prefetch
  // both hit this cache, turning a repeat chapter visit into an in-memory map
  // lookup instead of disk read + utf8 decode + sanitize + regex inject.
  static const int _kChapterHtmlCacheLimit = 6;
  final LinkedHashMap<String, Uint8List> _sanitizedHtmlCache =
      LinkedHashMap<String, Uint8List>();

  // BUG-270: in-flight prefetch dedup — the file path currently being warmed in
  // the background, so a navigation that lands on it does not race a second read.
  String? _prefetchingHtmlPath;

  String? _cachedStyleTag;

  Timer? _saveDebounce;

  /// 进程退出 flush 回调引用（TODO-086/BUG-191）：initState 登记到
  /// [ExitFlushRegistry]，dispose 注销。退出路径统一 await，保证未到 debounce
  /// 的阅读位置/统计在 exit(0) 前落库。
  ExitFlushCallback? _exitFlushCallback;
  Timer? _progressPollTimer;
  // BUG-380: 滚动进度刷新的「在飞 + 待重跑」守卫。rAF 节流后滚动回传可能高频到来，
  // 每次 _refreshProgress 都 evaluateJavascript 跑较重的 hoshiProgressDetails（遍历全章
  // TextNode + caretRangeFromPoint），未加守卫会让多次调用堆积。_scrollProgressInFlight
  // 标记当前是否有一次滚动触发的刷新在途；在途时再来的滚动回传只置 _scrollProgressPending，
  // 飞完后补跑一次（coalesce），既不堆积又不丢最终位置。仅作用于滚动路径，不影响 10s 轮询
  // 与翻章恢复直接调 _refreshProgress。
  bool _scrollProgressInFlight = false;
  bool _scrollProgressPending = false;
  // 卡死修复：滚动触发的进度重算加时间节流（对齐 hoshi 安卓 CONTINUOUS_PROGRESS_THROTTLE_MS
  // = 50ms）。原本只有「在飞/pending」coalesce，一完成就背靠背补跑 calculateProgress（遍历整章
  // 15 万字 DOM）→ 鼠标拖动/连续滚动每秒上百次回传把 WebView JS 线程占满 → 卡死。
  DateTime? _lastScrollProgressAt;
  // TODO-736 B-3：样式重锚 commit 清旗那一刻的时间戳。_handleReaderScroll 进门若距此
  // 250ms 内（reflow settle 尾沿 scroll），直接 return 不落库——治改字号/主题 reflow 的
  // settle 尾沿把瞬态滚动量当真实滚动落库。与 B-4 判据正交、各自独立单测、禁互兜底。
  DateTime? _reanchorClearedAt;
  Timer? _scrollProgressThrottleTimer;
  Timer? _contentReadyTimer;
  Timer? _gamepadAHoldTimer;
  // HBK-AUDIT-120: volume-key throttle uses a last-fire timestamp instead of an
  // empty-callback Timer. The old timer-as-flag pattern obscured intent and left
  // a stale timer gating the next press after a speed-setting change.
  DateTime? _lastVolumeKeyTime;
  // TODO-737: 翻页输入节流闸门的统一时间戳——滚轮(onWheelPaginate→_paginate)、音量键
  // (_onVolumeKey→_paginate)、连续滚轮跨章(onBoundarySwipe handler)共用此一字段，
  // 时间戳语义（读 throttleMs 即生效，无残留 timer）。删了 JS _wheelTimer 双处后，
  // 这是滚轮/音量键翻页的唯一节流真相源。
  DateTime? _lastPaginateTime;
  int _lastSavedSection = -1;
  double _lastSavedProgress = -1;
  int _lastProgressSection = -1;
  double _lastProgressValue = 0;

  AudiobookPlayerController? _audiobookController;
  String? _audiobookBookKey;
  String? _srtBookUid;
  Map<int, int>? _srtCueChapterMap;
  List<(int firstIdx, int lastIdx)>? _srtChapterRanges;

  bool _audioSlotResolved = false;
  List<FavoriteSentence>? _favoriteSentencesForBookCache;
  Future<List<FavoriteSentence>>? _favoriteSentencesForBookFuture;

  bool _lyricsMode = false;
  bool _lyricsModeTransition = false;
  bool _gamepadALongFired = false;
  // 重入守卫：「调整」面板从点击到 show 之间有 DB 读 await，快速连点会二次进入并
  // 弹出两个面板（BUG-026）。打开期间置 true、关闭后于 finally 复位。
  bool _appearanceSheetOpen = false;

  bool _lyricsPageReady = false;
  int _lyricsEntryChapter = 0;
  int _lyricsEntryCueIndex = 0;
  List<AudioCue> _lyricsCueList = const [];

  bool _pausedForLookup = false;

  ReadingTimeTracker? _readingTimeTracker;

  // TODO-291 阶段2：audioHandler 控制流（play/seek/skip/悬浮字幕翻转）订阅已上移到
  // [AudiobookSession]（进程级），reader 不再持有这些订阅。

  bool _showChrome = true;
  // TODO-728: true when the chrome was hidden BY the gamepad-present auto-immersive
  // path (not by the user). Used so that losing the controller restores the
  // chrome ONLY if the gamepad hid it; a manual toggle clears this flag and takes
  // ownership (a later controller-gone event then does not fight the user).
  bool _chromeHiddenByGamepad = false;
  double _lastSyncedWidth = 0;
  double _lastSyncedHeight = 0;
  // TODO-690 / BUG-399：桌面拖窗口边框 resize 的尾沿防抖。阅读器树内的透明
  // LayoutBuilder 在每帧约束变化时比对基线（readerLayoutResizeNeedsRepaginate），
  // 超阈值就（取消旧 timer）起一个短 timer，拖拽停手后最终尺寸落一次 _syncPageSize
  // 重排。不在 builder 里 Future.delayed（会泄漏 / 重入）；timer 在 dispose 取消。
  Timer? _resizeRepaginateDebounce;
  // 上次喂给防抖判定的布局约束尺寸（与 _lastSyncedWidth/Height 同坐标空间，但这条
  // 跟踪「约束」而非「已分页基线」，避免同一尺寸的多帧重复起 timer）。
  double _lastConstraintWidth = 0;
  double _lastConstraintHeight = 0;
  // BUG-111: 记录最近一次 setup 脚本注入 JS 时实际用作 dartPageWidth/Height 的尺寸
  // （= 当时 MediaQuery 读到的视口）。content-ready 后必须用它作为「已分页基线」喂给
  // _syncPageSize，而不是用 content-ready 那一刻的当前 MediaQuery——否则初始重排校验
  // 永远 no-op（见 _onRestoreComplete）。界面缩放(scale!=1.0)未 settle 时初始分页宽度
  // 会偏窄，靠这条基线让 content-ready 后的 _syncPageSize 检出差异并重排。
  double _paginatedWidth = 0;
  double _paginatedHeight = 0;

  final FocusNode _focusNode = FocusNode();

  // Focus scope for the bottom chrome (settings/audiobook bar). When a chrome
  // control holds focus, directional keys must traverse the chrome instead of
  // turning the page — gated in [_handleKeyEvent] via this scope's [hasFocus].
  // This intentionally keys off chrome focus (not root focus) so page-turn keys
  // keep working after a tap lands focus inside the WebView (HBK #1).
  final FocusScopeNode _chromeFocusScope =
      FocusScopeNode(debugLabel: 'readerChrome');

  // The dictionary popup's Flutter header toolbar (favourite / replay / play /
  // play-from-cue) is a sibling layer of the popup WebView content, reached by
  // Up at the top of the content — exactly like the reader bottom bar relative
  // to the reading content. Its own scope so focus can move into it and back.
  final FocusScopeNode _popupHeaderScope =
      FocusScopeNode(debugLabel: 'popupHeader');

  // The char-level dictionary reading-cursor state machine, owned by the shared
  // [DictionaryCaretController] (TODO-387) so video / home / standalone-window
  // surfaces can reuse it. This page is its [DictionaryCaretHost]: the controller
  // owns the surface / popup-state / busy fields and the popup-surface
  // transitions, while the reader keeps its reader/lyrics JS branches, keyboard
  // routing and the focus sandwich. The thin `_caret*` accessors below delegate
  // straight to the controller so every existing call site (and the source-scan
  // guards) keeps the same behaviour — only the ownership moved.
  late final DictionaryCaretController _caret = DictionaryCaretController(this);

  // Which surface holds the char-level reading cursor (a focused character inside
  // a WebView's DOM, driven from JS via [ReaderCaretScripts]). The cursor lives
  // on the reader content, or — after a lookup — on the top dictionary popup, and
  // follows the popup stack as the user goes deeper / backs out. While active,
  // A/Enter looks up the word at the cursor, B/Esc backs out a layer, and
  // directional keys / Tab step the cursor. Backed by [_caret].
  CaretSurface get _caretSurface => _caret.surface;
  set _caretSurface(CaretSurface value) => _caret.surface = value;

  bool get _caretActive => _caret.active;
  bool get _caretOnReader => _caret.onReader;
  bool get _caretOnLyrics => _caret.onLyrics;

  // The WebView char caret and focus-layer hops are part of the experimental
  // keyboard/gamepad focus navigation system. Page-turn and media shortcuts stay
  // active when the switch is off.
  bool get _focusNavEnabled => appModel.experimentalFocusNavigationEnabled;

  // Serializes the cursor's async JS operations. A gamepad D-pad auto-repeats
  // ~9×/s and a move that turns the page (move → _paginate → reanchor) round-
  // trips slower than that, so overlapping calls would evaluate against a mid-
  // pagination DOM and make the cursor jump. New directional input is dropped
  // while an op is in flight; the next auto-repeat tick moves instead.
  // Backed by [_caret].
  bool get _caretBusy => _caret.busy;
  set _caretBusy(bool value) => _caret.busy = value;

  bool get _showTopProgress =>
      _readerContentReady &&
      _progressCurrentChars != null &&
      _progressTotalChars != null &&
      _progressTotalChars! > 0 &&
      ReaderHibikiSource.instance.showTopProgressBar;

  double get _readerTopOffset => _stableTopInset + _infoFontSize * 1.5;

  double get _readerBottomReserve => _readerChromeHeight + _stableBottomInset;

  @override
  double get popupBottomReserve =>
      // 与 _buildBottomChrome 的可见条件保持一致：底栏占位 ⟺ 弹窗预留底部空间，
      // 否则切章期间底栏可见但预留为 0，弹窗可能被底栏遮挡。
      (_hasEverLoaded && _showChrome) ? _readerBottomReserve : 0;

  @override
  double get popupTopReserve => _stableTopInset;

  @override
  bool get popupVerticalWriting =>
      !_lyricsMode && (_settings?.writingMode.startsWith('vertical') ?? false);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _exitFlushCallback =
        ExitFlushRegistry.instance.register(_flushAllForProcessExit);
    // The inset reading-content focus ring only paints in traditional
    // (keyboard/gamepad) highlight mode; rebuild it when the mode flips so it
    // appears/disappears with the input device, not only on focus changes.
    FocusManager.instance.addHighlightModeListener(_onHighlightModeChanged);
    ReaderHibikiSource.onSettingsChangedLive = () {
      if (!mounted) return;
      // fire-and-forget 必须 catchError：否则 await 边界之后的异步异常（如
      // WebView 半销毁时 evaluateJavascript 抛 PlatformException）会逃进当前
      // zone，绕过 FlutterError.onError/takeException/platformDispatcher，
      // 生产里成未捕获异步错误、测试里让 binding 断言。
      unawaited(_applyStylesLive().catchError((Object e, StackTrace s) {
        ErrorLogService.instance
            .log('ReaderHibiki.onSettingsChangedLive', e, s);
      }));
      setState(() {});
    };
    ReaderHibikiSource.onLayoutReloadLive = () {
      if (!mounted) return;
      unawaited(
          _reloadWithCurrentSettings().catchError((Object e, StackTrace s) {
        ErrorLogService.instance.log('ReaderHibiki.onLayoutReloadLive', e, s);
      }));
    };
    // 纯 Flutter chrome 布局变化（如反转底栏）只需重建一次重读偏好，
    // 不动 WebView 内容、不重锚、不重排分页。
    ReaderHibikiSource.onChromeReloadLive = () {
      if (!mounted) return;
      setState(() {});
    };
    // TODO-728: controller presence changes drive the reader's auto-immersive
    // mode. The AppModel bridge already gates on gamepadAutoImmersive, so this
    // only fires when the user opted in.
    ReaderHibikiSource.onGamepadPresenceChanged = (bool present) {
      if (!mounted) return;
      _applyGamepadPresence(present);
    };
    _initBook();
  }

  Future<void> _initBook() async {
    final HibikiDatabase db = appModelNoUpdate.database;

    // TODO-131: profile→settings 链与 book 定位→解析链互不依赖（前者动
    // ReaderHibikiSource.readerSettings / active profile，后者动 _book / _extractDir），
    // 并行起跑把 profile/settings 的 DB 往返与 EPUB 解析 isolate 重叠，缩短白屏。
    final Future<void> profileSettingsFuture = _resolveProfileAndSettings(db);
    final Future<_BookLocateResult> bookLocateFuture = _locateBookOnDisk(db);

    await profileSettingsFuture;
    if (!mounted) return;
    _settings = ReaderHibikiSource.readerSettings;

    final _BookLocateResult located = await bookLocateFuture;
    if (!mounted) return;
    if (!located.exists) {
      debugPrint('[ReaderHibiki] book ${widget.bookKey} not found on disk');
      HibikiToast.show(msg: t.book_file_not_found);
      Navigator.of(context).pop();
      return;
    }

    final EpubBookRow? bookRow = located.bookRow;
    final String extractDir = located.extractDir;
    _extractDir = extractDir;

    // TODO-131: charsFromDb 命中 = 跳过整本 html_parser 计数（导入时已落库）。
    // 缺失（旧书 / 异常）时为 null → 后台 compute 补算，首屏不阻塞。
    List<int>? charsFromDb;
    try {
      _book = await compute(parseBookOnly, extractDir);
      debugPrint(
          '[ReaderHibiki] parsed EPUB: ${_book!.chapters.length} chapters');
      if (bookRow != null) {
        charsFromDb = charCountsFromChaptersJson(
            bookRow.chaptersJson, _book!.chapters.length);
      }
    } on FormatException catch (e) {
      debugPrint('[ReaderHibiki] EPUB parse failed ($e), trying DB metadata');
      _book = await _buildBookFromDb(db, widget.bookKey, extractDir);
      if (!mounted) return;
      _book ??= _buildLegacyBook(extractDir);
      if (bookRow != null) {
        charsFromDb = charCountsFromChaptersJson(
            bookRow.chaptersJson, _book!.chapters.length);
      }
      if (!mounted) return;
      HibikiToast.show(msg: t.epub_parse_fallback);
    }

    final List<String> hrefs = _book!.chapters.map((ch) => ch.href).toList();
    debugPrint('[ReaderHibiki] chapter hrefs: $hrefs');

    if (charsFromDb != null) {
      _applyCharCounts(charsFromDb);
    } else {
      // DB 计数不可用：以零计数占位（所有消费点已 >0 / empty 守卫，进度回退 JS
      // total、统计暂累 0），同时后台 isolate 重算整本，落定后 _applyCharCounts
      // 补齐 totalChars 并重置统计基准，保证最终进度/统计字数等价、不丢字数。
      _applyCharCounts(
          List<int>.filled(_book!.chapters.length, 0, growable: false));
      _recomputeCharCountsInBackground();
    }

    // TODO-131: spread map 与 audio slot 互不依赖（前者写 _spreadMap/_edgeMatchResults，
    // 后者写 _audiobookController，都只读已就绪的 _book），并行等待两组 DB 往返。
    await Future.wait(<Future<void>>[
      _initSpreadMap(appModelNoUpdate.database),
      _resolveAudioSlot(),
    ]);
    if (!mounted) return;

    final Bookmark? bm = widget.initialBookmarkJump;
    if (bm != null &&
        bm.sectionIndex >= 0 &&
        bm.sectionIndex < _book!.chapters.length) {
      _currentChapter = bm.sectionIndex;
      _initialProgress = bm.normCharOffset / 10000.0;
      _initialCharOffset = -1; // BUG-162: 书签按 normCharOffset 分数跳转，非 char 锚。
      _lastProgressSection = _currentChapter;
      _lastProgressValue = _initialProgress;
      debugPrint('[ReaderHibiki] restore from bookmark: '
          'chapter=$_currentChapter progress=$_initialProgress');
    } else {
      final ReaderPositionRepository repo = ReaderPositionRepository(db);
      final ReaderPosition? saved = await repo.findByBookKey(widget.bookKey);
      if (!mounted) return;
      debugPrint('[ReaderHibiki] restore lookup: bookKey=${widget.bookKey} '
          'saved=$saved section=${saved?.sectionIndex} '
          'offset=${saved?.normCharOffset}');
      if (saved != null &&
          saved.sectionIndex >= 0 &&
          saved.sectionIndex < _book!.chapters.length) {
        _currentChapter = saved.sectionIndex;
        _initialProgress = saved.normCharOffset / 10000.0;
        // BUG-162: 有精确锚就用它（restoreToCharOffset 不动点），否则 -1 回退分数。
        _initialCharOffset = saved.charOffset ?? -1;
        _lastProgressSection = _currentChapter;
        _lastProgressValue = _initialProgress;
        _lastProgressCharOffset = _initialCharOffset;
      } else {
        _restoreFromCurrentAudioCue();
      }
    }

    if (_settings!.keepScreenAwake) {
      try {
        WakelockPlus.enable();
      } catch (e) {
        debugPrint('[Hibiki] wakelock enable failed: $e');
      }
    }

    final ReaderHibikiSource src = ReaderHibikiSource.instance;
    if (src.volumePageTurningEnabled) {
      _setupVolumeKeyHandlers();
    }

    _syncDictionaryTheme();

    final bool savedLyricsMode =
        _audiobookController != null && ReaderHibikiSource.instance.lyricsMode;
    _lyricsMode = savedLyricsMode;
    if (!savedLyricsMode) {
      await ReaderHibikiSource.instance.setLyricsMode(false);
      if (!mounted) return;
    }

    _audioSlotResolved = true;

    setState(() {});
  }

  /// TODO-131: 按 bookKey 查 EpubBooks 行 + 校验磁盘目录存在。与 profile/settings
  /// 链并行起跑；`chaptersJson` 随行带回，供 [charCountsFromChaptersJson] 复用计数。
  Future<_BookLocateResult> _locateBookOnDisk(HibikiDatabase db) async {
    // Locate the book on disk by its stored extract_dir column (the on-disk
    // folder name may still be a legacy int id; the column is the truth).
    final EpubBookRow? bookRow = await db.getEpubBook(widget.bookKey);
    final String extractDir = bookRow?.extractDir ?? '';
    final bool exists = await EpubStorage.bookDirExists(extractDir);
    return _BookLocateResult(
      bookRow: bookRow,
      extractDir: extractDir,
      exists: exists,
    );
  }

  /// TODO-131: 落定每章字符数并重建累计前缀 + 刷新进度条总字数。开书时与延后重算
  /// 完成时共用。空/零计数也安全（消费点 >0 守卫），延后重算落定后再调一次补齐。
  void _applyCharCounts(List<int> counts) {
    _chapterCharCounts = counts;
    int cumulative = 0;
    _chapterCumulativeChars = <int>[];
    for (final int count in counts) {
      _chapterCumulativeChars.add(cumulative);
      cumulative += count;
    }
    if (mounted) {
      final int newTotal = _chapterCumulativeChars.isNotEmpty
          ? _chapterCumulativeChars.last + _chapterCharCounts.last
          : 0;
      if (newTotal > 0 && _progressTotalChars != newTotal) {
        setState(() {
          _progressTotalChars = newTotal;
        });
      }
    }
  }

  /// TODO-131: DB 计数缺失（旧书 / chaptersJson 无 characters 字段）时，把整本
  /// html_parser 逐章计数放后台 isolate 补算，**不阻塞首屏**。落定后用
  /// [_applyCharCounts] 补齐总字数，并把统计水位 `_sessionMaxAbsoluteChars` 重置到
  /// 当前位置——否则零计数期间它停在 0，计数落定后首个进度回调会把整段前缀误当本次
  /// 读到的新字数（幻象 spike）。重置后增量相对正确基准，统计字数等价。
  void _recomputeCharCountsInBackground() {
    final EpubBook? book = _book;
    if (book == null || book.chapters.isEmpty) return;
    unawaited(compute(countChapterChars, book).then((List<int> counts) {
      // 书可能在重算期间被换（重载 / 退出）；仅当仍是同一本、长度一致才采用。
      if (!mounted ||
          !identical(_book, book) ||
          counts.length != book.chapters.length) {
        return;
      }
      _applyCharCounts(counts);
      _sessionMaxAbsoluteChars = _absoluteCharPosition(_lastProgressValue);
    }).catchError((Object e, StackTrace s) {
      ErrorLogService.instance
          .log('ReaderHibiki._recomputeCharCountsInBackground', e, s);
    }));
  }

  Future<EpubBook?> _buildBookFromDb(
    HibikiDatabase db,
    String bookKey,
    String extractDir,
  ) async {
    final EpubBookRow? row = await db.getEpubBook(bookKey);
    if (row == null) return null;

    final List<dynamic> rawChapters =
        jsonDecode(row.chaptersJson) as List<dynamic>;
    if (rawChapters.isEmpty) return null;

    final List<EpubChapter> chapters = <EpubChapter>[];
    for (int i = 0; i < rawChapters.length; i++) {
      final Map<String, dynamic> ch = rawChapters[i] as Map<String, dynamic>;
      final String href = ch['href'] as String;
      final File file = File(p.join(extractDir, href));
      final String html = file.existsSync() ? file.readAsStringSync() : '';
      chapters.add(EpubChapter(
        id: ch['id'] as String? ?? 'section-$i',
        href: href,
        mediaType: ch['mediaType'] as String? ?? 'text/html',
        html: html,
        spineIndex: i,
      ));
    }

    List<EpubTocItem> toc = const <EpubTocItem>[];
    if (row.tocJson != null) {
      final List<dynamic> rawToc = jsonDecode(row.tocJson!) as List<dynamic>;
      toc = rawToc.map((dynamic e) {
        final Map<String, dynamic> item = e as Map<String, dynamic>;
        return EpubTocItem(
          label: item['title'] as String? ?? '',
          href: item['href'] as String?,
        );
      }).toList();
    }

    debugPrint('[ReaderHibiki] built from DB: ${chapters.length} chapters, '
        '${toc.length} toc entries');

    return EpubBook(
      title: row.title,
      author: row.author,
      chapters: chapters,
      toc: toc,
      rootDirectory: extractDir,
    );
  }

  EpubBook _buildLegacyBook(String extractDir) {
    final List<FileSystemEntity> htmlFiles =
        Directory(extractDir).listSync(recursive: true).where((e) {
      if (e is! File) return false;
      final String ext = p.extension(e.path).toLowerCase();
      return ext == '.html' || ext == '.xhtml' || ext == '.htm';
    }).toList()
          ..sort((a, b) => compareAudioFilePath(a.path, b.path));

    final List<EpubChapter> chapters = <EpubChapter>[];
    for (int i = 0; i < htmlFiles.length; i++) {
      final File f = htmlFiles[i] as File;
      chapters.add(EpubChapter(
        id: 'section-$i',
        href: p.relative(f.path, from: extractDir).replaceAll('\\', '/'),
        mediaType: 'text/html',
        html: f.readAsStringSync(),
        spineIndex: i,
      ));
    }

    return EpubBook(
      title: t.untitled_book(id: widget.bookKey),
      chapters: chapters,
      rootDirectory: extractDir,
    );
  }

  @override
  void dispose() {
    assert(() {
      ReaderHibikiPage.debugEvaluateJavascript = null;
      ReaderHibikiPage.debugCaretSurface = null;
      ReaderHibikiPage.debugEvaluateTopPopup = null;
      ReaderHibikiPage.debugInjectAudiobookBridge = null;
      return true;
    }());
    ReaderHibikiSource.onSettingsChangedLive = null;
    ReaderHibikiSource.onLayoutReloadLive = null;
    ReaderHibikiSource.onChromeReloadLive = null;
    ReaderHibikiSource.onGamepadPresenceChanged = null;
    FocusManager.instance.removeHighlightModeListener(_onHighlightModeChanged);
    final ExitFlushCallback? exitFlush = _exitFlushCallback;
    if (exitFlush != null) {
      ExitFlushRegistry.instance.unregister(exitFlush);
      _exitFlushCallback = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    _progressPollTimer?.cancel();
    _saveDebounce?.cancel();
    _scrollProgressThrottleTimer?.cancel();
    _contentReadyTimer?.cancel();
    _resizeRepaginateDebounce?.cancel();
    _clearGamepadAHold();
    VolumeKeyChannel.instance.setHandlers();
    VolumeKeyChannel.instance.setInterceptEnabled(false);
    appModel.setOverrideDictionaryTheme(null);
    appModel.setOverrideDictionaryColor(null);
    // HBK-AUDIT-122: shared sync-then-flush (also used by lifecycle handler).
    // 必须在 detachReader 之前：flush 读的是 _audiobookController（= session 控制器），
    // detach 不 dispose 控制器，但这里先把退出那一刻的位置写穿（BUG-203/032）。
    _syncAndFlushPosition();
    _flushReadingStats();
    // TODO-702：有声书退出即停（默认）/ 后台续播（可选）。
    // 两种情况都先 detachReader——卸下本 reader 的 WebView 侧回调（跨章/边界跳句
    // 退化为安全无操作），不 dispose 控制器；上面的 [_syncAndFlushPosition] 已把
    // 退出那一刻的位置写穿，控制器侧另有 force-flush 兜底（stopPlayback /
    // dispose），位置安全。
    //
    // - 默认（audiobookBackgroundPlay=false）：detach 后再 [AudiobookSession.stop]
    //   真正止声、释放 native 解码器、清悬浮窗/通知。stop 是 async，dispose 同步
    //   签名只能 fire-and-forget（unawaited）；但 stop 的同步首段已立刻置空
    //   `_controller`（audiobook_session.dart），秒重进的竞态窗口收敛到微任务级。
    // - 开启（=true）：只 detachReader，控制器留在 [AudiobookSession] 进程级常驻
    //   持有者里继续后台播放（保 TODO-291 阶段2 的后台续播）。
    appModel.audiobookSession.detachReader(this);
    if (!appModel.audiobookBackgroundPlay) {
      // fire-and-forget 必须 catchError：dispose 同步签名无法 await，stop 内
      // stopPlayback 在 await 边界后若抛平台异常（native 解码器半销毁），会逃进
      // 当前 zone 成未捕获异步错误。与本文件其它 unawaited future 惯例对齐。
      unawaited(
          appModel.audiobookSession.stop().catchError((Object e, StackTrace s) {
        ErrorLogService.instance.log('ReaderHibiki.disposeStopAudiobook', e, s);
      }));
    }
    _readingTimeTracker?.dispose();
    _focusNode.dispose();
    _chromeFocusScope.dispose();
    _popupHeaderScope.dispose();
    try {
      WakelockPlus.disable();
    } catch (e) {
      debugPrint('[Hibiki] wakelock disable failed: $e');
    }
    super.dispose();
  }

  /// BUG-203：返回书架前，先把 WebView 当前显示页落库，再交回基类走
  /// closeMedia / triggerAutoSyncAfterClose。
  ///
  /// 根因：dispose() 里的 [_syncAndFlushPosition] 是 fire-and-forget（dispose
  /// 同步签名无法 await），它内部 `await _syncPositionFromWebViewProgress()`
  /// （读实时 WebView 进度）与 `await _flushPosition()`（DB 写）抢不过紧随的
  /// super.dispose() 拆 WebView，恢复点退回 10s 轮询/debounce 的陈旧
  /// `_lastProgress*`，表现为退出重进落在前面好几页（分页/连续/竖排同此
  /// dispose flush，与模式无关）。
  ///
  /// 修：基类 [BaseSourcePageState.onWillPop] 在 closeMedia / triggerAutoSync
  /// 之前 `await onSourcePagePop()`，且此刻页面仍 mounted、WebView 仍存活，
  /// 对它 evaluateJavascript 安全（不同于进程退出期的 [_flushAllForProcessExit]
  /// 故意不碰 WebView）。这里 await 把实时当前页写穿，dispose 的 fire-and-forget
  /// 保留作兜底（硬 kill / 系统回收时 onWillPop 不一定跑到）。
  @override
  Future<void> onSourcePagePop() async {
    await _syncAndFlushPosition();
    await _flushReadingStats();
    // TODO-831：「退出后续播」关闭（audiobookBackgroundPlay=false）时，把真正
    // 停会话从 dispose 提前到这里——onSourcePagePop 被 onWillPop await，此刻页面
    // 仍 mounted、pop 动画尚未开始，await stop 完成后会话已空（_book/_controller
    // 置 null + notifyListeners），下层书架在 pop 动画首帧重建时 NowListeningMiniBar
    // 即见空会话从一开始 SizedBox.shrink，消除「显一帧再收起」的闪播放条。
    // dispose() 里的 unawaited(stop()) 兜底保留（硬 kill / 系统回收 / 非 PopScope
    // 退出路径 onWillPop 不一定跑到），stop() 内部对已清空的 controller 做 no-op，
    // 二次调用安全。
    if (!appModel.audiobookBackgroundPlay) {
      // W1：onSourcePagePop 被 onWillPop await，stop 在桌面释放 native 解码器时
      // 若抛平台异常，异常会沿 onWillPop → onPopInvokedWithResult 逃逸，导致
      // nav.pop() 不执行（用户退不出阅读器）。与 dispose 路径的 catchError 对齐：
      // 记错误后照常继续退出，绝不能因 stop 失败卡住不 pop。
      try {
        await appModel.audiobookSession.stop();
      } catch (e, s) {
        ErrorLogService.instance.log('ReaderHibiki.popStopAudiobook', e, s);
      }
    }
  }

  // The input device flipped between touch (mouse/pointer) and keyboard/gamepad.
  void _onHighlightModeChanged(FocusHighlightMode mode) {
    if (!mounted) return;
    // The char caret is a keyboard/gamepad affordance: hide its ring on the
    // mouse ("用鼠标的时候焦点应消失") and bring it back on hardware nav. Crucially
    // we SUSPEND (hide the ring) rather than exit — the caret keeps its surface,
    // so when the controller is picked back up the directions still drive the
    // popup/reader caret instead of falling through to the reader's page-turn.
    if (_caretActive) {
      final bool suspend = mode == FocusHighlightMode.touch;
      switch (_caretSurface) {
        case CaretSurface.popup:
          if (suspend) {
            topPopupState?.caretSuspend();
          } else {
            _resumePopupCaretForHardwareNav();
          }
          break;
        case CaretSurface.reader:
          _controller?.evaluateJavascript(
            source: suspend
                ? ReaderCaretScripts.suspendInvocation()
                : ReaderCaretScripts.resumeInvocation(),
          );
          break;
        case CaretSurface.lyrics:
          _controller?.evaluateJavascript(
            source: suspend
                ? ReaderLyricsCaretScripts.suspendInvocation()
                : ReaderLyricsCaretScripts.resumeInvocation(),
          );
          break;
        case CaretSurface.none:
          break;
      }
    }
    setState(() {});
  }

  void _resumePopupCaretForHardwareNav() =>
      _caret.resumePopupCaretForHardwareNav();

  @override
  void didChangeMetrics() {
    if (!mounted) {
      return;
    }
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncPageSize();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive) {
      // HBK-AUDIT-122: sync lyrics cue position before flushing so backgrounding
      // in lyrics mode persists the current playback position, not a stale scroll.
      _syncAndFlushPosition();
      _flushReadingStats();
    }
  }

  Future<void> _syncPageSize() async {
    if (_controller == null || !_readerContentReady || _lyricsMode) return;
    final Size screen = MediaQuery.of(context).size;
    final double w = screen.width;
    final double h = screen.height;
    // BUG-210 / TODO-146: 宽、高共用 1px 容差判定（见 readerViewportNeedsRepaginate）。
    // 旧代码宽度用零容差精确不等，Windows sub-pixel 宽抖动会误触发整章重载 + 粗粒度
    // progress 恢复，把用户从当前页弹到更靠前的页/章节开头（「翻页跳回章节开头」）。
    final ({bool width, bool height}) repaginate =
        readerViewportNeedsRepaginate(
      width: w,
      height: h,
      lastWidth: _lastSyncedWidth,
      lastHeight: _lastSyncedHeight,
    );
    final bool widthChanged = repaginate.width;
    final bool heightChanged = repaginate.height;
    if (!widthChanged && !heightChanged) return;
    // BUG-111: 诊断——窗口/缩放 settle 或 resize 后，把真实视口与已分页基线比对。
    // 若 content-ready 后这里报 widthChanged，说明初始分页宽度偏窄、正在自动重排铺满。
    debugPrint('[ReaderHibiki] _syncPageSize w=$w h=$h '
        'paginated=$_paginatedWidth x $_paginatedHeight '
        'widthChanged=$widthChanged heightChanged=$heightChanged');
    _lastSyncedWidth = w;
    _lastSyncedHeight = h;

    if (widthChanged) {
      final dynamic result = await _controller!.evaluateJavascript(
        source: ReaderPaginationScripts.stableProgressInvocation(),
      );
      if (!mounted || _controller == null) return;
      final ReaderStableProgressDetails? snapshot =
          parseReaderStableProgressDetails(result);
      final bool hasSameChapterCache = _lastProgressSection == _currentChapter;
      final double progress = snapshot?.progress ??
          (hasSameChapterCache ? _lastProgressValue : 0.0);
      final int? charOffset = snapshot?.charOffset ??
          (hasSameChapterCache ? _lastProgressCharOffset : null);
      await _navigateToChapter(
        _currentChapter,
        progress: progress,
        charOffset: charOffset,
      );
    } else {
      await _controller!.evaluateJavascript(
        source: ReaderPaginationScripts.updatePageSizeInvocation(w, h),
      );
      if (!mounted || _controller == null) return;
      await _caretRefresh();
    }
  }

  /// TODO-690 / BUG-399：阅读器树内透明 LayoutBuilder 的 resize 通道。
  ///
  /// builder 每帧把 `constraints` 与上次记录的约束基线比对（复用
  /// [readerLayoutResizeNeedsRepaginate] 的 1px 容差），超阈值则取消旧 timer 起一个
  /// ~50ms 尾沿防抖 timer，timer 回调直接调 [_syncPageSize]（它内部已含
  /// readerViewportNeedsRepaginate 判定、宽变整章重载 / 高变 updatePageSize 分流、
  /// _lastSyncedWidth/Height 基线更新与 _reanchorPending 串行旗，与 didChangeMetrics
  /// 路径靠基线天然去重幂等）。
  ///
  /// builder 内**不做**任何几何变换，只读 constraints 并起 timer；绝不在 builder 里
  /// Future.delayed（会泄漏 / 重入）。timer 在 [dispose] 取消。约束未变（同一尺寸多帧
  /// 重建）时早退，不重复起 timer。
  void _onReaderConstraintsChanged(BoxConstraints constraints) {
    final double w = constraints.maxWidth;
    final double h = constraints.maxHeight;
    if (!w.isFinite || !h.isFinite) return;
    final bool needsRepaginate = readerLayoutResizeNeedsRepaginate(
      width: w,
      height: h,
      lastWidth: _lastConstraintWidth,
      lastHeight: _lastConstraintHeight,
    );
    _lastConstraintWidth = w;
    _lastConstraintHeight = h;
    if (!needsRepaginate) return;
    _resizeRepaginateDebounce?.cancel();
    _resizeRepaginateDebounce = Timer(
      const Duration(milliseconds: 50),
      () {
        if (mounted) _syncPageSize();
      },
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final EdgeInsets vp = MediaQuery.of(context).viewPadding;
    _stableTopInset = vp.top;
    _stableBottomInset = vp.bottom;
  }

  // ── UI Build ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final Color bgColor = _themeBackgroundColor();

    // TODO-693: appUiScale 变化时（整体界面缩放），连续模式阅读位置会被 reflow 归零弹回
    // 章首（裸 window.scrollY 无分页模式的 snap/lock 保护）。在缩放变化那一帧采锚 + 置旗，
    // 过渡帧 settle 后重锚回原字符。门控/序列见 [_reanchorContinuousForUiScale]。
    // 用 select 只监听 appUiScale 标量，避免 AppModel 任意字段变更都触发重锚。
    ref.listen<double>(
      appProvider.select((AppModel m) => m.appUiScale),
      (double? previous, double next) {
        if (previous == null || previous == next) return;
        _reanchorContinuousForUiScale();
      },
    );

    // TODO-690 / BUG-399：透明 LayoutBuilder 作为桌面窗口 resize → 重排的通道。
    // 位于 HibikiAppUiScaleNeutralizer 之下（路由层 ReaderHibikiSource.buildLaunchPage
    // 已用 Neutralizer 包裹本页），在 WebView 子树外层。builder **零几何变换**：只读
    // constraints 交给 _onReaderConstraintsChanged（尾沿防抖起 _syncPageSize），原样返回
    // reader 子树。constraints.biggest 与 _syncPageSize 读的 MediaQuery.size 同处反缩放
    // 还原后的坐标空间，数值等价，故两条 resize 通道靠 _lastSyncedWidth/Height 基线去重。
    // 约束由布局系统每帧驱动，比 didChangeMetrics 更早更可靠（Windows 拖边框时后者滞后）。
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        _onReaderConstraintsChanged(constraints);
        return Actions(
          // Desktop gamepad path: the GamepadService dispatches GamepadButtonIntent
          // here (no gameButton* key events on desktop). Resolving it against the
          // reader/audiobook scopes routes polled controller input through the exact
          // same actions as the Android key-event path.
          actions: <Type, Action<Intent>>{
            GamepadButtonIntent: CallbackAction<GamepadButtonIntent>(
              onInvoke: (GamepadButtonIntent intent) =>
                  _handleGamepadButton(intent.button),
            ),
            GamepadLongPressIntent: CallbackAction<GamepadLongPressIntent>(
              onInvoke: (GamepadLongPressIntent intent) =>
                  _handleGamepadLongPress(intent.button),
            ),
          },
          child: Focus(
            autofocus: true,
            focusNode: _focusNode,
            onKeyEvent: _handleKeyEvent,
            child: PopScope(
              canPop: false,
              onPopInvokedWithResult: (didPop, dynamic result) async {
                if (didPop) return;
                final nav = Navigator.of(context);
                final bool allow = await onWillPop();
                if (allow && mounted) nav.pop();
              },
              child: Scaffold(
                backgroundColor: bgColor,
                resizeToAvoidBottomInset: false,
                body: Stack(
                  fit: StackFit.expand,
                  children: <Widget>[
                    Positioned.fill(
                      child: _buildBody(),
                    ),
                    if (!_readerContentReady)
                      Positioned.fill(
                        child: ColoredBox(color: bgColor),
                      ),
                    if (_readerContentReady)
                      const SizedBox.shrink(
                          key: ValueKey<String>('hoshi_content_ready')),
                    // On-screen focus indicator for the "reading content" layer,
                    // matching the app's standard focus ring (HibikiFocusRing:
                    // colorScheme.primary, 2.5px, 8px radius). Shown while the reader
                    // content holds primary focus and no char cursor is active (the
                    // cursor draws its own ring). Inset by the chrome insets so the
                    // ring sits inside the reading viewport and the bottom bar never
                    // occludes it — and so it is always on-screen (unlike the native
                    // WebView focus outline, which drew off-screen at the scroll pos).
                    if (_readerContentReady && !_lyricsMode)
                      Positioned.fill(
                        child: IgnorePointer(
                          child: AnimatedBuilder(
                            animation: _focusNode,
                            builder: (context, _) {
                              // Only in keyboard/gamepad highlight mode — matches the
                              // app-wide HibikiFocusRing convention (no focus ring in
                              // touch mode). Rebuilt on highlight change via
                              // _onHighlightModeChanged.
                              final bool show = _focusNavEnabled &&
                                  _focusNode.hasPrimaryFocus &&
                                  _caretSurface == CaretSurface.none &&
                                  FocusManager.instance.highlightMode ==
                                      FocusHighlightMode.traditional;
                              if (!show) return const SizedBox.shrink();
                              final double bottomInset = _showChrome
                                  ? _readerChromeHeight + _stableBottomInset
                                  : _stableBottomInset;
                              return Padding(
                                padding: EdgeInsets.fromLTRB(
                                    1.5, _readerTopOffset, 1.5, bottomInset),
                                child: DecoratedBox(
                                  decoration: BoxDecoration(
                                    borderRadius: BorderRadius.circular(8),
                                    border: Border.all(
                                      color:
                                          Theme.of(context).colorScheme.primary,
                                      width: 2.5,
                                    ),
                                  ),
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                    _buildTopProgressBar(),
                    buildDictionary(),
                    // The bottom chrome returns a Positioned; it MUST stay a direct
                    // child of this Stack. The chrome FocusScope is mounted INSIDE
                    // the Positioned (see _buildAudiobookBar / _buildSettingsBar) so
                    // it never detaches the Positioned's StackParentData (which would
                    // drop the bar to the Stack's top-start alignment).
                    _buildBottomChrome(),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildBody() {
    if (!_audioSlotResolved || _book == null || _extractDir == null) {
      return Center(child: adaptiveIndicator(context: context));
    }
    final Widget webView = _buildWebView();
    // BUG-379: 歌词模式（LyricsModeHtml）是独立 HTML，没有 window.hoshiReader，
    // _applyChromeInsets 对它整体 early-return，正文那套「告诉 WebView 底栏预留高度」
    // 的机制对歌词页完全失效。于是歌词 WebView 仍 Positioned.fill 铺满全屏，底栏
    // （_buildAudiobookBar，bottom:0）盖在其上，歌词文档级 CSS 滚动条（主题化的细条）
    // 沿整屏高度绘制，底部一段被绘制进底栏区域，看上去像「进度条跑进底栏里」。
    //
    // 正文模式滚动条被原生关闭（verticalScrollBarEnabled:false）且 body 经 setChromeInsets
    // 推离底栏，所以不暴露此问题；唯独歌词页两条都不成立。这里在 Flutter 侧把歌词 WebView
    // 收缩到底栏之上（底栏可见时留 _readerBottomReserve），视口本身不再与底栏重叠，
    // CSS 滚动条自然只画在歌词区域内。底栏可见条件与 _buildBottomChrome / popupBottomReserve
    // 保持一致（_hasEverLoaded && _showChrome），_showChrome 切换会触发 _rebuild 重建本树。
    if (_lyricsMode && _hasEverLoaded && _showChrome) {
      return Padding(
        padding: EdgeInsets.only(bottom: _readerBottomReserve),
        child: webView,
      );
    }
    return webView;
  }

  String _buildStyleTag() {
    return _cachedStyleTag ??= _computeStyleTag();
  }

  String _computeStyleTag() {
    final ReaderThemeColors rc = _readerThemeColors;
    return '<style id="hoshi-reader-style">\n${ReaderContentStyles.css(
      settings: _settings!,
      themeOverride: appModel.appThemeKey,
      // TODO-165 / BUG-224：正文 <body> 背景/字色统一吃 `_readerThemeColors` 派生色。
      // preset 命中时 _themeColors 走 switch case 用手调底色（忽略 customBg → 零破坏）；
      // system-theme（默认主题）/light-theme/未命中 key 落 default 分支，原来恒白底
      // #fff，现在吃这套真实 ColorScheme.surface/onSurface；custom-theme→用户色。
      customBg: _readerBackgroundHex,
      customFg: _customThemeTextCss,
      // BUG-396：selection/sasayaki/link 三角色色统一取自 `_readerThemeColors`（单一
      // 真相源）——preset 透传手调专色（与旧 switch 值逐一相等，零变化）、custom 用
      // 用户色、system/light 从真实 ColorScheme 强调色派生（不再落硬编码天蓝/灰/蓝）。
      selectionColor: _colorToCssRgba(rc.selection),
      sasayakiColor: _colorToCssRgba(rc.sasayaki),
      linkColor: _colorToCssRgba(rc.link),
    )}\n</style>';
  }

  void _invalidateStyleCache() {
    _cachedStyleTag = null;
    // BUG-270: cached chapter HTML bakes in the styleTag, so any style change
    // must drop it — the next served chapter then rebuilds with the fresh tag.
    _sanitizedHtmlCache.clear();
  }

  /// TODO-756b：把“鼠标悬停即自动查词”开关（[ReaderHibikiSource.hoverAutoLookup]）
  /// live 下发给 WebView 的全局 `window.__hoverAutoLookup`。setup 脚本注入初值，此处
  /// 在配置变化时改同一全局，无需整章重注入。半销毁 WebView 抛 PlatformException 时
  /// 就地兜底（与 [_applyStylesLive] 同纪律），下发本就无意义 → 安全 no-op。
  Future<void> _applyHoverAutoLookupLive() async {
    if (_controller == null) return;
    final bool enabled = ReaderHibikiSource.instance.hoverAutoLookup;
    try {
      await _controller!.evaluateJavascript(
        source: 'window.__hoverAutoLookup = $enabled;',
      );
    } catch (e, stack) {
      ErrorLogService.instance
          .log('ReaderHibiki.applyHoverAutoLookupLive', e, stack);
    }
  }

  Future<void> _applyStylesLive() async {
    if (_controller == null || _settings == null) return;
    _invalidateStyleCache();
    // _settings 即 ReaderHibikiSource.readerSettings 本体，setTtu* 已在触发本
    // 回调前写穿同一对象，无需再 _syncSettingsFromHive 自拷贝（旧 TTU 死桥）。
    if (!mounted || _controller == null) return;
    // TODO-756b：把“悬停即查词”开关下发到 WebView 的 window.__hoverAutoLookup（mousemove
    // 监听器据此跳过 Shift 门控）。独立于样式/歌词分支：阅读器与歌词模式都吃此开关。
    await _applyHoverAutoLookupLive();
    if (!mounted || _controller == null) return;
    if (_lyricsMode) {
      await _updateLyricsStyleLive();
      return;
    }
    final ReaderThemeColors rc = _readerThemeColors;
    final String css = ReaderContentStyles.css(
      settings: _settings!,
      themeOverride: appModel.appThemeKey,
      // TODO-165 / BUG-224：与 _computeStyleTag 对称——正文背景/字色统一吃当前主题
      // 派生色，system-theme（默认主题）不再恒白底。
      customBg: _readerBackgroundHex,
      customFg: _customThemeTextCss,
      // BUG-396：与 _computeStyleTag 对称——三角色色统一取自 `_readerThemeColors`
      // 单一真相源，system/light 也吃强调色（不再落硬编码默认）。
      selectionColor: _colorToCssRgba(rc.selection),
      sasayakiColor: _colorToCssRgba(rc.sasayaki),
      linkColor: _colorToCssRgba(rc.link),
    );
    final String jsonCss = jsonEncode(css);
    try {
      // 先确保 style 元素存在（begin 入口 setText 到它）。pagination 未就绪 / 非 reader 页
      // （无 hoshiReader）时 beginStyleReanchorInvocation 返回 -1，下面编排自然 no-op，
      // 这里的裸 textContent 兜底保证 CSS 仍然生效。
      await _controller!.evaluateJavascript(
        source: '''
(function(){
  var el = document.getElementById('hoshi-reader-style');
  if (!el) {
    el = document.createElement('style');
    el.id = 'hoshi-reader-style';
    document.head.appendChild(el);
  }
  // TODO-736 B-1：无 hoshiReader（pagination 未就绪 / 非 reader 页）时直接裸套 CSS；
  // 有 hoshiReader 时不在此换 CSS——交给下面 Dart 编排的 beginStyleReanchor 同步换 CSS
  // + 采锚 + 置旗，commit 在 postFrame settle 后滚回（settle-aware，挡住 reflow 归零污染）。
  if (!window.hoshiReader) { el.textContent = $jsonCss; }
})();
''',
      );
    } catch (e, stack) {
      // controller 非 null 但底层 WebView 平台视图已销毁时 evaluateJavascript
      // 抛 PlatformException。无活动 WebView 时套样式本就无意义 → 安全 no-op。
      ErrorLogService.instance
          .log('ReaderHibiki.applyStylesLive.eval', e, stack);
      return;
    }
    if (!mounted || _controller == null) return;
    // TODO-736 B-1/B-2（必补点2）：样式变更两阶段 settle-aware 重锚。换字号/字体/主题点经
    // 此走 begin（同步换 CSS + 精确采锚 + 置旗）→ postFrame settle → commit（滚回 + 清旗 +
    // 打 _reanchorClearedAt）。拆掉了旧 reanchorAfterStyleChange 的 rAF-finally 自驱清旗——
    // 那个在 reflow 未 settle 时就清旗，让 120ms 尾沿 scroll timer 把 reflow 归零的瞬态当真
    // 滚动落库 → 翻页多次改字号跳章首（B 现象的时序根因）。分页/连续各自的精确锚由 JS
    // `this` 解析（连续含 A-2 兜底），分页保 page-stable hint。
    await _reanchorForStyleChange(jsonCss);
    if (mounted) setState(() {});
  }

  void _invalidateFavoriteSentenceCache() {
    _favoriteSentencesForBookCache = null;
    _favoriteSentencesForBookFuture = null;
  }

  Future<List<FavoriteSentence>> _loadFavoriteSentencesForBook() async {
    final FavoriteSentenceRepository repo =
        FavoriteSentenceRepository(appModel.database);
    try {
      final List<FavoriteSentence> favorites = (await repo.getAll())
          .where((FavoriteSentence s) => s.bookKey == widget.bookKey)
          .toList(growable: false);
      _favoriteSentencesForBookCache = favorites;
      return favorites;
    } finally {
      _favoriteSentencesForBookFuture = null;
    }
  }

  Future<List<FavoriteSentence>> _favoriteSentencesForBook() {
    final List<FavoriteSentence>? cached = _favoriteSentencesForBookCache;
    if (cached != null) {
      return Future<List<FavoriteSentence>>.value(cached);
    }
    return _favoriteSentencesForBookFuture ??= _loadFavoriteSentencesForBook();
  }

  Future<List<FavoriteSentence>> _favoriteSentencesForSection(
      int section) async {
    final List<FavoriteSentence> favorites = await _favoriteSentencesForBook();
    return favorites
        .where((FavoriteSentence s) =>
            s.bookKey == widget.bookKey && s.sectionIndex == section)
        .toList(growable: false);
  }

  Future<void> _applyChapterHighlights() async {
    if (_controller == null) return;
    final List<FavoriteSentence> chapterFavs =
        await _favoriteSentencesForSection(_currentChapter);
    if (!mounted || _controller == null) return;
    final int withOffsets =
        chapterFavs.where((s) => s.normCharOffset != null).length;
    final int total =
        _favoriteSentencesForBookCache?.length ?? chapterFavs.length;
    debugPrint('[hoshi-hl] chapter=$_currentChapter '
        'total=$total chapterFavs=${chapterFavs.length} '
        'withOffsets=$withOffsets');
    if (chapterFavs.isNotEmpty) {
      await HighlightBridge.applyHighlights(_controller!, chapterFavs,
          backgroundHex: _readerBackgroundHex,
          customHighlightCss: _customHighlightCss);
      if (!mounted || _controller == null) return;
      await _controller!.evaluateJavascript(
        source:
            'if (!window.__hoshiCssHighlightsSupported) { window.hoshiReader && window.hoshiReader.buildNodeOffsets(); }',
      );
      // HBK-AUDIT-117: theme persistence moved to _onThemeChanged — it is
      // unrelated to highlight application and must not be gated on favorites.
    }
  }

  Future<void> _applyLyricsFavorites() async {
    if (_controller == null) return;
    final List<FavoriteSentence> all = await _favoriteSentencesForBook();
    if (_controller == null || !mounted) return;
    final List<String> texts =
        all.map((s) => s.text).where((t) => t.isNotEmpty).toList();
    final String json = jsonEncode(texts);
    await _controller!.evaluateJavascript(
      source:
          'window.__lyricsMarkFavorites && window.__lyricsMarkFavorites($json);',
    );
  }

  // ── Restore Complete ──────────────────────────────────────────────

  Completer<bool>? _restoreCompleter;
  int _navigateGeneration = 0;
  int _restoreExpectedGeneration = 0;

  // ── Audiobook Cue Wiring ──────────────────────────────────────────

  /// TODO-291 阶段2：实现 [ReaderAudiobookView.onReaderCueChanged]。由 session 的
  /// 控制器监听器转发（reader attach 期才被调用）。只管 WebView 侧（正文高亮 / lyrics /
  /// 进度同步）——悬浮窗 / 媒体通知同步已上移到 session 常驻执行，这里不再做，避免双写。
  @override
  void onReaderCueChanged() => _onCueChanged();

  // ── ReaderAudiobookView（TODO-291 阶段2：reader 向 session 暴露 WebView 侧回调） ──

  @override
  int getCurrentReaderSection() => _currentChapter;

  @override
  Future<void> onCueCrossChapter(int sectionIndex) =>
      _handleCueCrossChapter(sectionIndex);

  @override
  Future<void> onBoundarySkip(int delta) => _handleBoundarySkip(delta);

  AudioCue? _lookupCue;
  ({int offset, int length, String text})? _cachedSelectionRange;
  ({int offset, int length})? _cachedSentenceRange;
  int? _cachedSentenceOffset;
  bool _currentSentenceIsFavorited = false;

  /// TODO-270 F/G「查词窗口多句合一制卡」(乙方案)：会话级制卡草稿缓冲。弹窗点「+句」
  /// 把当前句（+句子音频区间）推进这里，连续查多句累积；制卡时合成一段写入卡片
  /// sentence 字段（[joinMinedSentences]），音频区间合并（[mergeMiningAudioRanges]，
  /// 跨章/跨音频文件退化为只合文本）。制卡成功或关闭弹窗栈后清空。书籍 + 有声书共用
  /// 同一 reader 页 / currentSentence 链路，区别只在裁句子音频。
  final MiningSentenceDraft _miningDraft = MiningSentenceDraft();

  /// TODO-644 / BUG-357：制卡串行化队列。`onMineFromPopup` / `onUpdateFromPopup` 都把
  /// 自己的 prepare→mine 工作经 [SerialTaskQueue.enqueue] 挂到队列尾，保证同一时刻只跑
  /// 一张卡的制卡序列。快速连制两张卡（来自两个 mine button，popup.js 的 per-button
  /// guard 互不影响）时，第二张排队等第一张完成后再跑，杜绝两次 prepare 在
  /// `extractAudioSegment` 的 await 处交错改写共享成员。配合 [_prepareMiningContext] 的
  /// await 前快照，双保险：快照消除单次错配，串行化消除连制交错。
  final SerialTaskQueue _miningQueue = SerialTaskQueue();

  /// reader（书籍/有声书）支持「+句」累积草稿。
  @override
  bool get supportsSentenceDraft => true;

  @override
  void clearDictionaryResult() {
    _lookupCue = null;
    _cachedSelectionRange = null;
    _cachedSentenceRange = null;
    _cachedSentenceOffset = null;
    _currentSentenceIsFavorited = false;
    appModel.currentMediaSource?.clearCurrentCueSentence();
    super.clearDictionaryResult();
  }

  /// TODO-393「上 N 句 / 下 N 句」上下文选择：把当前句之前 [prevCount] 句、之后
  /// [nextCount] 句作上下文**整体设置**进会话级制卡草稿（覆盖上一次选择，不累积），
  /// 返回上下文句总数（上 N + 下 N）。上下文句从阅读器 DOM 取（
  /// [ReaderSelectionScripts.getSurroundingSentences]，沿用查词同一句子边界规则，止于
  /// 段落边界），有声书顺带按各句归一化偏移裁出音频区间一并入队（制卡时合并成首句起→
  /// 末句止；跨章/跨音频文件退化为只合文本）。无 WebView 或无选区时清空上下文返回 0。
  @override
  Future<int> onSetSentenceContextToDraft(int prevCount, int nextCount) async {
    final InAppWebViewController? controller = _controller;
    if (controller == null || (prevCount <= 0 && nextCount <= 0)) {
      _miningDraft.setContext();
      return _miningDraft.length;
    }
    Object? raw;
    try {
      raw = await controller.evaluateJavascript(
        source: ReaderSelectionScripts.surroundingSentencesInvocation(
          prevCount,
          nextCount,
        ),
      );
    } catch (_) {
      _miningDraft.setContext();
      return _miningDraft.length;
    }
    final parsed = ReaderSelectionScripts.surroundingSentencesFromResult(raw);
    MiningDraftSentence toEntry(SurroundingSentence s) => MiningDraftSentence(
          sentence: s.sentence,
          audioRange: _sentenceAudioRangeFor(
            sentence: s.sentence,
            normOffset: s.normOffset,
            normLength: s.normLength,
          ),
        );
    _miningDraft.setContext(
      prev: <MiningDraftSentence>[for (final s in parsed.prev) toEntry(s)],
      next: <MiningDraftSentence>[for (final s in parsed.next) toEntry(s)],
    );
    return _miningDraft.length;
  }

  /// TODO-382 / TODO-393：弹窗点「清空已加句子」清掉本次查词的上下文选择（回到只制
  /// 当前句），回传清空后的句数（恒 0）。给用户一个明确、可见的撤销入口。
  @override
  Future<int> onClearSentenceDraftToDraft() async {
    _miningDraft.clear();
    return _miningDraft.length;
  }

  @override
  Future<MinePopupResult> onMineFromPopup(Map<String, String> fields) {
    // TODO-644 / BUG-357：经制卡串行队列执行，杜绝快速连制两张卡时两次 prepare→mine
    // 在 extractAudioSegment 的 await 处交错。第二张排队等第一张完成（不丢弃请求）。
    return _miningQueue.enqueue(() => _onMineFromPopupInner(fields));
  }

  @override
  Future<MinePopupResult> onUpdateFromPopup(
    int noteId,
    Map<String, String> fields,
  ) {
    // TODO-644 / BUG-357：覆盖同样经制卡串行队列，与制卡共用同一条队列尾（两者都读
    // 同一组共享成员），避免「连制 + 覆盖」交错。
    return _miningQueue.enqueue(() => _onUpdateFromPopupInner(noteId, fields));
  }

  List<AudioCue>? _cachedAllCues;
  bool _cachedSasayaki = false;

  // ── Spread (two-page) support ──────────────────────────────────────

  Map<int, bool>? _edgeMatchResults;

  /// TODO-700 T3：WebView 正文就绪的瞬间，确定性把 Flutter 焦点落到正文 [_focusNode]，
  /// 让首开书第一次按 B / 上下句 / 播放就作用在书内（消解「首开点两下播放才听书」「首开
  /// 按 B 退书」——根因是整页 autofocus 抢在内容就绪前、焦点落在表面层，B 冒泡全局返回）。
  /// 严格门控：光标态 / 词典弹窗态 / 歌词态都不抢（否则会覆盖正在用的光标焦点）。整页
  /// Focus 的 autofocus:true 仍保留作冷启动兜底，本 helper 只是把「确定性到位」补在每个
  /// 内容就绪落点（含切应用回来 / 重启后重进，不再依赖 FocusManager 进程内记忆）。
  void _settleFocusOnContentReady() {
    if (!mounted || !_readerContentReady || _lyricsMode) return;
    if (_caretActive || _caretSurface != CaretSurface.none) return;
    if (isDictionaryShown) return; // 弹窗 WebView 持焦点期间不抢
    _focusNode.requestFocus();
  }

  @override
  void onAllPopupsDismissed() {
    if (!mounted) return;

    // TODO-270 F/G：整条查词浮层栈关闭 = 一次「查词会话」结束，丢弃未制卡的多句
    // 草稿（避免下次查词带着上次没用掉的累积句）。制卡成功已在 onMineFromPopup
    // 清过，这里兜住「攒了几句但没制卡就关掉」的情况。
    _miningDraft.clear();
    _clearLookupState();
    // Return Flutter focus to the reading content. The dismissed popup's WebView
    // held the keyboard/gamepad focus, so without this the reader receives no key
    // events after the popup closes and the user is stuck with no way back in.
    _focusNode.requestFocus();
    // If the cursor was living in a popup (controller/keyboard flow), the popup
    // it was in is gone — bring it back to the reader at its remembered word.
    // This covers every dismiss path (B/Esc, tap-outside, swipe).
    if (_caretSurface == CaretSurface.popup) {
      _caret.popupState = null;
      unawaited(_enterCaret());
    }
  }

  /// 查词收尾序列：清栈热槽 → deferDisplay 查词 → 高亮并展示弹窗。reader 选词的
  /// 歌词模式与普通模式两分支共用（前后各自的 cue 解析 / cached-range 设置保留在
  /// 各分支，因时机不同：歌词从 fragment 提前设，普通从 data 在其后设）。
  Future<void> _runLookupAndHighlight(
    String searchTerm,
    Rect selectionRect,
  ) async {
    prunePopupStack(0);
    final int highlightCount = await searchDictionaryResult(
      searchTerm: searchTerm,
      selectionRect: selectionRect,
      deferDisplay: true,
    );
    await _highlightAndShowPopup(highlightCount, selectionRect);
  }

  // ── Key Navigation ────────────────────────────────────────────────

  /// 正文（Sasayaki 原生 EPUB / 合成书）中键点击 → 经 JS `cueIdAtPoint` 反查所在
  /// cue → 跳到该句并播放。点空白/无命中静默忽略。
  Future<void> _seekToClickedSentence(double x, double y) async {
    final AudiobookPlayerController? controller = _audiobookController;
    if (controller == null) return;
    final Object? raw = await _controller?.evaluateJavascript(
      source: 'window.hoshiReader && window.hoshiReader.cueIdAtPoint'
          ' ? window.hoshiReader.cueIdAtPoint($x, $y) : null',
    );
    // await 期间用户可能退出有声书（_audiobookController 被置空并 dispose）。
    // 用快照同一性校验，避免对已 dispose 的旧 controller 调 playCueAndContinue。
    if (!mounted || !identical(_audiobookController, controller)) return;
    if (raw is! String) return;
    final List<AudioCue>? allCues = _cachedAllCues;
    if (allCues == null) return;
    final AudioCue? cue = cueForPointerPayload(raw, allCues);
    if (cue != null) controller.playCueAndContinue(cue);
  }

  // ── Char-level reading cursor ─────────────────────────────────────

  /// A deeper popup layer was dismissed (B/Esc or swipe) but a parent popup
  /// remains: keep the cursor on the popup surface, follow it to the new top, and
  /// re-measure its ring.
  @override
  void onDictionaryStackChanged() => _caret.onDictionaryStackChanged();

  /// Hand the char-level cursor to the freshly rendered top popup when in cursor
  /// mode. Pure-touch users (surface == none) are unaffected.
  @override
  void onDictionaryPopupRendered(int index) =>
      _caret.onDictionaryPopupRendered(index);

  // ── DictionaryCaretHost ───────────────────────────────────────────
  // The reader is the host for its [_caret] state machine: it supplies the
  // popup-stack view and the `setState` / reader-ring side effects, while the
  // controller owns the surface/popup-state/busy fields and the popup transitions.

  @override
  bool get caretHostMounted => mounted;

  @override
  DictionaryPopupWebViewState? get caretTopPopupState => topPopupState;

  @override
  int get caretTopVisiblePopupIndex => topVisiblePopupIndex;

  @override
  void caretSetState(VoidCallback fn) {
    if (!mounted) {
      fn();
      return;
    }
    setState(fn);
  }

  /// Hide the reader-content caret ring (called by the controller only when the
  /// cursor leaves the reader surface for a popup). Mirrors the pre-extraction
  /// `_controller?.evaluateJavascript(ReaderCaretScripts.exit)`.
  @override
  void caretExitPrimaryRing() {
    _controller?.evaluateJavascript(
        source: ReaderCaretScripts.exitInvocation());
  }

  // ── Shift+Hover over dismiss barrier ──────────────────────────────

  double _barrierHoverLastDx = -1;
  double _barrierHoverLastDy = -1;

  @override
  void onDismissBarrierHover(PointerHoverEvent event) {
    if (!HardwareKeyboard.instance.isShiftPressed) {
      _barrierHoverLastDx = -1;
      _barrierHoverLastDy = -1;
      return;
    }
    // TODO-851「限一级弹窗」：已有可见弹窗时遮罩上的悬停不再查词，保证 hover 最多
    // 叠一层。这是第二个 hover 入口（另一处在 webview.part.dart onShiftHover），
    // 两处必须都门控，否则遮罩 hover 路径漏网。
    if (isDictionaryShown) return;
    // TODO-806 真坐标系修复：[event.localPosition] 是相对**dismiss barrier**
    // （Positioned.fill 铺满页面 Stack）的逻辑像素，而 WebView 被 chrome inset
    // （顶栏 [_readerTopOffset] / 底栏预留）挤在 Stack 内部、原点 ≠ barrier 原点。
    // 直接把 barrier-local 喂给 [_selectTextAt]（期望 WebView CSS 视口坐标）会按
    // inset 整体偏移，Shift 悬停越过查词遮罩会命中错字符。改成用 WebView 自己的
    // RenderBox 把全局指针位置（[event.position]）映成 WebView 局部坐标——与正常
    // 路径 onShiftHover（直接用 JS e.clientX/clientY）口径一致。WebView 的逻辑像素
    // 与 CSS 像素同尺度（平台视图把 widget 逻辑尺寸映成 CSS 视口，无页面缩放），
    // 故不需要再乘 devicePixelRatio（DPR 换的是逻辑↔物理，不是逻辑↔CSS；多乘反而
    // 会重新引入这个偏移）。RenderBox 不可用时（不应发生：barrier 在屏说明 WebView
    // 也在树上）回退到 barrier-local，退化成旧行为而非崩溃。
    final RenderObject? obj = _webViewKey.currentContext?.findRenderObject();
    final Offset local = (obj is RenderBox && obj.attached && obj.hasSize)
        ? obj.globalToLocal(event.position)
        : event.localPosition;
    final double dx = local.dx - _barrierHoverLastDx;
    final double dy = local.dy - _barrierHoverLastDy;
    if (dx * dx + dy * dy < 64) return;
    _barrierHoverLastDx = local.dx;
    _barrierHoverLastDy = local.dy;
    // TODO-851：遮罩悬停也是 hover 路径，传 fromHover:true，命中空白不触发 onTapEmpty。
    _selectTextAt(local.dx, local.dy, fromHover: true);
  }

  // ── Reader chrome helpers kept in the shell ─────────────────────────
  // `_colorToCssRgba` / `_toDouble` stay here because their other call sites
  // live in the still-in-shell WebView region; the rest of the reader chrome
  // domain lives in `reader_hibiki/chrome.part.dart` (TODO-589 batch7).

  static String? _colorToCssRgba(Color? c) {
    if (c == null) return null;
    return readerColorToCssRgba(c);
  }

  static double? _toDouble(dynamic result) {
    if (result is double) return result;
    if (result is int) return result.toDouble();
    if (result is String) {
      return double.tryParse(result.trim().replaceAll('"', ''));
    }
    return null;
  }

  @override
  Widget? buildPopupAudioControls() {
    final AudiobookPlayerController? ctrl = _audiobookController;
    final bool hasAudio = ctrl != null && ctrl.chapterCueCount > 0;

    Widget buildRow(ThemeData theme) {
      final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);
      final AudioCue? cue = _lookupCue;
      final bool hasCue = cue != null;
      return ReaderChromeScaler(
        scale: _readerChromeScale,
        baseHeight: _readerPopupHeaderBaseHeight,
        child: SizedBox(
          height: _readerPopupHeaderBaseHeight,
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(
                  color: theme.dividerColor,
                  width: 0.5,
                ),
              ),
            ),
            padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                HibikiIconButton(
                  icon: _currentSentenceIsFavorited
                      ? Icons.star
                      : Icons.star_border,
                  size: 20,
                  enabledColor: _currentSentenceIsFavorited
                      ? theme.colorScheme.primary
                      : null,
                  onTap: _toggleFavoriteSentence,
                  tooltip: t.action_favorite,
                  padding: EdgeInsets.all(tokens.spacing.gap / 2),
                ),
                if (hasAudio) ...[
                  SizedBox(width: tokens.spacing.gap),
                  HibikiIconButton(
                    icon: Icons.replay_outlined,
                    size: 20,
                    onTap: hasCue
                        ? () {
                            final AudioCue? cue = _lookupCue;
                            if (cue == null) return;
                            ctrl.playCueOnce(cue);
                          }
                        : null,
                    tooltip: t.repeat_cue,
                    padding: EdgeInsets.all(tokens.spacing.gap / 2),
                  ),
                  SizedBox(width: tokens.spacing.gap),
                  HibikiIconButton(
                    icon: ctrl.isPlaying
                        ? Icons.pause_outlined
                        : Icons.play_arrow_outlined,
                    size: 24,
                    onTap: ctrl.togglePlayPause,
                    tooltip: ctrl.isPlaying ? t.pause : t.play,
                    padding: EdgeInsets.all(tokens.spacing.gap / 2),
                  ),
                  SizedBox(width: tokens.spacing.gap),
                  HibikiIconButton(
                    icon: Icons.play_circle_outline,
                    size: 20,
                    onTap: hasCue
                        ? () {
                            final AudioCue? cue = _lookupCue;
                            if (cue == null) return;
                            ctrl.playCueAndContinue(cue);
                            clearDictionaryResult();
                          }
                        : null,
                    tooltip: t.play_from_cue,
                    padding: EdgeInsets.all(tokens.spacing.gap / 2),
                  ),
                ],
              ],
            ),
          ),
        ),
      );
    }

    // Own focus scope so the gamepad can move focus into the header (Up from the
    // popup content top) and the buttons traverse with Left/Right. The node is a
    // State field (stable across rebuilds); only the index==0 popup gets a
    // header, so exactly one widget ever uses this node at a time.
    if (!hasAudio) {
      return FocusScope(
        node: _popupHeaderScope,
        child: Builder(builder: (context) => buildRow(Theme.of(context))),
      );
    }
    return FocusScope(
      node: _popupHeaderScope,
      child: ListenableBuilder(
        listenable: ctrl,
        builder: (context, _) => buildRow(Theme.of(context)),
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────
  // TODO-291 阶段2：_audiobookFromRow / _srtBookFromRow / _resolveAudioFiles 已移到
  // [AudiobookSessionLauncher]（reader 与书架共用会话解析）。
}

@visibleForTesting
class ReaderLyricsModeHintDialog extends StatelessWidget {
  const ReaderLyricsModeHintDialog({
    required this.onClose,
    super.key,
  });

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.74,
      child: HibikiModalSheetFrame(
        title: t.lyrics_mode_hint_title,
        leadingIcon: Icons.lyrics_outlined,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Text(
          t.lyrics_mode_hint_body,
          style: tokens.type.listSubtitle,
        ),
        footer: Align(
          alignment: Alignment.centerRight,
          child: adaptiveDialogAction(
            context: context,
            onPressed: onClose,
            child: Text(MaterialLocalizations.of(context).okButtonLabel),
          ),
        ),
      ),
    );
  }
}

@visibleForTesting
class ReaderSrtAudioPickerDialog extends StatelessWidget {
  const ReaderSrtAudioPickerDialog({
    required this.currentLabel,
    required this.onPickFiles,
    super.key,
  });

  final String currentLabel;
  final VoidCallback onPickFiles;

  @override
  Widget build(BuildContext context) {
    final HibikiDesignTokens tokens = HibikiDesignTokens.of(context);

    return HibikiDialogFrame(
      maxWidth: 460,
      maxHeightFactor: 0.76,
      child: HibikiModalSheetFrame(
        title: t.srt_book_replace_audio,
        leadingIcon: Icons.audio_file_outlined,
        bodyPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          0,
          tokens.spacing.card,
          tokens.spacing.gap,
        ),
        footerPadding: EdgeInsets.fromLTRB(
          tokens.spacing.card,
          tokens.spacing.gap,
          tokens.spacing.card,
          tokens.spacing.card,
        ),
        body: Text(
          currentLabel,
          style: tokens.type.listSubtitle,
        ),
        footer: Wrap(
          alignment: WrapAlignment.end,
          spacing: tokens.spacing.gap,
          runSpacing: tokens.spacing.gap,
          children: [
            adaptiveDialogAction(
              context: context,
              onPressed: () => Navigator.pop(context),
              child: Text(t.dialog_cancel),
            ),
            FilledButton.icon(
              onPressed: onPickFiles,
              icon: const Icon(Icons.audio_file_outlined, size: 18),
              label: Text(t.srt_import_pick_audio_files),
            ),
          ],
        ),
      ),
    );
  }
}
