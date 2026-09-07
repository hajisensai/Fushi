import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show ImageFilter;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/utils/misc/fushi_toast.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/services.dart' hide ModifierKey;
import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:fushi/pages.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/content_font_chain.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart';
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:fushi/src/epub/epub_book.dart';
import 'package:fushi/src/epub/epub_parser.dart';
import 'package:fushi/src/epub/epub_spread_analyzer.dart';
import 'package:fushi/src/epub/epub_spread_map.dart';
import 'package:fushi/src/epub/epub_storage.dart';
import 'package:fushi/src/media/audiobook/audiobook_bridge.dart';
import 'package:fushi/src/media/audiobook/audiobook_session.dart';
import 'package:fushi/src/media/audiobook/audiobook_session_launcher.dart';
import 'package:fushi/src/media/audiobook/lyrics_mode_html.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_lookup_routing.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi/src/media/audiobook/highlight_bridge.dart';
import 'package:fushi/src/media/audiobook/audiobook_play_bar.dart';
import 'package:fushi/src/asr/asr_transcription_service.dart';
import 'package:fushi/src/media/audiobook/asr_transcribe_sheet.dart';
import 'package:fushi/src/media/audiobook/audiobook_import_dialog.dart';
import 'package:fushi/src/media/audiobook/srt_book_reimport_dialog.dart';
import 'package:fushi/src/media/import/srt_book_reimport.dart';
import 'package:fushi/src/media/audiobook/mining_audio_clip.dart';
import 'package:fushi/src/media/audiobook/audiobook_clip_export.dart';
import 'package:fushi/src/utils/misc/card_screenshot_downsampler.dart';
import 'package:fushi/src/media/audiobook/audiobook_clip_text_render.dart';
import 'package:fushi/src/media/audiobook/audiobook_clip_webview_render.dart';
import 'package:fushi/src/utils/misc/desktop_audio_clipper.dart'
    show extractAudioSegmentViaFfmpeg;
import 'package:fushi/src/media/display_title.dart';
import 'package:fushi/src/media/audiobook/mining_sentence_draft.dart';
import 'package:fushi/src/media/audiobook/reader_quick_settings_sheet.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/media/tracking/media_tracking_service.dart'
    show kMediaTrackingEnabled;
import 'package:fushi/src/mining/immersion_mining_request.dart'
    show immersionMiningAudioExtension;
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart'
    show DictionaryPopupWebViewState, MinePopupResult;
import 'package:fushi/src/pages/implementations/stat_activity.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/reader/reader_caret_scripts.dart';
import 'package:fushi/src/reader/reader_chapter_perf_trace.dart';
import 'package:fushi/src/reader/reader_engine_config.dart';
import 'package:fushi/src/reader/reader_script_compactor.dart';
import 'package:fushi/src/reader/reader_chrome_scaler.dart';
import 'package:fushi/src/reader/reader_lyrics_caret_scripts.dart';
import 'package:fushi/src/reader/reader_content_styles.dart';
import 'package:fushi/src/reader/image_reveal_key.dart';
import 'package:fushi/src/reader/reader_resource_sanitizer.dart';
import 'package:fushi/src/reader/reader_exit_flush.dart';
import 'package:fushi/src/reader/reader_pagination_scripts.dart';
import 'package:fushi/src/reader/reader_restore_anchor.dart';
import 'package:fushi/src/reader/reader_search_navigation.dart';
import 'package:fushi/src/reader/reader_selection_data.dart';
import 'package:fushi/src/reader/reader_selection_scripts.dart';
import 'package:fushi/src/reader/reader_chrome_floating.dart';
import 'package:fushi/src/reader/reader_settings.dart';
import 'package:fushi/src/reader/reader_chrome_controller.dart';
import 'package:fushi/src/reader/reader_desktop_chrome.dart';
import 'package:fushi/src/reader/reader_gallery_page.dart';
import 'package:fushi/src/reader/reader_open_trace.dart';
import 'package:fushi/src/reader/reader_progress_state.dart';
import 'package:fushi/src/reader/reader_statistics_dialog.dart';
import 'package:fushi/src/reader/reader_status_footer.dart';
import 'package:fushi/src/stats/read_unit_ledger.dart';
import 'package:fushi/src/stats/stat_facts.dart';
import 'package:fushi/src/reader/reader_top_progress.dart';
import 'package:fushi/src/reader/ttu_toc_flatten.dart';
import 'package:fushi/src/startup/exit_flush_registry.dart';
import 'package:fushi/src/webview/webview_death_guard.dart';
import 'package:fushi/src/sync/desktop_lookup_service.dart';
import 'package:fushi/src/media/audiobook/floating_lyric_channel.dart';
import 'package:fushi/src/media/audiobook/pointer_seek.dart';
import 'package:fushi/src/platform/macos_fullscreen_state.dart';
import 'package:fushi/src/platform/selection_external_actions.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/utils/misc/coalesced_async_runner.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/floating_lyric_hint.dart';
import 'package:fushi/src/utils/misc/debug_log_service.dart';
import 'package:fushi/src/utils/misc/channel_constants.dart';
import 'package:fushi/src/utils/misc/tts_channel.dart';
import 'package:fushi/src/utils/misc/serial_task_queue.dart';
import 'package:fushi/src/utils/misc/volume_key_channel.dart';
import 'package:share_plus/share_plus.dart';
import 'package:fushi/src/utils/misc/fushi_share.dart';
import 'package:path_provider/path_provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:window_manager/window_manager.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi/src/utils/misc/fushi_color.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi/src/shortcuts/input_binding.dart'
    show
        GamepadButton,
        InputBinding,
        ModifierKey,
        activeModifierKeys,
        domMouseButtonFromPointerButtons;
import 'package:fushi/src/shortcuts/mouse_binding_dispatch.dart'
    show dispatchClaimedMouseAction, resolveMouseBindingActionForButton;
import 'package:fushi/src/shortcuts/shortcut_registry.dart'
    show FushiShortcutRegistry;
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show
        GamepadButtonIntent,
        GamepadLongPressIntent,
        focusedEditableText,
        tryDictionaryPopupGamepadButton;
import 'package:fushi/src/shortcuts/shortcut_action.dart';
import 'package:fushi/src/focus/page_focus_ownership.dart';
import 'package:fushi/src/focus/webview_key_bridge.dart';
import 'package:fushi/src/shortcuts/reader_caret_router.dart';
import 'package:fushi/src/shortcuts/dictionary_caret_controller.dart';
// Re-export so existing references to `CaretSurface` via the reader page,
// and the source-scan guards that read this file, still resolve the enum
// after its definition moved into the shared caret controller (TODO-387).
export 'package:fushi/src/shortcuts/dictionary_caret_controller.dart'
    show CaretSurface;
import 'package:fushi/src/shortcuts/reader_space_override.dart';
import 'package:fushi/src/shortcuts/window_fullscreen_hosts.dart'
    show WindowFullscreenHost;
import 'package:fushi/src/shortcuts/global_navigation.dart'
    show
        desktopWindowFullscreenSupported,
        exitWindowFullscreenIfActive,
        readDesktopWindowFullscreen,
        setDesktopWindowFullscreen;

part 'reader_fushi/lyrics.part.dart';
part 'reader_fushi/mining.part.dart';
part 'reader_fushi/lookup.part.dart';
part 'reader_fushi/navigation.part.dart';
part 'reader_fushi/audiobook.part.dart';
part 'reader_fushi/caret.part.dart';
part 'reader_fushi/chrome.part.dart';
part 'reader_fushi/webview.part.dart';

/// TODO-904: native WebView2 实例创建失败时，fork 经 onReceivedError 合成的
/// [WebResourceError] 描述里携带的 sentinel 前缀（须与
/// `flutter_inappwebview_windows` 的 `kInAppWebViewCreationFailedSentinel` 字面量
/// 一致）。reader 凭此区分「实例创建失败」与普通页面加载错误，只对前者走可见恢复。
const String kReaderWebViewCreationFailedSentinel =
    'FUSHI_INAPPWEBVIEW_CREATION_FAILED';

/// What the reader-surface caret move resolves to in Dart, given the physical
/// key direction and the `status` fushiCaret.move returned.
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
  String physicalDir,
  String status,
) {
  // A physical Down off the bottom of the content reports either `pageForward`
  // (paged) or `blocked` (continuous, at the document end). Both turn the page.
  if (physicalDir == 'down' && status == 'blocked') {
    return ReaderCaretMoveOutcome.paginateForward;
  }
  if (status == 'pageForward') return ReaderCaretMoveOutcome.paginateForward;
  if (status == 'pageBackward') return ReaderCaretMoveOutcome.paginateBackward;
  return ReaderCaretMoveOutcome.none;
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
}) => !popupVisible && !chromeHasFocus;

/// 视口尺寸变化是否大到需要重排分页（BUG-210 / TODO-146）。
///
/// 桌面端用户报「翻页有时跳回章节开头」。根因不在 JS `paginate`（真实 Chromium
/// 引擎下逐页步进稳健，BUG-169 修复有效），而在 [_ReaderFushiPageState._syncPageSize]
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
/// 翻页才恢复。唯一 resize→重排入口是 [_ReaderFushiPageState.didChangeMetrics]
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

/// BUG-438 / TODO-889：内容就绪兜底超时的 wall-clock 绝对 deadline 计算（纯函数）。
///
/// 根因：手柄连/断引发系统 inset 抖动 → `didChangeMetrics` 每次直连 `_syncPageSize`
/// → 宽变判定触发 `_navigateToChapter` → `_beginNavigation` 把 `_readerContentReady`
/// 置 false 重挂 loading 遮罩，并调 `_startContentReadyTimeout`。旧实现每次都 cancel
/// 旧 8s timer 再起新 8s（相对 deadline）：抖动间隔 < 8s 时兜底永远被推迟、到不了点，
/// loading 遮罩永挂 = 无限 loading（断+重连多次抖动解释「重连概率更大」）。
///
/// 修复 = 改 wall-clock 绝对 deadline。一次 content-not-ready 周期里第一次武装时记下
/// `now + 8s` 的绝对截止时刻；后续抖动重复武装时**保留**仍在未来的旧 deadline（不外推），
/// 抖动多少次兜底都在原 deadline 到点解除 loading。content 真正就绪时清空 deadline，
/// 下一次真实导航重新拿到一个新的 8s 窗口（见 `_clearContentReadyTimeout`）。
///
/// 返回本次 timer 应使用的绝对 deadline：
///   * `existingDeadline` 为 null 或已过期（<= now）→ 开新窗口 `now + timeout`；
///   * 否则保留 `existingDeadline`（抖动不外推）。
DateTime contentReadyTimeoutDeadline({
  required DateTime now,
  required DateTime? existingDeadline,
  Duration timeout = const Duration(seconds: 8),
}) {
  if (existingDeadline == null || !existingDeadline.isAfter(now)) {
    return now.add(timeout);
  }
  return existingDeadline;
}

/// 阅读器主题用的四个颜色角色：正文背景、正文字色、私语(振假名/sasayaki)叠色、
/// 是否暗色。preset 主题在 [_ReaderFushiPageState._themeMap] 里手调，其余主题
/// （light-theme / system-theme / 任意未覆盖的 key）由 [resolveReaderThemeColors]
/// 回落到真实 ColorScheme 派生，避免再写死成白底（BUG-208 / TODO-143）。
typedef ReaderThemeColors = ({
  Color bg,
  Color fg,
  Color sentenceAudioHighlight,
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
  Color? audioHighlightOverride,
}) {
  final ReaderThemeColors base = _resolveBaseReaderThemeColors(
    themeKey: themeKey,
    presetMap: presetMap,
    scheme: scheme,
    customColors: customColors,
  );
  // TODO-977 根因修复：音频高亮（sasayaki 跟随高亮）颜色过去**只在 custom-theme**
  // 时可被用户改（其余主题恒用 primary/preset），所以非自定义主题下「一直用主色」。
  // 这里在五角色色的单一真相源里统一覆盖 sasayaki：只要用户设了全局音频高亮色，
  // 不论当前主题是哪个分支，都写穿到渲染——消除「默认主色恒抢占」这个特殊情况，
  // 而不是给某个主题分支加 if。null 时保持旧的随主题取色（向后兼容）。
  if (audioHighlightOverride == null) return base;
  return (
    bg: base.bg,
    fg: base.fg,
    sentenceAudioHighlight: audioHighlightOverride,
    selection: base.selection,
    link: base.link,
    dark: base.dark,
  );
}

/// 五角色色的「随主题取色」基底，不含 TODO-977 的音频高亮全局覆盖。
ReaderThemeColors _resolveBaseReaderThemeColors({
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
    sentenceAudioHighlight: scheme.primary.withValues(
      alpha: dark ? 0.34 : 0.40,
    ),
    // selection 用 tertiary：与 sasayaki(primary) 错开色相，查词高亮 ≠ 跟读高亮。
    selection: scheme.tertiary.withValues(alpha: dark ? 0.35 : 0.40),
    link: scheme.primary,
    dark: dark,
  );
}

/// EPUB 学习单位（`countStudyChars` 口径）的**全书绝对**偏移：`章首累计 + 章内偏移`。
///
/// `ReadUnitLedger` 的坐标系（`docs/plans/2026-09-06-read-unit-ledger.md`）：一个可见
/// 区间的起 / 止都经此换算成全书绝对偏移，章边界对账本透明（章末页 `[start, 章总字数)`
/// 与下一章首页 `[cumulative[N+1], …)` 在同一根数轴上相邻）。[charOffset] clamp 到
/// `[0, 本章字数]`：JS 偏移与 Dart 章字数是同一口径，但零计数占位期 / 口径漂移时不能
/// 越章。[chapter] 越界 / 计数未就绪 / [charOffset] < 0（JS 拿不到 caret）→ -1，调用方
/// 据此不 `arrive`——宁可不计，也不把「拿不到起点」当章首（那会把整段前缀计成新读）。
int absoluteCharOffsetOf({
  required List<int> chapterCumulativeChars,
  required List<int> chapterCharCounts,
  required int chapter,
  required int charOffset,
}) {
  if (charOffset < 0 ||
      chapter < 0 ||
      chapter >= chapterCumulativeChars.length ||
      chapter >= chapterCharCounts.length) {
    return -1;
  }
  final int chapterChars = chapterCharCounts[chapter];
  final int clamped = charOffset > chapterChars ? chapterChars : charOffset;
  return chapterCumulativeChars[chapter] + clamped;
}

/// 阅读时钟「此刻可跑」的统一判据（BUG-2209 / BUG-2208）。
///
/// 三个正交旗：用户在统计浮层手动暂停（[manualPause]）、app 切后台 / 桌面失焦
/// （[lifecycleStopped]）、阅读器面板 / 弹层 / 全页路由压在正文上（[modalDepth] > 0，
/// 对齐 Hoshi Android 的 `modalPaused`）。任一为真都不算在读。页面里所有 start /
/// stop 决策只经这一个判据——旧实现 `_ensureStudyClock` 只看手动暂停旗，后台听书
/// 跟随每次翻章 / 进度刷新都经它把已被生命周期停掉的时钟重新起表。
bool studyClockMayRun({
  required bool manualPause,
  required bool lifecycleStopped,
  required int modalDepth,
}) => !manualPause && !lifecycleStopped && modalDepth == 0;

/// TODO-1229 / BUG-1829：跨章去抖判据（纯函数，供单测锁定「一次连续手势=一次跨章」语义）。
///
/// 危险窗是「**刚跨完一章**」那一段：残余惯性会在刚落地的短章(插图/单页章)边界上再次
/// 触发跨章 → **跳两章**。所以冷却锚定的是**跨章事件本身**——[lastTurnAt] 只在两种真实
/// 事件上 stamp：① 真正发起一次跨章；② 该次跨章落地的新章 content-ready（
/// `_noteChapterTurnSettledIfPending`，TODO-1229 v3 的重锚，覆盖「加载 >450ms 时窗口早
/// 过期」的洞）。距 [lastTurnAt] 不足 [cooldown] 即判为同一手势的残余惯性 → 返回 true
/// （拦截）。[lastTurnAt] 为 null（从未跨章）恒放行。
///
/// **BUG-1829：被拦截 / 被丢弃的输入绝不 stamp。** v2 曾让调用方在拦截和在飞丢弃时把
/// 时间戳滑到当下，想用「输入静默」当手势结束的判据；v3 换成 content-ready 重锚之后那条
/// 滑窗已经多余，却留了下来，于是变成纯粹的危害：真实滚轮每 30~100ms 一个事件，用户只要
/// 还在拨，窗口就被自己的输入无限续期、**永远等不到过期**——拨得越快越不动。单页章
/// （封面/插图/目录/版权页）里每一次滚轮都必须走跨章判定，整章因此成为滚轮死区（实测
/// 100ms 间隔连发 5 次：零跨章；同一本书正文长章同样节奏则正常翻页）。判据维度必须是
/// 「距上次**跨章**多久」，不是「距上次**输入**多久」——后者由用户持续输入控制，等于把
/// 闸门的钥匙交给了被闸门拦住的那一方。
bool chapterTurnCoolingDown({
  required DateTime? lastTurnAt,
  required DateTime now,
  required Duration cooldown,
}) {
  if (lastTurnAt == null) return false;
  return now.difference(lastTurnAt) < cooldown;
}

/// TODO-796：图片/封面页（纯 `<img>`，全章无可读文本）的进度 UI 兜底锚点。
///
/// 这类页 `paginationMetrics.totalChars==0` → JS `fushiProgressDetails()` 返空串
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

/// TODO-1229（第三次复诉的新症状）：漫画「图片合并章节」(双页 spread) 跳章后**图片
/// 闪现即消失**的根因修复。
///
/// spread 页是内联 HTML（两张整页 `<img>`）。旧实现的 `<script>` 在**解析那一刻**就
/// 同步 `callHandler('spreadReady')`——**不等图片 decode**。cf0adf642（BUG-568 v3）把
/// 跨章冷却窗重锚 `_noteChapterTurnSettledIfPending` 接在 spreadReady 上，本意是「新章
/// 内容一就绪就开一个完整 [_kChapterTurnCooldown] 窗口挡住残余滚轮」。但 spreadReady
/// 早于图片可见，整页大图 decode 常 >450ms → 冷却窗在图片 paint 之前就过期 → 图片刚
/// 出现（闪）时残余惯性滚轮不再被拦 → 二次跨章把图片翻走（消失）。单图章节（走分页壳）
/// 不闪，是因为它 restore / `notifyRestoreComplete` 前有 `Promise.all(imagePromises)`
/// 等图片 `load`，content-ready 天然对齐图片可见。
///
/// 修法：让 spread HTML 也**等两张图 `load`/`error` 后再发 spreadReady**，镜像分页壳的
/// `Promise.all(imagePromises)` 契约——`img.complete` 已就绪同步短路、`error` 也算就绪
/// 防坏图/慢图悬空、无图则立即就绪。这样冷却窗重锚对齐真实图片可见时刻，不动 cf0adf642
/// 的冷却闸门/pending 机制，只把「就绪信号」挪到正确时机；Dart 侧 8s
/// `_startContentReadyTimeout` 仍是最终兜底（与分页壳一致）。
///
/// [leftUrl] / [rightUrl] 是已解析的整页图 URL（调用方已按 RTL/LTR 排好左右）。纯字符串
/// 生成、无副作用，供单测锁定「spreadReady 被图片 load 门控」（撤回同步触发 → 守卫转红）。
///
/// BUG-1426：本文档还必须自带**翻页输入**。spread 是第四种独立文档，
/// `_onChapterLoadComplete` 的 spread 守卫（BUG-1280 ③）把整份正文引擎挡在门外，
/// 而滚轮 / 横扫 / 键桥全在那份引擎里 ⇒ 进了双页页面滚轮和翻页键一起失效。三条通道
/// 都直连**既有** Dart handler，Dart 侧不新增翻页语义：
/// * `wheel` → `onWheelPaginate`（直接拼 [kPagedWheelGestureHelperJs]，与正文引擎
///   注入的是**同一份**常量：主轴取绝对值更大的那个 + 抖动余量，`delta > 0` =
///   forward，并回传 trackpad / mouse 供 Dart 侧的手势闸门分流）；
/// * 单指横扫 → `onSwipe`（与正文 `touchend` 分支同款判据：横向分量占优，且位移过
///   [swipeDistThreshold] 或「过 [swipeFastDistThreshold] + 速度 ≥ 900px/s」，`dx < 0`
///   = `'left'`）。阈值由调用方从 [ReaderSettings] 取同一真值传入，不在此另立默认；
/// * 键盘 → [keyBridgeScript]（调用方用 `webViewKeyBridgeScript` 按注册表**当前**绑定
///   生成）。Windows 的 WebView2 一旦持有 OS 焦点，按键只存在于 DOM 里，Flutter 的
///   `Focus.onKeyEvent` 收不到（TODO-1078 / BUG-136 同源）。空串 = 不装键桥。
String buildSpreadPageHtml({
  required String leftUrl,
  required String rightUrl,
  required int swipeDistThreshold,
  required int swipeFastDistThreshold,
  String keyBridgeScript = '',
}) {
  return '''
<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1.0,maximum-scale=1.0,user-scalable=no">
<style>
*{margin:0;padding:0;box-sizing:border-box}
html,body{width:100vw;height:100vh;overflow:hidden;background:#000}
.spread{display:flex;width:100vw;height:100vh}
.spread-half{flex:1;display:flex;justify-content:center;align-items:center;overflow:hidden}
.spread-half img{max-width:100%;max-height:100vh;object-fit:contain;cursor:pointer}
</style>
</head><body>
<div class="spread">
<div class="spread-half"><img src="$leftUrl" class="block-img"/></div>
<div class="spread-half"><img src="$rightUrl" class="block-img"/></div>
</div>
<script>
(function(){
  var imgs = Array.prototype.slice.call(document.querySelectorAll('img'));
  imgs.forEach(function(img){
    img.addEventListener('click',function(){
      window.flutter_inappwebview.callHandler('onImageTap',img.src);
    });
  });
  // BUG-1280：spread 是第四种独立文档（继歌词 BUG-756、VN BUG-1195 之后），HTML 本身
  // 不含正文 fushiReader 的 onTap/onTapEmpty，自带的手势只有「点图片 → onImageTap」。
  // 底栏一收起就没有唤出通道 → 看不到返回按钮 → 退不出这本书。
  //
  // 注意这条在修复前**分平台**：Windows 的 loadData 丢 baseUrl，onLoadStop 判 stale，
  // 正文引擎从不注入，spread 页确实一个唤出通道都没有；Android 保留 baseUrl，判据放行，
  // 正文引擎（含 onTapEmpty）被误注进来，反而"意外"有过一条受 tapEmptyToHideChrome
  // 门控的通道。那条误注入已由 _onChapterLoadComplete 的 spread 守卫堵掉（见其注释），
  // 所以两个平台现在都只剩下面这一条、且语义一致的专桥。
  //
  // 修法镜像歌词的 onLyricsTapEmpty：图片以外（letterbox 留白 / 页缝）的点击走专桥
  // 给 Dart，由 Dart 判唤出还是收起（chrome 可见性的真值只在 Dart 侧）。
  document.addEventListener('click', function(e){
    if (e && e.target && e.target.tagName === 'IMG') return;
    window.flutter_inappwebview.callHandler('onSpreadTapEmpty');
  });
  // BUG-1426：翻页输入。正文引擎（滚轮 / 横扫 / 键桥都在里面）对 spread 文档是
  // 被守卫挡住的，本文档必须自带，否则进了双页页面滚轮和翻页键一起没反应。
  // 滚轮：直接拼 [kPagedWheelGestureHelperJs]——正文引擎注入的就是同一个常量，
  // 「逐字同款」由此成为**结构事实**而不再是一句注释承诺。节流 / 跨章冷却 /
  // 虚拟页翻页全在 Dart 侧那一份，这里不重复实现。
  //
  // BUG-1745：改动前这里是手抄的第二份实现（旧的「轴」判据、只传 2 个参数），
  // 于是触摸板聚合闸门只修好了正文侧，双页模式上下滑一次照样翻 3 页。
$kPagedWheelGestureHelperJs
  document.addEventListener('wheel', function(e){
    _handlePagedWheelTick(e);
  }, {passive: false});
  // 单指横扫：判据与阈值同正文 touchend 分支（横向分量占优 + 距离/速度二选一），
  // 方向约定同样是 dx < 0 → 'left'，直送既有 onSwipe handler（那里按书写方向和
  // invertSwipeDirection 把 left/right 折成 forward/backward）。
  var _swipeStartX = 0, _swipeStartY = 0, _swipeStartAt = 0, _swipeTracking = false;
  var _swipeDoneAt = 0;
  document.addEventListener('touchstart', function(e){
    if (!e.touches || e.touches.length !== 1) { _swipeTracking = false; return; }
    _swipeStartX = e.touches[0].clientX;
    _swipeStartY = e.touches[0].clientY;
    _swipeStartAt = Date.now();
    _swipeTracking = true;
  }, {passive: true});
  document.addEventListener('touchend', function(e){
    if (!_swipeTracking) return;
    _swipeTracking = false;
    var t = e.changedTouches && e.changedTouches[0];
    if (!t) return;
    var dx = t.clientX - _swipeStartX;
    var dy = t.clientY - _swipeStartY;
    var absDx = Math.abs(dx), absDy = Math.abs(dy);
    if (absDx <= absDy) return;
    var velocity = absDx / Math.max(1, Date.now() - _swipeStartAt) * 1000;
    if (absDx < $swipeDistThreshold &&
        !(absDx >= $swipeFastDistThreshold && velocity >= 900)) return;
    if (e.preventDefault) e.preventDefault();
    _swipeDoneAt = Date.now();
    window.flutter_inappwebview.callHandler('onSwipe', dx < 0 ? 'left' : 'right');
  }, {passive: false});
  // 横扫之后浏览器仍可能合成一次 click；不拦就会同时命中 onImageTap（弹图片查看器）
  // 或 onSpreadTapEmpty（翻底栏）。capture 阶段单点吞掉，两个消费者都碰不到它。
  // 用时间窗而非裸标志：preventDefault 已压掉合成 click 时标志不会残留到下一次
  // 真实点击（那会表现成「翻页后第一下点击无效」）。
  document.addEventListener('click', function(e){
    if (!_swipeDoneAt || (Date.now() - _swipeDoneAt) > 700) return;
    _swipeDoneAt = 0;
    e.stopPropagation();
    if (e.preventDefault) e.preventDefault();
  }, true);
  var signaled = false;
  function signalReady(){
    if (signaled) return;
    signaled = true;
    window.flutter_inappwebview.callHandler('spreadReady');
  }
  // TODO-1229：等两张整页图 decode 完（或 error）再发 spreadReady，让跨章冷却窗
  // 重锚对齐图片真实可见时刻，避免大图 decode 期间冷却窗过早过期被残余滚轮二次跨章。
  var pending = imgs.length;
  if (pending === 0) {
    signalReady();
  } else {
    imgs.forEach(function(img){
      if (img.complete && img.naturalWidth > 0) {
        pending -= 1;
        if (pending <= 0) signalReady();
      } else {
        var onOne = function(){
          img.removeEventListener('load', onOne);
          img.removeEventListener('error', onOne);
          pending -= 1;
          if (pending <= 0) signalReady();
        };
        img.addEventListener('load', onOne);
        img.addEventListener('error', onOne);
      }
    });
  }
})();
$keyBridgeScript
</script>
</body></html>
''';
}

/// BUG-1426：spread 独立文档要交回 Dart 的键盘 token 表（[InputBinding.serialize]
/// 原样，如 `ArrowLeft` / `Ctrl+KeyD`）。
///
/// 只导出在双页页面上**真正有意义**的动作：翻页、唤/收底栏、退出书。spread 页没有
/// 正文，查词 / caret / 振假名那些动作在这里无处可施，桥进来只会白白吞掉按键。
///
/// 表由注册表**当前**绑定实时导出而不是硬编码键名（漫画页旧桥写死
/// `ArrowLeft/ArrowRight/Escape` 的教训，BUG-1347）：用户改键后 spread 页跟着变。
/// 注册表未装载时 `bindingsFor` 对每个动作都返回空集，与「用户清空了绑定」在数据上
/// 不可区分，返回空表即可（下一次进 spread 页会拿到真表）。
///
/// **裸 Space 恒排除**：它归正文同款的 `onSpaceKey` 桥（那条经
/// `resolveReaderSpaceOverride` 解析，有声书激活时是播放/暂停而不是翻页）。两座桥
/// 都是本 document 上的独立 `keydown` 监听，同一次按下各命中一次就会翻两页。
List<String> spreadKeyBridgeTokens(
  FushiShortcutRegistry registry, {
  List<ShortcutAction> actions = kSpreadBridgedActions,
}) {
  if (!registry.isLoaded) return const <String>[];
  final List<String> tokens = <String>[];
  for (final ShortcutAction action in actions) {
    for (final InputBinding binding
        in registry.bindingsFor(action).keyboardBindings) {
      // 裸 Space 的排除**与动作属于哪个 scope 无关**：判据只看这一条绑定本身，所以
      // 后来往 [kSpreadBridgedActions] 里加的跨 scope 兜底动作即便被用户绑成裸
      // Space，也一样进不了本表、复活不了双触发。
      if (binding.key == LogicalKeyboardKey.space &&
          binding.modifiers.isEmpty) {
        continue;
      }
      final String token = binding.serialize();
      if (!tokens.contains(token)) tokens.add(token);
    }
  }
  return tokens;
}

/// [spreadKeyBridgeTokens] 导出的动作集（顺序即 token 表顺序，稳定可比较）。
///
/// **允许混入非 reader scope 的动作**：桥的解析侧（[spreadKeyBridgeScopes] /
/// [resolveSpreadKeyBridgeAction]）从本表自身导出要试的 scope，所以往这里加一个
/// 兜底动作（如把「返回上一级」统一成一个跨表面动作后的那个动作）不需要再改任何
/// 解析代码。排在前面的动作所属的 scope 先解析 → **页面专属键永远优先于兜底**。
const List<ShortcutAction> kSpreadBridgedActions = <ShortcutAction>[
  ShortcutAction.readerPageForward,
  ShortcutAction.readerPageBackward,
  ShortcutAction.readerToggleChrome,
  // 「返回上一级」统一成 universal scope 的一个动作后，退书走的就是它；桥的解析
  // scope 由本表自身导出（[spreadKeyBridgeScopes]），所以这里换成跨 scope 的兜底
  // 动作不需要改解析代码，reader 仍排在 universal 之前 → 页面专属键优先。
  ShortcutAction.globalBack,
];

/// `onSpreadKey` 反解析 token 时要依次尝试的 scope，**从 [actions] 自身按出现序
/// 去重导出**，不是另立一份清单。
///
/// BUG-1442：桥此前把「导出哪些动作」（数据）和「解析哪个 scope」（硬编码
/// `ShortcutScope.reader`）分成两处真值，于是往动作集里加任何非 reader scope 的
/// 动作都会**静默失效**——token 进了 JS 表、按下也回传了 Dart，但 `resolveKeyboard`
/// 在 reader scope 里找不到它，`onSpreadKey` 直接早退。两处合成一处后，动作集是
/// 唯一真值，二者不可能漂开。
List<ShortcutScope> spreadKeyBridgeScopes({
  List<ShortcutAction> actions = kSpreadBridgedActions,
}) {
  final List<ShortcutScope> scopes = <ShortcutScope>[];
  for (final ShortcutAction action in actions) {
    if (!scopes.contains(action.scope)) scopes.add(action.scope);
  }
  return scopes;
}

/// 把 `onSpreadKey` 回传的 [binding] 解析成动作：按 [spreadKeyBridgeScopes] 的顺序
/// 逐个 scope 试 [FushiShortcutRegistry.resolveKeyboard]，首个命中即用。
///
/// 顺序即 [actions] 里各 scope 首次出现的顺序，所以页面专属 scope（reader）排在
/// 兜底 scope 之前 → 同一个键被两边都绑时页面专属胜出，与 Flutter 焦点路径的
/// 「reader → audiobook 逐级回退」同构。解析走的仍是与焦点路径**同一个**
/// `resolveKeyboard`，改键对两条路一起生效。
ShortcutAction? resolveSpreadKeyBridgeAction(
  FushiShortcutRegistry registry,
  InputBinding binding, {
  List<ShortcutAction> actions = kSpreadBridgedActions,
}) {
  for (final ShortcutScope scope in spreadKeyBridgeScopes(actions: actions)) {
    final ShortcutAction? action = registry.resolveKeyboard(
      binding.key,
      modifiers: binding.modifiers,
      scope: scope,
    );
    if (action != null) return action;
  }
  return null;
}

/// BUG-213：章内原生滚动回传（`onReaderScroll`）到来时，是否应刷新章内进度。
///
/// 章内进度 UI 字段只在 `_refreshProgress()` 里写；原生滚动（连续模式 window 滚动、
/// 分页模式触摸/trackpad/键盘箭头）此前没有任何刷新通道，进度条要等 10s 轮询或翻章才
/// 更新。setup 脚本新增的 scroll reporter 把滚动回传给这里，但必须在以下时机一律抑制，
/// 避免恢复期程序化滚动、歌词模式或控制器未就绪时误触发：
/// - [restoreInFlight]：章节恢复/重载期间 WebView 正被程序化滚动到锚点；
/// - [lyricsMode]：歌词模式不是正文阅读，无章内进度语义；
/// - !`readerContentReady`：内容尚未就绪，`fushiProgressDetails` 可能算不出总数；
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

/// TODO-937：连续/滚动模式下手动滚动后，是否应重定位字符级焦点环（caret）到
/// 首个可见字符。caret 没有 JS scroll 监听，只在 Dart 显式调 _caretRefresh()
/// 时移动；连续模式手动滚动只走 _refreshProgressFromScroll 刷进度、从不碰
/// caret，旧锚字符随内容滚出视口后焦点环钉死在屏外。该谓词决定是否在
/// 滚动进度刷新落地的同一节流相位补一次 _caretRefresh()：
/// - !`continuousMode`（分页模式）：翻页走 _caretReanchor 已跟随，不走此支；
/// - !`caretActive`：纯触屏无键盘/手柄用户，caret 未激活，零开销；
/// - !`caretOnReader`：caret 在查词弹窗/歌词表面时不动（弹窗滚动是另一套 _scrollIntoView）。
///
/// 门控与 [readerScrollProgressRefreshAllowed] 正交：调用点已在进度门控通过后，
/// 恢复期/重锚 settle/未就绪由那里统一抑制，此谓词只管「连续模式 + caret 在正文」。
/// 纯函数，无副作用，供单测锁定门控真值表（撤销任一守卫 → 对应用例转红）。
bool readerScrollCaretFollowAllowed({
  required bool continuousMode,
  required bool caretActive,
  required bool caretOnReader,
}) {
  return continuousMode && caretActive && caretOnReader;
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

/// B-3 settle 窗（毫秒）：重锚 commit / 听书跟随滚动打点 `_reanchorClearedAt` 后，这么久
/// 之内的 scroll 回传一律不落库（[readerScrollWithinReanchorSettle]）。听书 reveal 的补刷
/// （`_scheduleReanchorSettleProgressRefresh`）也按它排在窗关之后。
const int kReaderReanchorSettleMs = 250;

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
  int settleMs = kReaderReanchorSettleMs,
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
/// - [onAfterCommit]（可选，TODO-933）：commit 成功**清旗之后**确定性回调一次。恢复路径用它
///   补刷进度——`_reanchorPending` 此刻已被 `commitUiScaleReanchorInvocation` 清掉，故补刷读到的
///   `stableProgressInvocation` 不再被 null gate 挡掉，首屏进度条得以 seed。commit 抛异常时
///   **不**调用（旗未确定性清，补刷仍会被挡，没意义）。默认 no-op，不影响缩放/样式重锚路径。
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
  Future<void> Function()? onAfterCommit,
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
      // commit 失败：旗未确定性清，不跑 onAfterCommit 补刷（补刷仍会被 null gate 挡）。
      return;
    }
    // TODO-933：commit 成功清旗之后，确定性补跑一次补刷（恢复路径 seed 首屏进度）。
    // dispose 竞态复检（evalCommit 期间可能 dispose）；补刷异常经 onCommitError 上报后吞掉，
    // 不外抛——它跑在 postFrame 回调里，逃逸会被引擎吞或崩。
    if (onAfterCommit != null && stillAlive()) {
      try {
        await onAfterCommit();
      } catch (e, stack) {
        onCommitError(e, stack);
      }
    }
  });
}

typedef ReaderStableProgressDetails = ({
  int current,
  int total,
  double progress,
  int charOffset,
  int charOffsetEnd,
});

/// Parses `window.fushiProgressDetails()` after the JS-side settled gate.
///
/// A stable `0,total,0` is a valid chapter-start position (manual chapter
/// jumps must still persist it). `null`/empty/invalid/zero-total results mean
/// the reader has not settled enough to make a durable position decision.
///
/// 协议 `current,total,start,end`：第三段 = 当前可见区间起点的章内学习单位偏移
/// （视口首字符，落库恢复锚），第四段 = 当前可见区间**终点**的章内偏移（只喂
/// `ReadUnitLedger`，不落库）。三段输入（旧 shell / 未实现终点探测）向后兼容，
/// 第四段缺省 -1 → 调用方不 arrive（宁可不计）。
ReaderStableProgressDetails? parseReaderStableProgressDetails(dynamic result) {
  if (result == null) return null;
  final String str = result.toString().replaceAll('"', '').trim();
  if (str.isEmpty) return null;

  final List<String> parts = str.split(',');
  if (parts.length < 2) return null;
  final int? current = int.tryParse(parts[0]);
  final int? total = int.tryParse(parts[1]);
  if (current == null || total == null || total <= 0) return null;

  final int charOffset = parts.length >= 3
      ? (int.tryParse(parts[2]) ?? -1)
      : -1;
  final int charOffsetEnd = parts.length >= 4
      ? (int.tryParse(parts[3]) ?? -1)
      : -1;
  return (
    current: current,
    total: total,
    progress: (current / total).clamp(0.0, 1.0).toDouble(),
    charOffset: charOffset,
    charOffsetEnd: charOffsetEnd,
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
    // TODO-1192: 与导入路径同口径——只数实义字符（剔标点/括号/空白），对齐 hoshi。
    (int i) => book.chapterCharacterCount(i),
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

/// TODO-1192: [EpubBooks.chaptersJson] 里每章 `characters` 计数是否已是当前口径
/// （[kChapterCharCountCaliber]）。仅当**每一章**条目都带 `charCaliber` == 当前
/// 版本、且条目数与 [expectedChapters] 一致时返回 true；任一缺标记（旧书 / v1 导入）
/// 或版本不符返回 false，开书据此触发后台按新口径 `countStudyChars` 重算并回写。
/// 与 [charCountsFromChaptersJson] 拆开：后者只管「计数是否可用」（口径无关，旧书也
/// 先用旧计数别闪 0），本函数只管「口径是否最新」。纯函数，供单测锁定判定。
bool chaptersJsonCharCaliberIsCurrent(
  String chaptersJson,
  int expectedChapters,
) {
  if (expectedChapters <= 0) return false;
  final Object? decoded;
  try {
    decoded = jsonDecode(chaptersJson);
  } on FormatException {
    return false;
  }
  if (decoded is! List || decoded.length != expectedChapters) return false;
  for (final Object? entry in decoded) {
    if (entry is! Map) return false;
    if (entry['charCaliber'] != kChapterCharCountCaliber) return false;
  }
  return true;
}

/// BUG-285 / BUG-162（TODO-575 路线·渐进重建 phase2）：位置落库参数归一化，从
/// `_persistPosition` 凿出的纯函数（替换脆弱源码扫描守卫，真行为测见
/// reader_position_save_args_test.dart）。
/// - 分数进度量化为 normCharOffset ∈ [0,10000]（round 定点，恢复端 /10000 还原）。
/// - charOffset >= 0 写精确锚；< 0（WebView 当帧算不出精确偏移的瞬态）必须映射成
///   null——ReaderPositionRepository.save 收到 null 才会「同 section 保留既有精确
///   锚、仅跨 section 失效」；透传 -1 会把精确锚覆盖成 -1，恢复/有声书跨章重锚
///   退化到章首分数粒度（BUG-285 的回归形态）。
({int normCharOffset, int? charOffset}) readerPositionSaveArgs({
  required double progress,
  required int charOffset,
}) {
  return (
    normCharOffset: (progress * 10000).round(),
    charOffset: charOffset >= 0 ? charOffset : null,
  );
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

/// TODO-575 批1: 自定义字体文件头魔数校验（从 [_ReaderFushiPageState._isValidFontData]
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
/// [_ReaderFushiPageState._jumpToGlobalCharOffset] 凿出（原函数保留 navigate/JS
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
  final double progress = chapterLen > 0
      ? (globalOffset - chapterStart) / chapterLen
      : 0;
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

/// 收藏句列表「阅读位置百分比」：由 (章节索引, 章内绝对可匹配字符偏移) 求全书进度分数
/// [0,1]，与 [resolveChapterProgressForGlobalOffset] 互为正/逆（这里 section+offset →
/// 全局偏移 → /总字符）。收藏面板每行右侧显示 `78.6%`，让用户不放音频 / 不复制文本也能
/// 一眼看出这条收藏在书里的位置。
///
/// - [cumulativeChars]：每章起始累积字符（`_chapterCumulativeChars`）。
/// - [charCounts]：每章字符数（`_chapterCharCounts`）。
/// - 章内偏移夹到 `[0, 章长]`（收藏 `normCharOffset` 是 JS 可匹配字符索引，与 Dart 章长
///   同量纲近似；章基 `cumulativeChars[section]` 精确，故全书分数是良好近似）。
///
/// 表为空 / 长度不匹配 / 总字符<=0 / `sectionIndex` 越界时返回 `null`（调用方不显示百分比，
/// 例如章字符账本尚未在本次阅读会话建好时静默不显示，绝不显示错误位置）。
double? favoriteBookProgressFraction({
  required List<int> cumulativeChars,
  required List<int> charCounts,
  required int sectionIndex,
  required int? normCharOffset,
}) {
  if (cumulativeChars.isEmpty ||
      charCounts.isEmpty ||
      cumulativeChars.length != charCounts.length ||
      sectionIndex < 0 ||
      sectionIndex >= cumulativeChars.length) {
    return null;
  }
  final int total = cumulativeChars.last + charCounts.last;
  if (total <= 0) return null;
  final int chapterLen = charCounts[sectionIndex];
  final int inChapter = normCharOffset == null
      ? 0
      : normCharOffset.clamp(0, chapterLen > 0 ? chapterLen : 0);
  final int globalOffset = cumulativeChars[sectionIndex] + inChapter;
  return (globalOffset / total).clamp(0.0, 1.0);
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

class ReaderFushiPage extends BaseSourcePage {
  const ReaderFushiPage({
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
  /// full-screen route). The reentrancy `assert` in `onWebViewCreated` fires in
  /// debug if a second reader is created before the first disposes — see
  /// [debugHookOwner].
  @visibleForTesting
  static Future<dynamic> Function(String source)? debugEvaluateJavascript;

  /// TODO-2603：上面这批调试钩子的**当前所有者 State**（debug-only，`assert` 里读写，
  /// release 被树摇掉）。
  ///
  /// 钩子的生命周期跟着**页面**走，不跟着 WebView 实例走：renderer 死后换 key 重建时
  /// State 不重建、`onWebViewCreated` 会再触发一次并重装钩子，那是合法的。旧的
  /// 「钩子必须为 null」断言分不出「同一页重装」和「两个阅读器同时活着」，重建必炸。
  /// 换成所有者身份判据后，只有**另一个** State 抢装才报错；`dispose` 无条件释放
  /// 所有权。
  @visibleForTesting
  static Object? debugHookOwner;

  /// 测试钩子：抓当前阅读器 WebView 正文为 PNG（经 WebView2 CDP，离屏可用）。
  /// 仅 debug/profile build 在 onWebViewCreated 注册；release / 未在阅读器页时为 null。
  @visibleForTesting
  static Future<Uint8List?> Function()? debugCaptureWebView;

  /// Test hook: reports which surface the char cursor lives on
  /// (`none`/`reader`/`popup`). Set in build, cleared on dispose, asserted out of
  /// release builds. Lets integration tests observe the cursor↔popup transfer.
  @visibleForTesting
  static String Function()? debugCaretSurface;

  /// Test hook: evaluate JS on the top visible dictionary popup (resolved via
  /// `topPopupState`, the same path production uses). Null when no popup is up.
  @visibleForTesting
  static Future<dynamic> Function(String source)? debugEvaluateTopPopup;

  /// Test hook: inject the real audiobook bridge JS (`__fushiHighlight`,
  /// image-pause helpers, sasayaki highlight) on demand. Lets integration tests
  /// drive the production highlight / image-pause reveal path on a plain
  /// (non-audiobook) book in the real paginated WebView, without seeding a full
  /// audiobook. Set in build, cleared on dispose.
  @visibleForTesting
  static Future<void> Function()? debugInjectAudiobookBridge;

  /// Test hook: opens the in-reader quick settings sheet without relying on a
  /// native-device tap. The bottom chrome intentionally stays outside normal
  /// reader focus traversal, so device automation needs this debug entry point
  /// before it can focus the sheet's own controls.
  @visibleForTesting
  static Future<void> Function()? debugOpenQuickSettings;

  /// Test hook: toggles lyrics mode directly for lower-level integration tests.
  @visibleForTesting
  static Future<void> Function()? debugToggleLyricsMode;

  /// Test hook: reports whether the current reader route is displaying a ready
  /// LyricsModeHtml document.
  @visibleForTesting
  static bool Function()? debugLyricsModeReady;

  /// Test hook (TODO-1308 问题②/BUG-696): drives the REAL in-book favorite
  /// jump path (`_jumpToFavoriteSentence` — the same method the quick-settings
  /// sheet's onJumpToFavorite invokes) so integration tests can assert the
  /// landing position without scripting the sheet UI.
  @visibleForTesting
  static Future<void> Function(FavoriteSentence fav)? debugJumpToFavorite;

  @override
  BaseSourcePageState<ReaderFushiPage> createState() => _ReaderFushiPageState();
}

class _ReaderFushiPageState extends BaseSourcePageState<ReaderFushiPage>
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

  /// TODO-1204：查词计数归属本书——[title] 与阅读统计 tile 的聚合键（[EpubBook.title]，
  /// 见 study_segments 的 mediaKey）对齐，[bookKey] 存书身份。
  @override
  ({String? bookKey, String? title})? get lookupBookIdentity =>
      (bookKey: widget.bookKey, title: _book?.title);
  EpubSpreadMap? _spreadMap;

  /// BUG-1280：**上一次交给 WebView 的文档是不是 spread 独立文档**
  /// （[buildSpreadPageHtml]，两张整页 `<img>`，无正文 `fushiReader`）。
  ///
  /// 写点是**三个**，正好是把文档交给 WebView 的三个装载原语：`_loadSpreadPage`
  /// 置位，`_loadChapterDirectly` 与 **`_loadLyricsPage`** 复位。所以它跟踪的是
  /// 「WebView 里现在是什么文档」，而不是「spread map 存不存在」
  /// （`_spreadMap != null` 在整本书生命周期为真，分不出当前这一页是双页还是普通章）。
  ///
  /// **歌词那处最容易漏，本 PR 实现时就漏过**：不在 `_loadLyricsPage` 复位，从双页
  /// 页面切进歌词模式时本标记会残留为真，`_onChapterLoadComplete` 的 spread 守卫把
  /// 歌词分支一起挡掉 → 歌词永远不就绪。新增装载点必须同步写它。
  ///
  /// 存在的理由是 `onLoadStop` 的陈旧判据只比 URL 的 path，而 `_loadSpreadPage`
  /// 传的 baseUrl 与 `_chapterUrl(_currentChapter)` 逐字相同 → 该判据**分不出**
  /// spread 文档和正文章节，于是在保留 baseUrl 的平台上会把整份正文引擎注进
  /// spread 文档。详见 `_onChapterLoadComplete` 的守卫注释。
  bool _spreadDocumentLoaded = false;
  ReaderSettings? _settings;
  String? _extractDir;

  /// v82：本书子表键（= EpubBooks.uid，开书定位时一次解析存下，写库不再逐次
  /// resolve）。null = 书行缺失或旧行无 uid——reader_positions / revealed_images
  /// 的读写跳过，**不**拿 bookKey 兜底写入（epub 域 uid 缺失即 no-op，与
  /// resolveEpubBookUid 的契约一致）。
  String? _bookUid;

  /// 库内 part 文件（extension）改状态的入口：扩展不被视作 State 子类实例成员，
  /// 直接调 @protected 的 setState 会报 invalid_use_of_protected_member。由本 State
  /// 子类持有的这个转发器统一承接。part 中的异步回调可能在 route dispose 后才返回；
  /// 此时状态已不可再更新，统一在转发边界丢弃，避免晚到回调触发 setState-after-dispose。
  void _rebuild(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
  }

  void _onChromeControllerChanged() => _rebuild(() {});

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
  // BUG-2015：连续模式跨章前捕获旧视口，加载期间继续展示，目标章就绪后淡出。
  // 这张图只跨一次章节导航存活；不用于分页/手动跳转，也不落盘。
  MemoryImage? _chapterTransitionSnapshot;
  bool _chapterTransitionCaptureInFlight = false;
  bool _hasEverLoaded = false;
  bool _readerTextContextMenuActive = false;
  // BUG-1236：移动端长按拖选后的非模态选区操作条。旧 showMenu 的全屏
  // ModalBarrier 会截断 WebView 手柄触摸；OverlayEntry 只让按钮区域命中。
  OverlayEntry? _selectionActionBarEntry;
  ReaderSelectionData? _selectionActionData;
  bool _restoreInFlight = false;
  bool _isNavigatingToChapter = false;
  // TODO-1037：跨章推进经过的「纯图片章逐个停留」序列在途时为真，防重入跨章导航。
  bool _imageChapterPauseInFlight = false;
  // BUG-782 加固：PopScope 退出链（onWillPop 异步 flush + closeMedia）在途为真，
  // 并发退出触发（ESC 连按/退出按钮后再 ESC）合并为一次，防连退两级。
  bool _popInProgress = false;
  double _initialProgress = 0;
  // BUG-162: 退出再进的精确恢复锚（section 内绝对字符偏移）。-1 = 无精确锚（旧
  // 存档 / 书签跳转）→ 走粗粒度 restoreProgress 分数。
  int _initialCharOffset = -1;
  // BUG-461: 收藏句跳转的句尾绝对字符偏移（_initialCharOffset + 句长）。-1 = 无（单点
  // 句首锚，旧行为）。仅连续模式横排用它把整句对齐进可见区，句尾不被底栏切。
  int _initialCharOffsetEnd = -1;
  // _refreshProgress 算得的最新精确字符偏移，供退出 flush 与 debounce 保存共用。
  int _lastProgressCharOffset = -1;
  // BUG-459: 临时浏览跳转（收藏句 / 制卡历史跳回原文）整页生命周期内抑制 ReaderPosition
  // 持久化——用户从收藏 / 制卡历史点进来看某句，不应把该书真实阅读进度覆盖成跳转锚。
  // 由 widget.initialBookmarkJump.preserveSavedPosition 在开书时置位；普通打开 / 真实
  // 书签跳转恒 false，照常 debounce / 退出 flush 保存。
  bool _suppressPositionPersist = false;
  String? _initialFragment;
  // TODO-1309: 跨章「文本搜索跳转」落定目标章后要执行的章内精确定位（scrollToSearchMatch
  // 的 JS）+ 绑定的导航代际。旧两段式（调用方在 restore 完成微任务里抢发 scrollToSearchMatch）
  // 会被随后的 settle-reflow / 连续重锚采样冲回章首（双跳）；改为排进队列，由
  // _applyPendingPreciseLocate 在恢复落定且 settle 之后消费。代际用于并发导航去重（顶掉后
  // 代际不匹配即丢弃，不误用到别的章）。null=无待处理。书签/收藏/字符跳转把分数烘进导航
  // （_navigateToChapterAndWait 的 progress），单次原子恢复直接落点，不入本队列。
  final ReaderPreciseLocateQueue _preciseLocateQueue =
      ReaderPreciseLocateQueue();

  double _stableTopInset = 0;
  double _stableBottomInset = 0;

  /// 底栏内容行的自然（未缩放）高度。
  static const double _readerChromeBaseHeight = 56;

  /// 查词弹窗顶部四按钮栏的自然（未缩放）高度。
  static const double _readerPopupHeaderBaseHeight = 48;

  /// 阅读器底栏的隐形界面缩放系数：取自全局 appUiScale（阅读器子树被中和器改写成
  /// 1.0，故不能用 FushiAppUiScale.of）。在 build 里读 appModel 会随缩放变化重建。
  double get _readerChromeScale => appModel.appUiScale;

  // BUG-1438：曾有 `_readerImageMenuScale = normalize(_readerChromeScale)`，把 chrome
  // 的缩放口径套到右键菜单 / 选区操作条上。那是错的——菜单由 PopupMenuRoute / 根
  // OverlayEntry 承载，**在中和器之外**，落在全局 FushiAppUiScale 的缩放画布里，
  // 画布→屏幕这一跳已经按 scale 放大过一次；再乘一次得到 scale²（实测 scale=2 时
  // chrome 文字 40px 而菜单 80px）。菜单尺寸一律写常量，见 chrome.part.dart 的
  // _showReaderImageContextMenuAtGlobalPosition 注释。

  /// 缩放后底栏在屏高度。所有把底栏高度喂给 WebView/光标/焦点环/正文预留的地方都
  /// 走这个 getter，保证视觉高度与预留高度恒等。
  double get _readerChromeHeight => ReaderChromeScaler.scaledHeight(
    _readerChromeBaseHeight,
    _readerChromeScale,
  );
  static const double _infoFontSize = kTopProgressFontSize;

  /// 字数进度状态（[ReaderProgressState]）；下面四个同名 getter/setter 只是转发，
  /// 保持既有调用点与源码守卫不变。
  final ReaderProgressState _progress = ReaderProgressState();
  int? get _progressCurrentChars => _progress.currentChars;
  set _progressCurrentChars(int? v) => _progress.currentChars = v;
  int? get _progressTotalChars => _progress.totalChars;
  set _progressTotalChars(int? v) => _progress.totalChars = v;

  /// 「读过」判据的唯一账本（入账额 = 会话翻过的并集 ∩ [0, 当前位置)，用户 2026-09-06
  /// 裁定，见 `docs/plans/2026-09-06-read-unit-ledger.md`）：单元 = 当前可见区间的全书
  /// 绝对字符偏移 `[start, end)`，由 [_refreshProgress] 每次采样 `arrive`；每次落定按差分
  /// 把新增 / 撤回的学习单位数记进（扣出）当前打开段。替代旧的标量水位 + 速度封顶令牌桶
  /// （`_sessionMaxAbsoluteChars` / `accumulateSessionCharsCapped`）——那套要在恢复完成 /
  /// 进度条拖动 / 搜索跳转 / cue 跳转 / 字数补算五处播种，漏一处就是幻象字数
  /// （BUG-1107 / BUG-2206）；账本只计翻走的单元，跳过的从未成为当前单元，结构上
  /// 不需要播种。
  late final ReadUnitLedger _readLedger = ReadUnitLedger(
    onCredit: (List<(int, int)> fresh) =>
        _ensureStudyClock().addChars(readUnitsLength(fresh)),
    onRetract: (List<(int, int)> retracted) =>
        _ensureStudyClock().retractChars(readUnitsLength(retracted)),
  );

  /// 听书跟随 reveal 落定后的进度补刷（见 `_scheduleReanchorSettleProgressRefresh`）。
  Timer? _revealProgressRefreshTimer;

  List<int> get _chapterCharCounts => _progress.chapterCharCounts;
  set _chapterCharCounts(List<int> v) => _progress.chapterCharCounts = v;
  List<int> get _chapterCumulativeChars => _progress.chapterCumulativeChars;
  set _chapterCumulativeChars(List<int> v) =>
      _progress.chapterCumulativeChars = v;

  /// 书自带 CSS 的净化结果缓存（拦截器热路径，键 = 文件绝对路径）。与
  /// [_sanitizedHtmlCache] 对称封顶：HTML 侧早有 LRU 上限，这侧此前无上限，
  /// 超多 CSS 的书翻遍全书后按路径无限累积。CSS 不随主题/字号变
  /// （_reloadWithCurrentSettings 整体清），逐出后重算无正确性影响。
  static const int _kSanitizedCssCacheLimit = 24;
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

  /// TODO-perf（跨章·图片）预热配额（PR#469 审查）：`_prefetchAdjacentChapterImages`
  /// 把整解码后的位图塞进 WebView 图片缓存，整页插图书（1600×2400 PNG × N）在移动端
  /// 是实打实的内存压力。对齐 [_kChapterHtmlCacheLimit] 那侧的上限思路，这里按张数 +
  /// 磁盘字节双封顶；预热是尽力而为，超配额停下只是少省一点，不影响正确性。
  static const int _kImagePrefetchMaxCount = 4;
  static const int _kImagePrefetchMaxBytes = 8 * 1024 * 1024;

  /// TODO-perf（跨章·图片）阅读方向（PR#469 审查）：预热必须跟着用户读的方向走，写死
  /// `+1` 会在倒着翻章时预热**刚离开的那一章**（纯反效果）。每次 [_beginNavigation]
  /// 按目标章与当前章的相对位置更新；同章重恢复（换字号/重排版）不改方向。
  int _chapterAdvanceDirection = 1;

  // BUG-270: in-flight prefetch dedup — the file path currently being warmed in
  // the background, so a navigation that lands on it does not race a second read.
  String? _prefetchingHtmlPath;

  /// 本书的内容语言（BCP-47）。来自 EpubBooks.language：导入时由 OPF 的
  /// dc:language 回填，或用户在书籍设置里手动指定。null = 未知，正文字体退回
  /// 浏览器默认（不猜，见 content_font_chain.dart）。
  String? _contentLanguage;

  String? _cachedStyleTag;

  /// 样式代际：[_invalidateStyleCache] 每次自增。真异步预取（读盘/净化期间样式
  /// 可能变更）据此丢弃过期结果——styleTag 烤进缓存条目，旧代际结果入缓存=脏数据
  /// （用户刚换的字号/主题被预取章悄悄换回旧样式）。
  int _styleEpoch = 0;

  Timer? _saveDebounce;

  /// 进程退出 flush 回调引用（TODO-086/BUG-191）：initState 登记到
  /// [ExitFlushRegistry]，dispose 注销。退出路径统一 await，保证未到 debounce
  /// 的阅读位置/统计在 exit(0) 前落库。
  ExitFlushCallback? _exitFlushCallback;
  Timer? _progressPollTimer;

  /// renderer 死亡处置（救命动作 = [_buildWebView] 里给 `InAppWebView` 传了非
  /// null 的 `onRenderProcessGone`，否则 Android 会连坐杀掉整个 app）。
  ///
  /// **这里目前仍不重建**（`afterRebuild` 为 null），与漫画/词典弹窗/Lapis 三处
  /// 不同 —— 但理由已经换了，别照抄旧结论。
  ///
  /// 旧理由（已失效）：恢复锚 `_initialProgress` / `_initialCharOffset` 记的是
  /// **进入本章那一刻的快照**，章内滚动只更新 `_lastProgress*`，于是换 key 重建
  /// 后 restore 会回到章首、再被 `_debouncedSavePosition` 如实落库，把 DB 里更靠
  /// 后的真实进度覆盖掉。
  ///
  /// TODO-2603 已把这三处前置全部修掉：
  /// ① 恢复锚的所有权切成两段（见 [ReaderRestoreAnchor]）：恢复在飞时归导航发起
  ///    方，恢复落定后由实时进度采样（`_refreshProgress` /
  ///    `_syncPositionFromWebViewProgress` → `_adoptLiveProgressAsRestoreAnchor`）
  ///    接管。恢复锚因此**结构性地**始终等于当前阅读位置，崩溃回调不需要再临时
  ///    拷 `_lastProgress*`；
  /// ② `onWebViewCreated` 的调试钩子断言改成所有者身份判据
  ///    （[ReaderFushiPage.debugHookOwner]），同一 State 重装合法、两个阅读器
  ///    同时活着仍会炸；
  /// ③ `_refreshProgress` 的 `evaluateJavascript` 补了 try/catch + 日志。
  ///
  /// 剩下的只是**开关**：把 `afterRebuild` 接上「换 epoch key + setState」。刻意
  /// 留到独立一轮做，因为它要连着真机验证（renderer 真死一次、重建后落点与落库
  /// 都对）才算数，与本轮的静态前置不同源。
  ///
  /// flush 侧仍要做满：取消轮询与 debounce（报废 controller 上的
  /// `evaluateJavascript` 会抛成未捕获异步错误）、落盘当前位置、丢掉 controller。
  late final WebViewDeathGuard _webViewDeathGuard = WebViewDeathGuard(
    surface: 'reader_fushi',
    flushBeforeRebuild: () async {
      _progressPollTimer?.cancel();
      _progressPollTimer = null;
      _controller = null;
      await _flushPosition();
    },
  );
  // BUG-380: 滚动进度刷新的「在飞 + 待重跑」守卫。rAF 节流后滚动回传可能高频到来，
  // 每次 _refreshProgress 都 evaluateJavascript 跑较重的 fushiProgressDetails（遍历全章
  // TextNode + caretRangeFromPoint），未加守卫会让多次调用堆积。_scrollProgressInFlight
  // 标记当前是否有一次滚动触发的刷新在途；在途时再来的滚动回传只置 _scrollProgressPending，
  // 飞完后补跑一次（coalesce），既不堆积又不丢最终位置。仅作用于滚动路径，不影响 10s 轮询
  // 与翻章恢复直接调 _refreshProgress。
  bool _scrollProgressInFlight = false;
  bool _scrollProgressPending = false;
  // BUG-493 (TODO-1053 Bug B) 根因修复（事件驱动版）：恢复完成后首发 _refreshProgress()
  // 撞上 JS 侧 _reanchorPending=true → stableProgressInvocation 返 null → 顶部进度条隐藏。
  // 旧修复在 Dart 侧武装 120ms×8 轮询重试兜「清旗时机不可知」；现已把 JS 侧清旗收敛到
  // 单一 setter（_sharedJs 的 _setReanchorPending），true→false 转换即 callHandler
  // 'onReanchorSettled'（webview.part.dart 注册）→ Dart 补刷一次进度。事件覆盖所有清旗
  // 路径（含 commit 之外的逃逸路径），轮询重试字段已整体删除。
  // TODO-1229 v2：跨章去抖冷却窗（固定 450ms，对齐默认 wheelPageTurnInterval）。必须
  // 足够长以桥接一次惯性手势内相邻 wheel/touch 事件的间隔(约 16~60ms，偶有尖峰)——冷却窗
  // 若短于间隔会在手势中途重新开启而放行第二次跨章。用固定常量(不跟随用户可调的
  // wheelPageTurnInterval)保证鲁棒：即便用户把章内翻页节流调得很小，跨章冷却仍稳定桥接惯性。
  static const Duration _kChapterTurnCooldown = Duration(milliseconds: 450);
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
  // BUG-438 / TODO-889：内容就绪兜底超时的 wall-clock 绝对截止时刻。手柄连/断
  // inset 抖动反复触发 _beginNavigation → _startContentReadyTimeout 重复武装时，
  // 保留这个仍在未来的 deadline（不外推），保证抖动多次后兜底仍能到点解除 loading。
  // content 真正就绪 / dispose 时由 _clearContentReadyTimeout 清空，下次真实导航
  // 重新拿到新窗口。null = 当前没有武装中的兜底超时。
  DateTime? _contentReadyDeadline;
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
  // BUG-1342：macOS 横向触控板的一次物理滑动会产生持续 1s+ 的 wheel tick。
  // 此 gate 活在 reader State，跨 WebView 文档/章节导航持续存在；只作用于横向主轴，
  // 纵向鼠标滚轮仍保留既有的固定窗口节流手感。
  final ReaderWheelGestureGate _pagedWheelGestureGate =
      ReaderWheelGestureGate();
  // TODO-1229 / BUG-1829：跨章去抖时间戳（独立于 _lastPaginateTime 的章内节流）。BUG-568
  // 案A 的 _paginationInFlight 守卫只覆盖「换章加载+restore」这一段瞬态窗口，而
  // _lastPaginateTime 节流窗口锚定在手势起点(第一 tick)。两窗口都在手势中途失效后，残余
  // 惯性会在刚落地的短章(章首插图页/单页章)边界上再次触发跨章 → **跳两章**。
  //
  // 本时间戳把「下一次跨章」的冷却锚定到**跨章事件本身**，只在两种真实事件上 stamp：
  //   ① [_noteChapterTurn]：真正发起一次跨章；
  //   ② [_noteChapterTurnSettledIfPending]：该次跨章落地的新章 content-ready（v3 重锚，
  //      覆盖「加载 >450ms、期间没有续窗 tick」的洞）。
  // **被冷却闸门拒掉、或被在飞守卫丢弃的输入一律不 stamp**（BUG-1829）：v2 曾靠它们把窗口
  // 滑到当下，用「输入静默」当手势结束判据；v3 的 content-ready 重锚落地后这条滑窗已多余，
  // 却留了下来，于是真实滚轮（每 30~100ms 一个事件）只要用户还在拨就把窗口无限续期，永远
  // 等不到过期——拨得越快越不动，单页章直接成滚轮死区。判据维度是「距上次**跨章**」，不是
  // 「距上次**输入**」。只作用于惯性型输入(滚轮/触摸，throttleMs>0)的跨章决策，不影响章内
  // 翻页，也不节流键盘/手柄(throttleMs=0)。
  DateTime? _lastChapterTurnAt;
  // TODO-1229 第三次复诉（滚轮仍双跳）：v2 冷却窗只靠「换章加载期不断到达的惯性 tick」
  // 把时间戳滑到当下来维持（那条滑窗已由 BUG-1829 删除，见上）。但鼠标滚轮
  // 是**离散**事件流——用户拨两三格越过章末边界后 burst 就结束了，换章加载（整章解析+渲染
  // +restore，常 >450ms）期间**没有**后续 tick 续窗；等新章(短插图/单页章)在边界上
  // 出现时冷却窗早已过期(now - 上次跨章 > 450ms)，紧随其后的残余滚动在新章边界二次跨章 →
  // 「第一次正常然后很快又跳一次」。根因=冷却窗锚在「输入」，而危险窗其实是「新章刚出现的
  // 那一刻」；长加载把两者拉开出一个洞。修法：惯性跨章真正发起导航时置本旗，等新章内容
  // 就绪(content-ready)那一刻**重新把冷却窗 stamp 到当下**——无论加载多久、期间有没有
  // 续窗 tick，新章一出现就有一个完整 [_kChapterTurnCooldown] 窗口挡住残余惯性。键盘/手柄
  // 跨章(throttleMs==0)不置旗、也天然不过冷却闸门，逐次翻章不受影响。
  bool _inertiaChapterTurnPending = false;
  int _lastSavedSection = -1;
  double _lastSavedProgress = -1;
  int _lastProgressSection = -1;
  double _lastProgressValue = 0;

  // TODO-1289：图片防剧透遮罩「点击揭开」的本次阅读会话真相源。揭开只删 WebView 内
  // DOM class，章节 (重)载 / 布局设置切换会重跑分页脚本重新遮罩；把已揭开图片的稳定
  // key（绝对 URL）留在这套内存集里（随本 State 生命周期，覆盖整本书阅读会话），
  // 重载章节时嵌回分页脚本让这些图片跳过重新遮罩。JS 侧经 onImageRevealed 回传。
  final Set<String> _revealedImageKeys = <String>{};

  AudiobookPlayerController? _audiobookController;
  String? _audiobookBookKey;
  String? _srtBookUid;
  Map<int, int>? _srtCueChapterMap;
  List<(int firstIdx, int lastIdx)>? _srtChapterRanges;

  bool _audioSlotResolved = false;
  // TODO-945：有声书片段导出进行中标志（防重入），管线在 audiobook.part.dart。
  bool _audiobookClipExporting = false;
  List<FavoriteSentence>? _favoriteSentencesForBookCache;
  Future<List<FavoriteSentence>>? _favoriteSentencesForBookFuture;

  bool _lyricsMode = false;
  bool _lyricsModeTransition = false;
  // BUG-785: 「上次退出时在歌词模式」的待恢复意图。fresh open 仍先以正文加载
  // （_lyricsMode=false，避免直接整页加载歌词 HTML 跳过 EPUB → iOS 白屏），等 EPUB
  // 内容就绪 + 有声书已挂载后再切歌词（等价用户手动切，已知安全）。一次性，恢复后清零。
  bool _pendingLyricsRestore = false;
  bool _gamepadALongFired = false;
  // 重入守卫：「调整」面板从点击到 show 之间有 DB 读 await，快速连点会二次进入并
  // 弹出两个面板（BUG-026）。打开期间置 true、关闭后于 finally 复位。
  bool get _appearanceSheetOpen => _chrome.appearanceSheetOpen;
  set _appearanceSheetOpen(bool value) => _chrome.appearanceSheetOpen = value;

  // BUG-969：设置实时预览的合并执行器。拖 slider 时 onSettingsChangedLive 每个
  // tick 触发一次，旧实现每次直接跑「CSS 注入 + 样式重锚 + tap-gate 同步 + 整页
  // setState」→ 一次拖动上百趟 WebView 往返叠加、本页 build 每 tick 全量重建。
  // 合并语义：在飞期间的触发只置脏标记、收尾补跑一趟；动作跑时读最新设置，
  // last-write-wins 最终状态不丢；单次设置变更仍立即执行。
  late final CoalescedAsyncRunner _liveSettingsRunner = CoalescedAsyncRunner(
    () async {
      if (!mounted) return;
      // 必须就地 catch：await 边界之后的异步异常（如 WebView 半销毁时
      // evaluateJavascript 抛 PlatformException）会逃进当前 zone，绕过
      // FlutterError.onError/takeException/platformDispatcher，生产里成未捕获
      // 异步错误、测试里让 binding 断言。
      try {
        await _applyStylesLive();
      } catch (e, s) {
        ErrorLogService.instance.log('ReaderFushi.onSettingsChangedLive', e, s);
      }
      if (!mounted) return;
      // BUG-712 ①：highlightOnTap 是 JS 侧点词门控镜像的另一半，设置热更新时同步。
      _syncTapGateJs();
      setState(() {});
    },
  );

  bool _lyricsPageReady = false;
  int _lyricsLoadGeneration = 0;
  int? _lyricsReadyFinalizingGeneration;
  int? _lyricsDocumentLoadGeneration;
  // 首次进入歌词模式的提示对话框的一次性待弹旗：_toggleLyricsMode 进入分支置 true，
  // 歌词文档真正就绪（_onChapterLoadComplete 歌词分支，_lyricsPageReady 置位点）消费。
  // 事件驱动，替代旧的「loadData 后裸 delay 100ms 再弹」（慢机 100ms 未必加载完，
  // 对话框可能压在空白页上）。退出歌词模式随 _lyricsPageReady 一并复位。
  bool _pendingLyricsHintOnReady = false;
  int _lyricsEntryChapter = 0;
  int _lyricsEntryCueIndex = 0;
  int _lyricsCueIndexOffset = 0;
  bool _lyricsCueWindowUsesAllBookCues = false;
  List<AudioCue> _lyricsCueList = const [];

  bool _pausedForLookup = false;

  /// v92：本页**唯一**的阅读时钟兼累计器（时长 / 字数同一段同一 uid），取代旧的
  /// `ReadingTimeTracker` + `_sessionReadingMs` / `_sessionCharsRead` 三处各算各的账
  /// （BUG-1052 / BUG-1107 的形状）。页面不再持有任何可被重锚的会话计数字段。
  StudyClock? _studyClock;

  /// 用户在阅读统计浮层里手动暂停了会话计时。为 true 时 [_ensureStudyClock] /
  /// 生命周期 resumed 都不再 `start()`，直到用户再点一次继续；切屏自动暂停
  /// （BUG-892）与之正交——账仍只在 [StudyClock] 一本。
  bool _studyClockManualPause = false;

  /// app 切后台 / 桌面失焦期间为 true（`didChangeAppLifecycleState`）。BUG-2209：
  /// 后台听书跟随会经 [_ensureStudyClock] 反复到达，必须有一枚生命周期旗让它知道
  /// 「现在不许起表」，而不是只看手动暂停旗。
  bool _studyClockLifecycleStopped = false;

  /// 压在正文上的面板 / 弹层 / 全页路由计数（BUG-2208）。> 0 时时钟停表：调半小时
  /// 外观参数、翻目录、搜书、看插图都不是阅读。经 [_withStudyClockPaused] 增减。
  int _studyClockModalDepth = 0;

  // TODO-291 阶段2：audioHandler 控制流（play/seek/skip/悬浮字幕翻转）订阅已上移到
  // [AudiobookSession]（进程级），reader 不再持有这些订阅。

  /// 底栏全屏按钮的图标状态（进/出全屏两个图标）。
  ///
  /// 只是**显示用的镜像**，不是真相源：真相在 native 窗口那边，每次切换都先读它再取反
  /// （见 `_changeReaderWindowFullscreen`）。用户改用快捷键（默认 F11）切换时这份镜像
  /// 会短暂落后一帧图标——不影响任何行为，下一次按按钮仍按真值走。
  bool _isWindowFullscreen = false;

  /// 全屏切换的串行闸：native 往返期间再点按钮不重入。
  bool _windowFullscreenTransitioning = false;

  /// chrome 显隐状态机的唯一持有者（[ReaderChromeController]）；下面的
  /// `_showChrome` / `_chromeTransientVisible` / `_appearanceSheetOpen` /
  /// `_chromeAutoHideTimer` 只是同名转发，保持既有调用点与源码守卫不变。
  final ReaderChromeController _chrome = ReaderChromeController();

  /// 开书分阶段计时（initState → 首屏恢复完成；有声书槽迟到时补一行）。
  late final ReaderOpenTrace _openTrace = ReaderOpenTrace(widget.bookKey);

  bool get _showChrome => _chrome.showChrome;
  set _showChrome(bool value) => _chrome.showChrome = value;

  // TODO-975: floating chrome (顶部进度 / 底栏) 的「被点击唤出、临时可见」态。挤压
  // 模式恒忽略此旗；悬浮模式下唤出置 true + 武装 _chromeAutoHideTimer，计时到 / 再点
  // 一下立即收起置 false。顶部与底栏共用同一旗与同一计时器（决策#1 时长共用、决策#2
  // 两栏唤出/收起联动）。改 _chromeTransientVisible 不改预留高 → 不需重锚。
  bool get _chromeTransientVisible => _chrome.transientVisible;
  set _chromeTransientVisible(bool value) => _chrome.transientVisible = value;
  Timer? get _chromeAutoHideTimer => _chrome.autoHideTimer;
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
  final FocusScopeNode _chromeFocusScope = FocusScopeNode(
    debugLabel: 'readerChrome',
  );

  // The dictionary popup's Flutter header toolbar (favourite / replay / play /
  // play-from-cue) is a sibling layer of the popup WebView content, reached by
  // Up at the top of the content — exactly like the reader bottom bar relative
  // to the reading content. Its own scope so focus can move into it and back.
  final FocusScopeNode _popupHeaderScope = FocusScopeNode(
    debugLabel: 'popupHeader',
  );

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
      // 桌面端底部状态行取代顶部进度 pill：进度数字挪到右下角，顶部不再有 chrome。
      // 「阅读进度指示」开关在桌面端落到状态行右侧（见 _buildStatusFooter）。
      !_statusFooterEnabled &&
      _readerContentReady &&
      _progressCurrentChars != null &&
      _progressTotalChars != null &&
      _progressTotalChars! > 0 &&
      ReaderFushiSource.instance.showTopProgressBar;

  /// 桌面端底部状态行（ッツ Reader 风格：左阅读追踪 / 右字数进度）是否启用。
  /// 单一真相源 [readerStatusFooterEnabled]：桌面且非歌词模式。
  bool get _statusFooterEnabled => readerStatusFooterEnabled(
    desktop: isDesktopPlatform,
    lyricsMode: _lyricsMode,
  );

  /// 状态行的底部预留高（挤压式：视觉高度 == 预留高度，正文永不压到它下面）。
  /// 不随 `_hasEverLoaded` 翻转——预留从初始 HTML 起就含它，首屏就绪后不必再补发
  /// insets 触发一次 reflow；只有**绘制**才等首次冷加载完成（[_buildStatusFooter]）。
  double get _statusFooterReserve => readerStatusFooterReserve(
    enabled: _statusFooterEnabled,
    footerHeight: kReaderStatusFooterHeight,
  );

  /// 桌面端 ッツ 形态 chrome（顶部工具栏 + 右侧抽屉）是否启用：与状态行同判据
  /// （桌面且非歌词模式），单一真相源 [readerDesktopChromeEnabled]。
  bool get _desktopChromeEnabled => readerDesktopChromeEnabled(
    desktop: isDesktopPlatform,
    lyricsMode: _lyricsMode,
  );

  /// 顶部工具栏的顶部预留高：悬浮态（默认）恒 0；挤压态且底栏占位时占工具栏高
  /// （与 [_bottomChromeReserve] 同一台状态机的上端），并入 [_readerTopOffset]。
  double get _desktopHeaderReserve => readerDesktopHeaderReserve(
    enabled: _desktopChromeEnabled,
    barOccupiesLayout: _hasEverLoaded && _showChrome,
    floating: _bottomBarFloating,
    headerHeight: kReaderDesktopHeaderHeight,
  );

  /// 顶部进度信息条的预留高（单一真相源 [kTopProgressStripHeight]）。历史值为裸
  /// `_infoFontSize * 1.5`，未计入 BUG-547 毛玻璃 pill 后加的上下内边距，导致挤压模式
  /// 下 pill 实高（文字行盒 + 6px 内边距）超出预留、压住正文首行；现改为共享
  /// [kTopProgressStripHeight]（行盒估计 + pill 内边距）。
  static const double _infoStripHeight = kTopProgressStripHeight;

  /// TODO-975 决策#2：顶部进度是否悬浮（点击唤出 + 自动收起 + 不占预留）。
  bool get _topProgressFloating =>
      ReaderFushiSource.instance.topProgressFloating;

  /// TODO-975 决策#3：底栏是否悬浮 == 「点空白处隐藏控制栏」开关。复用既有偏好，
  /// 不另设开关（单一真相源、消除并列特例）。
  bool get _bottomBarFloating =>
      ReaderFushiSource.instance.tapEmptyToHideChrome;

  /// TODO-975：顶部进度的预留高（单一真相源）。关进度 / 悬浮态恒 0（需求 A：关进度
  /// 回收 18px），挤压且显示时占 [_infoStripHeight]。
  double get _topProgressReserve => topProgressReserve(
    showTopProgress: _showTopProgress,
    floating: _topProgressFloating,
    infoStripHeight: _infoStripHeight,
  );

  /// TODO-975：底栏内容行的预留高（不含系统底 inset，单一真相源）。底栏不占位 /
  /// 悬浮态恒 0，挤压且占位时占 [_readerChromeHeight]。占位判据与
  /// [_buildBottomChrome] 的可见条件（_hasEverLoaded && _showChrome）一致。
  double get _bottomChromeReserve => bottomChromeReserve(
    barOccupiesLayout: _hasEverLoaded && _showChrome,
    floating: _bottomBarFloating,
    chromeHeight: _readerChromeHeight,
  );

  /// TODO-975：顶部进度此刻是否绘制。悬浮态额外受 [_chromeTransientVisible]（点击
  /// 唤出、计时自动收起）门控；挤压态恒随 [_showTopProgress]。
  bool get _topProgressShouldPaint => topProgressVisible(
    showTopProgress: _showTopProgress,
    floating: _topProgressFloating,
    transientVisible: _chromeTransientVisible,
  );

  /// TODO-975：底栏此刻是否绘制。挤压态随 [_showChrome]；悬浮态额外受
  /// [_chromeTransientVisible] 门控（与顶部共用同一唤出/收起状态）。
  bool get _bottomBarShouldPaint => bottomBarVisible(
    hasEverLoaded: _hasEverLoaded,
    chromeExpanded: _showChrome,
    floating: _bottomBarFloating,
    transientVisible: _chromeTransientVisible,
  );

  /// TODO-975：是否有任一 chrome 处于悬浮模式（决定是否启用「点击唤出 + 自动收起」
  /// 状态机；都不悬浮时走纯挤压旧路径，无 timer）。
  ///
  /// 桌面端状态行取代顶部进度 pill 之后，顶部进度的悬浮开关在桌面端没有对应的
  /// 可见面，不再算作「有悬浮 chrome」——否则底栏挤压 + 顶部悬浮的组合下点空白会
  /// 进一台什么都不画的状态机（点了没反应）。
  bool get _anyChromeFloating =>
      (_topProgressFloating && !_statusFooterEnabled) || _bottomBarFloating;

  /// BUG-1343：macOS 的 NSWindow 全局启用了透明标题栏 + full-size content，而默认 MD3 根壳
  /// 不挂 MacosWindow/ToolBar。阅读器需自行保留一条可拖拽标题栏，否则原生 WebView
  /// 吞满顶边后窗口没有稳定抓手。其它平台严格为 0。
  ///
  /// BUG-1744：原生全屏下这条带子必须归零。全屏时既没有标题栏也没有交通灯，窗口
  /// 也不能被拖动——留着它就是一条纯浪费的不透明横带（用户报的「顶部横带」），
  /// 还连带把正文整体下压 28pt。这里是单一真相源：[_readerTopOffset] /
  /// [popupTopReserve] / `independentDocumentInsets` / 顶部进度条全部读它。
  double get _macosWindowTitlebarInset =>
      Platform.isMacOS && !_macosFullscreen ? kMacTitleBarHeight : 0;

  /// macOS 原生全屏态。非 macOS 恒为 false。
  bool _macosFullscreen = false;

  double get _readerTopOffset =>
      _stableTopInset +
      _macosWindowTitlebarInset +
      _topProgressReserve +
      _desktopHeaderReserve;

  double get _readerBottomReserve =>
      _bottomChromeReserve + _statusFooterReserve + _stableBottomInset;

  @override
  double get popupBottomReserve =>
      // 弹窗避让只对挤压底栏预留空间；悬浮底栏不占正文位置故 0（避免弹窗为不存在
      // 的预留留白）。_bottomChromeReserve 已含「占位 + 非悬浮」两道门控。
      _bottomChromeReserve > 0 ? _readerBottomReserve : 0;

  @override
  double get popupTopReserve => _stableTopInset + _macosWindowTitlebarInset;

  @override
  bool get popupVerticalWriting =>
      !_lyricsMode && (_settings?.writingMode.startsWith('vertical') ?? false);

  @override
  void initState() {
    super.initState();
    // chrome 状态机的变更（含自动收起计时到点）统一经此重建。
    _chrome.addListener(_onChromeControllerChanged);
    assert(() {
      ReaderFushiPage.debugOpenQuickSettings = () async {
        unawaited(_showAppearanceSheet());
        await Future<void>.delayed(Duration.zero);
      };
      ReaderFushiPage.debugToggleLyricsMode = _toggleLyricsMode;
      ReaderFushiPage.debugLyricsModeReady = () =>
          mounted && _lyricsMode && _lyricsPageReady;
      ReaderFushiPage.debugJumpToFavorite = _jumpToFavoriteSentence;
      return true;
    }());
    WidgetsBinding.instance.addObserver(this);
    // 底栏全屏按钮的图标镜像：进页时问一次 native 真值。不问的话，「在已经全屏的窗口里
    // 打开这本书」从第一帧起图标就是错的（镜像默认 false）。与漫画页的
    // `_readInitialFullscreenState` 同款；桌面才有窗口可全屏。
    if (desktopWindowFullscreenSupported) {
      unawaited(_readInitialWindowFullscreenState());
    }
    _exitFlushCallback = ExitFlushRegistry.instance.register(
      _flushAllForProcessExit,
    );
    // BUG-1744：macOS 全屏进出必须重算顶部让位并把新 inset 回喂给 WebView。
    // didChangeDependencies 只比较 viewPadding，而桌面全屏切换通常不改
    // viewPadding（两边都是 0），所以那条路径永远不会触发。
    _macosFullscreen = MacosFullscreenState.instance.isFullscreen.value;
    MacosFullscreenState.instance.isFullscreen.addListener(
      _onMacosFullscreenChanged,
    );
    unawaited(MacosFullscreenState.instance.ensureRegistered());
    // The inset reading-content focus ring only paints in traditional
    // (keyboard/gamepad) highlight mode; rebuild it when the mode flips so it
    // appears/disappears with the input device, not only on focus changes.
    FocusManager.instance.addHighlightModeListener(_onHighlightModeChanged);
    ReaderFushiSource.onSettingsChangedLive = () {
      if (!mounted) return;
      // BUG-969：经 _liveSettingsRunner 合并（错误处理/tap-gate 同步/setState
      // 都在 runner 动作内），拖动风暴收敛为背靠背串行趟。
      unawaited(_liveSettingsRunner.trigger());
    };
    ReaderFushiSource.onLayoutReloadLive = () {
      if (!mounted) return;
      unawaited(
        _reloadWithCurrentSettings().catchError((Object e, StackTrace s) {
          ErrorLogService.instance.log('ReaderFushi.onLayoutReloadLive', e, s);
        }),
      );
    };
    // 纯 Flutter chrome 布局变化（如反转底栏）只需重建一次重读偏好，
    // 不动 WebView 内容、不重锚、不重排分页。
    ReaderFushiSource.onChromeReloadLive = () {
      if (!mounted) return;
      setState(() {});
    };
    // TODO-975：改变了喂给 WebView 的预留高的 chrome 偏好（开/关顶部进度、顶部/底栏
    // 挤压↔悬浮切换）。除重建外还需重新下发 chrome insets 并重锚连续模式滚动位置，
    // 否则预留高变化触发的 reflow 会把 window.scrollY 归零弹回章首。切换悬浮模式时
    // 先收起临时可见态（新模式从隐藏起步、reserve 自洽）。
    ReaderFushiSource.onChromeReanchorLive = () {
      if (!mounted) return;
      _cancelChromeAutoHide();
      setState(() {
        _chromeTransientVisible = false;
      });
      unawaited(
        _applyChromeInsetsAndReanchor().catchError((Object e, StackTrace s) {
          ErrorLogService.instance.log(
            'ReaderFushi.onChromeReanchorLive',
            e,
            s,
          );
        }),
      );
    };
    _initBook();
  }

  Future<void> _initBook() async {
    // BUG-437: 整个 init 链里多处 DB await（_resolveProfileAndSettings /
    // db.getEpubBook / _resolveAudioSlot / repo.findByBookUid）此前无任何 top-level
    // 错误兜底。任一抛异常（双实例共享 WAL DB 写锁超 busy_timeout 抛 SQLITE_BUSY、
    // 磁盘/解析故障等）就逃逸出这个 async 链 → _book / _audioSlotResolved 永不置好 →
    // 尾部 setState 永不执行 → _buildBody 永远返回 spinner → WebView 从不构造 →
    // 唯一兜底超时 _startContentReadyTimeout（只在 onWebViewCreated 启动）从不触发 →
    // 永久卡加载、无任何恢复路径。这里加 top-level try/catch：捕获任何异常后确定性归还
    // 加载态——记真实异常 + 提示打开失败 + 退回书架（复用 not-found 分支同款 toast+pop
    // 恢复机制），绝不让 spinner 永挂。这是根因修，非纯计时绕过。
    try {
      await _initBookInner();
    } catch (e, stack) {
      debugPrint('[ReaderFushi] _initBook failed: $e\n$stack');
      ErrorLogService.instance.log('ReaderFushi._initBook', e, stack);
      if (!mounted) return;
      FushiToast.show(msg: t.reader_open_failed, severity: ToastSeverity.error);
      // BUG-782 同款并发退出合流：init 失败自动退与用户手动退（PopScope 的
      // onPopInvokedWithResult）可能同窗竞发，两条各自 pop 会连退两级把书架也
      // 弹掉。共用同一把 _popInProgress 锁：用户已在退出就让用户路径收尾，这里
      // 不再补刀；本路径 pop 后页面随即 dispose，锁无需复位。
      if (_popInProgress) return;
      _popInProgress = true;
      Navigator.of(context).pop();
    }
  }

  /// BUG-898：打开书时从 Drift 灌入本书已揭开的图片 key（跨 app 重启持久 + 图片库双向
  /// 同步的真相源）。必须在首次注入分页脚本 revealedKeysJson 之前完成，历史揭开项才不会
  /// 被重新遮罩。DB 失败不阻塞开书（退化为全部遮罩，与旧版一致）。
  Future<void> _loadRevealedImageKeys(FushiDatabase db) async {
    // v82：revealed_images 键 = 书 uid（[_bookUid]，_initBookInner 定位后已就绪）。
    final String? bookUid = _bookUid;
    if (bookUid == null) return;
    try {
      final Set<String> keys = await db.getRevealedImageKeys(bookUid);
      _revealedImageKeys.addAll(keys);
    } catch (e, s) {
      ErrorLogService.instance.log('ReaderFushi.loadRevealedImageKeys', e, s);
    }
  }

  Future<void> _initBookInner() async {
    final FushiDatabase db = appModelNoUpdate.database;

    // TODO-131: profile→settings 链与 book 定位→解析链互不依赖（前者动
    // ReaderFushiSource.readerSettings / active profile，后者动 _book / _extractDir），
    // 并行起跑把 profile/settings 的 DB 往返与 EPUB 解析 isolate 重叠，缩短白屏。
    final Future<void> profileSettingsFuture = _resolveProfileAndSettings(db);
    final Future<_BookLocateResult> bookLocateFuture = _locateBookOnDisk(db);
    // TODO-131 同思路：恢复位置查询提前起跑与解析重叠，消费点仍在原位置 await
    // （书签跳转分支不消费）。v82 起位置键 = EpubBooks.uid，需先等 locate 拿到书行
    // （仍与 profile/settings 链、EPUB 解析 isolate 并行，只比旧的纯并行多一跳
    // locate 依赖——uid 本来就来自那次查询）。uid 缺失（书行不在库/旧行空 uid）
    // 视同无保存位置。ignore() 防「书不在盘上」等早退路径把它留成未处理异步错误；
    // 正常路径 await 时错误照常抛给 _initBook 的兜底。
    final Future<ReaderPosition?> savedPositionFuture =
        widget.initialBookmarkJump != null
        ? Future<ReaderPosition?>.value(null)
        : bookLocateFuture.then((_BookLocateResult located) {
            final String? uid = located.bookRow?.uid;
            if (uid == null || uid.isEmpty) {
              return Future<ReaderPosition?>.value(null);
            }
            return ReaderPositionRepository(db).findByBookUid(uid);
          });
    savedPositionFuture.ignore();

    await profileSettingsFuture;
    if (!mounted) return;
    _settings = ReaderFushiSource.readerSettings;
    _openTrace.mark('settings');

    final _BookLocateResult located = await bookLocateFuture;
    if (!mounted) return;
    _openTrace.mark('located');
    if (!located.exists) {
      debugPrint('[ReaderFushi] book ${widget.bookKey} not found on disk');
      FushiToast.show(
        msg: t.book_file_not_found,
        severity: ToastSeverity.error,
      );
      // 与 _initBook catch 同款 _popInProgress 合流（防与用户手动退出竞发连退两级）。
      if (_popInProgress) return;
      _popInProgress = true;
      Navigator.of(context).pop();
      return;
    }

    final EpubBookRow? bookRow = located.bookRow;
    final String extractDir = located.extractDir;
    _extractDir = extractDir;
    // v82：子表（阅读位置/揭图）键 = 书稳定 uid，一次解析存字段。空 uid（不应
    // 出现，v81 回填兜底）视同缺失——相关写入跳过，不拿 bookKey 兜底。
    // 正文语言：本书手动指定/导入回填的 dc:language > 全局默认内容语言。
    // 书这一档没有独立的「元数据」层——dc:language 在导入时就写进同一列了。
    _contentLanguage = resolveContentLanguage(
      explicit: bookRow?.language,
      globalDefault: appModel.prefsRepo.defaultContentLanguage,
    );
    // 查词卡的**词头**跟这本书的语言走（释义跟词典走）。开书即登记。
    appModel.currentLookupLanguage = _contentLanguage;

    final String? locatedUid = bookRow?.uid;
    _bookUid = (locatedUid == null || locatedUid.isEmpty) ? null : locatedUid;

    // TODO-131: charsFromDb 命中 = 跳过整本 html_parser 计数（导入时已落库）。
    // 缺失（旧书 / 异常）时为 null → 后台 compute 补算，首屏不阻塞。
    List<int>? charsFromDb;
    try {
      _book = await compute(parseBookOnly, extractDir);
      debugPrint(
        '[ReaderFushi] parsed EPUB: ${_book!.chapters.length} chapters',
      );
      if (bookRow != null) {
        charsFromDb = charCountsFromChaptersJson(
          bookRow.chaptersJson,
          _book!.chapters.length,
        );
      }
    } on FormatException catch (e) {
      debugPrint('[ReaderFushi] EPUB parse failed ($e), trying DB metadata');
      _book = await _buildBookFromDb(db, widget.bookKey, extractDir);
      if (!mounted) return;
      _book ??= _buildLegacyBook(extractDir, coverHref: bookRow?.coverPath);
      if (bookRow != null) {
        charsFromDb = charCountsFromChaptersJson(
          bookRow.chaptersJson,
          _book!.chapters.length,
        );
      }
      if (!mounted) return;
      FushiToast.show(
        msg: t.epub_parse_fallback,
        severity: ToastSeverity.warning,
      );
    }

    final List<String> hrefs = _book!.chapters.map((ch) => ch.href).toList();
    debugPrint('[ReaderFushi] chapter hrefs: $hrefs');
    _openTrace.mark('parsed');

    if (charsFromDb != null) {
      // TODO-1192: 先立刻用命中的计数（即便是旧口径 v1，先让进度/总字数有值不闪 0）；
      // 若该缓存不是当前口径（[kChapterCharCountCaliber]），后台按新口径重算并回写 DB，
      // 使书架总字数与后续统计随之对齐 hoshi。
      _applyCharCounts(charsFromDb);
      if (bookRow != null &&
          chaptersJsonCharCaliberIsCurrent(
            bookRow.chaptersJson,
            _book!.chapters.length,
          )) {
        // 当前口径计数兼作 isImageOnlyChapter 的免解析短路提示（方向安全性见
        // [EpubBook.setChapterCharCountHints]）；旧口径方向无保证，不注入，
        // 等后台重算落定后由 _recomputeCharCountsInBackground 补上。
        _book!.setChapterCharCountHints(charsFromDb);
      } else {
        _recomputeCharCountsInBackground();
      }
    } else {
      // DB 计数不可用：以零计数占位（所有消费点已 >0 / empty 守卫，进度回退 JS
      // total、统计暂累 0），同时后台 isolate 重算整本，落定后 _applyCharCounts
      // 补齐 totalChars 并重置统计基准，保证最终进度/统计字数等价、不丢字数。
      _applyCharCounts(
        List<int>.filled(_book!.chapters.length, 0, growable: false),
      );
      _recomputeCharCountsInBackground();
    }

    // TODO-131: spread map 与 audio slot 互不依赖（前者写 _spreadMap/_edgeMatchResults，
    // 后者写 _audiobookController，都只读已就绪的 _book），并行等待两组 DB 往返。
    _openTrace.mark('charCounts');

    // 有声书槽（音频服务初始化 + 会话附着 + 全书 cue 预热）不再挡首屏：正文 WebView
    // 只等书与 spread 表；音频在后台落定后再 _rebuild（底栏出现）并补发 chrome insets。
    // 两种情况必须先等它：① 没有保存位置 → 起点要从当前音频 cue 推；② 歌词模式要
    // 恢复（依赖控制器）。
    final Future<void> audioSlotFuture = _resolveAudioSlot().then((_) {
      _openTrace.markLate('audioSlot');
    });
    await Future.wait(<Future<void>>[
      _initSpreadMap(appModelNoUpdate.database),
      _loadRevealedImageKeys(db),
    ]);
    if (!mounted) return;
    _openTrace.mark('spreadMap');
    if (ReaderFushiSource.instance.lyricsMode) {
      await audioSlotFuture;
      if (!mounted) return;
    }

    final Bookmark? bm = widget.initialBookmarkJump;
    if (bm != null &&
        bm.sectionIndex >= 0 &&
        bm.sectionIndex < _book!.chapters.length) {
      _currentChapter = bm.sectionIndex;
      // BUG-459: 收藏句 / 制卡历史跳转带 charAnchor（getNormalizedOffset 口径的章节内
      // 绝对字符索引，与 _initialCharOffset / ReaderPosition.charOffset 同计量）→ 走精确
      // 字符锚恢复（scrollToCharOffset），不再把绝对索引误当 0-10000 分数 /10000≈0 而
      // 恒跳章首。真实书签 charAnchor==null → 仍按 normCharOffset 分数跳（BUG-162 不变）。
      final int? charAnchor = bm.charAnchor;
      if (charAnchor != null && charAnchor >= 0) {
        _initialCharOffset = charAnchor;
        _initialProgress = 0.0; // 精确锚优先；分数仅作锚算不出时的兜底。
        // BUG-461: 句长可用时算句尾绝对偏移（连续模式横排整句对齐进可见区，句尾不被
        // 底栏切）。无句长（制卡行 / 老收藏）→ -1 退回单点句首锚（旧行为）。
        final int? len = bm.charAnchorLength;
        _initialCharOffsetEnd = (len != null && len > 0)
            ? charAnchor + len
            : -1;
      } else {
        _initialProgress = bm.normCharOffset / 10000.0;
        _initialCharOffset = -1; // BUG-162: 书签按 normCharOffset 分数跳转，非 char 锚。
        _initialCharOffsetEnd = -1;
      }
      // BUG-459: 临时浏览跳转（收藏 / 制卡历史）进入后不覆盖该书已保存的阅读进度——
      // 用户点进来看某句不该毁掉真正的阅读位置。普通书签跳转照常持久化。
      _suppressPositionPersist = bm.preserveSavedPosition;
      _lastProgressSection = _currentChapter;
      _lastProgressValue = _initialProgress;
      _lastProgressCharOffset = _initialCharOffset;
      debugPrint(
        '[ReaderFushi] restore from bookmark: '
        'chapter=$_currentChapter progress=$_initialProgress '
        'charAnchor=$_initialCharOffset '
        'preserveSavedPosition=$_suppressPositionPersist',
      );
    } else {
      final ReaderPosition? saved = await savedPositionFuture;
      if (!mounted) return;
      debugPrint(
        '[ReaderFushi] restore lookup: bookKey=${widget.bookKey} '
        'saved=$saved section=${saved?.sectionIndex} '
        'offset=${saved?.normCharOffset}',
      );
      if (saved != null &&
          saved.sectionIndex >= 0 &&
          saved.sectionIndex < _book!.chapters.length) {
        _currentChapter = saved.sectionIndex;
        _initialProgress = saved.normCharOffset / 10000.0;
        // BUG-162: 有精确锚就用它（restoreToCharOffset 不动点），否则 -1 回退分数。
        _initialCharOffset = saved.charOffset ?? -1;
        // BUG-461: 存档恢复无句子区间，单点句首锚（仅收藏句跳转才有句尾锚）。
        _initialCharOffsetEnd = -1;
        _lastProgressSection = _currentChapter;
        _lastProgressValue = _initialProgress;
        _lastProgressCharOffset = _initialCharOffset;
      } else {
        // 没有保存位置：起点从当前音频 cue 推，这条路必须等有声书槽落定。
        await audioSlotFuture;
        if (!mounted) return;
        _restoreFromCurrentAudioCue();
      }
    }
    _openTrace.mark('position');

    if (_settings!.keepScreenAwake) {
      try {
        WakelockPlus.enable();
      } catch (e) {
        debugPrint('[Fushi] wakelock enable failed: $e');
      }
    }

    final ReaderFushiSource src = ReaderFushiSource.instance;
    if (src.volumePageTurningEnabled) {
      _setupVolumeKeyHandlers();
    }

    _syncDictionaryTheme();

    // BUG-785: 歌词模式改为可跨会话恢复（用户请求「重进书籍还在歌词模式」）。
    // fresh open 仍先以正文加载（_lyricsMode=false）——直接按 persisted lyrics_mode
    // 让 WebView 整页加载歌词 HTML、跳过 EPUB 正文，iOS 大字幕书会内容超时甚至白屏。
    // 这里把「上次是歌词模式」记成待恢复意图（保留偏好、不再抹除），等 EPUB 内容就绪
    // + 有声书已挂载后（见 _onChapterLoadComplete）再切歌词，等价用户手动切、已知安全。
    _lyricsMode = false;
    _pendingLyricsRestore = ReaderFushiSource.instance.lyricsMode;

    _audioSlotResolved = true;

    setState(() {});

    // 有声书槽迟到落定：底栏 / 状态行接线要重建，且底栏预留可能从 0 变非 0，补发一次
    // chrome insets（与 BUG-467 首屏补发同一条路）。附着失败只记日志，不影响正文。
    unawaited(
      audioSlotFuture
          .then((_) {
            if (!mounted) return;
            _rebuild(() {});
            if (_hasEverLoaded) _reapplyChromeInsetsAfterFirstLoad();
          })
          .catchError((Object e, StackTrace s) {
            ErrorLogService.instance.log(
              'ReaderFushi.resolveAudioSlot(deferred)',
              e,
              s,
            );
          }),
    );
  }

  /// TODO-131: 按 bookKey 查 EpubBooks 行 + 校验磁盘目录存在。与 profile/settings
  /// 链并行起跑；`chaptersJson` 随行带回，供 [charCountsFromChaptersJson] 复用计数。
  Future<_BookLocateResult> _locateBookOnDisk(FushiDatabase db) async {
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
  /// [_applyCharCounts] 补齐总字数，并 `_readLedger.reset()`：全书绝对偏移的坐标系
  /// 整体变了（章首累计 / 章字数都换口径），零计数期间记下的并集与当前单元不再有
  /// 意义——清并集 + 丢当前，从下一次采样重新起单元。
  void _recomputeCharCountsInBackground() {
    final EpubBook? book = _book;
    if (book == null || book.chapters.isEmpty) return;
    unawaited(
      compute(countChapterChars, book)
          .then((List<int> counts) {
            // 书可能在重算期间被换（重载 / 退出）；仅当仍是同一本、长度一致才采用。
            if (!mounted ||
                !identical(_book, book) ||
                counts.length != book.chapters.length) {
              return;
            }
            _applyCharCounts(counts);
            // 新口径计数落定：补注 isImageOnlyChapter 的免解析短路提示（开书时旧口径
            // 未注入的书由此补齐，后续 spread 重建/预取不再逐章解析）。
            book.setChapterCharCountHints(counts);
            _readLedger.reset();
            // TODO-1192: 把新口径计数回写 chaptersJson（含 charCaliber 标记），使书架总
            // 字数与下次开书都用新口径，避免每次开书都重算（旧书 / v1 书一次性升级）。
            unawaited(_persistRecomputedCharCounts(counts));
          })
          .catchError((Object e, StackTrace s) {
            ErrorLogService.instance.log(
              'ReaderFushi._recomputeCharCountsInBackground',
              e,
              s,
            );
          }),
    );
  }

  Future<EpubBook?> _buildBookFromDb(
    FushiDatabase db,
    String bookKey,
    String extractDir,
  ) async {
    final EpubBookRow? row = await db.getEpubBook(bookKey);
    if (row == null) return null;

    final List<dynamic> rawChapters =
        jsonDecode(row.chaptersJson) as List<dynamic>;
    if (rawChapters.isEmpty) return null;

    final List<EpubChapter> chapters = <EpubChapter>[];
    // BUG-1203：资源拦截器按 [EpubBook.mediaType]（即 resources 表）判「这是不是该
    // 走 HTML 处理链的内容文档」。这条 DB 元数据回退路径此前不建 resources，判据在
    // 这里只能退回扩展名猜测——正是「OPF 解析失败 + 章节用怪扩展名」这本书会整本
    // 空白的场景。chaptersJson 里逐章存着导入时解析到的 mediaType，直接灌进去，
    // 主路径与回退路径就用同一份真相源，无需在拦截器里分叉。
    final Map<String, EpubResource> resources = <String, EpubResource>{};
    final String normExtractDir = p.normalize(extractDir);
    for (int i = 0; i < rawChapters.length; i++) {
      final Map<String, dynamic> ch = rawChapters[i] as Map<String, dynamic>;
      final String href = ch['href'] as String;
      final File file = File(p.join(extractDir, href));
      final String html = file.existsSync() ? file.readAsStringSync() : '';
      final String mediaType = ch['mediaType'] as String? ?? 'text/html';
      chapters.add(
        EpubChapter(
          id: ch['id'] as String? ?? 'section-$i',
          href: href,
          mediaType: mediaType,
          html: html,
          spineIndex: i,
        ),
      );
      // BUG-1218：key 与 filePath 必须与 [EpubParser._resolveWithinExtract] /
      // [EpubParser._relHref] **同构造**——越界判据用 canonicalize（大小写折叠，
      // `../` 逃逸不被绕过），真实路径与键用 normalize（**保留大小写**）。此前这里
      // 用 canonicalize 建键，而 parser 侧与拦截器侧都已改成保留大小写，三方
      // 2:1 不一致：混合大小写的书在这条回退路径上 resources 永远查不中，
      // BUG-1203 的「OPF media-type 优先」静默退回扩展名兜底；filePath 折成小写
      // 更让大小写敏感平台直接读不到文件。
      final String joined = p.join(extractDir, href);
      if (!p.isWithin(p.canonicalize(extractDir), p.canonicalize(joined))) {
        continue;
      }
      final String absPath = p.normalize(joined);
      final String relPath = p
          .relative(absPath, from: normExtractDir)
          .replaceAll('\\', '/');
      resources[normalizeHref(relPath)] = EpubResource(
        mediaType: mediaType,
        filePath: absPath,
      );
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

    debugPrint(
      '[ReaderFushi] built from DB: ${chapters.length} chapters, '
      '${toc.length} toc entries',
    );

    return EpubBook(
      title: row.title,
      author: row.author,
      chapters: chapters,
      toc: toc,
      // TODO-1299: 主解析路径 parseBookOnly 会设 coverHref，制卡才能带书籍封面；
      // 此 DB 元数据回退路径也必须带上，否则 mining 的 `_book?.coverHref != null`
      // 分支永不进，制卡恒无封面。row.coverPath 正是导入时落库的相对封面路径
      // （epub_importer.dart: coverPath = book.coverHref），与 _extractDir 拼接即封面文件。
      coverHref: row.coverPath,
      resources: resources,
      rootDirectory: extractDir,
    );
  }

  EpubBook _buildLegacyBook(String extractDir, {String? coverHref}) {
    final List<FileSystemEntity> htmlFiles =
        Directory(extractDir).listSync(recursive: true).where((e) {
          if (e is! File) return false;
          final String ext = p.extension(e.path).toLowerCase();
          return ext == '.html' || ext == '.xhtml' || ext == '.htm';
        }).toList()..sort((a, b) => compareAudioFilePath(a.path, b.path));

    final List<EpubChapter> chapters = <EpubChapter>[];
    for (int i = 0; i < htmlFiles.length; i++) {
      final File f = htmlFiles[i] as File;
      chapters.add(
        EpubChapter(
          id: 'section-$i',
          href: p.relative(f.path, from: extractDir).replaceAll('\\', '/'),
          mediaType: 'text/html',
          html: f.readAsStringSync(),
          spineIndex: i,
        ),
      );
    }

    return EpubBook(
      title: t.untitled_book(id: widget.bookKey),
      chapters: chapters,
      // TODO-1299: 传入 DB 行的 coverPath（旧书 / 无 DB 行时为 null），使制卡封面
      // 链路在纯目录回退时也不丢封面。
      coverHref: coverHref,
      rootDirectory: extractDir,
    );
  }

  /// TODO-1192: 把后台按新口径（`countStudyChars`）重算出的每章字数回写进
  /// [EpubBooks.chaptersJson]，并打上当前口径版本 [kChapterCharCountCaliber]，使书架
  /// 总字数（[ReaderFushiSource] 直接读 chaptersJson 的 characters）与下次开书都用
  /// 新口径，不必每次开书重算。只覆写 `characters` / `charCaliber` 两个字段、保留原有
  /// 条目结构（id/href/mediaType 等）——绝不改章节数或顺序；数量不符（竞态换书 / 脏
  /// 数据）宁可跳过不写，也不写坏结构（下次开书再算）。
  Future<void> _persistRecomputedCharCounts(List<int> counts) async {
    final String bookKey = widget.bookKey;
    try {
      final EpubBookRow? row = await appModel.database.getEpubBook(bookKey);
      if (row == null) return;
      final Object? decoded = jsonDecode(row.chaptersJson);
      if (decoded is! List || decoded.length != counts.length) return;
      final List<Object?> updated = <Object?>[];
      for (int i = 0; i < decoded.length; i++) {
        final Object? entry = decoded[i];
        if (entry is! Map) return;
        final Map<String, Object?> next = Map<String, Object?>.from(entry);
        next['characters'] = counts[i];
        next['charCaliber'] = kChapterCharCountCaliber;
        updated.add(next);
      }
      await appModel.database.updateEpubBookChaptersJson(
        bookKey,
        jsonEncode(updated),
      );
    } catch (e, stack) {
      ErrorLogService.instance.log(
        'ReaderFushi._persistRecomputedCharCounts',
        e,
        stack,
      );
    }
  }

  @override
  void dispose() {
    // 关书 = 离开当前单元：先把它结算进时钟（翻走即计），再走下面的 flush。必须在
    // [_failNavigation] 之前——那里会 `_readLedger.discard()`（导航中止路径不计），
    // 而关书那页是用户真读到的。
    _readLedger.leave();
    // Search navigation can still be awaiting restore while the route closes.
    // Complete it as failed now (and clear its precise-locate request) instead
    // of leaving the callback alive until the 10-second timeout.
    _failNavigation();
    MacosFullscreenState.instance.isFullscreen.removeListener(
      _onMacosFullscreenChanged,
    );
    assert(() {
      // TODO-2603：页面走了就释放钩子所有权，下一个阅读器才能装（无条件清，与旧行为
      // 逐字一致——钩子本来就是无条件清的，这里只多清一个所有者字段）。
      ReaderFushiPage.debugHookOwner = null;
      ReaderFushiPage.debugEvaluateJavascript = null;
      ReaderFushiPage.debugCaptureWebView = null;
      ReaderFushiPage.debugCaretSurface = null;
      ReaderFushiPage.debugEvaluateTopPopup = null;
      ReaderFushiPage.debugInjectAudiobookBridge = null;
      ReaderFushiPage.debugOpenQuickSettings = null;
      ReaderFushiPage.debugToggleLyricsMode = null;
      ReaderFushiPage.debugLyricsModeReady = null;
      ReaderFushiPage.debugJumpToFavorite = null;
      return true;
    }());
    ReaderFushiSource.onSettingsChangedLive = null;
    ReaderFushiSource.onLayoutReloadLive = null;
    ReaderFushiSource.onChromeReloadLive = null;
    ReaderFushiSource.onChromeReanchorLive = null;
    FocusManager.instance.removeHighlightModeListener(_onHighlightModeChanged);
    final ExitFlushCallback? exitFlush = _exitFlushCallback;
    if (exitFlush != null) {
      ExitFlushRegistry.instance.unregister(exitFlush);
      _exitFlushCallback = null;
    }
    WidgetsBinding.instance.removeObserver(this);
    _removeSelectionActionBar();
    _progressPollTimer?.cancel();
    _revealProgressRefreshTimer?.cancel();
    _saveDebounce?.cancel();
    _scrollProgressThrottleTimer?.cancel();
    _contentReadyTimer?.cancel();
    _contentReadyDeadline = null;
    final MemoryImage? chapterTransitionSnapshot = _chapterTransitionSnapshot;
    _chapterTransitionSnapshot = null;
    if (chapterTransitionSnapshot != null) {
      unawaited(chapterTransitionSnapshot.evict());
    }
    _resizeRepaginateDebounce?.cancel();
    _chromeAutoHideTimer?.cancel();
    _chrome.removeListener(_onChromeControllerChanged);
    _chrome.dispose();
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
          ErrorLogService.instance.log(
            'ReaderFushi.disposeStopAudiobook',
            e,
            s,
          );
        }),
      );
    }
    _studyClock?.dispose();
    _focusNode.dispose();
    _chromeFocusScope.dispose();
    _popupHeaderScope.dispose();
    try {
      WakelockPlus.disable();
    } catch (e) {
      debugPrint('[Fushi] wakelock disable failed: $e');
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
    // 离开当前单元（翻走即计）后再结算时钟，让最后一页的字数进同一段。
    _readLedger.leave();
    await _flushReadingStats();
    // TODO-831：「退出后续播」关闭（audiobookBackgroundPlay=false）时，把真正
    // 停会话从 dispose 提前到这里——此刻页面仍 mounted、pop 动画尚未开始，
    // [AudiobookSession.stop] 的**同步首段**（第一个 await 之前）就把会话置空
    // （_book/_controller = null + notifyListeners），下层书架在 pop 动画首帧重建时
    // NowListeningMiniBar 即见空会话从一开始 SizedBox.shrink，消除「显一帧再收起」
    // 的闪播放条。dispose() 里的 unawaited(stop()) 兜底保留（硬 kill / 系统回收 /
    // 非 PopScope 退出路径 onWillPop 不一定跑到），stop() 内部对已清空的 controller
    // 做 no-op，二次调用安全。
    //
    // BUG-1273：这里**不得 await** stop()。stop() 的 await 段是「停 native 播放器 +
    // 销毁解码器」（stopPlayback → just_audio `_setPlatformActive(false)` 拆平台，
    // 随后 disposeAndRelease 再 await 一次 `_player.dispose()`），耗时不可控，且
    // **只有播放态才真正干活**（暂停态几乎瞬时返回）。而 onSourcePagePop 被
    // onWillPop await、onWillPop 又被 PopScope 的 onPopInvokedWithResult await，
    // 外层还有 `_popInProgress` 单飞门：一旦这一步慢/挂，用户播放中按返回（手势
    // 侧滑 / 返回键 / ESC）第一次触发就把单飞门顶住，**后续每一次返回都被静默丢弃**，
    // 直到 native 播放器真停下来那一刻才连着止声一起 pop——用户感知就是「播放时侧滑
    // 返回无效，等句子停了那次返回才生效」。会话可见状态由同步首段负责，native 资源
    // 释放与「用户已经离开这一页」无因果关系，改 fire-and-forget（catchError 兜住
    // 平台异常，语义与 dispose 路径一致）。
    if (!appModel.audiobookBackgroundPlay) {
      unawaited(
        appModel.audiobookSession.stop().catchError((Object e, StackTrace s) {
          ErrorLogService.instance.log('ReaderFushi.popStopAudiobook', e, s);
        }),
      );
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
        // video 面属于视频页，阅读器不可能持有——防御性忽略。
        case CaretSurface.video:
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
    // BUG-438 / TODO-889：手柄连/断引发系统 inset 抖动，旧实现每帧 postFrame 直连
    // _syncPageSize → 宽变触发 _navigateToChapter → 反复把 _readerContentReady 置 false
    // 重挂 loading，配合相对 8s 兜底超时被反复推迟 → 无限 loading。改走与
    // _onReaderConstraintsChanged 共享的 ~50ms 尾沿防抖（_armResizeRepaginateDebounce），
    // 多次抖动只在 settle 后触发一次重排，且 _syncPageSize 内部基线判定天然去重幂等。
    _armResizeRepaginateDebounce();
  }

  /// BUG-438 / TODO-889 / TODO-690：resize→重排的共享 ~50ms 尾沿防抖武装点
  /// （[didChangeMetrics] 与 [_onReaderConstraintsChanged] 此前逐字重复的两份收敛于此）。
  /// 先取消旧 timer 再起新的（拖拽期不堆积），timer 回调 mounted 守卫后调
  /// [_syncPageSize]；timer 在 dispose 取消（_resizeRepaginateDebounce?.cancel()）。
  void _armResizeRepaginateDebounce() {
    _resizeRepaginateDebounce?.cancel();
    _resizeRepaginateDebounce = Timer(const Duration(milliseconds: 50), () {
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
      // BUG-892: 进后台/失焦（桌面切窗 = inactive）时停掉阅读时钟——否则后台挂起、
      // 熄屏、睡眠期间的墙钟时长会在恢复时被一次性计入（34h 的书 / 单小时 >1h / 凌晨
      // 幻影阅读）。这就是「切屏自动暂停」：stop() 先结算失焦瞬间的部分窗口（受
      // kMaxReadingGap 守卫）再封段落库，时长与字数在同一段里一起写穿。
      // BUG-2209：置生命周期旗再经统一判据停表——后台听书跟随经 _ensureStudyClock
      // 到达时看到旗子，不会把时钟重新起起来。
      _studyClockLifecycleStopped = true;
      _syncStudyClockRunState();
    } else if (state == AppLifecycleState.resumed) {
      // TODO-900: OS 层失焦（Alt+Tab 切窗）后 Flutter 不保证把 primaryFocus 归还到
      // 页级 [_focusNode]，导致切窗回来后页级 / 全局快捷键全死，且因是焦点状态而非可
      // 重建对象，只有重启 app 才靠 autofocus 抢回。对齐视频页 [_reclaimVideoFocusIfOwned]
      // 的 resumed 回收范式，把焦点收回正文（门控见 helper，绝不抢对话框 / 查词焦点）。
      _focusOwnership.reclaim(FocusReclaimCause.appResumed);
      // BUG-892 / BUG-1052: 后台那段间隔靠「时钟停着」丢弃，而不是靠回前台重锚一个
      // 墙钟基准——后者会连同重锚前那段**真实前台阅读时长**一起抹掉。start() 只重锚
      // tick 起点并开新段；不存在第二个可被重置的时钟。用户手动暂停 / 面板仍开着时
      // 不自动续表（统一判据 studyClockMayRun）。
      _studyClockLifecycleStopped = false;
      _syncStudyClockRunState();
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
    debugPrint(
      '[ReaderFushi] _syncPageSize w=$w h=$h '
      'paginated=$_paginatedWidth x $_paginatedHeight '
      'widthChanged=$widthChanged heightChanged=$heightChanged',
    );
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
      final double progress =
          snapshot?.progress ??
          (hasSameChapterCache ? _lastProgressValue : 0.0);
      final int? charOffset =
          snapshot?.charOffset ??
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
    _armResizeRepaginateDebounce();
  }

  /// BUG-1744：全屏翻转 → 重算 [_macosWindowTitlebarInset] → 回喂 WebView 几何。
  ///
  /// 只 setState 是不够的：JS 侧的 `--chrome-top-inset` 由 [_applyChromeInsets]
  /// 单独推送，不跟着 Flutter 重建走。漏了它，正文 padding-top 会停在旧的 28px
  /// 上（全屏后顶部仍留一条空白带，正是要修的症状）。
  void _onMacosFullscreenChanged() {
    if (!mounted) return;
    final bool next = MacosFullscreenState.instance.isFullscreen.value;
    if (next == _macosFullscreen) return;
    setState(() => _macosFullscreen = next);
    unawaited(_applyChromeInsets());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final EdgeInsets vp = MediaQuery.of(context).viewPadding;
    // TODO-1375：inset（系统安全区 / notch / 全屏进出改变的 viewPadding）变化时，
    // 过去只更新这两个 Dart 字段，却从不把新 inset 回喂给 WebView 的分页几何——
    // padding-top/bottom 的 `--chrome-top/bottom-inset`、竖排 verticalColumnWidthCss
    // 的列高扣项都读它。全屏 / 旋转 / notch 变化后若不回喂，JS 的 `--chrome-*-inset`
    // 停在旧值：列高与边距按 stale inset 算，正文越出可视带、手调页边距被 stale inset
    // 淹没（症状②「调上下边距没用」）。inset 真变时回喂并 re-anchor（复用
    // setChromeInsets 的 `_reanchorPending` 串行契约，幂等）；reader 未就绪 / 歌词模式
    // 由 [_applyChromeInsets] 内部早返回挡掉。桌面 inset 多为 0（此分支不触发，零变化）。
    final bool insetChanged =
        vp.top != _stableTopInset || vp.bottom != _stableBottomInset;
    _stableTopInset = vp.top;
    _stableBottomInset = vp.bottom;
    if (insetChanged) {
      unawaited(_applyChromeInsets());
    }
  }

  // ── UI Build ──────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final Color bgColor = _themeBackgroundColor();

    // TODO-693: appUiScale 变化时（整体界面缩放），连续模式阅读位置会被 reflow 归零弹回
    // 章首（裸 window.scrollY 无分页模式的 snap/lock 保护）。在缩放变化那一帧采锚 + 置旗，
    // 过渡帧 settle 后重锚回原字符。门控/序列见 [_reanchorContinuousForUiScale]。
    // 用 select 只监听 appUiScale 标量，避免 AppModel 任意字段变更都触发重锚。
    ref.listen<double>(appProvider.select((AppModel m) => m.appUiScale), (
      double? previous,
      double next,
    ) {
      if (previous == null || previous == next) return;
      _reanchorContinuousForUiScale();
    });

    // TODO-690 / BUG-399：透明 LayoutBuilder 作为桌面窗口 resize → 重排的通道。
    // 位于 FushiAppUiScaleNeutralizer 之下（路由层 ReaderFushiSource.buildLaunchPage
    // 已用 Neutralizer 包裹本页），在 WebView 子树外层。builder **零几何变换**：只读
    // constraints 交给 _onReaderConstraintsChanged（尾沿防抖起 _syncPageSize），原样返回
    // reader 子树。constraints.biggest 与 _syncPageSize 读的 MediaQuery.size 同处反缩放
    // 还原后的坐标空间，数值等价，故两条 resize 通道靠 _lastSyncedWidth/Height 基线去重。
    // 约束由布局系统每帧驱动，比 didChangeMetrics 更早更可靠（Windows 拖边框时后者滞后）。
    // 小说页是**窗口全屏的合法宿主**之一：全屏键（默认 F11）只在小说 / 漫画 / 视频里
    // 能进入全屏，靠的就是下面那层 [WindowFullscreenHost] 声明。用局部变量而不是把整棵
    // 树往里缩一级，纯粹是为了不给这个文件制造一次全量重缩进的 diff。
    final Widget page = LayoutBuilder(
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
            // 鼠标通道与键盘/手柄挂在同一层（正文 WebView + chrome + 词典弹层的共同
            // 祖先）。`translucent` 让本层自己占住命中；[Listener] 不进手势竞技场也不
            // 消费事件，下层照常收到同一次按下。
            //
            // ⚠️ 本层只覆盖**指针归 Flutter** 的区域。原生 WebView 在非 Windows 上把
            // 指针整个吃掉，正文区那半边由页内 JS 的 `onPointerSeek` 回传（那条路还
            // 承担**位置型**动作「seek 到点击句」，它需要点击坐标，Flutter 侧拿不到）。
            // 两条路的分工判据是 [hostOwnsWebViewPointerInput]，不重复派发。
            child: Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: _handleReaderPointerDown,
              child: PopScope(
                canPop: false,
                onPopInvokedWithResult: (didPop, dynamic result) async {
                  if (didPop) return;
                  // BUG-782 加固：onWillPop 是异步长操作（落位置 flush + closeMedia
                  // 约百毫秒），窗口期内第二次退出触发（ESC/手柄 B 连按、退出按钮后
                  // 再 ESC）会并发再跑一条 onWillPop——首条完成 pop 掉阅读器后，第二
                  // 条的 nav.pop() 会把下面的书架也弹掉（连退两级 + closeMedia/自动
                  // 同步重复执行）。并发退出触发合并为一次。
                  if (_popInProgress) return;
                  _popInProgress = true;
                  try {
                    final nav = Navigator.of(context);
                    final bool allow = await onWillPop();
                    if (allow && mounted) nav.pop();
                  } finally {
                    // onWillPop 异常逃逸时复位，用户可重试退出而非永久困死。
                    _popInProgress = false;
                  }
                },
                child: Scaffold(
                  backgroundColor: bgColor,
                  resizeToAvoidBottomInset: false,
                  body: Stack(
                    fit: StackFit.expand,
                    children: <Widget>[
                      Positioned.fill(child: _buildBody()),
                      if (!_readerContentReady ||
                          _chapterTransitionSnapshot != null)
                        Positioned.fill(
                          child: _buildChapterTransitionOverlay(bgColor),
                        ),
                      if (_readerContentReady)
                        const SizedBox.shrink(
                          key: ValueKey<String>('fushi_content_ready'),
                        ),
                      if (!kReleaseMode && _lyricsMode && _lyricsPageReady)
                        Positioned(
                          left: 0,
                          top: 0,
                          width: 1,
                          height: 1,
                          child: IgnorePointer(
                            child: Semantics(
                              container: true,
                              identifier: 'hibiki.reader.lyrics.ready',
                              label: 'lyrics ready',
                              child: const SizedBox(
                                key: ValueKey<String>('fushi_lyrics_ready'),
                                width: 1,
                                height: 1,
                              ),
                            ),
                          ),
                        ),
                      // On-screen focus indicator for the "reading content" layer,
                      // matching the app's standard focus ring (FushiFocusRing:
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
                                // app-wide FushiFocusRing convention (no focus ring in
                                // touch mode). Rebuilt on highlight change via
                                // _onHighlightModeChanged.
                                final bool show =
                                    _focusNavEnabled &&
                                    _focusNode.hasPrimaryFocus &&
                                    _caretSurface == CaretSurface.none &&
                                    FocusManager.instance.highlightMode ==
                                        FocusHighlightMode.traditional;
                                if (!show) return const SizedBox.shrink();
                                // TODO-975：焦点环预留与喂 WebView 同源 _readerBottomReserve
                                // （悬浮 0 / 挤压含底栏），保证环始终落在正文视口内。
                                final double bottomInset = _readerBottomReserve;
                                return Padding(
                                  padding: EdgeInsets.fromLTRB(
                                    1.5,
                                    _readerTopOffset,
                                    1.5,
                                    bottomInset,
                                  ),
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: Theme.of(
                                          context,
                                        ).colorScheme.primary,
                                        width: 2.5,
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      // BUG-1744：全屏时窗口不可拖动、也没有交通灯要让位——这条
                      // 不透明带在全屏下纯粹是一条顶部横带，必须整体不挂。
                      if (Platform.isMacOS && !_macosFullscreen)
                        Positioned(
                          top: 0,
                          left: 0,
                          right: 0,
                          height: kMacTitleBarHeight,
                          // BUG-1692：本 Stack 里排在 WebView **之后**的每一块 Flutter
                          // 内容都必须自带 RepaintBoundary，否则它们会合并进页面级
                          // RepaintBoundary 那一张 cull rect = 整窗的 PictureLayer，
                          // macOS engine 据此把整窗加进 FlutterMutatorView 的
                          // _hitTestIgnoreRegion，WebView 整块收不到任何鼠标事件。
                          child: RepaintBoundary(
                            child: DragToMoveArea(
                              child: ColoredBox(
                                key: const ValueKey<String>(
                                  'fushi_reader_window_drag_area',
                                ),
                                color: bgColor,
                              ),
                            ),
                          ),
                        ),
                      _buildTopProgressBar(),
                      // 桌面端顶边悬停热区（收起时才存在）+ 顶部工具栏（ッツ 形态）：与底栏
                      // 同一显隐状态机，排在词典弹层之前。
                      _buildHoverRevealLayer(),
                      _buildDesktopHeader(),
                      // 桌面端底部状态行：排在词典弹层 / 底栏之前，让它们盖在其上。
                      _buildStatusFooter(),
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
          ),
        );
      },
    );
    return WindowFullscreenHost(child: page);
  }

  Widget _buildBody() {
    if (!_audioSlotResolved || _book == null || _extractDir == null) {
      return Center(child: adaptiveIndicator(context: context));
    }
    final Widget webView = _buildWebView();
    // BUG-379 / BUG-1343：歌词模式（LyricsModeHtml）与 spread 整页图都是独立 HTML，
    // 没有 window.fushiReader，_applyChromeInsets 对它们整体 early-return，正文那套
    // 「告诉 WebView 预留多少」的机制对它们失效，只能由 Flutter 侧收缩视口本身。
    // 留多少是 [independentDocumentInsets] 说了算（单一真相源，行为单测直接钉它）；
    // 这里只负责喂当前状态并按结果包 Padding。
    // BUG-1381：底部预留曾以 `EdgeInsets.only(bottom: _readerBottomReserve)` 这个**写法**
    // 被静态守卫钉住，PR#670 把顶/底两笔留白合成一个 Padding 后写法变了、行为没变，
    // 守卫却红了。改由纯函数承载契约后，守卫钉的是「预留来自它」而非某种拼写。
    // _showChrome / _hasEverLoaded 切换会触发 _rebuild 重建本树。
    final EdgeInsets independentDocumentPadding = independentDocumentInsets(
      lyricsMode: _lyricsMode,
      spreadDocumentLoaded: _spreadDocumentLoaded,
      // 底栏占位条件与 _buildBottomChrome / popupBottomReserve 一致。
      chromeOccupiesLayout: _hasEverLoaded && _showChrome,
      bottomReserve: _readerBottomReserve,
      titlebarInset: _macosWindowTitlebarInset,
    );
    if (independentDocumentPadding == EdgeInsets.zero) return webView;
    return Padding(padding: independentDocumentPadding, child: webView);
  }

  Widget _buildChapterTransitionOverlay(Color backgroundColor) {
    final MemoryImage? snapshot = _chapterTransitionSnapshot;
    if (snapshot == null) return ColoredBox(color: backgroundColor);
    final Duration fadeDuration = appModel.einkMode
        ? Duration.zero
        : const Duration(milliseconds: 140);
    return IgnorePointer(
      child: ColoredBox(
        color: backgroundColor,
        child: AnimatedOpacity(
          key: const ValueKey<String>('fushi_chapter_transition_snapshot'),
          opacity: _readerContentReady ? 0 : 1,
          duration: fadeDuration,
          curve: Curves.easeOut,
          onEnd: () {
            if (!_readerContentReady ||
                !identical(_chapterTransitionSnapshot, snapshot)) {
              return;
            }
            _rebuild(() => _chapterTransitionSnapshot = null);
            unawaited(snapshot.evict());
          },
          child: Image(
            image: snapshot,
            fit: BoxFit.fill,
            gaplessPlayback: true,
            filterQuality: FilterQuality.low,
          ),
        ),
      ),
    );
  }

  String _buildStyleTag() {
    return _cachedStyleTag ??= _computeStyleTag();
  }

  /// _computeStyleTag / _currentStyleJson 共享的正文 CSS 生成（此前两处以相同参数各调
  /// 一次 [ReaderContentStyles.css]，任一参数改动要双处同步，否则 <style> 标签与
  /// beginStyleReanchor 下发的 CSS 漂移）。两个包装分别包 <style> 标签 / jsonEncode。
  String _currentReaderCss() {
    final ReaderThemeColors rc = _readerThemeColors;
    return ReaderContentStyles.css(
      settings: _settings!,
      themeOverride: appModel.appThemeKey,
      // 正文字体按**书自己的语言**选链（与界面语言无关）：中文界面下打开日文书，
      // 界面该是中文字形、正文该是日文字形，两个独立的正确答案。
      contentLanguage: _contentLanguage,
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
      sentenceAudioHighlightColor: _colorToCssRgba(rc.sentenceAudioHighlight),
      linkColor: _colorToCssRgba(rc.link),
      // 墨水屏模式：全局单开关叠加在阅读器主题之上（纯黑白+线式高亮+关过渡），
      // 黑白方向跟 app 明暗模式，与全局 E-ink ColorScheme 一致。
      einkMode: appModel.einkMode,
      einkDark: appModel.isDarkMode,
    );
  }

  String _computeStyleTag() {
    return '<style id="fushi-reader-style">\n${_currentReaderCss()}\n</style>';
  }

  void _invalidateStyleCache() {
    _cachedStyleTag = null;
    _styleEpoch++;
    // BUG-270: cached chapter HTML bakes in the styleTag, so any style change
    // must drop it — the next served chapter then rebuilds with the fresh tag.
    _sanitizedHtmlCache.clear();
  }

  /// TODO-756b：把“鼠标悬停即自动查词”开关（[ReaderFushiSource.hoverAutoLookup]）
  /// live 下发给 WebView 的全局 `window.__hoverAutoLookup`。setup 脚本注入初值，此处
  /// 在配置变化时改同一全局，无需整章重注入。半销毁 WebView 抛 PlatformException 时
  /// 就地兜底（与 [_applyStylesLive] 同纪律），下发本就无意义 → 安全 no-op。
  Future<void> _applyHoverAutoLookupLive() async {
    if (_controller == null) return;
    final bool enabled = ReaderFushiSource.instance.hoverAutoLookup;
    try {
      await _controller!.evaluateJavascript(
        source: 'window.__hoverAutoLookup = $enabled;',
      );
    } catch (e, stack) {
      ErrorLogService.instance.log(
        'ReaderFushi.applyHoverAutoLookupLive',
        e,
        stack,
      );
    }
  }

  /// 当前正文样式的 JSON 编码（喂给 beginStyleReanchorInvocation）。从 [_applyStylesLive]
  /// 抽出，供它与 TODO-975 的 chrome-inset 重锚（[_applyChromeInsetsAndReanchor]，CSS
  /// 不变但需复用样式重锚的滚动保位）共用同一套色/样式计算；CSS 本体经
  /// [_currentReaderCss] 与 [_computeStyleTag] 同源，双处参数漂移已消除。
  String _currentStyleJson() {
    return jsonEncode(_currentReaderCss());
  }

  Future<void> _applyStylesLive() async {
    if (_controller == null || _settings == null) return;
    _invalidateStyleCache();
    // _settings 即 ReaderFushiSource.readerSettings 本体，setReaderPref* 已在触发本
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
    final String jsonCss = _currentStyleJson();
    // 余白/主题实时不生效根因修复：CSS 换入（用户可见效果）不得被样式重锚的就绪门控
    // [readerStyleReanchorAllowed] 挡掉。旧实现只在 `!window.fushiReader` 时裸换 CSS，
    // 有 fushiReader 时把换 CSS 全托付给下面 gate 后的 beginStyleReanchor；一旦 gate 关闭
    // （内容未就绪 / 重排在飞 / 切章瞬态），[runUiScaleReanchorOrchestration] 在 evalBegin 前
    // 就 return，CSS 被静默丢弃 → 主题/余白改完不生效、必须退出重进重烤 _computeStyleTag
    // 才见效。这里把「换 CSS」与「重锚就绪门控」解耦：重锚会跑（gate 开）时仍交给
    // beginStyleReanchor 原子「采锚→换 CSS」（保翻页保位不裁行）；重锚不会跑（gate 关）时
    // 就地裸换 CSS 并失效 paginationMetrics（让余白几何重新分栏）。二者互斥、绝不双换、
    // CSS 永不丢。
    final bool reanchorWillRun = readerStyleReanchorAllowed(
      controllerAvailable: _controller != null,
      readerContentReady: _readerContentReady,
      lyricsMode: _lyricsMode,
    );
    try {
      await _controller!.evaluateJavascript(
        source:
            '''
(function(){
  var el = document.getElementById('fushi-reader-style');
  if (!el) {
    el = document.createElement('style');
    el.id = 'fushi-reader-style';
    document.head.appendChild(el);
  }
  // 重锚不会跑（无 fushiReader / 内容未就绪 / 重排在飞）时就地换 CSS，并失效分页 metrics
  // 让几何（余白/字号）重新分栏；重锚会跑时不在此换——交给下面 beginStyleReanchor 原子
  // 采锚 + 换 CSS + 置旗（settle-aware commit 保翻页保位）。
  if (!window.fushiReader || ${!reanchorWillRun}) {
    el.textContent = $jsonCss;
    if (window.fushiReader && window.fushiReader.paginationMetrics !== undefined) {
      window.fushiReader.paginationMetrics = null;
    }
  }
})();
''',
      );
    } catch (e, stack) {
      // controller 非 null 但底层 WebView 平台视图已销毁时 evaluateJavascript
      // 抛 PlatformException。无活动 WebView 时套样式本就无意义 → 安全 no-op。
      ErrorLogService.instance.log(
        'ReaderFushi.applyStylesLive.eval',
        e,
        stack,
      );
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
    final FavoriteSentenceRepository repo = FavoriteSentenceRepository(
      appModel.database,
    );
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
    int section,
  ) async {
    final List<FavoriteSentence> favorites = await _favoriteSentencesForBook();
    return favorites
        .where(
          (FavoriteSentence s) =>
              s.bookKey == widget.bookKey && s.sectionIndex == section,
        )
        .toList(growable: false);
  }

  Future<void> _applyChapterHighlights() async {
    if (_controller == null) return;
    final List<FavoriteSentence> chapterFavs =
        await _favoriteSentencesForSection(_currentChapter);
    if (!mounted || _controller == null) return;
    final int withOffsets = chapterFavs
        .where((s) => s.normCharOffset != null)
        .length;
    final int total =
        _favoriteSentencesForBookCache?.length ?? chapterFavs.length;
    debugPrint(
      '[fushi-hl] chapter=$_currentChapter '
      'total=$total chapterFavs=${chapterFavs.length} '
      'withOffsets=$withOffsets',
    );
    if (chapterFavs.isNotEmpty) {
      await HighlightBridge.applyHighlights(
        _controller!,
        chapterFavs,
        backgroundHex: _readerBackgroundHex,
        customHighlightCss: _customHighlightCss,
      );
      if (!mounted || _controller == null) return;
      await _controller!.evaluateJavascript(
        source:
            'if (!window.__fushiCssHighlightsSupported) { window.fushiReader && window.fushiReader.buildNodeOffsets(); }',
      );
      // HBK-AUDIT-117: theme persistence moved to _onThemeChanged — it is
      // unrelated to highlight application and must not be gated on favorites.
    }
  }

  Future<void> _applyLyricsFavorites() async {
    if (_controller == null) return;
    final List<FavoriteSentence> all = await _favoriteSentencesForBook();
    if (_controller == null || !mounted) return;
    final List<String> texts = all
        .map((s) => s.text)
        .where((t) => t.isNotEmpty)
        .toList();
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

  /// BUG-1107：显式跳句（skipToCue 漏斗：音量键 / 快捷键 / 底栏按钮 / 媒体通知）
  /// → 把统计字数水位抬到目标 cue 位置，跳过的段落不算已读。实现见
  /// audiobook.part.dart 的 [_handleExplicitCueJump]。
  @override
  void onExplicitCueJump(AudioCue cue) => _handleExplicitCueJump(cue);

  AudioCue? _lookupCue;
  ({int offset, int length, String text})? _cachedSelectionRange;
  ({int offset, int length})? _cachedSentenceRange;
  int? _cachedSentenceOffset;

  /// TODO-1127：选区那一刻抽取到的、夹在选区里的 EPUB 插图（`normOffset` = 图在整书归一化
  /// 文本坐标里的位置，`-1` = 未知 → 兜底挂最前段；`bytes` = 已按需降采样的 PNG/JPEG）。
  /// 与 [_cachedSelectionRange] 同一次原生选区解析原子写入，供片段导出把插图按相对顺序渲进
  /// 卡片；空列表 = 选区无夹图（导出行为与旧版逐字节一致）。
  List<({int normOffset, Uint8List bytes})> _cachedSelectionImages =
      const <({int normOffset, Uint8List bytes})>[];

  /// BUG-492 (TODO-1053 Bug A)。选区发生那一刻 [_lookupSectionIndex] 的快照。收藏 /
  /// 制卡写入的 `sectionIndex` 必须绑定到「选中该句时」渲染的真实章号，而不是写入时刻
  /// 再读裸 [_currentChapter]——有声书连续推进 / 跨章滚动会在选区与写入之间异步改写
  /// [_currentChapter]，把第 N 章的句子记成第 N+1 章 → 恢复端忠实跳错章、charAnchor 在
  /// 错章内合法 → scrollToCharOffset 静默停错位。与 [_cachedSentenceRange] 同批（同一次
  /// `onTextSelected` / 原生选区解析）原子写入，消除 Dart 侧 section 与选区异章。null =
  /// 无缓存选区，消费点 [_favoriteSectionIndex] 回退当前 [_lookupSectionIndex]（旧行为）。
  int? _cachedSelectionSectionIndex;
  bool _currentSentenceIsFavorited = false;

  /// BUG-494 (TODO-1053 Bug C)：当前句若已收藏，缓存其**精确条目 id**（未收藏 → null）。
  /// 取消收藏走 [FavoriteSentenceRepository.removeById]（按此 id 删单条），杜绝身份键坍缩下
  /// 的连坐误删——同章重复短句 normCharOffset 均 null 时内容键相同，若按内容删会把另一条
  /// 同内容记录一起删掉。由 [_checkFavoriteStatus] 与收藏 toggle 同步维护。
  String? _currentFavoriteId;

  /// 收藏 / 制卡写入与「是否已收藏」判定统一取的 section 来源：优先用选区时刻快照的
  /// [_cachedSelectionSectionIndex]（绑定到选中句所在真实章），无快照时回退当前
  /// [_lookupSectionIndex]（首次收藏无前置查词等场景，行为与旧版一致）。
  int get _favoriteSectionIndex =>
      _cachedSelectionSectionIndex ?? _lookupSectionIndex;

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
    _cachedSelectionImages = const <({int normOffset, Uint8List bytes})>[];
    _cachedSelectionSectionIndex = null;
    _currentSentenceIsFavorited = false;
    _currentFavoriteId = null;
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

  /// Niratan「制卡前调整·选择句子上下文」：把当前草稿真实上下文句 + 当前正查句 + 词偏移
  /// 打包给弹窗预览。当前句取制卡同一来源（[MediaSource.currentSentence]，见
  /// [_prepareMiningContext]），词偏移取查词时缓存的 [_cachedSentenceOffset]，保证预览
  /// 与真正落卡的 sentence 字段一致。
  @override
  Future<Map<String, Object?>> onSentenceContextPreviewFromDraft() async {
    final String current =
        appModel.currentMediaSource?.currentSentence.text ?? '';
    return buildSentenceContextPreview(
      draft: _miningDraft,
      current: current,
      currentOffset: _cachedSentenceOffset,
    );
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
  bool _cachedSentenceAudio = false;

  // ── Spread (two-page) support ──────────────────────────────────────

  Map<int, bool>? _edgeMatchResults;

  /// 本页键盘焦点的单一所有者：所有「把焦点收回正文 [_focusNode]」的回收都走它，
  /// 判据集中在 [_canOwnReaderFocus]。
  ///
  /// 取代原先的 `_settleFocusOnContentReady` / `_reclaimReaderFocusIfOwned` /
  /// `_reclaimReaderFocusAfterGesture` / `_reclaimReaderFocusForTouchPopup` 四个
  /// 名字相近、门控各不相同的私有 helper——它们每个都对「弹窗可见时该不该抢」
  /// 给出过不同答案（BUG-136 说不抢、BUG-1071 ② 说必须抢），靠方法名区分极易接错。
  late final PageFocusOwnership _focusOwnership = PageFocusOwnership(
    node: _focusNode,
    canOwn: _canOwnReaderFocus,
  );

  /// 「阅读器正文此刻应当持有键盘」的统一判据，按回收原因分流。
  bool _canOwnReaderFocus(FocusReclaimCause cause) {
    if (!mounted) return false;
    switch (cause) {
      // BUG-1071 ②：词典弹窗是**纯原生 WebView**、没有 Flutter 焦点节点，指针唤出
      // 它时 OS 焦点落在弹窗上。必须在弹窗可见时把 Flutter 焦点拉回正文，否则关词典
      // 键（Esc / 绑定键）永远抵达不了 [_handleKeyEvent]。故此 cause 与下面 gesture
      // 的「弹窗可见就让位」正好相反——这正是两者当初必须是两个 helper 的原因。
      case FocusReclaimCause.popupRendered:
        return _lyricsMode ? false : isDictionaryShown;
      // 整条查词浮层栈关闭：曾持键盘的弹窗 WebView 已消失，不归还用户会被困死
      // （收不到任何按键，没有任何办法回到正文）。
      case FocusReclaimCause.popupDismissed:
        return true;
      // TODO-700 T8：底栏整体是 ExcludeFocus（见 [_wrapBottomChromeBar]），任何时刻
      // 都不是合法的焦点所有者，故切底栏没有「让位给谁」这回事——只是重新确认焦点
      // 仍在正文，正文已持焦时是纯 no-op。**不套**下面那组严格门控：歌词模式 / 内容
      // 未就绪下正文键盘节点依然是 [_handleKeyEvent] 的唯一入口，此时不归位就等于
      // 切一下底栏把键丢了（统一前这里是无条件 requestFocus，行为保持不变）。
      case FocusReclaimCause.chromeToggled:
        return true;
      // BUG-136：原生 WebView 在任一指针手势上捕获 OS 焦点。只让位给另一个**合法的
      // Flutter 焦点所有者**（可见弹窗 / 底栏 chrome），其余一律收回。
      case FocusReclaimCause.gesture:
        return shouldReclaimReaderFocusAfterGesture(
          popupVisible: isDictionaryShown,
          chromeHasFocus: _chromeFocusScope.hasFocus,
        );
      // TODO-700 T3 / TODO-900：内容就绪、切窗回前台、底栏显隐后的归位。严格门控：
      // 光标态 / 词典弹窗态 / 歌词态都不抢（否则会覆盖正在用的光标焦点）。整页 Focus
      // 的 autofocus:true 仍保留作冷启动兜底，这里只是把「确定性到位」补在每个落点
      // （含切应用回来 / 重启后重进，不再依赖 FocusManager 进程内记忆）。
      case FocusReclaimCause.contentReady:
      case FocusReclaimCause.appResumed:
      case FocusReclaimCause.surfaceRemounted:
      case FocusReclaimCause.overlayClosed:
        if (!_readerContentReady || _lyricsMode) return false;
        if (_caretActive || _caretSurface != CaretSurface.none) return false;
        if (isDictionaryShown) return false; // 弹窗 WebView 持焦点期间不抢
        // resumed 是全局生命周期回调，阅读器上方可能压着设置 / 查词大对话框；
        // 直接抢会夺走对话框焦点（Never break userspace 红线）。那些覆盖层关闭
        // 时各自的返回点会归还焦点。
        if (cause == FocusReclaimCause.appResumed) {
          final ModalRoute<Object?>? owner = ModalRoute.of(context);
          if (owner != null && !owner.isCurrent) return false;
        }
        return true;
    }
  }

  @override
  void onAllPopupsDismissed() {
    if (!mounted) return;

    // TODO-270 F/G：整条查词浮层栈关闭 = 一次「查词会话」结束，丢弃未制卡的多句
    // 草稿（避免下次查词带着上次没用掉的累积句）。制卡成功已在 onMineFromPopup
    // 清过，这里兜住「攒了几句但没制卡就关掉」的情况。
    _miningDraft.clear();
    _clearLookupState();
    final int dismissedGeneration = activeLookupGeneration;
    unawaited(_finishLookupSessionAfterPopupsDismissed(dismissedGeneration));
  }

  /// BUG-1344：macOS WKWebView 的 evaluateJavascript 通过异步 method-channel completion
  /// 落地。必须等原生选区 + CSS Highlight 真正清完后再 requestFocus；旧顺序先抢
  /// Flutter 焦点，会先绘出失焦灰选区，迟到的 JS 清理没有下一次 surface invalidation，
  /// 直到切应用才消失。等待期间若页面销毁或新查词已打开，则旧会话不得抢回焦点。
  Future<void> _finishLookupSessionAfterPopupsDismissed(
    int dismissedGeneration,
  ) async {
    await _clearSelectionJs();
    if (!mounted ||
        activeLookupGeneration != dismissedGeneration ||
        isDictionaryShown) {
      return;
    }
    // Return Flutter focus to the reading content. The dismissed popup's WebView
    // held the keyboard/gamepad focus, so without this the reader receives no key
    // events after the popup closes and the user is stuck with no way back in.
    _focusOwnership.reclaim(FocusReclaimCause.popupDismissed);
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
      source:
          'window.fushiReader && window.fushiReader.cueIdAtPoint'
          ' ? window.fushiReader.cueIdAtPoint($x, $y) : null',
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
  void onDictionaryPopupRendered(int index) {
    _caret.onDictionaryPopupRendered(index);
    // BUG-1071 ②：指针（触摸/鼠标点词）唤出的弹窗此前**没有任何 Flutter 焦点持有者**
    // —— 弹窗是纯原生平台 WebView（无 Flutter FocusNode），点词后 OS 焦点落在原生
    // WebView 上，Esc/关词典键被它吞或到不了 [_handleKeyEvent] → 用户报「键盘关词典
    // 经常失效」（光标/手柄唤出时焦点仍在 _focusNode 才「有时能关」）。这里把 Flutter
    // 焦点收回正文 _focusNode（与阅读器每个指针手势 BUG-136 reclaim 同一已验证机制，
    // requestFocus 会把平台焦点从原生 WebView 夺回），使关词典键确定性抵达
    // _handleKeyEvent → readerDismissDict → clearDictionaryResult，不再依赖飘忽焦点。
    //
    // 仅指针唤出（[_caretSurface] == none）路径 reclaim：光标/手柄唤出时
    // [_caret.onDictionaryPopupRendered] 会把光标 transfer 进弹窗，_focusNode 本就持焦
    // 驱动光标键，此处不介入以免与 transfer 竞争（不回归 BUG-136：弹窗无 Flutter 焦点
    // 节点，reclaim 键盘焦点不影响弹窗指针交互——嵌套查词/制卡/收藏均 pointer 驱动）。
    if (_caretSurface == CaretSurface.none) {
      _focusOwnership.reclaim(FocusReclaimCause.popupRendered);
    }
  }

  /// BUG-1071 复诉：上面的焦点 reclaim 只在**弹窗渲染那一刻**成立。用户与弹窗交互
  /// 一次（滚动看释义 / 点释义 / 点发音）OS 焦点就回到原生 WebView，之后按键必然
  /// 再次失效；而绑到「关闭词典」的**鼠标键**从一开始就只有 `onPointerSeek` 一个
  /// 消费者，只覆盖「点在弹窗矩形之外的正文区」——点词后弹窗恰好贴在光标旁，按侧键
  /// 时指针几乎必然落在弹窗上，事件被弹窗吃掉，全程无反应。
  ///
  /// 故让弹窗自己把这些输入交回来：键盘与鼠标同一条通道，token 表由注册表当前绑定
  /// 实时导出（改键立即生效）。
  @override
  ShortcutScope? get dictionaryPopupInputScope => ShortcutScope.reader;

  @override
  Set<ShortcutAction> get dictionaryPopupForwardedActions =>
      const <ShortcutAction>{
        // 「返回上一级」（默认 Esc）：弹窗持焦时也必须能关词典。它现在是 universal
        // scope 的动作，[resolveDictionaryPopupInputToken] 会在宿主 scope 未命中后
        // 回落到 universal，两端解析口径一致。
        ShortcutAction.globalBack,
        // 「只关词典」的专用动作（默认无键盘绑定，用户可绑鼠标侧键）——BUG-1071
        // 那条鼠标通道的唯一消费者，保留。
        ShortcutAction.readerDismissDict,
      };

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
      source: ReaderCaretScripts.exitInvocation(),
    );
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
    // 连续查词（和鼠标一样）：弹窗出现后，全屏 dismiss barrier 盖在 WebView 之上，
    // WebView DOM 的 onShiftHover 收不到事件——此时唯一还能接 hover 的入口就是这里。
    // 故此处**不再**门控 isDictionaryShown（旧 TODO-851「限一级弹窗」放开）：按住
    // Shift 一路滑，命中新词就 _selectTextAt 换词。换词经 _runLookupAndHighlight →
    // prunePopupStack(0) 复用热槽无缝替换（不叠层、不白屏，BUG-092/482 已验证），
    // 命中同一个词由 JS selectText 的 fromHover 同词短路挡住（不重复 fire、不闪、不刷
    // FFI）。下面的 8px 平方阈值仍在，避免每像素抖动都查。
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

  // ── Tap dismiss barrier → 连续查词（TODO-1027）─────────

  /// TODO-1027：点查词弹窗矩形外的正文（dismiss barrier）。barrier 叠在阅读器
  /// WebView 之上（buildDictionary 在 _buildWebView 之后），旧行为 onTap=只关整栈，
  /// tap 到不了底下 WebView，点新词必须再点一次才查——查词被关窗逻辑堵塞。
  /// 改为用 WebView 自己的 RenderBox 把全局指针位置逆映成 WebView 局部（CSS）坐标，
  /// 与 onDismissBarrierHover / 正常 onShiftHover 口径一致，转给真点击路径的 [_selectTextAt]
  /// （fromHover:false）：
  ///   • 命中词 → onTextSelected → _handleTextSelected → _runLookupAndHighlight（内部
  ///     prunePopupStack(0) 保留热槽，旧窗无缝换新窗，BUG-092/093/095 不回归）；
  ///   • 命中真空白 → JS fire onTapEmpty，有可见弹窗时在那里 clearDictionaryResult 关栈
  ///     （并由 onAllPopupsDismissed 触发续播BUG-072）。
  /// RenderBox 不可用时（不应发生：barrier 在屏说明 WebView 也在树上）退回默认清栈。
  @override
  void onDismissBarrierTap(Offset globalPos) {
    final RenderObject? obj = _webViewKey.currentContext?.findRenderObject();
    if (obj is! RenderBox || !obj.attached || !obj.hasSize) {
      // WebView 不可用：退回默认「点空白关栈」。
      clearDictionaryResult();
      return;
    }
    // 与 onDismissBarrierHover 同口径：逻辑像素与 CSS 像素同尺度，不乘 DPR。
    final Offset local = obj.globalToLocal(globalPos);
    // 真点击路径（fromHover:false）：命中词走查词，命中空白 fire onTapEmpty。
    _selectTextAt(local.dx, local.dy);
  }

  // ── Reader chrome helpers kept in the shell ─────────────────────────
  // `_colorToCssRgba` / `_toDouble` stay here because their other call sites
  // live in the still-in-shell WebView region; the rest of the reader chrome
  // domain lives in `reader_fushi/chrome.part.dart` (TODO-589 batch7).

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
      final FushiDesignTokens tokens = FushiDesignTokens.of(context);
      final AudioCue? cue = _lookupCue;
      final bool hasCue = cue != null;
      return ReaderChromeScaler(
        scale: _readerChromeScale,
        baseHeight: _readerPopupHeaderBaseHeight,
        child: SizedBox(
          height: _readerPopupHeaderBaseHeight,
          // TODO-1187：header 底边框已移出 —— 分隔线改由 [DictionaryPopupLayer] 在
          // 「有词条」时才画（无结果/搜索中悬空的多余横线消除）。
          child: Container(
            padding: EdgeInsets.symmetric(vertical: tokens.spacing.gap / 4),
            // BUG-826：查词弹窗顶栏收窄时按钮曾相互重叠。顶栏改由 [DictionaryPopupLayer]
            // 用 Row 把本 header 夹在左右按钮簇之间的有界宽度里居中（不再全宽居中压两侧）。
            // 但音频行是固定尺寸按钮，窄宽下会溢出该有界区被裁切；用 [FittedBox]
            // (`scaleDown`) 把整行等比缩小到刚好放下——绝不横向溢出/裁切，也不重叠。
            // `mainAxisSize: min` 让行取按钮总宽（有限内在宽），FittedBox 才能量到并缩放。
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FushiIconButton(
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
                    FushiIconButton(
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
                    FushiIconButton(
                      icon: ctrl.isPlaying
                          ? Icons.pause_outlined
                          : Icons.play_arrow_outlined,
                      size: 24,
                      onTap: ctrl.togglePlayPause,
                      tooltip: ctrl.isPlaying ? t.pause : t.play,
                      padding: EdgeInsets.all(tokens.spacing.gap / 2),
                    ),
                    SizedBox(width: tokens.spacing.gap),
                    FushiIconButton(
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
                    // TODO-954：导出片段入口已从查词弹窗 header 迁到「文字选区右键菜单」
                    // （Windows Flutter 菜单 / 移动端原生 ContextMenu），见
                    // chrome.part.dart `_showReaderTextContextMenu` 与 webview.part.dart。
                    // 这里只保留播放控制，避免弹窗里塞与查词无关的导出按钮。
                  ],
                ],
              ),
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
  const ReaderLyricsModeHintDialog({required this.onClose, super.key});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final FushiDesignTokens tokens = FushiDesignTokens.of(context);

    return FushiDialogFrame(
      maxWidth: 420,
      maxHeightFactor: 0.74,
      child: FushiModalSheetFrame(
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
        body: Text(t.lyrics_mode_hint_body, style: tokens.type.listSubtitle),
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
