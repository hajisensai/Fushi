import 'package:fushi_dictionary/fushi_dictionary.dart';
import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:file_picker/file_picker.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:fushi_anki/fushi_anki.dart';
import 'package:fushi_audio/fushi_audio.dart';
import 'package:fushi_core/fushi_core.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;
import 'package:share_plus/share_plus.dart';
import 'package:fushi/src/shortcuts/context_menu_trigger.dart';
import 'package:fushi/src/utils/misc/collection_exporter.dart';
import 'package:fushi/src/utils/misc/fushi_share.dart';
import 'package:window_manager/window_manager.dart';

import 'package:fushi/i18n/strings.g.dart';
import 'package:fushi/src/anki/anki_view_model.dart';
import 'package:fushi/src/storage/app_paths.dart';
import 'package:fushi/src/media/audiobook/mining_sentence_draft.dart';
import 'package:fushi/src/media/sources/reader_fushi_source.dart';
import 'package:fushi/src/media/tracking/media_tracking_service.dart'
    show kMediaTrackingEnabled;
import 'package:fushi/src/pages/implementations/video_loading_overlay.dart';
import 'package:fushi/src/utils/misc/lookup_dismiss_barrier.dart';
import 'package:fushi/src/utils/components/fushi_windows_title_bar.dart';
// 只取语义枚举与调色板：视频页的通知一律走左上角 _showOsd，不得用 FushiToast
// （BUG-931 有守卫），故刻意不 import 整套 toast API。
import 'package:fushi/src/utils/misc/toast_severity.dart';
import 'package:fushi/src/media/drag_drop/drop_classification.dart';
import 'package:fushi/src/media/drag_drop/fushi_file_drop_target.dart';
import 'package:fushi/src/media/import/real_path_directory_picker.dart';
import 'package:fushi/src/media/media_cover_source.dart';
import 'package:fushi/src/media/video/dandanplay_client.dart';
import 'package:fushi/src/media/video/danmaku_manual_match_panel.dart';
import 'package:fushi/src/media/source_library/source_stream_headers.dart';
import 'package:fushi/src/media/video/stream_video_launch.dart';
import 'package:fushi/src/media/video/subtitle_embedded_fonts.dart';
import 'package:fushi/src/media/video/video_display_claim.dart';
import 'package:fushi/src/media/video/video_episode_start_policy.dart';
import 'package:fushi/src/media/video/video_exit_flush.dart';
import 'package:fushi/src/media/video/video_import_dialog.dart';
import 'package:fushi/src/media/video/video_top_bar_slots.dart';
import 'package:fushi/src/media/video/m3u8_playlist.dart';
import 'package:fushi/src/media/video/url_stream_video.dart';
import 'package:fushi/src/media/video/web_video_bridge.dart'
    show shouldOpenInWebVideoPlayer;
import 'package:fushi/src/pages/implementations/web_video_fushi_page.dart'
    show WebVideoFushiPage;
import 'package:fushi/src/media/video/youtube_source_resolver.dart'
    show
        YoutubeCaptionTrack,
        resolveYoutubeCaptionTracks,
        resolveYoutubeCaptionCues,
        pickBestYoutubeCaptionTrack,
        // BUG-1289：字幕轨选择器的显示标签合成（可读语言名 + ASR/翻译标注）。
        youtubeCaptionTrackLabel,
        YoutubeVideoVariant,
        YoutubeVariantSet,
        resolveYoutubeVideoVariants,
        isYoutubeUrl;
import 'package:fushi/src/media/video/video_resource_check.dart';
import 'package:fushi/src/media/video/video_long_press_speed_badge.dart';
import 'package:fushi/src/media/video/video_horizontal_seek_gesture.dart';
import 'package:fushi/src/media/video/video_seek_indicator_label.dart';
import 'package:fushi/src/media/video/series_playback_prefs.dart';
import 'package:fushi/src/media/video/video_asbplayer_config.dart';
import 'package:fushi/src/media/video/video_book_repository.dart';
import 'package:fushi/src/media/video/video_chrome_colors.dart';
import 'package:fushi/src/media/video/video_control_customization.dart';
import 'package:fushi/src/media/video/video_control_item_presentation.dart';
import 'package:fushi/src/media/video/video_custom_action_bindings.dart';
import 'package:fushi/src/media/video/video_custom_action_picker.dart';
import 'package:fushi/src/media/video/video_control_layout_edit_overlay.dart';
import 'package:fushi/src/media/video/video_control_popover_placement.dart';
import 'package:fushi/src/media/video/video_controls_focus_gate.dart';
import 'package:fushi/src/media/video/video_controls_theme_pair.dart';
import 'package:fushi/src/media/video/video_danmaku_model.dart';
import 'package:fushi/src/media/video/video_danmaku_overlay.dart';
import 'package:fushi/src/media/video/video_danmaku_source.dart';
import 'package:fushi/src/media/video/video_filename_parser.dart';
import 'package:fushi/src/media/video/video_immersive_mode.dart';
import 'package:fushi/src/media/video/video_lua_script_manager.dart';
import 'package:fushi/src/media/video/video_hdr_output.dart';
import 'package:fushi/src/media/video/video_mpv_config.dart';
import 'package:fushi/src/media/video/video_player_controller.dart';
import 'package:fushi/src/media/video/video_screenshot_filename.dart';
import 'package:fushi/src/startup/exit_flush_registry.dart';
import 'package:fushi/src/utils/window_caption_channel.dart';
import 'package:fushi/src/focus/page_focus_ownership.dart';
import 'package:fushi/src/focus/panel_focus_scope.dart';
import 'package:fushi/src/media/video/video_player_shortcuts.dart';
// TODO-1342：视频播放器手柄映射。GamepadButtonIntent（桌面轮询派发）+ GamepadButton
// （原生按键归一）+ ShortcutAction/ShortcutScope（video 作用域绑定解析）。
import 'package:fushi/src/shortcuts/dictionary_caret_controller.dart'
    show CaretSurface, DictionaryCaretController, DictionaryCaretHost;
import 'package:fushi/src/shortcuts/gamepad_service.dart'
    show
        GamepadButtonIntent,
        GamepadLongPressIntent,
        focusedEditableText,
        tryDictionaryPopupGamepadButton;
import 'package:fushi/src/shortcuts/input_binding.dart'
    show GamepadButton, InputBinding, activeModifierKeys;
import 'package:fushi/src/shortcuts/mouse_binding_dispatch.dart'
    show dispatchClaimedMouseAction, resolveMouseBindingAction;
import 'package:fushi/src/shortcuts/reader_caret_router.dart'
    show CaretAction, ReaderCaretRouter;
import 'package:fushi/src/shortcuts/window_fullscreen_hosts.dart'
    show WindowFullscreenHost;
import 'package:fushi/src/shortcuts/shortcut_action.dart'
    show ShortcutAction, ShortcutScope;
import 'package:fushi/src/media/video/video_foreground_layers.dart'
    show VideoForegroundLayer, topVideoForegroundLayer;
import 'package:fushi/src/media/video/video_shader_manager.dart';
import 'package:fushi/src/media/video/video_shader_tier.dart';
import 'package:fushi/src/media/video/video_chapter_panel.dart';
import 'package:fushi/src/media/video/audio_energy_probe.dart';
import 'package:fushi/src/media/video/waveform_envelope_cache.dart';
import 'package:fushi/src/media/video/subtitle_auto_align.dart';
import 'package:fushi/src/media/video/subtitle_waveform_align_panel.dart';
import 'package:fushi/src/media/video/video_chapter_markers.dart';
import 'package:fushi/src/media/video/video_clip_exporter.dart';
import 'package:fushi/src/media/video/video_clip_subtitle.dart';
import 'package:fushi/src/media/video/video_clip_subtitle_burn.dart';
import 'package:fushi/src/media/video/video_clip_subtitle_image.dart';
import 'package:fushi/src/media/video/video_episode_panel.dart';
import 'package:fushi/src/media/video/video_side_panel.dart';
import 'package:fushi/src/media/video/video_subtitle_style.dart';
import 'package:fushi/src/media/video/video_thumbnail_preview_controller.dart';
import 'package:fushi/src/media/video/video_thumbnail_preview_overlay.dart';
import 'package:fushi/src/media/video/video_watch_tracker.dart';
import 'package:fushi/src/media/video/subtitle/subtitle_search_seed.dart';
import 'package:fushi/src/pages/implementations/subtitle_workbench_page.dart';
import 'package:fushi/src/media/video/video_quick_settings_host.dart';
import 'package:fushi/src/media/video/video_quick_settings_sheet.dart';
import 'package:fushi/src/media/video/video_sidecar.dart';
import 'package:fushi/src/media/video/video_subtitle_jump_panel.dart';
import 'package:fushi/src/media/video/video_subtitle_obscure_mode.dart';
import 'package:fushi/src/media/video/video_subtitle_overlay.dart';
import 'package:fushi/src/media/video/video_subtitle_source.dart';
import 'package:fushi/src/media/video/video_volume_overlays.dart';
import 'package:fushi/src/models/app_model.dart';
import 'package:fushi/src/models/content_font_chain.dart';
import 'package:fushi/src/models/preferences_repository.dart';
import 'package:fushi/src/profile/profile_view_model.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_controller.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_input_bridge.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_layer.dart';
import 'package:fushi/src/pages/implementations/dictionary_page_mixin.dart';
import 'package:fushi/src/pages/implementations/dictionary_popup_webview.dart'
    show MinePopupResult, DictionaryPopupWebViewState;
import 'package:fushi/src/pages/implementations/stat_activity.dart';
import 'package:fushi/src/sync/interconnect_sync_backend.dart';
import 'package:fushi/src/sync/sync_backend.dart' show SyncPeerUnreachableError;
import 'package:fushi/src/sync/fushi_library_host_service.dart';
import 'package:fushi/src/sync/remote_cover_fetcher.dart';
import 'package:fushi/src/sync/remote_video_client.dart';
import 'package:fushi/src/mining/immersion_mining_engine.dart';
import 'package:fushi/src/mining/immersion_mining_request.dart';
import 'package:fushi/src/utils/adaptive/adaptive_widgets.dart'
    show adaptivePageRoute;
import 'package:fushi/src/utils/adaptive/adaptive_platform.dart'
    show einkSafeDuration;
import 'package:fushi/src/utils/app_ui_scale.dart';
import 'package:fushi/src/utils/misc/desktop_audio_clipper.dart';
import 'package:fushi/src/utils/misc/error_log_service.dart';
import 'package:fushi/src/utils/misc/render_backend_service.dart';
import 'package:fushi/src/platform/desktop/macos_traffic_lights.dart';
import 'package:fushi/src/platform/screen_brightness_controller.dart';
import 'package:fushi/src/platform/windows_ime_space_channel.dart';
import 'package:fushi/src/platform/windows_ime_space_dispatch.dart';
import 'package:fushi/src/utils/misc/platform_utils.dart';
import 'package:fushi/src/utils/misc/show_app_dialog.dart';
import 'package:fushi/src/utils/overlay_entry_lifecycle.dart';
import 'package:fushi/src/utils/components/copy_feedback.dart';
import 'package:fushi/src/utils/components/fading_chrome_gate.dart';
import 'package:fushi/src/utils/components/fushi_design_tokens.dart';
import 'package:fushi/src/utils/components/fushi_destructive_confirm_dialog.dart';
import 'package:fushi/src/utils/components/fushi_icon_button.dart';
import 'package:fushi/src/utils/components/fushi_material_components.dart';

part 'video_fushi/danmaku.part.dart';
part 'video_fushi/clip_export.part.dart';
part 'video_fushi/controls_visibility.part.dart';
part 'video_fushi/episode.part.dart';
part 'video_fushi/flicker_notice.part.dart';
part 'video_fushi/subtitle.part.dart';
part 'video_fushi/controls_popover.part.dart';
part 'video_fushi/volume_osd.part.dart';
part 'video_fushi/chapter.part.dart';
part 'video_fushi/audio_track.part.dart';
part 'video_fushi/quality.part.dart';
part 'video_fushi/side_panel.part.dart';
part 'video_fushi/controls_theme.part.dart';
part 'video_fushi/speed.part.dart';
part 'video_fushi/lookup_favorite.part.dart';
part 'video_fushi/lookup_mining.part.dart';
part 'video_fushi/subtitle_caret.part.dart';
part 'video_fushi/fullscreen.part.dart';
part 'video_fushi/layout.part.dart';

/// 视频页：media_kit 播放器 + 可点击字幕 overlay（点词查词 + 制卡）。
///
/// 装配：[VideoPlayerController.load] 打开视频 + cue 同步 → [Stack] 叠
/// [Video]（media_kit 桌面控制：播放/进度/音量/全屏 + 顶栏字幕轨/音轨切换）
/// 与 [VideoSubtitleOverlay]（逐字符可点）。
///
/// 查词浮层与阅读器/词典页**统一**：点字幕字符 → [_lookupAt] 经
/// [DictionaryPageMixin] 的 [pushNestedPopup] 推入 [DictionaryPopupLayer] 浮层
/// （popup.html WebView，与书内/词典页同款：递归查词 + 单词发音 + auto-read +
/// 制卡），并用被点字符的屏幕 rect 定位。制卡走 mixin 的 [onMineEntry]——视频页
/// 覆写它注入视频专属上下文：当前帧截图 coverPath + 当前字幕 cue 的音频片段
/// （裁**当前选中音轨**）sasayakiAudioPath + 例句 sentence + 单词发音
/// （popup.js 已把 `{audio}` 写进 fields）。
///
/// 全屏：media_kit 全屏是独立 root 路由，复用同一 `controls` builder，故
/// [VideoSubtitleOverlay] 包进 controls builder（[_buildVideoControls]）随全屏
/// 一起进路由，保证全屏时字幕仍显示且可点查词。
///
/// 查词浮层用**根 Overlay**（`Overlay.of(context, rootOverlay: true)`）渲染，而非本页
/// `Stack`——这样全屏（media_kit 推到根 navigator 的独立路由）时浮层也能浮在全屏画面
/// **之上**，窗口/全屏统一一套。根 Overlay 在 [FushiAppUiScale] 的 `FittedBox` 之内
/// （挂在 `MaterialApp.builder`），其坐标空间是**缩放后的小画布（view/s）**；若浮层直接在
/// 此渲染，其词典 WebView 会按小画布尺寸栅格化、再被外层 `FittedBox` 拉大 → **字糊**
/// （与 BUG-039 阅读器同源；BUG-051）。故 [_buildPopupOverlay] 把整棵浮层子树用
/// [FushiAppUiScaleNeutralizer] 中和回**真实视口尺寸、净缩放=1**，WebView 按原生像素密度
/// 渲染 → 清晰。中和后浮层坐标系即真实屏幕空间（净变换=1），与 `localToGlobal` 的字符
/// rect 同系，故 [_lookupAt] **直接**用该屏幕 rect 定位（不再 ÷s 换算到画布），界面任意
/// 缩放下定位都不偏。
///
/// 制卡取 cue 的纯函数：按播放位置 [positionMs] 解析「用户正在学的那条字幕句」，
/// 供 [VideoFushiPage] 制卡裁真实句子音频段用（TODO-104b / BUG-188）。
///
/// **为什么不直接复用 [VideoPlayerController.currentCue]**：`currentCue` 被字幕显示
/// 语义独占——句间静音 gap / 末句之后必须清成 null（真实字幕在时间窗结束后就该消失，
/// BUG-074）。用户常在「字幕刚消失的那一瞬」（已暂停、字幕条已撤但查词浮层还在）制卡，
/// 此刻 `currentCue == null`，制卡链路（`_lastLookupCue ?? currentCue`）拿不到 cue →
/// 句子音频字段空。这是**数据所有权冲突**：同一个 `_currentCue` 既服务 UI 显示又被制卡
/// 复用。本函数让制卡走**独立的按位置解析**，不复用被 gap 清空的 UI 状态。
///
/// 解析规则（与字幕显示同一 [effectiveSubtitlePositionMs] 坐标系，保证裁的就是用户看到
/// 的那句）：
/// 1. [JsonAlignmentParser.findCueIndex] 精确命中（位置落在某条 cue 的 `[startMs, endMs]`
///    闭区间内）→ 返回该 cue（与字幕显示期一致，不改正常路径）。
/// 2. 命中 -1（gap / 早于首句）→ floor 回退：取「起点 `startMs <= effectivePos` 的最后一条
///    cue」=用户最后看到、正在学的那句。
/// 3. floor 也无（位置早于全部 cue，一句都没起播过）/ 空 cue → 返回 null，制卡诚实留空。
AudioCue? resolveMiningCueForPosition({
  required List<AudioCue> cues,
  required int positionMs,
  required int delayMs,
}) {
  final int idx = resolveMiningCueIndexForPosition(
    cues: cues,
    positionMs: positionMs,
    delayMs: delayMs,
  );
  return idx >= 0 ? cues[idx] : null;
}

/// 解析查词浮层（及其制卡）应锚定的字幕 cue（BUG-966）。
///
/// 两条查词入口共用 [_VideoLookupFavorite._lookupAt]，但被查词句的 cue 来源不同：
/// - **主画面字幕 overlay 点字符查词**：点的就是当前正在显示的字幕，[overrideCue] 传 null，
///   回落到 [currentCue]（句间 gap / 末句后为 null）→ 再按播放位置解析（TODO-104b / BUG-188）。
/// - **字幕跳转列表点词查词**：用户点的是列表里**任意一条**字幕，可能远离播放头（点列表只
///   暂停、不 seek），此时必须用被点的 [overrideCue]；否则制卡区间会锚到播放位置那句，
///   卡片句子文本是被点条目、句子音频却截自播放位置那句，声音对不上（BUG-966）。
///
/// 优先级：[overrideCue]（列表明确指定的句） > [currentCue]（overlay 正显示的句） >
/// 按播放位置解析（gap / 末句后兜底）。三者皆无 → null，制卡诚实留空。
AudioCue? resolveVideoLookupAnchorCue({
  AudioCue? overrideCue,
  AudioCue? currentCue,
  required List<AudioCue> cues,
  required int positionMs,
  required int delayMs,
}) {
  return overrideCue ??
      currentCue ??
      resolveMiningCueForPosition(
        cues: cues,
        positionMs: positionMs,
        delayMs: delayMs,
      );
}

/// 同 [resolveMiningCueForPosition]，但返回**下标**而非 cue 对象（一句都没起播过 / 空 cue
/// 返回 -1）。跨字幕制卡（TODO-102）按下「开始/结束」时要记录 cue 的**下标**来界定区间，
/// 而单句制卡只要 cue 对象——两者共用同一套「精确命中 → floor 兜底」解析，避免漂移。
int resolveMiningCueIndexForPosition({
  required List<AudioCue> cues,
  required int positionMs,
  required int delayMs,
}) {
  if (cues.isEmpty) return -1;
  final int effectivePos = effectiveSubtitlePositionMs(positionMs, delayMs);
  // 1. 精确命中：位置落在某条 cue 的时间窗内（与字幕显示期同一判据）。
  final int hit = JsonAlignmentParser.findCueIndex(
    cues: cues,
    positionMs: effectivePos,
  );
  if (hit >= 0) return hit;
  // 2. gap / 末句后：floor 找「起点 <= 当前位置」的最后一条 cue（用户最后看到的那句）。
  //    [cues] 由 [VideoPlayerController.setCues] 保证按 startMs 升序，可二分。
  int lo = 0;
  int hi = cues.length;
  while (lo < hi) {
    final int mid = (lo + hi) >>> 1;
    if (cues[mid].startMs <= effectivePos) {
      lo = mid + 1;
    } else {
      hi = mid;
    }
  }
  // 3. 位置早于全部 cue（lo - 1 < 0）：一句都没起播过，诚实返回 -1。
  return lo - 1;
}

/// TODO-680 / BUG-392：把 cue 时间轴上的制卡区间反算回**播放器时间轴**。
///
/// cue 命中走 [effectiveSubtitlePositionMs]：`effective = playerPos - delayMs`，即
/// 文本字幕 cue 的 `startMs`/`endMs` 都是**字幕文件原始坐标**，制卡选句时用减法把
/// 播放位置换算到字幕坐标后再匹配（[resolveMiningCueIndexForPosition]）。但裁句子音频 /
/// 导出封面 GIF 是按**播放器时间轴**对视频文件抽取的——必须做与 [effectiveSubtitlePositionMs]
/// 相反方向的逆变换 `playerPos = subtitleTime + delayMs`，否则 `delayMs != 0` 时裁出来的
/// 音频/封面整体偏移 `delayMs`（裁的是字幕原始窗而非用户实际听到/看到的播放窗）。
///
/// 与 [VideoPlayerController.cueSeekTargetMs]（句子 seek 的逆变换）同一方向、同一真相源，
/// 只是这里作用于制卡裁剪区间。下界 clamp 到 0（播放时间不为负）。
@visibleForTesting
int miningClipTimeMs(int subtitleTimeMs, int delayMs) =>
    (subtitleTimeMs + delayMs).clamp(0, 1 << 30);

/// 判定一个**字位簇**（grapheme cluster）是否属于「拉丁单词字符」：拉丁字母
/// （含 café 的 é、连字号外的重音字母）或 ASCII 数字。用字位簇的首个码点的
/// Unicode `Script=Latin` 属性判定，故 NFC/NFD 的重音字母都按基字母（拉丁）归类。
/// CJK（汉字 / 假名 / 谚文）不是拉丁脚本，恒返回 false → 逐字查词行为不变。
bool _isLatinWordGrapheme(String grapheme) {
  if (grapheme.isEmpty) return false;
  return _kLatinWordCharRegExp.hasMatch(grapheme);
}

final RegExp _kLatinWordCharRegExp =
    RegExp(r'^[\p{Script=Latin}0-9]', unicode: true);

/// 点字幕第 [graphemeIndex] 个字位起的查询串。
///
/// 查询串只由**起点**决定，终点恒为句尾——引擎按查询串做最长匹配并回报
/// `bestLength`（弹窗 / 字幕据此高亮整词跨度），多喂的后文超出 `scanLength`
/// （`FushiDicts.defaultScanLength` = 16 码点）自然丢弃。
///
/// 起点按脚本分：
/// - CJK / 标点 / 空白：就是被点字位本身（逐字查词，点「永」命中「永遠」、
///   点「遠」能单独查「遠」）。
/// - 拉丁单词字符：回退到该单词的**词首**，这样点 "hello" 的任意字母（含
///   'e' / 'o'）都从 "hello" 起查，而不是旧 `skip(index)` 的 "ello" 查不到
///   （TODO-916 症状③）。空格 / 标点 / 连字号 / CJK 都是词首边界。
///
/// BUG-1773：拉丁分支此前**同时**把终点钉死在词尾，于是查询串被截成单个单词，
/// `listen to` / `look forward to` 这类空格分词短语的词条永远匹配不到——点空格
/// 反而能查出短语（走了 CJK 的「到句尾」分支）就是这个特例的照妖镜。终点从来
/// 不该由脚本决定：C++ `scan_candidates` 明确禁止在空格分词语言的单词中间切
/// （native/fushidicts/fushidicts_src/scan/word_scan.cpp），候选恒是
/// `listen to music` / `listen to` / `listen`，单词自己仍在候选里，不会被短语挤掉。
/// 网页播放器页（web_video_fushi_page.dart）与本页共用同一取词规则，故为公开顶层函数。
String subtitleLookupTerm(String sentence, int graphemeIndex) =>
    subtitleLookupSpan(sentence, graphemeIndex).term;

/// [subtitleLookupTerm] 的结构化形态：查询串 + 它在句中的 grapheme **起点**。
///
/// 起点是字幕高亮（BUG-2091）的锚：拉丁词回退到词首后，高亮必须从词首起算而不是
/// 从被点字母起算，否则点 "hello" 的 'o' 只会亮出 "o"。越界返回 `(start: -1, term: '')`。
({int start, String term}) subtitleLookupSpan(
  String sentence,
  int graphemeIndex,
) {
  final List<String> graphemes = sentence.characters.toList();
  if (graphemeIndex < 0 || graphemeIndex >= graphemes.length) {
    return (start: -1, term: '');
  }
  int start = graphemeIndex;
  // 拉丁单词字符：只把起点回退到词首。其余脚本起点即命中字位。
  if (_isLatinWordGrapheme(graphemes[graphemeIndex])) {
    while (start > 0 && _isLatinWordGrapheme(graphemes[start - 1])) {
      start--;
    }
  }
  // **起点必须跳过前导空白**：查询串在 `pushNestedPopup` 里先 `trim()` 再送引擎，
  // 而引擎回报的匹配长度（matchedRunes）是相对 **trim 后**那个串数的。起点若停在
  // 空白上，[lookupHighlightGraphemeCount] 就把这个长度套回带前导空白的串——高亮
  // 整体左移一格、尾部少一个字符。
  //
  // 点中空格是常态而非边角：英文字幕逐字命中、`hoverAutoLookup` 扫过词间空隙都会
  // 落在空格上（`_isLatinWordGrapheme(' ')` 为假，起点不回退）。日文同理，
  // `String.trim()` 连 U+3000 全角空格一起吃。
  //
  // 弹窗查的词一字不变（引擎拿到的本来就是 trim 后的串），变的只有高亮锚点。
  while (start < graphemes.length && graphemes[start].trim().isEmpty) {
    start++;
  }
  // 整段都是空白：没有可查的词。此前会带着一串空格去查（引擎 trim 成空、返回 0），
  // 副作用是白暂停一次视频、弹一个空浮层。
  if (start >= graphemes.length) return (start: -1, term: '');
  return (start: start, term: graphemes.skip(start).join());
}

/// 引擎回报的匹配长度是**码点**数（`bestLength` / [lookupHighlightCharCount]），
/// 字幕逐字登记按 **grapheme**；把查询串 [term] 的前 [matchedRunes] 个码点折算成
/// grapheme 数，供 [SubtitleLookupHighlight.graphemeCount]。拉丁/假名两者相等，
/// 带组合字符 / emoji 时不会把一个 grapheme 切成半个。非正数返回 0。
int lookupHighlightGraphemeCount(String term, int matchedRunes) {
  if (matchedRunes <= 0 || term.isEmpty) return 0;
  return String.fromCharCodes(term.runes.take(matchedRunes)).characters.length;
}

@visibleForTesting
String videoFavoriteCacheKey({
  required String text,
  required int? startMs,
  required int? episodeIndex,
  required bool isPlaylist,
}) {
  final int? normalizedEpisodeIndex = isPlaylist ? episodeIndex : null;
  return startMs == null
      ? 'legacy|$text'
      : 'cue|${normalizedEpisodeIndex ?? 'single'}|$startMs|$text';
}

/// TODO-897 / BUG-805：缺失资源对话框的用户选择。「重新导入」现为真动作
/// （单视频重链选文件 / 播放列表打开导入对话框），不再有独立「重新选择文件」项。
enum _MissingResourceChoice { reimport, delete, cancel }

/// TODO-1213：视频（尤其网络流）加载阶段。裸转圈无反馈会让用户以为卡死，
/// [_VideoFushiPageState._buildLoadingBody] 据此显示对应阶段文案：连接流 → 下载
/// 字幕 → 缓冲 → 准备。纯 UI 状态，不影响 controller.load 时序。
enum _VideoLoadPhase { connecting, downloadingSubtitle, buffering, preparing }

/// 统一合集 Phase 3：播放列表上下文里的一集（剧集面板 / 上下集 / 自动连播 / 预热用）。
///
/// 本地播放列表：[bookUid] = 成员集自己的 VideoBooks 行 uid（换集靠 pushReplacement 到
/// 该集的单视频页）、[path] = 该集视频路径（预热用）。远端播放列表：[bookUid] = null、
/// [path] = ''（换集靠 episodeIndex 向 host 建流，不走 pushReplacement）。
class _PlaylistEpisodeRef {
  const _PlaylistEpisodeRef({
    this.bookUid,
    required this.title,
    this.displayTitle,
    this.path = '',
    this.coverPath,
    this.coverUrl,
    this.coverCacheKey,
    this.completed = false,
    this.started = false,
  });
  final String? bookUid;
  final String title;

  /// 剧集面板展示名（v68 Jellyfin 对齐：集级刮削集名）。null = 无集级集名，
  /// 面板回落 [title]。**刻意与 [title] 分开**：title 还流向制卡
  /// documentTitle（「系列名 - 剧集名」），换成刮削集名会静默改卡片字段。
  final String? displayTitle;

  final String path;

  /// 本机封面文件路径（本地集：`video_books.coverPath`）。
  final String? coverPath;

  /// 互联/远端封面 URL（远端合集成员：`RemoteVideoInfo.coverUrl`）。
  final String? coverUrl;

  /// 远端封面的稳定磁盘缓存键（用 `RemoteVideoInfo.id`）。
  final String? coverCacheKey;

  /// 看完 / 在看（本地集：`completedAt` / `lastPositionMs`；远端集无口径恒
  /// false）。剧集面板右上角标（Jellyfin played 勾）的数据源——轨道组件本就
  /// 支持，此前面板一直没喂。
  final bool completed;
  final bool started;
}

class VideoFushiPage extends ConsumerStatefulWidget {
  const VideoFushiPage({
    required this.bookUid,
    required this.repo,
    this.playlistCollectionId,
    this.initialCueStartMs,
    this.initialEpisodeIndex,
    this.initialSubtitleListVisible = false,
    this.initialFullscreen = false,
    super.key,
  })  : remoteInfo = null,
        remoteClient = null,
        remoteCollectionMembers = null;

  VideoFushiPage.remote({
    required RemoteVideoInfo info,
    required this.repo,
    required RemoteVideoClient client,
    this.initialCueStartMs,
    this.initialEpisodeIndex,
    this.initialSubtitleListVisible = false,
    this.remoteCollectionMembers,
    super.key,
  })  : bookUid = info.id,
        remoteInfo = info,
        remoteClient = client,
        initialFullscreen = false,
        playlistCollectionId = null;

  final String bookUid;
  final VideoBookRepository repo;
  final RemoteVideoInfo? remoteInfo;
  final RemoteVideoClient? remoteClient;

  /// 客户端互联视频合集播放：本远端视频所属合集的**有序成员**（含自己）。非空且 >1 = 作为
  /// 合集某一集打开，播放器据此建剧集列表 + 跨成员自动连播（成员各自独立 video id，换集换
  /// 的是成员 id 而非同 id 的 episodeIndex）。null/单元素 = 独立单视频打开。远端专用；本地走
  /// [playlistCollectionId]，host-playlist 走 host 下发的 [RemoteVideoInfo.episodes]。
  final List<RemoteVideoInfo>? remoteCollectionMembers;

  /// 统一合集 Phase 3：本集所属 playlist 合集 id（非空 = 作为播放列表某一集打开，
  /// player 据此建兄弟集列表 + 剧集面板 + 上下集 + 自动连播；null = 独立单视频打开）。
  /// 本地专用；远端播放列表走 host 驱动的 episodeIndex，不用此字段。
  final int? playlistCollectionId;
  final int? initialCueStartMs;
  final int? initialEpisodeIndex;
  final bool initialSubtitleListVisible;

  /// BUG-839：作为「从全屏页连播/换集而来」的新页打开——首帧就绪后自动重进全屏路由，
  /// 保持连播全屏沉浸不被换集打断。仅本地 pushReplacement 换集在换集前处于全屏时置真
  /// （见 [_VideoEpisode._switchEpisode]）；首开 / 远端恒 false。
  final bool initialFullscreen;

  /// 打开视频播放页的**唯一入口**：在路由层用 [FushiAppUiScaleNeutralizer] 把整页中和
  /// （与阅读器 [ReaderFushiSource.buildLaunchPage] 同范式）。
  ///
  /// 根因（用户报「视频没画面」）：全局 [FushiAppUiScale] 用 `FittedBox(BoxFit.fill)` 把
  /// 整棵子树渲染进一个缩放画布再拉大；media_kit 的 [Video] 在桌面是平台 Texture，落在
  /// 缩放画布里会被栅格化再放大 → 糊甚至空白（无画面）。阅读器早已在路由层中和，视频页
  /// 此前三个 push 点都漏了这层 → 用户调过界面缩放后视频就没画面。统一收口到这里，让
  /// [Video] 的 Texture 落在净缩放=1 的真实视口、按原生密度渲染，并杜绝再漏第四处。
  static Widget neutralized({
    required String bookUid,
    required VideoBookRepository repo,
    int? playlistCollectionId,
    int? initialCueStartMs,
    int? initialEpisodeIndex,
    bool initialSubtitleListVisible = false,
    bool initialFullscreen = false,
  }) =>
      FushiAppUiScaleNeutralizer(
        child: VideoFushiPage(
          bookUid: bookUid,
          repo: repo,
          playlistCollectionId: playlistCollectionId,
          initialCueStartMs: initialCueStartMs,
          initialEpisodeIndex: initialEpisodeIndex,
          initialSubtitleListVisible: initialSubtitleListVisible,
          initialFullscreen: initialFullscreen,
        ),
      );

  static Widget neutralizedRemote({
    required RemoteVideoInfo info,
    required VideoBookRepository repo,
    required RemoteVideoClient client,
    int? initialCueStartMs,
    int? initialEpisodeIndex,
    bool initialSubtitleListVisible = false,
    List<RemoteVideoInfo>? remoteCollectionMembers,
  }) =>
      FushiAppUiScaleNeutralizer(
        child: VideoFushiPage.remote(
          info: info,
          repo: repo,
          client: client,
          initialCueStartMs: initialCueStartMs,
          initialEpisodeIndex: initialEpisodeIndex,
          initialSubtitleListVisible: initialSubtitleListVisible,
          remoteCollectionMembers: remoteCollectionMembers,
        ),
      );

  /// 查词浮层关闭后是否应恢复播放：仅当浮层栈**已全部关闭**（[stackEmpty]）且本次确实
  /// 是因查词而由我们暂停了正在播放的视频（[pausedForLookup]）。两条件缺一不可——关掉
  /// 递归查词的子层但父层仍在（栈非空）不恢复；查词前本就暂停的视频（未置位）也不恢复。
  /// [caretHoldsPause]（videoEnterCaret）：字级选词光标仍激活时**不**恢复——用户关掉
  /// 浮层后往往还要移动光标继续查下一个词，恢复播放会让 cue 换掉、光标失锚；暂停由
  /// 光标会话接管，退出光标时按同一 [pausedForLookup] 标记恢复（单一恢复真相源）。
  /// 纯函数：与 [_VideoFushiPageState._popNestedPopupAt] 共用，供单测直接验证（BUG-072）。
  @visibleForTesting
  static bool shouldResumeAfterLookupDismiss({
    required bool stackEmpty,
    required bool pausedForLookup,
    bool caretHoldsPause = false,
  }) =>
      stackEmpty && pausedForLookup && !caretHoldsPause;

  /// 点查词浮层外的 dismiss barrier 命中了字幕字符时，是否应「换词」（对该字符重新查词、
  /// 替换可见浮层）而非「逐层关顶层」（TODO-758 / BUG-410，纯函数供单测）。
  ///
  /// 仅在**非嵌套**（[topVisibleIndex] <= 0：只有顶层可见，或仅剩隐藏热槽返回 -1）且确实
  /// 命中字幕字符（[hitSubtitle]）时才换词——单层查词点同句另一个字符切换查词是合理交互。
  /// 嵌套态（[topVisibleIndex] > 0，存在父层）下底部字幕仍清晰渲染、其字符矩形持续绑定，
  /// 用户点第 2+ 个窗外面常落在字幕文字上 → 若仍换词会把整栈替换掉，顶层窗没关而是被替换
  /// （位置相关、间歇）。故嵌套态点外一律返回 false（逐层关一层，与 reader dismissTopPopup
  /// 同语义）。
  @visibleForTesting
  static bool shouldSwitchWordOnBarrierTap({
    required int topVisibleIndex,
    required bool hitSubtitle,
  }) =>
      topVisibleIndex <= 0 && hitSubtitle;

  /// Shift-悬停在查词浮层 barrier 上「连续切换查词」的移动节流阈值（像素，BUG-861）。
  /// 与字幕盒 [VideoSubtitleOverlay] 的 `_kShiftHoverThresholdPx` / 阅读器 barrier hover
  /// 的 8px 同构：鼠标移动未超此阈值不重复查词，越过阈值 + 命中新字符才换词。
  static const double barrierHoverThresholdPx = 8;

  /// 长按横向拖动连续调速的映射系数（TODO-338）：每 px 横向位移改变多少倍速。
  /// 200px ≈ 1.0x，故拖半屏（~600px）≈ ±3x，覆盖 [longPressDragMinSpeed]..
  /// [longPressDragMaxSpeed] 全程而手感不过敏。
  static const double longPressDragSpeedPerPixel = 1.0 / 200.0;

  /// 长按拖动调速的下/上限（TODO-338）。
  static const double longPressDragMinSpeed = 0.5;
  static const double longPressDragMaxSpeed = 4.0;

  /// 把长按拖动的横向位移映射成目标倍速（TODO-338，纯函数供单测）：以 [baseSpeed]
  /// （长按固定加速速）为基准，[dx]（相对长按起点的横向位移，右正左负）按
  /// [longPressDragSpeedPerPixel] 线性加减，clamp 到 [longPressDragMinSpeed]..
  /// [longPressDragMaxSpeed]，再 snap 到 0.1x 步进。向右拖加速、向左减速。
  @visibleForTesting
  static double longPressDragSpeedFor(double baseSpeed, double dx) {
    final double target = (baseSpeed + dx * longPressDragSpeedPerPixel).clamp(
      longPressDragMinSpeed,
      longPressDragMaxSpeed,
    );
    return (target * 10).roundToDouble() / 10;
  }

  @override
  ConsumerState<VideoFushiPage> createState() => _VideoFushiPageState();
}

/// TODO-1059：驱动 media_kit 移动控制条**重启自动隐藏计时**的单发信号。
///
/// 移动端底部按钮栏的 play / 快进 / 快退按钮各按自己的 `onPressed` 执行，media_kit
/// fork 的隐藏 `Timer` 只在整屏 tap 与 seek 时重置，按按钮不重置 → 用户还在按按钮，
/// 控制条已到点自动隐藏，手指落到按钮下方的画面上（误触，用户报「持续点按钮仍自动
/// 隐藏易误触」）。Hibiki 在这些按钮按下时 [poke]，fork 侧订阅本信号（经
/// `MaterialVideoControlsThemeData.restartHideTimerSignal`），在控制条可见时取消并重排
/// 隐藏 Timer，续命一个 `controlsHoverDuration`。是 [ChangeNotifier] 的极薄包装：
/// [poke] 仅 `notifyListeners()`，不携带状态，纯边沿触发。
class _RestartHideTimerSignal extends ChangeNotifier {
  void poke() => notifyListeners();
}

class _VideoOsdMessage {
  const _VideoOsdMessage({
    required this.message,
    this.icon,
    this.progress,
    this.prominent = false,
    this.severity = ToastSeverity.neutral,
  });

  final String message;
  final IconData? icon;
  final double? progress;

  /// 语义配色。左上角 OSD 此前**没有任何颜色参数**（70 处调用全恒灰），成功与失败
  /// 长得一模一样——包括视频页制卡：`describeMineOutcome` 早就算出了状态，却只被
  /// 拿去选 `prominent` 布尔，颜色信息整个丢掉。与底部 toast 共用同一套语义
  /// （[ToastSeverity]），保持两套通知系统同一门语言。
  final ToastSeverity severity;

  /// TODO-971：突出变体（制卡成功用）。普通 OSD 沿用音量/亮度同款左上角小角标，
  /// 太轻易被忽略；制卡成功这类用户主动操作的确认改成居中、更大字号、停留更久的
  /// 卡片，区别于被动的音量小角标。
  final bool prominent;
}

enum _VideoLevelHudKind { leftBrightness, rightVolume }

class _VideoLevelHudState {
  const _VideoLevelHudState({required this.kind, required this.value});

  final _VideoLevelHudKind kind;
  final double value;
}

/// 集成测试钩子（仅测试用）：对当前 [VideoFushiPage] 的 [State] 读播放位置 /
/// 驱动真实播放，验证「退出→再进续播」链路而不暴露页面私有字段。State 以
/// [VideoFushiTestHooks] 形式按接口暴露，测试经 `tester.state` 拿到后 `as` 转型。
@visibleForTesting
abstract class VideoFushiTestHooks {
  /// 当前播放位置（毫秒）；未就绪为 null。
  int? get debugPositionMs;

  /// 当前 controller 读到的内封章节数量。
  int get debugChapterCount;

  /// media_kit 控制条（OSC）当前真实可见性（BUG-2030 的被测真相源）。
  /// 直取 fork 推来的 `_mediaKitControlsVisible`，不是任何镜像。
  bool get debugControlsVisible;

  /// 当前 controller 读到的媒体时长（毫秒）；未就绪为 null/0。
  int? get debugDurationMs;

  /// 制卡 GIF/帧的抽取源（YouTube=低分辨率 miningVideoUrl；本地=videoPath）。
  String? get debugMiningSource;

  /// 制卡音频的抽取源（YouTube=audio-only 流；本地/muxed=null→回落 miningSource）。
  String? get debugMiningAudioSource;

  /// 测试直接打开章节侧栏，避免用坐标/私有控件路径模拟点击。
  void debugShowChapterPanel();

  /// 测试直接打开弹幕设置分类（TODO-1376），避免坐标点击设置按钮再切分类。
  void debugOpenDanmakuSettings();

  /// 测试直接打开弹幕手动搜索/选集侧栏（TODO-1376）。
  void debugOpenDanmakuMatch();

  /// 开始真实播放（驱动 libmpv），让位置自然前进。
  Future<void> debugPlay();

  /// 暂停 / 绝对 seek（BUG-2108 首次覆盖计时 E2E：拖回重听不计时）。
  Future<void> debugPause();
  Future<void> debugSeekMs(int positionMs);
}

// TODO-314：字幕跳转列表不再走 overlay 面板系统，改 push-aside（[_subtitleListVisible]
// / [_videoWithSubtitlePanel]），把画面真挤窄到左侧而非浮层遮挡。故此枚举不再含字幕列表项。
enum _VideoSidePanelKind {
  speed,
  settings,
  // TODO-1351：`subtitleSources` / `audioTracks` 两个「外面浮的轨切换器」已删——字幕轨
  // 收进设置面板「字幕」分类顶部、音频轨收进「音频」分类。TODO-1350：`secondarySubtitleSources`
  // 副字幕浮层也删——副字幕源改内联在「字幕」分类的可展开区里就地切换（不再跳独立窗口）。
  chapters,
  quality,
  // TODO-1376：弹幕手动搜索/选集匹配侧栏。
  danmakuMatch,
}

class _VideoSidePanelState {
  const _VideoSidePanelState({
    required this.kind,
    required this.alignment,
  });

  final _VideoSidePanelKind kind;
  final Alignment alignment;
}

enum _VideoControlPopoverKind { volume, speed }

class _VideoControlPopoverPlacement {
  const _VideoControlPopoverPlacement({
    required this.targetAnchor,
    required this.followerAnchor,
    required this.gapDirection,
  });

  final Alignment targetAnchor;
  final Alignment followerAnchor;

  /// 浮层相对按钮锚点的「让位」方向单位向量（TODO-560）：向上弹为 (0,-1)、向下弹为
  /// (0,1)、向左弹为 (-1,0)、向右弹为 (1,0)。渲染时乘以 gap 得到 [CompositedTransformFollower]
  /// 的 offset，使浮层始终朝画面内侧离开按钮（旧实现只会 (0,-gap) 恒向上）。
  final Offset gapDirection;
}

class _VideoFushiPageState extends ConsumerState<VideoFushiPage>
    with DictionaryPageMixin, WidgetsBindingObserver
    implements VideoFushiTestHooks, DictionaryCaretHost {
  // 控制条尺寸基线（界面缩放 ×1.0 时的值）。视频页整页被
  // [FushiAppUiScaleNeutralizer] 中和回 scale=1.0（保证 WebView 查词坐标一致），
  // 故 media_kit 控制条不会自动吃全局「界面大小」——这些基线再乘 [_videoUiScale]
  // 暴露成下面的实例 getter，让顶/底栏图标、按钮条高度、播放键与查词弹窗同一口径
  // 随界面缩放一起放大缩小（TODO-067）。
  static const double _videoButtonBarHeightBase = 56;
  static const double _videoControlIconSizeBase = 32;
  static const double _videoPlayPauseIconSizeBase = 36;
  static const double _videoControlTitleFontSizeBase = 16;

  /// 按钮条触摸高度，随界面大小缩放（TODO-067）。
  double get _videoButtonBarHeight => _videoButtonBarHeightBase * _videoUiScale;

  /// 顶/底栏控制图标尺寸，随界面大小缩放（TODO-067）。与查词弹窗 ×appUiScale 同口径。
  double get _videoControlIconSize => _videoControlIconSizeBase * _videoUiScale;

  /// 中央播放/暂停键尺寸，随界面大小缩放（TODO-067）。
  double get _videoPlayPauseIconSize =>
      _videoPlayPauseIconSizeBase * _videoUiScale;

  /// 移动控制条底部留白基线（BUG-184）：进度条 / 底部按钮条不贴屏幕物理底边。
  ///
  /// media_kit 的 [MaterialVideoControlsThemeData] 构造器把 `seekBarMargin` 默认成
  /// [EdgeInsets.zero]、`bottomButtonBarMargin` 默认成只有左右无底部（与导出常量
  /// [kDefaultMaterialVideoControlsThemeData] 那套含 `bottom: 42` 的留白不同）。本页
  /// 直接 new 主题、未传这两个 margin 时，进度条会落在 `bottom: 0` 紧贴屏幕最底——
  /// 在 Android 上看起来「进度条在最下面」（被手势条/物理边缘吞掉，非控制条惯例位置）。
  /// 这个基线把进度条与按钮条整体抬离最底，再叠加 [_videoBottomSystemInset] 的系统
  /// 导航栏/手势栏 inset。
  ///
  /// TODO-740：原值 24 是叠加在系统手势安全区（[_videoBottomSystemInset]）之上的固定
  /// 额外留白，偏大，控制底栏离屏幕底端太远（YouTube/B 站只让系统手势安全区不加大基线）。
  /// 降到 8（极小呼吸距离、非 0 保守）：系统手势安全区仍由 [_videoBottomSystemInset]
  /// 独立兜底（不回归 BUG-184 手势条吞进度条），字幕避让走 [_subtitleControlsBottomReserve]
  /// 把本基线作为加总项之一，进度条下移字幕同步下移、相对关系不变（不遮挡）。
  static const double _videoBottomChromeBaseline = 8;

  /// 移动控制条进度条与底部按钮条之间的竖直间距基线（TODO-156/BUG-217）。media_kit
  /// 把进度条与底部按钮条放在**同一个** `Stack(alignment: bottomCenter)`，两者都按
  /// `bottom` 对齐；本页原先把 `seekBarMargin.bottom` 与 `bottomButtonBarMargin.bottom`
  /// 设成同一基线 → 进度条落到按钮条同一基线上、与按钮重叠（手机上「按钮没在进度条
  /// 下面」）。把 `seekBarMargin.bottom` 抬高 = 按钮条高 + 本间距，让进度条整体落在
  /// 按钮条上方。随界面大小缩放（[_videoUiScale]）。
  static const double _videoSeekBarButtonGapBase = 8;

  /// 移动控制条进度条触摸热区高度基线（TODO-157/BUG-218）。media_kit 默认
  /// `seekBarContainerHeight=36`，对准才滑得到；抬高扩大可命中热区。随界面缩放。
  /// 热区向上长（[_mobileControlsTheme] 把进度条整体抬到按钮条上方），不向下侵入
  /// 系统边缘手势区。TODO-971：原 52×缩放 的透明命中带过大，吞掉轨道上方一大片
  /// 区域的底部点击；收窄到 40（仍高于 media_kit 默认 36，保留易命中），缩短透明
  /// 命中带又不丢可命中性。
  static const double _videoSeekBarContainerHeightBase = 40;

  /// 移动控制条进度条拖动滑块尺寸基线（TODO-157/BUG-218）。media_kit 默认 12.8；
  /// 抬高让滑块更易对准。随界面缩放。
  static const double _videoSeekBarThumbSizeBase = 18;

  /// 移动控制条进度条轨道高度基线（TODO-157/BUG-218）。media_kit 默认 2.4；抬高让
  /// 轨道更醒目、更易滑。随界面缩放。
  static const double _videoSeekBarTrackHeightBase = 5;

  /// 字幕避让骑在可见进度条**轨道上缘**之上的呼吸间距基线（TODO-568）。media_kit 的
  /// 可见进度条轨道贴在触摸热区容器底缘（`bottomCenter`），轨道上方是大片透明命中区；
  /// reserve 抬到「轨道上缘 + 本间距」让字幕底缘恰骑进度条上方一点点（不被遮、也不像
  /// 旧版用整段热区高那样顶飞 ~47×缩放 的空白）。随界面缩放。
  static const double _videoSubtitleSeekBarBreathingBase = 8;

  /// **桌面**控制条进度条触摸热区高度（BUG-1224）。桌面 theme 此前不覆盖
  /// `seekBarContainerHeight`、吃 media_kit fork 的构造器默认 36；现在显式传同一个值，
  /// 让「控制条实际用的热区高」与「字幕避让算的热区高」是同一个真相源，不再靠猜 fork
  /// 默认值（fork 改默认值 → 避让会跟着漂，本 bug 的隐蔽处之一）。取值仍是 36 且**不随
  /// 缩放**，与改动前的桌面渲染逐像素一致（本次只修避让，不动控制条外观）。
  static const double _videoDesktopSeekBarContainerHeight = 36;

  /// **桌面**进度条被向下压、骑到按钮行上沿的重叠量（BUG-1224）。media_kit fork 桌面
  /// 控制条用 `Transform.translate` 把进度条整体下压这么多，于是它 36px 高的透明触摸热区
  /// 只有下半截落在按钮行里、上半截（36 − 16 = 20px）探出到按钮行**上方**——正是字幕
  /// 底缘所在处。fork 侧已把这个量提成主题字段 `seekBarBottomButtonBarOverlap`（默认同为
  /// 16），本值同时喂给 theme 和字幕避让，两边不会各自漂。不随缩放（与 fork 原常量一致）。
  static const double _videoDesktopSeekBarButtonBarOverlap = 16;

  static const double _videoControlPopoverGapBase = 8;

  /// 进度条与按钮条竖直间距，随界面大小缩放（TODO-156）。
  double get _videoSeekBarButtonGap =>
      _videoSeekBarButtonGapBase * _videoUiScale;

  /// 进度条触摸热区高度，随界面大小缩放（TODO-157）。**移动** theme 用。
  double get _videoSeekBarContainerHeight =>
      _videoSeekBarContainerHeightBase * _videoUiScale;

  /// 当前平台控制条**实际生效**的进度条触摸热区高度（BUG-1224）：桌面 theme 传
  /// [_videoDesktopSeekBarContainerHeight]（36，不随缩放），移动 theme 传
  /// [_videoSeekBarContainerHeight]（40×缩放）。字幕避让必须按**这个**值算，用错平台的
  /// 值就会算出错的热区上缘、字幕重新压进 seek 命中区。
  double get _activeSeekBarContainerHeight => _isDesktopVideoControls
      ? _videoDesktopSeekBarContainerHeight
      : _videoSeekBarContainerHeight;

  /// 当前平台进度条骑按钮行上沿的重叠量（BUG-1224）：桌面 =
  /// [_videoDesktopSeekBarButtonBarOverlap]；移动端进度条被 `seekBarMargin.bottom` 整体
  /// 抬到按钮行**上方**、不下压，故为 0。
  double get _activeSeekBarButtonBarOverlap =>
      _isDesktopVideoControls ? _videoDesktopSeekBarButtonBarOverlap : 0;

  /// 进度条拖动滑块尺寸，随界面大小缩放（TODO-157）。
  double get _videoSeekBarThumbSize =>
      _videoSeekBarThumbSizeBase * _videoUiScale;

  /// 进度条轨道高度，随界面大小缩放（TODO-157）。
  double get _videoSeekBarTrackHeight =>
      _videoSeekBarTrackHeightBase * _videoUiScale;

  /// 字幕避让骑在进度条轨道上缘之上的呼吸间距，随界面大小缩放（TODO-568）。
  double get _videoSubtitleSeekBarBreathingGap =>
      _videoSubtitleSeekBarBreathingBase * _videoUiScale;

  static const Duration _videoDoubleClickInterval = Duration(milliseconds: 400);
  static const double _videoDoubleClickSlop = 48;

  /// 章节刻度层（TODO-432）淡入淡出时长：对齐 media_kit 控制条默认
  /// `controlsTransitionDuration`（300ms，本页未覆盖），使刻度与 seek bar 同步显隐。
  static const Duration _videoChromeFadeDuration = Duration(milliseconds: 300);

  /// 唤醒控制条用的合成 hover 设备 id（[_pokeControlsVisible]）。取一个不与真实
  /// 鼠标/触控设备号冲突的固定值，使重复派发落在同一逻辑设备上。
  static const int _syntheticHoverDevice = 0x6869626B; // 'hibk'

  /// 合成 hover 位置的 ±1px 抖动开关（TODO-148/BUG-215）。Flutter `MouseTracker`
  /// 对**同一设备落在同一坐标**的连续 hover 会去重（位置没变就不再回调 onHover），
  /// 连按快进 / 跳句时 [_pokeControlsVisible] 每次都派发到控制条**固定中心点**，第二
  /// 次起 media_kit 的 `MouseRegion.onHover` 不再触发、隐藏 `Timer` 不续命，控制条
  /// 仍只活 2 秒就消失。每次派发翻转此标志、把 x 偏 ±1px，使坐标始终变化，强制
  /// MouseTracker 每次都回调 onHover 续命。仅 1px 抖动不会偏出控制条命中区。
  bool _pokeParity = false;

  /// TODO-1059：移动端底部按钮栏按下时经 [_pokeControlsVisible] 触发本信号，续命
  /// media_kit 控制条的自动隐藏计时（见 [_RestartHideTimerSignal] / 传入
  /// [_mobileControlsTheme] 的 `restartHideTimerSignal`）。随本 State dispose 释放。
  final _RestartHideTimerSignal _restartHideTimerSignal =
      _RestartHideTimerSignal();

  /// 合成 hover 派发去重旗（BUG-425）。[_pokeControlsVisible] 经
  /// [GestureBinding.handlePointerEvent] 派发合成 [PointerHoverEvent] 唤醒控制条，但派发
  /// 会同步进入 Flutter `MouseTracker.updateWithEvent` → 写 `_mouseStates[device]`。当
  /// poke 由 **MouseRegion 自己的 onEnter/onHover 回调**触发（rail / 锁按钮 keep-alive、
  /// 字幕盒 hover）时，这些回调本就跑在 `MouseTracker.updateAllDevices` 遍历 `_mouseStates`
  /// 的 `_deviceUpdatePhase` 内 → 合成派发在迭代期增删该 Map → release 构建抛
  /// `Concurrent modification during iteration: _Map len:2`（debug 是 `_debugDuringDeviceUpdate`
  /// 断言）。修复：合成派发恒经 [scheduleMicrotask] 延迟到当前调用栈（含 MouseTracker 迭代）
  /// 解开后再执行，绝不重入；此旗把同一微任务窗口内的多次 poke 折叠成一次派发（dedup）。
  bool _pokeDispatchScheduled = false;

  /// 待派发的合成 hover 事件（BUG-425）。[_pokeControlsVisible] 在命中区几何有效时同步构造，
  /// [_dispatchPokeHover] 在微任务里取出派发。每次 poke 刷新为最新抖动位置，连按时去重为单
  /// 次派发但派发的仍是最新位置（保 TODO-148/BUG-215 的去重续命）。
  PointerHoverEvent? _pendingPokeHover;
  static const double _volumeStep = 5.0;

  /// media_kit 移动控制条竖滑（左=亮度 / 右=音量）的灵敏度（TODO-172/BUG-230）。
  /// media_kit 公式是 `value -= delta.dy / verticalGestureSensitivity`——值越大越
  /// 不敏感。其默认 100（满量程仅需约 100px 竖向拖动，太敏感，轻轻一划就拉满 / 归零）。
  /// 抬到 320（灵敏度降到约 1/3，满量程约需 320px 拖动），符合用户「太灵敏」反馈。
  /// 仅移动端有此竖滑手势，传给 [_mobileControlsTheme]；桌面 [_desktopControlsTheme]
  /// 无此手势、不设此参数（诚实降级）。
  static const double _videoVerticalGestureSensitivity = 320.0;

  // TODO-916 症状① / BUG-1485：移动控制条横滑 seek（仅移动端有此手势，桌面走鼠标拖
  // 进度条 + 键盘 seek 键 085/090，不接横滑）。像素→时间的换算**不再**用 media_kit 的
  // `horizontalGestureSensitivity`（那条公式按视频总时长比例换算，2 小时的片子每像素
  // 7.2 秒，一拽就起飞），改由 [VideoHorizontalSeekGesture] 这个纯函数模型接管，档位
  // 走用户设置 `_asbConfig.dragSeekSensitivity`。接线见 [_mobileControlsTheme]，HUD
  // 文本格式见 [VideoSeekIndicatorLabel]。

  // TODO-057: 视频左半区竖滑调屏幕亮度、右半区竖滑调音量。手势 + 指示器复用
  // media_kit 移动控制条竖滑手势接线见 [_mobileControlsTheme]；亮度落设备背光经
  // 此 controller 且诚实门控，音量是播放器能力，不跟随亮度能力门控。
  final ScreenBrightnessController _brightness =
      ScreenBrightnessController.instance;

  /// 进入视频时的系统屏幕亮度快照（移动端）。退出播放器 [restore] 写回，防止把
  /// 用户系统亮度永久留在拖动后的值（iOS 系统级亮度尤其要还原）。null=尚未取到。
  double? _enterBrightness;

  int get _asbSeekMs => _asbConfig.seekSeconds * 1000;
  double get _speedStep => _asbConfig.speedStep;

  ColorScheme _videoChromeColorScheme(BuildContext context) =>
      Theme.of(context).colorScheme;

  // 播放器 chrome 前景固定亮色体系（UI 巡检 PR-4 P1）：控制条 / 顶栏 / 底栏时间 /
  // 侧浮条 / 章节刻度压在 media_kit fork 的**固定深色 scrim** 上（播放器表面固定
  // 深色 OSD 体系，不随 colorScheme），前景必须固定亮色——此前跟随 cs.primary /
  // cs.onSurface，浅色 / eink 主题下黑压黑。深色主题下取值与旧实现一致（视觉不变）。
  // 单一真相源在 [video_chrome_colors.dart]（纯函数，测试同源）。

  /// chrome 中性前景（标题 / 时间 / 章节刻度）：固定近白，见
  /// [videoChromeNeutralForeground]。
  static const Color _videoChromeNeutralFg = videoChromeNeutralForeground;

  /// chrome 强调色（按钮 / 进度条 / 滑块）：恒亮 tone 的 primary，见
  /// [videoChromeAccentColor]。
  Color _videoChromeAccent(ColorScheme cs) => videoChromeAccentColor(cs);

  /// 顶栏标题字号，随界面大小缩放（TODO-067），与图标按钮同口径。
  double get _videoControlTitleFontSize =>
      _videoControlTitleFontSizeBase * _videoUiScale;

  /// 顶栏标题样式：中性前景固定近白（chrome 固定亮色体系，不随 colorScheme）。
  TextStyle _videoControlTitleStyle() => TextStyle(
        color: _videoChromeNeutralFg,
        fontSize: _videoControlTitleFontSize,
      );

  Color _subtitleTextColor(ColorScheme cs) => cs.onSurface;
  Color _subtitleShadowColor(ColorScheme cs) => cs.shadow;
  // TODO-1059 方案A：字幕盒默认底色不再跟随主题 `surface`（浅色主题下近白 → 字幕
  // 背景泛白违和），改用固定半透明黑 [kDefaultSubtitleBackgroundColor]。仅当
  // 用户未显式选背景色（[VideoSubtitleStyle.backgroundColor]==null）时作为默认色
  // 喂进 [VideoSubtitleStyle.resolveBackgroundColor]；显式选过的颜色仍逐字尊重。
  Color _subtitleBackgroundColor(ColorScheme cs) =>
      kDefaultSubtitleBackgroundColor;
  double get _videoUiScale => appModel.appUiScale;

  Color _osdSurfaceColor(ColorScheme cs) =>
      cs.inverseSurface.withValues(alpha: 0.82);

  Color _osdTextColor(ColorScheme cs) => cs.onInverseSurface;

  @override
  int? get debugPositionMs => _controller?.positionMs;

  @override
  int get debugChapterCount => _controller?.chapters.length ?? 0;

  @override
  bool get debugControlsVisible => _mediaKitControlsVisible.value;

  @override
  int? get debugDurationMs => _controller?.durationMs;

  @override
  String? get debugMiningSource => _controller?.miningSource;

  @override
  String? get debugMiningAudioSource => _controller?.miningAudioSource;

  @override
  void debugShowChapterPanel() {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    _showChapterPanel(controller);
  }

  @override
  void debugOpenDanmakuSettings() {
    _showPlayerSettings(initialCategory: 'danmaku');
  }

  @override
  void debugOpenDanmakuMatch() {
    _openDanmakuManualMatch();
  }

  @override
  Future<void> debugPlay() async => _controller?.play();

  @override
  Future<void> debugPause() async => _controller?.pause();

  @override
  Future<void> debugSeekMs(int positionMs) async =>
      _controller?.seekMs(positionMs);

  VideoPlayerController? _controller;

  /// BUG-772：首开时新建但尚未赋给 [_controller] 的「在途」controller。持有它，才能在
  /// 用户于 `await controller.load()` 完成前退出页时，于 [dispose] 主动 dispose 取消它
  /// （触发 `loadToken++` → 在途 load 的 `_isCurrentLoad` 判据翻假、干净放弃后续原生
  /// 下发），杜绝在已离开页面上把 libmpv/WGC 完整拉起再拆的 GPU churn（进程共享 D3D
  /// device 被 device-lost 污染 → 下次启动 raster present 楔死）。换集复用不设。
  VideoPlayerController? _pendingController;

  /// TODO-1276：首开视频「转两次圈」根治开关。
  ///
  /// 根因：首开路径有**两个独立的加载指示器**接力——① 页级 [VideoLoadingOverlay]
  /// （[_buildLoadingBody]，在 `_controller`/`videoController` 为空时显示）覆盖
  /// `controller.load()`（open+seek+play）阶段；② `load()` 返回、[Video] 挂载后，
  /// media_kit 自带缓冲圈继续覆盖「已下发 play 但首帧尚未解码出画」的窗口。两个圈
  /// 背景/样式不同（页级在 surface 底、media_kit 在纯黑底），用户看到转圈消失又出现
  /// = 「转两次圈」。
  ///
  /// 修复：**首开**时把页级加载态保持到首帧真正解码出画
  /// （[VideoPlayerController.hasFirstFrame]）再挂载 [Video]——此刻 media_kit 已有帧、
  /// 不再缓冲 → 全程只有一个圈。换集（复用 controller，`_controller != null`）不改动
  /// 此值（保持 true），维持既有「换集只走 media_kit 缓冲圈」行为，且不触碰全屏路由
  /// 复用的同一 VideoController 实例（BUG-120/121）。
  bool _videoReadyToShow = false;

  /// TODO-1276：首帧就绪兜底定时器。解码异常机型（TODO-984「闪烁+空白无画面」）/ 纯
  /// 音频容器首帧永不就绪时，超时后仍切给 media_kit 由其自有状态（黑屏/缓冲圈）接管，
  /// 绝不无限转圈——只把「上界」从两个圈收敛为一个圈，保留旧行为下界。
  Timer? _firstFramePromoteTimer;

  /// TODO-1244：字幕对轴波形包络缓存。抽一次 ffmpeg 逐帧能量包络后按
  /// `videoPath|audioStreamIndex` 记住结果，之后每次打开快速设置面板 / 波形对轴视图直接
  /// 复用，不再重跑 ffmpeg（切视频/切音轨时 key 变化自动失效，见 [WaveformEnvelopeCache]）。
  final WaveformEnvelopeCache _subtitleWaveformCache = WaveformEnvelopeCache();

  /// 进度条 hover 缩略图预览调度器（TODO-669，方案 A）。仅桌面本地文件视频时创建；
  /// 移动端 / 远端流为 null（不取帧，仅经 [_onSeekBarHover] 走 timestampOnly）。
  /// 换集（视频路径变）时重建（绑新离屏取帧器），页面 dispose 时一并销毁。
  VideoThumbnailPreviewController? _thumbnailPreview;
  OffscreenVideoFrameGrabber? _thumbnailGrabber;
  VideoPlayerController? _chapterListenerController;
  VoidCallback? _chapterListener;
  bool _failed = false;

  /// 加载失败态的用户可读原因（[_failed] 为 true 时展示在 [_buildFailedBody]）。null
  /// = 尚无具体原因（回退到通用文案）。各失败点（book row 缺失 / 流解析失败 / 换集失败 /
  /// controller.load 抛异常）在置 [_failed] 时经 [_describeLoadFailure] 从异常派生一句
  /// 友好文案，替代旧的「只有一个红叹号、没有任何说明」。
  String? _failReason;

  /// TODO-1213：当前加载阶段（网络流 / 本地共用）。非就绪态时 [_buildScaffold] 的
  /// spinner 分支据此显示带上下文的加载态（标题 + 返回 + 阶段文案）。默认 preparing，
  /// 首帧即有文案；[_loadRemoteEpisode] / [_applyLoad] 各阶段推进。就绪 / 失败 / 缺失
  /// 态走其它分支、不看它。
  _VideoLoadPhase _loadingPhase = _VideoLoadPhase.preparing;

  /// TODO-1213：字幕下载阶段的确定性进度（0..1）。仅当 host 端
  /// [RemoteVideoClient.getRemoteVideoSubtitle] 回调 onProgress 时非空 → 显进度条 +
  /// 百分比；否则 null → indeterminate spinner + 阶段文案。
  double? _subtitleProgress;

  /// TODO-897：本地视频资源缺失（被移动 / 删除 / 所在盘未挂载）。置位后
  /// [_buildScaffold] 在转圈判据之前短路成「资源缺失」态，不再无限转圈。
  bool _missingResource = false;

  /// 缺失态对应的 video book 行（用于复用 [_confirmMissingResourceDelete] 的删除
  /// 序列：删条目要 coverPath / subtitleSource / videoPath 三参数）。仅本地路径
  /// 缺失时置；远端 / 流不进缺失态故恒 null。
  VideoBookRow? _missingRow;

  /// 本次 _init 加载到的 video book 行（单视频 / 播放列表共用，远端为 null）。
  /// 缺失态删除序列复用其 coverPath / subtitleSource / videoPath。
  VideoBookRow? _bookRow;
  String? _title;

  /// 播放列表（系列）名（TODO-761，方案 B）。仅当本视频是播放列表（多集，
  /// [_isPlaylist] 为真）时记 [VideoBookRow.title]（系列名）；单视频 / 远端视频
  /// 保持 null。制卡时 [DictionaryPageMixin] 的 `documentTitle` 据此拼成
  /// 「系列名 - 剧集名」，老 Anki 卡片模板的 `{document-title}` 自动带上系列名，
  /// 无需改模板。**只用于制卡 documentTitle**，不影响播放器标题栏（仍是剧集名 [_title]）。
  String? _playlistTitle;
  List<VideoDanmakuItem> _danmakuItems = const <VideoDanmakuItem>[];

  /// TODO-1376：屏蔽规则过滤后、真正送进 overlay 的弹幕（[_danmakuItems] 为原始全集）。
  /// 缓存而非每帧重算：overlay ticker 每帧 rebuild，过滤上千条会拖慢。规则或原始集
  /// 变化时经 [_applyDanmakuItems] / [_setVideoDanmakuBlockRules] 重算一次。
  List<VideoDanmakuItem> _danmakuVisibleItems = const <VideoDanmakuItem>[];
  int _danmakuLoadSeq = 0;

  /// TODO-1376：弹幕样式（字号/不透明度/速度/显示区域）与屏蔽规则，源自全局偏好。
  late VideoDanmakuStyle _danmakuStyle = appModel.videoDanmakuStyle;
  late VideoDanmakuBlockRules _danmakuBlockRules =
      parseVideoDanmakuBlockRules(appModel.videoDanmakuBlockRulesText);

  /// 库内 part 文件（extension）改状态的入口：扩展不被视作 State 子类实例成员，
  /// 直接调 @protected 的 setState 会报 invalid_use_of_protected_member。由本 State
  /// 子类持有的这个转发器统一承接，零行为变化（仅转发）。
  void _rebuild(VoidCallback fn) => setState(fn);

  /// 同 [_rebuild]：库内 part（extension）调 [DictionaryPageMixin] 的 @protected
  /// [recordMined] 会报 invalid_use_of_protected_member（扩展不算 State 子类实例
  /// 成员）。由本 State 子类持有的这个转发器统一承接，零行为变化（仅转发）。
  Future<void> _recordMinedForVideo() => recordMined();

  /// 顶栏标题的响应式来源（BUG-120）。顶栏文字渲染在 media_kit 控制条主题里，全屏是
  /// 推到根 navigator 的独立路由、进入时**快照捕获**当时的主题（含标题字符串），页面
  /// `setState` 不会重建全屏路由 → 全屏换集后标题停在旧集。改用 [ValueNotifier] + 顶栏
  /// `ValueListenableBuilder` 监听：它在全屏路由内也会随 notifier 变化自重建，标题跟上。
  final ValueNotifier<String?> _titleNotifier = ValueNotifier<String?>(null);

  /// 字幕跳转列表面板的可见性（TODO-069；asbplayer 式 transcript 面板）。
  ///
  /// 用 [ValueNotifier] 而非 setState：面板渲染在 media_kit controls builder 内的
  /// [Stack]（[_buildVideoControlsInner]），全屏是推到根 navigator 的独立路由、不随
  /// 本页 setState 重建（与标题 [_titleNotifier] 同源，BUG-120）。监听 notifier 才能
  /// 让窗口与全屏两种场景都随 L 键 / 入口按钮翻转可见。
  final ValueNotifier<bool> _subtitleListVisible = ValueNotifier<bool>(false);

  /// BUG-1907：请求字幕列表面板展开搜索框的计数器（每 +1 一次请求）。
  /// 见 `_requestSubtitleListSearch`——整表快捷键够不到面板，只能这样递话。
  final ValueNotifier<int> _subtitleSearchRequests = ValueNotifier<int>(0);

  /// BUG-877：字幕列表面板左边缘拖拽中的临时宽度（逻辑像素）。仅拖动期间非 null，
  /// [_subtitleJumpSidePanel] 优先用它实时反映拖动；拖动结束落 Drift preferences 后复位 null，
  /// 回到读持久化值。避免每次 `onHorizontalDragUpdate` 都写 DB。
  double? _subtitleListWidthDrag;

  /// BUG-930：鼠标是否正悬在字幕列表宽度拖拽把手（[_subtitleListResizeHandle]）上。
  /// 把手要显 `resizeLeftRight`（左右箭头）光标，但侧栏 [_withSubtitleListCursorReveal]
  /// 的 `onHover` 每帧经 [_forceRevealOsCursorForPanel] **原生强设** OS 光标为 `basic`
  /// （箭头，BUG-391 缓解），会盖掉框架为把手下发的 resize 光标 → 调宽光标永远出不来。
  /// 悬在把手上时置真，让 [_forceRevealOsCursorForPanel] 让位（不再强设 basic），把光标
  /// 交给把手 MouseRegion 声明的 resize。只被 hover 回调读、不触发重建，故不走 setState。
  bool _pointerOverSubtitleResizeHandle = false;

  /// 剧集列表 push-aside 侧栏可见性（TODO-638）。剧集列表此前是
  /// `showModalBottomSheet`（底部弹层），与其它侧栏（字幕列表 push-aside、设置 /
  /// 倍速等 overlay）显示风格不一致。改成与字幕列表同款的 push-aside 侧栏后，可见性
  /// 同样用 [ValueNotifier]（全屏路由也响应，与 [_subtitleListVisible] 同源，BUG-120）。
  /// 与字幕列表互斥：同一时刻右栏只占其一，开一个先关另一个（避免两侧栏分占右栏）。
  final ValueNotifier<bool> _episodeListVisible = ValueNotifier<bool>(false);
  final ValueNotifier<_VideoSidePanelState?> _videoSidePanel =
      ValueNotifier<_VideoSidePanelState?>(null);

  /// TODO-1351：下次构建设置面板时要定位到的分类（`audio` / `subtitle` / null=默认）。
  /// 「音频轨」「字幕轨」按钮把轨切换收进设置面板对应 tab，靠它把面板直接开在目标分类。
  String? _settingsInitialCategory;

  final ValueNotifier<_VideoControlPopoverKind?> _videoControlPopover =
      ValueNotifier<_VideoControlPopoverKind?>(null);
  final Map<String, LayerLink> _controlPopoverItemLinks = <String, LayerLink>{};
  final Map<String, GlobalKey> _controlPopoverTargetKeys =
      <String, GlobalKey>{};
  LayerLink? _activeControlPopoverLink;
  _VideoControlPopoverPlacement? _activeControlPopoverPlacement;
  VideoControlSlot? _activeControlPopoverSourceSlot;
  VideoControlItem? _activeControlPopoverSourceItem;
  bool _controlPopoverAnchorHovered = false;
  bool _controlPopoverPanelHovered = false;
  bool _controlPopoverPinned = false;
  Timer? _controlPopoverHideTimer;

  /// 画面内控制布局编辑模式（TODO-440）。用 [ValueNotifier] 而非普通 setState：
  /// 叠层渲染在 media_kit controls builder 里，全屏路由同样需要即时开关。
  final ValueNotifier<bool> _videoControlEditMode = ValueNotifier<bool>(false);

  /// 当前 9 槽控制按钮布局的响应式来源（TODO-466）。
  ///
  /// 保存「画面上编辑」草稿后，窗口页 setState 能刷新普通页面树，但全屏路由和
  /// media_kit controls builder 是独立子树；只改字段/落偏好会让当前控制层继续用旧
  /// theme 快照。用 notifier 推进当前布局，并在 controls builder 内重建控制主题，
  /// 窗口与全屏都能立即反映新槽位。
  final ValueNotifier<VideoControlLayout> _controlLayoutNotifier =
      ValueNotifier<VideoControlLayout>(VideoControlLayout.currentChrome);

  /// 自定义「快捷键 1..4」按钮的绑定（槽位 → 视频动作）。与 [_controlLayoutNotifier]
  /// 同样走 notifier 而不是裸字段：控制层（含全屏路由那棵独立子树）只在监听到通知时
  /// 才重建，绑定改了却不通知 = 按钮图标/行为停在旧动作上（BUG-391 那条「漏监听 =
  /// 改了白改」的同款陷阱，见 layout.part.dart 的 merge 列表）。
  final ValueNotifier<VideoCustomActionBindings> _customActionBindingsNotifier =
      ValueNotifier<VideoCustomActionBindings>(VideoCustomActionBindings.empty);

  /// 当前生效的自定义按钮绑定表。
  VideoCustomActionBindings get _customActionBindings =>
      _customActionBindingsNotifier.value;

  List<SubtitleSource> _subtitleMenuSources = const <SubtitleSource>[];
  bool _subtitleMenuLoading = false;

  /// BUG-1863：本页在前台期间是否真的进过后台（`paused` / `hidden`，**不含**
  /// `inactive`）。回前台时据它决定要不要重建视频解码链，见
  /// [_refreshDecodeAfterResumeIfNeeded]。
  bool _enteredRealBackground = false;

  /// BUG-939：`_subtitleMenuSources` 已成功枚举时对应的本地视频路径。字幕轨枚举
  /// （ffprobe 探测内嵌轨 + 同目录外挂）按此 key 记忆：同一视频重开「字幕」分类直接
  /// 用缓存渲染，不再每次重跑 ffprobe 显加载条、也不再把已枚举出的字幕轨先清空重来
  /// （用户报「字幕轨每次都要加载、明明没可加载的地方；之前有的字幕还会消失要等」）。
  /// null=尚未为当前视频枚举 / 已失效（换视频）→ 下次打开重新枚举。BUG-1329：导入或
  /// 下载新字幕档**不**作废这个 key（那会换来一整趟无谓的容器重探 + 长时间加载条），
  /// 新档由 `_registerImportedSubtitleSource` 记进 `_importedSubtitleSources`，渲染时
  /// 与本枚举结果合并（BUG-1861，不再写进本缓存）。
  String? _subtitleMenuSourcesPath;

  /// BUG-1861：本次播放会话里**落盘并应用过**的外挂字幕档（Jimaku 下载 / 手动导入）。
  ///
  /// 与 `_subtitleMenuSources`（纯枚举结果：内封轨 + 视频同目录 sidecar）是两份独立
  /// 真相，渲染时由 `mergeImportedSubtitleSourcesForMenu` 合并。独立存放的理由见该函数
  /// 注释：枚举可能失败 / 在途 / 因换集失配，而「这个档案就在盘上、刚被应用」是不依赖
  /// 枚举的既成事实，不能被枚举缓存的有效性 gate 掉（那正是用户报的「字幕应用上了但
  /// 列表里没有」）。远端模式同样维护它——远端主 / 副字幕轨行都只覆盖 host sidecar /
  /// YouTube 轨 / host 内封轨，本机下载或导入的档案此前在远端根本没有对应行（两栏都
  /// 没有）。换视频源时清空。
  List<SubtitleSource> _importedSubtitleSources = const <SubtitleSource>[];

  /// 当前视频是否有内封章节（TODO-424）：控制条章节入口按钮的显隐门控。章节列表是
  /// [VideoPlayerController.refreshChapters] open 后**异步**填充的，故缓存这个布尔并由
  /// [_onControllerChaptersChanged] 监听 controller 通知刷新——章节就绪后触发一次
  /// setState 让按钮出现（控制条主题在 build 里构造一次，不监听 controller 不会自重建）。
  bool _hasChapters = false;

  /// 锁定 / 沉浸模式（TODO-101）。开启后：鼠标移动 / 单击不再唤起 media_kit 控制条
  /// （顶/底栏按钮全部不弹），视频纯画面播放；但查词（点字幕字符）与所有键盘 / 手柄
  /// 快捷键（上下句、seek、字幕列表、播放暂停等）仍照常工作。痛点：「每次鼠标查词就
  /// 弹按钮有点烦」。
  ///
  /// 用 [ValueNotifier] 而非 setState：锁定态要在 media_kit controls builder 内的
  /// [Stack]（[_buildVideoControlsInner]）里 gate `AdaptiveVideoControls` 的指针、并驱动
  /// 常驻解锁按钮的显隐；全屏是推到根 navigator 的独立路由、不随本页 setState 重建
  /// （与 [_titleNotifier] / [_subtitleListVisible] 同源，BUG-120）。监听 notifier 才能
  /// 让窗口与全屏两种场景都随锁屏按钮 / 快捷键翻转。
  final ValueNotifier<bool> _immersiveLocked = ValueNotifier<bool>(false);

  /// 视频内角标通知（mpv 式 OSD）。取代会从屏幕底部弹出、遮挡控制条、且与 mpv 等
  /// 播放器观感割裂的 Material SnackBar（用户要求改成 mpv 那样的左上角短暂提示）。
  /// null=不显示。渲染在 [_buildVideoControls] 的 controls overlay 里，故窗口/全屏
  /// 都显示；[IgnorePointer] 包裹，绝不拦截点击（不破坏单击暂停 / 拖放 / 字幕查词）。
  final ValueNotifier<_VideoOsdMessage?> _osdNotifier =
      ValueNotifier<_VideoOsdMessage?>(null);

  /// OSD 自动消失定时器（每次 [_showOsd] 重置）。
  Timer? _osdTimer;

  /// 自动连播倒计时剩余秒数（TODO-639）。null=没有倒计时；非空时画面右下角显示
  /// 「N 秒后播放下一集 · 取消」可点 overlay，归零后进下一集。与 [_osdNotifier] 分开：
  /// 这个 overlay 必须可点（取消按钮），不能套 [IgnorePointer]。
  final ValueNotifier<int?> _autoAdvanceCountdownNotifier =
      ValueNotifier<int?>(null);

  /// 自动连播倒计时定时器（每秒 -1，归零触发进下一集）。
  Timer? _autoAdvanceCountdownTimer;

  /// 倒计时进入的目标集索引（[_cancelAutoAdvanceCountdown] / 归零推进时用）。
  int? _autoAdvanceCountdownTarget;

  /// Page-level level HUD value (0..100). Null means hidden.
  final ValueNotifier<_VideoLevelHudState?> _levelHudNotifier =
      ValueNotifier<_VideoLevelHudState?>(null);

  /// TODO-1119 / BUG-545：Windows「高显卡占用黑屏闪烁」运行时提示条可见性。控制器判定
  /// 疑似黑闪时经 [_handleSuspectedBlackFlicker] 置 true；用 [ValueNotifier] 而非 setState
  /// （提示条挂在 media_kit controls builder 的 Stack，全屏路由也需即时开关，与其它 OSD
  /// 同源，BUG-120）。方法域在 flicker_notice.part.dart。
  final ValueNotifier<bool> _blackFlickerNoticeNotifier =
      ValueNotifier<bool>(false);

  /// 本会话是否已弹过一次黑闪提示（每会话最多一次；与偏好「不再提示」共同门控）。
  bool _blackFlickerNoticeShown = false;

  /// Auto-hide timer for the page-level level HUD.
  Timer? _levelHudTimer;

  /// media_kit 底部控制条 **真实** 可见性（TODO-364）——单一真相源，由 media_kit 自己的
  /// 控制条 State 在每次 `visible` 变化时推进来。
  ///
  /// 历史根因（TODO-129 旧实现）：media_kit 把控制条可见性 `visible` 与隐藏 `Timer` 藏在
  /// 私有 State，旧 Hibiki 侧另建一份 **镜像** [_videoControlsVisible] + 一个独立隐藏
  /// `Timer`（已删）复刻同一套触发源喂给字幕避让。两套 `Timer` 各自计时、
  /// 各入口（hover / 移动 tap / 键盘 poke）独立维护 → 镜像与真实控制条 **相位会反**：
  /// 进度条起落动画中又来一次操作时，镜像翻成与真实可见态相反，字幕避让方向就反了
  /// （用户：「进度条起来下去同时其他操作字幕行为相反，让他们用同一个变量」）。
  ///
  /// 修复：vendored media_kit_video fork 给两套控制主题加 `visibilityNotifier`，控制条
  /// State 每次改 `visible` 都推进本 notifier（见 third_party/media_kit_video/PATCHES.md）。
  /// 本字段即那唯一真相源，字幕避让消费它派生出的 [_videoControlsVisible]，彻底消除独立
  /// 镜像 + 第二个 `Timer` 的相位漂移。窗口 / 全屏复用同一 controls builder，故两套主题
  /// 都注入同一个 notifier。
  final ValueNotifier<bool> _mediaKitControlsVisible =
      ValueNotifier<bool>(false);

  /// 字幕避让真正消费的控制条可见性（TODO-129/364）。**单一写入点** =
  /// [_applyControlsVisibilityFromMediaKit]：它把 media_kit 真实可见性
  /// （[_mediaKitControlsVisible]）按沉浸锁 / 侧栏 / 字幕列表门控取下限派生进来。不再有
  /// 任何入口直接乐观翻它（那是 TODO-364 相位反的根因），故它恒等于「真实可见态 且 无遮挡
  /// overlay」。
  ///
  /// 用 [ValueNotifier] 而非 setState：字幕 overlay 在 media_kit controls builder 内的
  /// [Stack]（[_buildVideoControlsInner]），全屏是推到根 navigator 的独立路由、不随本页
  /// setState 重建（与 [_titleNotifier] / [_immersiveLocked] 同源，BUG-120）。监听
  /// notifier 才能让窗口与全屏两种场景字幕都随控制条显隐上顶 / 落回。
  final ValueNotifier<bool> _videoControlsVisible = ValueNotifier<bool>(false);

  /// 鼠标当前是否悬停在右 / 左浮动学习按钮 rail 上（BUG-283）。
  ///
  /// 根因：rail 按钮是 opaque 的 [IconButton]，叠在 media_kit 桌面控制条那个**全画面**
  /// hover-tracking [MouseRegion] 之上。鼠标移到 rail 按钮上时，Flutter MouseTracker 把
  /// 最顶命中切到按钮 → media_kit 的 `MouseRegion.onExit` 触发 → 它**立即**把 `visible`
  /// 置 false（见 media_kit `material_desktop.dart` 的 `onExit`）→ [_videoControlsVisible]
  /// 派生为 false → rail [SizedBox.shrink] 消失 → 鼠标位置下方重新变成 media_kit region →
  /// `onEnter` 把 visible 拉回 true → rail 重现 → 鼠标又落按钮上 → 每帧级别快速闪烁。
  ///
  /// 修复（消除特殊情况，而非去抖/延迟掩盖）：rail 的显隐判据改为
  /// `[_videoControlsVisible] || 鼠标正悬在 rail 上`。鼠标进 rail 即置本标记 true，rail 在
  /// hover 期间永不被 media_kit 的瞬时 visible 抖动收走 → 振荡根除。进 rail 同时
  /// [_pokeControlsVisible] 喂合成 hover 给 media_kit（其自身设计的续命路径），底层控制条
  /// 也跟着保持，观感统一。仅桌面有 hover 语义（移动端无，[ValueNotifier] 恒 false 不影响）。
  final ValueNotifier<bool> _railHovered = ValueNotifier<bool>(false);

  /// 视频左侧常驻锁 / 解锁按钮（TODO-126）的可见性。非沉浸态显示锁图标（进入沉浸）、
  /// 沉浸态显示解锁图标（退出沉浸）——两态用同一枚侧边按钮（[_buildSideLockButton]）。
  ///
  /// 与 [_videoControlsVisible] 同样走「hover / tap 唤起 + 2s 自动淡出」时序，但**独立于
  /// 它**：沉浸态下 [_markControlsVisible] 被锁强制 false（防 media_kit 控制条弹出），若解
  /// 锁按钮复用 [_videoControlsVisible] 就会被一起 gate 成永久淡出、再也唤不回（用户就没有
  /// 可见退出口了）。故另起一份不被锁 gate 的可见性源 [_pokeLockButton]，保证沉浸态解锁按钮
  /// 无操作淡出后仍能被鼠标移动 / 触屏唤回。Esc / Shift+L 始终可解锁（守卫已钉），淡出不
  /// 影响这两条退出口。用 [ValueNotifier] 让全屏路由也随之翻转（与 [_immersiveLocked] /
  /// [_videoControlsVisible] 同源，BUG-120）。初始 true：开页先显示让用户发现锁按钮，2s 淡出。
  final ValueNotifier<bool> _lockButtonVisible = ValueNotifier<bool>(true);

  /// 鼠标是否正悬在侧边锁 / 解锁（沉浸）按钮上（TODO-388，BUG-294）。
  ///
  /// 根因：侧边锁按钮的可见性走 [_lockButtonVisible] + [_pokeLockButton] 的 2s 自动淡出
  /// 定时器，唤起只发生在「鼠标在视频区移动」时（[_videoControlsHoverWrap] 的 onHover →
  /// [_pokeLockButton]）。一旦鼠标**静止悬停在按钮本身**上，不再有 hover 事件续命定时器，
  /// 2s 后按钮就在光标正下方淡出消失——与用户报告「沉浸按钮鼠标放上去会消失」一致。
  /// 屏幕右侧 rail 按钮用 [_railHovered] + [_railHoverKeepAlive] 解决同类问题（hover 期间
  /// 顶住显示、永不被自动淡出收走）。本字段把同一机制套到锁按钮上：鼠标进按钮置 true 顶住
  /// 可见、移出置 false 让可见性回落到 [_lockButtonVisible] 的自然淡出。仅桌面有 hover。
  final ValueNotifier<bool> _lockButtonHovered = ValueNotifier<bool>(false);

  /// 侧边锁 / 解锁按钮自动淡出定时器（TODO-126）。每次 [_pokeLockButton] 唤起重置。
  Timer? _lockButtonHideTimer;

  /// OS 鼠标光标是否应隐藏的单一真相源（TODO-318 / BUG-258）。
  ///
  /// 根因：media_kit 自己用 `MouseRegion(cursor: none)`（`hideMouseOnControlsRemoval`）在
  /// 控制条淡出时隐藏光标，但 hibiki 把 overlay chrome（锁按钮 rail / OSD / 字幕跳转面板等）
  /// 叠在 media_kit 之上 → 最上层 MouseRegion 的 cursor 解析胜出 → 鼠标放到这些 chrome 上时
  /// 光标重现；沉浸锁态下 [IgnorePointer] 又剥了 media_kit 的 region，光标更无人隐藏。
  ///
  /// 解法：在 controls 子树最外层（[_videoControlsHoverWrap]）包一个 `MouseRegion(cursor:
  /// none)`，由本 notifier 驱动统一胜出，盖过所有 chrome。隐藏时机镜像 controls 自动隐藏
  /// 2s 计时 + 沉浸锁态；真实鼠标移动经 [_handleVideoControlsHover] 自然唤回（置 false）。
  /// 用 [ValueNotifier] 让全屏路由也响应（与 [_videoControlsVisible] / [_immersiveLocked]
  /// 同源，BUG-120）。仅桌面有 OS 光标语义；移动端 [_videoControlsHoverWrap] 透传 child。
  final ValueNotifier<bool> _cursorHidden = ValueNotifier<bool>(false);

  /// 翻转 OS 光标隐藏单一真相源（TODO-318）。仅桌面生效（移动端无 OS 光标）。
  void _setCursorHidden(bool hidden) {
    if (!_isDesktopVideoControls) return;
    _cursorHidden.value = hidden;
  }

  /// 系统栏（状态/导航/手势栏）**当前是否真正可见**（TODO-658/BUG-383）。视频页进入即
  /// [SystemUiMode.immersiveSticky] 隐藏系统栏，故默认 `false`。由 [SystemChrome.
  /// setSystemUIChangeCallback] 在系统栏可见性变化时回写（仅移动端注册）。
  ///
  /// 这是 [_videoBottomSystemInset] 是否计入底部系统 inset 的**唯一权威开关**：
  /// `MediaQuery.viewPadding.bottom` / `padding.bottom` 在 targetSdk 35 强制 edge-to-edge
  /// + **手势导航**下，即便 immersiveSticky 已隐藏导航栏，仍上报手势条物理高度（引擎
  /// `getInsets(systemBars())` 在手势导航下照单全收，见 Flutter #170640，且 padding 与
  /// viewPadding 在无键盘时同源 = 换字段不解决问题）→ 旧实现把这段恒非零的 inset 永久
  /// 叠进进度条/字幕/刻度带几何，进度条被顶高到屏幕中上部（BUG-370 当初只重申
  /// immersiveSticky 是治标，inset 仍非零）。改读系统栏**真实可见性**：隐栏（沉浸态，
  /// 常态）→ inset=0，进度条回到惯例 `基线+按钮条+间距`；导航栏真显示（三键导航 / 手势条
  /// 临时唤出）→ 计入 inset 避开它（保 BUG-184「导航栏可见时进度条上移避让」本意）。
  bool _systemBarsVisible = false;

  /// 注册系统栏可见性回调（仅移动端）。immersiveSticky 隐栏 → `false`；上划临时唤回 /
  /// 三键导航显示 → `true`。回写 [_systemBarsVisible] 并 `setState` 重建进度条/字幕/刻度
  /// 几何（[_mobileControlsTheme] / [_subtitleControlsBottomReserve] / 章节刻度带均在
  /// build 期读 [_videoBottomSystemInset]）。桌面无系统栏语义，不注册。
  void _registerSystemBarsVisibilityCallback() {
    if (!isMobilePlatform) return;
    SystemChrome.setSystemUIChangeCallback(
      (bool systemOverlaysAreVisible) async {
        if (!mounted) return;
        if (_systemBarsVisible == systemOverlaysAreVisible) return;
        setState(() => _systemBarsVisible = systemOverlaysAreVisible);
      },
    );
  }

  /// media_kit [Video] 的键盘焦点节点。media_kit 的 `Video` 自带 FocusNode + 内置
  /// 快捷键（空格=播放/暂停、方向键=快进/快退/音量等）。本页把这个节点提到 State 持有，
  /// 是为了在任何**会夺走窗口键盘焦点的覆盖层**（对话框 / bottom sheet / 系统文件选择器）
  /// 关闭后，能主动把焦点还给 [Video]——否则那些覆盖层关闭后焦点悬空，空格等快捷键失灵
  /// （根因：FilePicker 打开系统对话框抢走焦点，关闭后不会自动归还）。见 [_focusOwnership]。
  final FocusNode _videoFocusNode = FocusNode(debugLabel: 'videoKeyboard');

  /// media_kit controls 子树内的 [BuildContext]（在 [_buildVideoControls] 用 [Builder]
  /// 捕获）。覆盖默认键盘快捷键时，全屏相关 helper（[isFullscreen]/[toggleFullscreen]/
  /// [exitFullscreen]）必须用 controls 子树内的 context 才能找到 media_kit 的
  /// `FullscreenInheritedWidget` / `VideoStateInheritedWidget`——本页 build 的 context 是
  /// 它们的祖先，传进去会查不到。故捕获一个后代 context 供 Escape/F 快捷键用。
  BuildContext? _videoControlsContext;
  final Stopwatch _videoInputClock = Stopwatch()..start();
  final VideoGamepadSecondaryTapDeduper _videoGamepadSecondaryTapDeduper =
      VideoGamepadSecondaryTapDeduper();
  DateTime? _lastVideoPointerUpAt;
  Offset? _lastVideoPointerUpPosition;
  bool _videoFullscreenTransitioning = false;

  /// 全屏路由当前是否在栈上：进全屏置位、全屏路由 future 完成（任意退出路径：
  /// Esc / F / 按钮 / 双击 / 系统返回）复位。
  ///
  /// 这是窗口侧 controls 在全屏期间必须卸载（[VideoControlsFocusGate]）的唯一依据：
  /// 全屏路由会用**同一个** [_videoFocusNode] 再挂一个 [Focus]，若窗口侧 controls
  /// 不卸载，退全屏时全屏侧 Focus dispose 的 detach 会把节点从焦点树摘除，窗口侧
  /// 只剩 stale attachment、永远不再 reparent → 节点永久孤儿、此后所有
  /// [_focusOwnership] 的回收（含每个菜单/对话框关闭后的归还）全部静默失效——这正是
  /// 「设置/导入/点外部后快捷键失灵」在打过逐点 refocus 补丁后仍复发的共同根因
  /// （TODO-040/042）。
  bool _videoFullscreenActive = false;

  /// 当前在栈上的全屏路由（[_videoFullscreenActive] 为真时非 null）。
  /// [_canOwnVideoFocus] 用它判定全屏期间「键盘所有者路由」是否被
  /// 对话框/遮罩压住（`isCurrent`），避免切窗返回时抢走全屏内对话框的焦点。
  PageRoute<void>? _videoFullscreenRoute;

  /// BUG-839：`initialFullscreen` 新页「首帧就绪后重进全屏」的一次性闸门 + 有界重试计数。
  /// controls 首建帧（设 [_videoControlsContext]）可能晚于就绪帧，故就绪后逐帧重试到
  /// context 可用再进全屏；失败/缺失态或超过上限则放弃，避免死循环（见
  /// [_scheduleInitialFullscreenIfNeeded]）。
  bool _didInitialFullscreen = false;

  /// BUG-2043：本页是否持有从上一集页**接管**来的原生全屏（窗口已是原生全屏、栈上
  /// 尚无本页的全屏路由）。initState 经 [_claimHandedOverNativeFullscreen] 置真；就绪
  /// 后压上全屏路由（退出改由路由 pop 收口）、再换下一集（所有权继续传递）或
  /// [_releaseHandedOverNativeFullscreen] 亲自退出，三者都把它翻假。
  bool _ownsHandedOverNativeFullscreen = false;
  int _initialFullscreenRetries = 0;

  /// 观看统计采集器（观看时长 + 字幕字数 + 完成标记）；首次 load 建，dispose 释放。
  VideoWatchTracker? _watchTracker;

  /// 进程退出 flush 回调引用（TODO-086/BUG-191）：initState 登记到
  /// [ExitFlushRegistry]，dispose 注销。保证未落库的播放位置 + 观看统计在
  /// exit(0) 前写穿。
  ExitFlushCallback? _exitFlushCallback;

  /// 查词浮层栈（与阅读器/词典页同款，由共享 [DictionaryPopupController] 管理）。
  /// 在 initState 安全读取一次 lowMemory 构造——不可放字段初始化器懒读 appModel，
  /// 否则首次访问可能落在 dispose/deactivate 的 postframe（element 树不稳定）→ ref.read 抛错。
  late final DictionaryPopupController _popup;

  /// 字幕字符命中句柄：查词浮层的 dismiss barrier 用它反查「点到的是不是另一个字幕
  /// 字符」，是则切换查词、保持暂停（见 [_onDismissBarrierTap] / [VideoSubtitleHitTester]）。
  final VideoSubtitleHitTester _subtitleHitTester = VideoSubtitleHitTester();

  /// 字幕**列表侧栏**字符命中句柄（BUG-874）：与 [_subtitleHitTester] 对称。查词浮层的
  /// dismiss barrier 盖在推挤式字幕列表侧栏之上、抢走点击，故 barrier 在底部字幕 miss 后再
  /// 用本句柄反查「点到的是不是列表里某行某个字符」，是则切换查词、保持浮层（见
  /// [_onDismissBarrierTap] / [VideoSubtitleListHitTester]）。
  final VideoSubtitleListHitTester _subtitleListHitTester =
      VideoSubtitleListHitTester();

  /// BUG-880：最后一次已知的全局指针位置。桌面查词只在鼠标**移动**派发的 `PointerHoverEvent`
  /// 上触发（画面字幕 overlay 的 `_handleShiftHover`、字幕列表行的 hover、barrier 的
  /// [_onDismissBarrierHover] 都如此），故光标停在词上不动、按 Shift 却因「没有 hover 移动
  /// 事件」而查不出来——用户报的「按了不出」核心根因。页面根 [Listener.onPointerHover] 与
  /// [_onDismissBarrierHover] 持续把最新位置写进这里，Shift 按下瞬间即在此位置反查立即查词。
  Offset _lastGlobalPointerPos = Offset.zero;

  /// BUG-880：Shift 键按下瞬间用 [_lastGlobalPointerPos] 反查字幕字符并立即查词（不必抖鼠标）。
  /// 先查画面字幕命中句柄（[_subtitleHitTester]，含嵌套门控 [shouldSwitchWordOnBarrierTap]），
  /// 未命中再查字幕列表侧栏（[_subtitleListHitTester]）。命中即走与移动触发的 hover 换词同一
  /// 去重入口 / 列表查词入口，故与连续 hover 查词天然去重、不会同词双查。[Offset.zero]（尚无
  /// hover：移动端或刚进页面）不触发。
  void _triggerShiftLookupAtLastPointer() {
    if (_lastGlobalPointerPos == Offset.zero) return;
    final SubtitleCharHit? hit =
        _subtitleHitTester.hitTest(_lastGlobalPointerPos);
    if (hit != null) {
      if (VideoFushiPage.shouldSwitchWordOnBarrierTap(
        topVisibleIndex: _topVisiblePopupIndex,
        hitSubtitle: true,
      )) {
        _handleSubtitleHoverLookup(
            hit.sentence, hit.graphemeIndex, hit.charRect, hit.cue);
      }
      return;
    }
    final SubtitleListHit? listHit =
        _subtitleListHitTester.hitTest(_lastGlobalPointerPos);
    if (listHit != null) {
      _handleSubtitleListLookup(
        listHit.cue,
        listHit.graphemeIndex,
        listHit.charRect,
      );
    }
  }

  /// 承载查词浮层栈的根 Overlay 入口；非空时浮层栈渲染在根 Overlay（窗口/全屏统一，
  /// 全屏时浮在 media_kit 全屏路由之上）。栈空时移除、栈变化时 `markNeedsBuild`。
  OverlayEntry? _popupOverlayEntry;

  /// 最近一次查词所在字幕句（整条 cue 文本）；[onMineEntry] 制卡时作 sentence。
  /// 点字符查词时即时记录，确保制卡例句是「点词那一刻的那句字幕」。
  String _lastLookupSentence = '';

  /// 最近一次字幕查词所在 cue。制卡可能发生在弹窗打开后数秒，此时视频播放位置可能已
  /// 变化；GIF / sasayaki 音频必须仍然导出点词那句，而不是制卡瞬间的 currentCue。
  AudioCue? _lastLookupCue;

  /// 最近一次字幕查词命中的词在字幕上的范围（BUG-2091），由 [_lookupAt] 按引擎回报的
  /// 匹配长度写入；查无结果写 null。**不**在关栈路径复位——overlay 拿到的是
  /// [_activeSubtitleLookupHighlight] 这个派生值：弹窗栈全关即 null，任何关闭路径都
  /// 自动正确，不存在只在成功路径复位的布尔镜像。
  SubtitleLookupHighlight? _subtitleLookupHighlight;

  /// 传给 [VideoSubtitleOverlay] 的高亮：仅弹窗栈还有可见层时才亮。
  SubtitleLookupHighlight? get _activeSubtitleLookupHighlight =>
      _hasVisiblePopup ? _subtitleLookupHighlight : null;

  /// TODO-270 E「查词窗口多句合一制卡」(乙方案·视频车道)：会话级制卡草稿缓冲。弹窗点
  /// 「+句」把当前正查字幕句（[_lastLookupSentence]）+ 其 cue 的画面/音频时间窗推进
  /// 这里，连续查多句累积；制卡（[onMineEntry] / [onUpdateEntry]）时把草稿全部句 +
  /// 当前句用 [MiningSentenceDraft.composeText] 合成 sentence 字段、用
  /// [MiningSentenceDraft.composeAudioRange] 合并成「首句起→末句止」的单一区间（GIF +
  /// 音频共用）。制卡
  /// 成功或关闭整条查词浮层栈后清空。视频所有 cue 同属一个视频文件，故区间合并恒成功
  /// （[MiningSentenceDraft] 把 [AudioPlaybackRange.audioFileIndex] 当文件键，视频统一
  /// 用 0）。reader/有声书车道（[ReaderFushiPage] 的 `_miningDraft`）共用同一草稿模型。
  final MiningSentenceDraft _miningDraft = MiningSentenceDraft();

  /// TODO-393「上 N 句 / 下 N 句」上下文选择（视频车道）：弹窗选「上 N 句 / 下 N 句」
  /// 把当前正查字幕句之前/之后的 N 条 cue 作上下文整体设置进本视频会话级制卡草稿，
  /// 返回上下文句总数（上 N + 下 N）。mixin 的 [buildNestedPopupLayer] 据此非空回调让
  /// popup 渲染上下文选择器。
  @override
  Future<int> Function(int prevCount, int nextCount)?
      get onSetSentenceContextToDraft => _setSentenceContextToDraft;

  /// TODO-382「+句」可撤销（视频车道）：弹窗点「清空已加句子」清掉本会话累积的全部草稿
  /// 句，回传清空后的句数（恒 0）。不动字幕列表「选入词卡」的 cue 选择集（两套独立机制）。
  @override
  Future<int> Function()? get onClearSentenceDraftToDraft =>
      _clearSentenceDraft;

  /// Niratan「制卡前调整·选择句子上下文」（视频车道）：把当前草稿真实上下文句 + 当前
  /// 正查字幕句（[_lastLookupSentence]）打包给弹窗预览。视频无「词在句中的字符偏移」
  /// 缓存（cue 文本非阅读器 DOM 选区），词偏移传 null——弹窗侧回退到首次出现高亮。
  @override
  Future<Map<String, Object?>> Function()?
      get onSentenceContextPreviewToDraft =>
          () async => buildSentenceContextPreview(
                draft: _miningDraft,
                current: _lastLookupSentence,
                currentOffset: null,
              );

  /// 「本次查词浮层是我们因查词而主动暂停了正在播放的视频」标记。
  ///
  /// 查词暂停 / 关浮层恢复与阅读器 [ReaderFushiPage] 同源：浮层打开时若视频在播放则
  /// 暂停（让用户读词），浮层栈**全部关闭**后再自动恢复播放。video 页用
  /// [DictionaryPageMixin]（没有 reader 的 `onAllPopupsDismissed` 钩子），故用本标记 +
  /// 在 [_popNestedPopupAt] 这唯一的关栈汇聚点恢复，覆盖遮罩点击 / 返回键 / 浮层
  /// 滑动·Esc 全部关闭路径。仅当查词前视频确在播放才置位，避免把查词前本就暂停的
  /// 视频自动播起来；递归查词（已暂停，`isPlaying==false`）不会覆写它（BUG-072）。
  bool _pausedForLookup = false;

  /// 字级选词光标状态机（videoEnterCaret）：复用阅读器抽出的
  /// [DictionaryCaretController]（TODO-387 预留的跨页面复用点）。主面 =
  /// [CaretSurface.video]（字幕 overlay 登记表下标 [_subtitleCaretEntry]），查词后
  /// transfer 进顶层弹窗（[CaretSurface.popup]），与阅读器共用弹窗 caret 全套。
  /// 域方法见 video_fushi/subtitle_caret.part.dart。
  late final DictionaryCaretController _videoCaret =
      DictionaryCaretController(this);

  /// 选词光标当前停的字幕字符登记表下标（传给 [VideoSubtitleOverlay.caretEntryIndex]
  /// 画光标环）；null = 主面无锚（未激活，或字幕 gap 期环隐藏）。
  int? _subtitleCaretEntry;

  /// 光标会话的「暂停 → 再播放」迁移追踪；null = 无进行中的光标会话。见
  /// [SubtitleCaretPauseTracker]（初值必须来自进入时的播放态，否则本就暂停的视频
  /// 进光标后自动退出永久失效）。
  SubtitleCaretPauseTracker? _caretPauseTracker;

  /// 光标会话内当前活动 cue 集合签名（跳句/seek 后重锚判据）。
  String _caretCueSignature = '';

  // ── DictionaryCaretHost（选词光标状态机的宿主 seam）─────────────────

  @override
  bool get caretHostMounted => mounted;

  @override
  DictionaryPopupWebViewState? get caretTopPopupState {
    final int idx = _topVisiblePopupIndex;
    if (idx < 0 || idx >= _popup.entries.length) return null;
    return _popup.entries[idx].webViewKey.currentState;
  }

  @override
  int get caretTopVisiblePopupIndex => _topVisiblePopupIndex;

  @override
  void caretSetState(VoidCallback fn) {
    if (!mounted) return;
    setState(fn);
  }

  @override
  void caretExitPrimaryRing() {
    // video 主面的光标环（字幕字符高亮）在 transfer 进弹窗时**保留**——标记正在查
    // 的词（对齐 lyrics 面语义）。控制器只对 CaretSurface.reader 调本方法，此处
    // 防御性 no-op。
  }

  /// 弹窗层渲染完成（DictionaryPageMixin 钩子）：光标激活时把它 transfer 进刚显示
  /// 的顶层弹窗（与阅读器 onDictionaryPopupRendered → controller 同链路）。
  @override
  void onNestedPopupRendered(int index) {
    _videoCaret.onDictionaryPopupRendered(index);
  }

  /// 当前查词所在字幕句是否已被收藏（驱动查词浮层顶部收藏星标的实心/空心）。每次
  /// [_lookupAt] 成功后据 [_lastLookupSentence] 异步刷新。视频句子收藏走与书内同一
  /// [FavoriteSentenceRepository]（preferences JSON），来源标 [kFavoriteSentenceSourceVideo]。
  bool _currentVideoSentenceIsFavorited = false;

  /// 本视频已收藏句锚点的缓存集合（驱动字幕跳转列表行内收藏星标的实心/空心，TODO-152
  /// 子A）。同步查询需要（[VideoSubtitleJumpPanel.isCueFavorited] 每次重建调用），故缓存
  /// 而非每行异步查 DB。打开列表面板时 [_refreshFavoritedCueCache] 从 repo 拉一次，
  /// 行内收藏 toggle 后增量更新。新条目按 `bookUid + cue.startMs` 匹配；旧条目没有
  /// startMs 时保留 text-only 兼容键。
  final Set<String> _favoritedVideoSentences = <String>{};

  // ── DictionaryPageMixin 必需的抽象成员 ──────────────────────────────
  @override
  AppModel get mixinAppModel => appModel;

  @override
  ThemeData get mixinTheme => Theme.of(context);

  // 视频页的收藏/制卡计入视频统计（而非书籍统计）。
  @override
  String get dictionarySourceType => kStatSourceVideo;

  /// TODO-1204：查词 / 制卡计数归属本视频——[title] 用 [_title]（剧集标题，与
  /// 视频统计 tile 的身份分组键对齐），[bookKey] 存
  /// [VideoFushiPage.bookUid]。远端视频无观看统计 tile，其计数仍进「查词」汇总。
  @override
  ({String? bookKey, String? title})? get lookupBookIdentity =>
      (bookKey: widget.bookUid, title: _title ?? '');

  /// 多集播放列表的兄弟集（单视频/独立打开时为空）。统一合集 Phase 3：本地从 playlist
  /// 合集成员建、远端从 host episodes 建；只作面板/上下集/连播上下文，播放本身每集是独立
  /// 单视频（本地 pushReplacement 换集，widget.bookUid 恒为当前集）。
  List<_PlaylistEpisodeRef> _episodes = const <_PlaylistEpisodeRef>[];

  /// 播放中合集的附加图组（v68）：剧集面板封面回退链的合集段（本集无封面 →
  /// titleCard → backdrop）。仅本地合集连播路径填充；单视频/远端恒空。
  List<MediaImageRow> _playlistCollectionImages = const <MediaImageRow>[];

  /// 当前集索引（[_episodes] 下标）；单视频恒 0。
  int _currentEpisode = 0;

  bool _autoAdvanceInFlight = false;
  String? _lastPrewarmedEpisodePath;

  /// 音量控件显示真相源（0..100，静音时为 0）（TODO-377 / TODO-438）。
  ///
  /// 底栏音量控件在 TODO-438 后只保留固定尺寸图标锚点（[_buildVolumeButton]），hover /
  /// click / tap 打开锚定按钮上方的紧凑浮层。底栏本身不内联滑条、不随 hover 改宽，仍保持
  /// 零布局位移。
  ///
  /// [VideoPlayerController.setVolume] 不发 [ChangeNotifier] 通知，控制条也不监听
  /// controller 的音量变化重建，故用本 notifier 作显示真相源：所有改音量入口（滑条拖动 /
  /// 滚轮 / 键盘音量键 / 静音切换 / media_kit 移动端竖滑）统一经 [_syncVolumeDisplay]
  /// 写它，[ValueListenableBuilder] 只重建音量图标 / 浮层子树，不重建整条。
  final ValueNotifier<double> _volumeDisplay = ValueNotifier<double>(100);

  /// 当前 video book 的可听音量记忆（0..100）。播放列表按整张 video book 共享；
  /// 每集仍只独立保存播放进度。
  double _playbackVolume = 100.0;
  double? _pendingVolumePersist;
  Timer? _volumePersistDebounce;
  double? _pendingSpeedPersist;
  Timer? _speedPersistDebounce;

  /// 换集加载代际计数：每次 [_loadRemoteEpisode] 自增并捕获本次序号；其慢路径（ffmpeg
  /// 枚举字幕源 + 解析 cue）跑完后若序号已被后续切集取代，则放弃应用，避免「播放中
  /// 途快速切集时旧的慢加载落地后覆盖新集字幕/视频」（用户报：切到第4集字幕/音画
  /// 对不上，疑似中途切换；本机不可复现，加此守卫兜底竞态）。
  int _episodeLoadSeq = 0;

  /// 当前播放的视频文件绝对路径（枚举字幕源用）；未 load 时为 null。
  String? _currentVideoPath;

  /// 视频内嵌字体加载器（对齐 mpv attachment 字体）：开视频时抽 MKV 内嵌字体附件注册进
  /// 引擎，字幕 overlay 按 ASS `Fontname` 命中真实字体。内部按视频路径缓存 + 进程级 family
  /// 去重，故可反复调（换集/重开）。见 [_maybeLoadEmbeddedSubtitleFonts]。
  final SubtitleEmbeddedFontLoader _embeddedFontLoader =
      SubtitleEmbeddedFontLoader();

  /// 远端模式（[_isRemote]）下 host 下发并下载到本地临时文件的那条外挂字幕路径；
  /// 无 host 字幕时为 null。远端没有本地视频文件，字幕菜单不能走 [_currentVideoPath]
  /// 的同目录枚举（恒 null → 早返回 → 点了没反应，#2），故单独记下这条 host 字幕，
  /// 让远端字幕菜单可在「关闭 / host 字幕 / 本地导入」三者间切换。
  String? _remoteSubtitlePath;
  List<RemoteVideoEmbeddedSubtitleTrack> _remoteEmbeddedSubtitleTracks =
      const <RemoteVideoEmbeddedSubtitleTrack>[];

  /// TODO-1307 字幕后置：用户在「字幕后置异步解析」间隙是否已显式关闭字幕
  /// （[_clearRemoteSubtitle]）。为真时 [_resolveDeferredYoutubeCaptions] 只回填 cue 供菜单
  /// 重选、不自动抢占应用（尊重用户选择）。每次 [_loadRemoteEpisode] 起播时重置为 false。
  bool _remoteSubtitleUserDismissed = false;

  /// 当前选中的字幕源持久化值（外挂路径 / `embedded:<n>` / `off:`=用户显式关闭哨兵
  /// （[SubtitleSource.offSentinel]，TODO-818） / null=无偏好或远端清字幕）；用于字幕
  /// 源菜单高亮当前项。
  String? _currentSubtitleSource;

  /// 当前选中的副字幕源持久化值（TODO-857 / TODO-1312 视频双字幕）：与
  /// [_currentSubtitleSource] 同款四态编码（外挂路径 / `embedded:<n>` / `off:` /
  /// null）。TODO-1312 起副字幕改走 Flutter overlay 副层 cue 流（[VideoPlayerController.
  /// setSecondaryCues]，可逐字符查词），不再 libmpv `secondary-sid` 自渲染；持久化格式
  /// 沿用不变。恢复仅支持内嵌轨。用于副字幕源菜单高亮当前项。
  String? _currentSecondarySubtitleSource;

  /// 当前选中的音轨 id（libmpv `AudioTrack.id`）；null=未选过跟随默认。
  /// 多集换集时复用同一值（用户选了日语音轨，每集都用日语）。
  String? _currentAudioTrackId;

  /// HLS 画质（TODO-1158）：当前视频若是 HLS master playlist（m3u8 直链，含多档码率
  /// variant），[_hlsMasterUri] 记 master URL、[_hlsVariants] 是解析出的档位（高到低
  /// 排序）、[_selectedHlsVariantIndex] 是当前选中档（-1=自动/master ABR）。非 HLS /
  /// media playlist 时三者为空态（无画质菜单）。切档走 [_switchHlsVariant]（换 variant
  /// URL 重载，保持播放位置）。[_hlsDetectSeq] 是异步探测去重位（换片时旧探测结果丢弃）。
  String? _hlsMasterUri;
  List<HlsVariant> _hlsVariants = const <HlsVariant>[];
  int _selectedHlsVariantIndex = -1;
  int _hlsDetectSeq = 0;

  /// YouTube 画质档（用户报「YouTube 没法调画质」）：与 HLS 画质并行的一套状态，**懒解析**
  /// ——用户点开画质菜单时才 [resolveYoutubeVideoVariants]（一次 getManifest）填 [_youtubeVariants]
  /// （各档 video-only 流，高→低）。[_selectedYoutubeVariantIndex] 当前选中档（-1=自动=解析器
  /// 默认最佳）；[_youtubeVariantsAudioUrl] 分离音轨（切档保持同一音频）；[_youtubeVariantsLoading]
  /// 解析中（画质侧栏显 spinner）。切档走 [_switchYoutubeVariant]（换 video-only URL + 同音轨重载，
  /// 保持播放位置 + 现有字幕 cue）。非 YouTube 时恒空。
  List<YoutubeVideoVariant> _youtubeVariants = const <YoutubeVideoVariant>[];
  int _selectedYoutubeVariantIndex = -1;

  /// 「自动」档对应的 [_youtubeVariants] 下标（= 解析器默认最佳挑选，avc1≤1080p）。用户选
  /// 「自动」时切到这条 URL；-1=尚未解析。
  int _youtubeVariantsDefaultIndex = -1;
  String? _youtubeVariantsAudioUrl;
  bool _youtubeVariantsLoading = false;

  /// 本集是否已解析过画质档（含「解析成功但无分离流→空档」）。用作「已解析空档」哨兵，
  /// 避免 muxed-only 视频每次点开画质菜单都重复 getManifest。每集起播复位。
  bool _youtubeVariantsResolved = false;

  bool _clipExportMarking = false;
  bool _clipExporting = false;
  int? _clipExportStartMs;
  String? _clipExportStartPath;
  int? _clipExportStartAudioStreamIndex;
  // 标记起点时快照的真实音轨条数，作 ffmpeg `-map 0:a:N` 的下标上界（BUG-345）。
  int? _clipExportStartAudioStreamCount;
  int _clipExportGeneration = 0;

  /// 音画延迟（毫秒）：字幕 cue 同步偏移，跨重启保留；换集复用同一值。
  int _delayMs = 0;

  /// 副字幕独立调轴（毫秒，TODO-2837 主副字幕分开调轴）：null = 未单独设置 =
  /// 跟随 [_delayMs]（v86 前「主副共用一个 offset」行为）；非 null = 副轨独立偏移
  /// （主副字幕轴不同源时各调各的）。两层持久化镜像 [_delayMs]（per-book
  /// `VideoBooks.secondaryDelayMs` + 合集级 `MediaCollections.secondarySubtitleDelayMs`），
  /// 换集复用同一值。远端播放恒 null（host 不下发副轨偏移，副字幕也不参与远端流）。
  int? _secondaryDelayMs;

  /// 播放倍速：用户在设置面板调，跨重启保留；换集复用同一值（速度记忆）。
  double _playbackSpeed = 1.0;
  double? _longPressPreviousSpeed;

  /// 长按拖动调速的基准速（长按起点的固定加速速，TODO-338）。非空表示正处于一次长按
  /// 调速手势中；横向拖动以此为基准连续加减，松手清空。
  double? _longPressDragBaseSpeed;

  /// 键盘按住/手柄翻转的临时倍速是否进行中（用户请求：与手机长按画面同语义）。
  /// 与手势长按共用 [_longPressPreviousSpeed] 恢复位，此标志区分恢复权归属：
  /// true 时恢复只走 [_releaseHoldSpeed]，手势松手不越权恢复。
  bool _holdSpeedActive = false;

  /// 键盘按住临时倍速的触发键（非空 = 正按住中）。keyup/repeat 只按此键识别、
  /// 不看修饰键，按住期间先松修饰键也不会把倍速卡在加速态。
  LogicalKeyboardKey? _holdSpeedTriggerKey;

  /// TODO-1154：长按倍速指示徽章的跟随锚点（局部坐标，即 GestureDetector/Stack 同一坐标系
  /// 的 `details.localPosition`）+ 当前速度。非空时在指针上方渲染「Nx」徽章跟手移动
  /// （B 站/YouTube 长按倍速气泡观感），松手清空。**不**复用钉死左上角的 [_showOsd]。
  final ValueNotifier<({Offset position, double speed})?> _longPressSpeedBadge =
      ValueNotifier<({Offset position, double speed})?>(null);

  /// 当前字幕外观（全局偏好快照；设置面板改动后刷新）。
  VideoSubtitleStyle _subtitleStyle = VideoSubtitleStyle.defaults;

  /// 「拖拽调整字幕位置」模式开关（TODO-2838）：设置面板入口进入、画面顶部横幅
  /// 「完成」退出。开启时字幕 overlay 让出查词指针面、改挂竖直拖拽（见
  /// [VideoSubtitleOverlay.dragAdjustEnabled]），松手经 [_handleSubtitleDragAdjustEnd]
  /// 写回 [_subtitleStyle] 并持久化。
  bool _subtitleDragAdjustActive = false;
  VideoAsbplayerConfig _asbConfig = VideoAsbplayerConfig.defaults;

  /// Live 9-slot control button layout (TODO-274/312 phase 2). This is loaded
  /// from / saved to [AppModel.videoControlLayout], which shares the legacy pref
  /// key and auto-migrates old v1 blobs via [VideoControlLayout.decode]. The
  /// getter reads [_controlLayoutNotifier] so the current controls builder can
  /// rebuild immediately after [_setVideoControlLayout].
  VideoControlLayout get _controlLayout => _controlLayoutNotifier.value;

  /// 桌面端是否把原生窗口锁定为当前视频比例。移动端窗口不可改尺寸。
  /// 初始 false 与偏好默认对齐（回归修复）：偏好快照在 init 赋值前不主动锁窗口，
  /// 消除「赋值前 stale true 抢锁」的瞬态窗口。
  bool _lockWindowAspectRatio = false;
  double? _appliedWindowAspectRatio;

  /// 画面缩放/比例模式（窗口 + 全屏 [Video] fit 共用；TODO-152 子B）。新安装默认
  /// contain/适应；init 时读全局偏好快照，已有用户偏好 cover/fill 会按原值恢复，
  /// 设置面板改动经 [_setVideoFitMode] 落盘 + setState 重建 Video。
  VideoFitMode _videoFitMode = VideoFitMode.contain;

  /// Windows HDR 直通 / 10-bit 输出模式（`video_hdr_output.dart`），init 时从
  /// AppModel 读入，随控制器创建下发；改设置经 [_setVideoHdrOutputMode]。
  VideoHdrOutputMode _videoHdrOutputMode = VideoHdrOutputMode.auto;

  bool get _isPlaylist => _episodes.length > 1;

  /// 收藏/制卡是否按集区分：本地每集是独立 VideoBooks 行（bookKey 已唯一定位集，单视频
  /// 语义）→ false；远端多集是 host 单 id → 需按 episodeIndex 区分 → true（统一合集 Phase 3）。
  bool get _favoriteIsPlaylist => _isRemote && _episodes.length > 1;

  /// 收藏/制卡的集下标锚点：[_favoriteIsPlaylist] 时为当前集，否则 null（单视频语义）。
  int? get _favoriteSectionIndex =>
      _favoriteIsPlaylist ? _currentEpisode : null;

  /// 缓存的 [AppModel] 引用。`appProvider` 是单例（实例不变），在 [initState] 一次
  /// 性读取并缓存。**不能**每次 `ref.read(appProvider)`：浮层层（[buildNestedPopupLayer]）
  /// 在 `LayoutBuilder` 回调里访问 `mixinAppModel`，而 widget 失活（deactivated）后
  /// `ref.read` 会抛「Looking up a deactivated widget's ancestor is unsafe」。缓存实例
  /// 后即使 widget 已失活也安全（BUG: 视频查词关页时崩溃）。
  late final AppModel _appModel = ref.read(appProvider);

  AppModel get appModel => _appModel;

  /// TODO-1157：书架里「粘贴 URL 导入」的流媒体书（[isStreamVideoBook]）在 [_init] 里
  /// 按 videoPath/streamSpecJson 重建的播放客户端 + info。非流媒体书 / LAN 远端书恒 null。
  /// 让流媒体书像本地视频一样从书架点开，却复用与「导入即播」完全一致的远端播放路径
  /// （prefs 断点、无本地文件），行为与旧临时流播放一致（Never break userspace）。
  RemoteVideoInfo? _resolvedStreamInfo;
  UrlStreamVideoClient? _resolvedStreamClient;

  /// 客户端互联视频合集播放：有序远端合集成员（来自 widget.remoteCollectionMembers）。
  /// `length > 1` = 合集连播模式；单视频 / host-playlist 恒空。
  List<RemoteVideoInfo> _remoteMembers = const <RemoteVideoInfo>[];

  /// 合集连播模式下的「当前成员」（可变）：换成员时更新，使 [_effectiveRemoteInfo] /
  /// 断点键 / 字幕键 / host 上报天然跟到新成员 id。非合集模式为 null（回落 widget.remoteInfo）。
  RemoteVideoInfo? _activeRemoteMember;

  /// 是否处于客户端合集连播模式（成员是各自独立 video id）。
  bool get _isRemoteCollection => _remoteMembers.length > 1;

  /// 有效远端 info/client：合集连播优先返回当前成员 [_activeRemoteMember]（换成员即跟随）；
  /// 否则 LAN 远端书用构造器传入的 widget.remote*，书架流媒体书用 [_init] 重建的
  /// _resolvedStream*。二者互斥、至多一个非空。
  RemoteVideoInfo? get _effectiveRemoteInfo =>
      _activeRemoteMember ?? widget.remoteInfo ?? _resolvedStreamInfo;
  RemoteVideoClient? get _effectiveRemoteClient =>
      widget.remoteClient ?? _resolvedStreamClient;

  bool get _isRemote => _effectiveRemoteInfo != null;

  /// 远端断点 / 字幕 prefs 键 `(uid, episodeIndex)`。**合集连播模式**：每个成员是独立视频
  /// id，键 = `(成员 id, 0)`，天然按成员隔离，且与 host 按成员带回的 positionMs 对齐；
  /// **host-playlist / 单视频模式**：`(widget.bookUid, index)`（旧行为，index==0 时兼容旧单
  /// 视频 prefs）。[index] 是目标集下标（读某集断点时传目标；写当前集传 [_currentEpisode]）。
  (String uid, int episodeIndex) _remotePositionKeyForIndex(int index) {
    if (_isRemoteCollection) {
      final int i = index.clamp(0, _remoteMembers.length - 1);
      return (_remoteMembers[i].id, 0);
    }
    return (widget.bookUid, index);
  }

  /// app 当前目标学习语言代码（如 `'ja'`/`'ko'`），用于 sidecar 字幕语言优先检测。
  String get _targetLangCode => JapaneseLanguage.instance.locale.languageCode;

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      WindowsImeSpaceChannel.setHandler(this, _handleWindowsImeSpaceDown);
    }
    // 不在 initState 读 appModel.lowMemoryMode（它读 prefsRepo，未初始化会抛；
    // 错误态 smoke 用未初始化 AppModel）。先建空 controller，真实 lowMemory 留到
    // _seedWarmPopup（成功路径、必已初始化）再设——与 base_source_page 同范式。
    _popup = DictionaryPopupController(
      lowMemory: false,
      onLookupStackDepthChanged: recordLookupStackDepth,
    );
    // TODO-1204：接线查词计数（视频来源，带 bookUid + 剧集标题）。
    attachLookupCounter(_popup);
    _subtitleListVisible.value = widget.initialSubtitleListVisible;
    // BUG-2043：从全屏页换集而来 → 认领旧页留下的原生全屏（见 fullscreen.part.dart）。
    _claimHandedOverNativeFullscreen();
    // TODO-364 单一真相源：字幕避让可见性恒由 media_kit 真实可见性
    // （[_mediaKitControlsVisible]）+ 三个门控派生。订阅这四个输入，任一变化即重派生
    // [_videoControlsVisible]，杜绝旧镜像与真实控制条相位反。
    _mediaKitControlsVisible.addListener(_applyControlsVisibilityFromMediaKit);
    _immersiveLocked.addListener(_applyControlsVisibilityFromMediaKit);
    _videoSidePanel.addListener(_applyControlsVisibilityFromMediaKit);
    _videoControlPopover.addListener(_applyControlsVisibilityFromMediaKit);
    _subtitleListVisible.addListener(_applyControlsVisibilityFromMediaKit);
    _episodeListVisible.addListener(_applyControlsVisibilityFromMediaKit);
    _videoControlEditMode.addListener(_applyControlsVisibilityFromMediaKit);
    // BUG-1798：查词浮层也是 [_hasVideoOverlay] 的输入，与上面六个门控同等订阅——否则弹窗
    // 打开 / 关闭时光标策略不重跑，鼠标悬在弹窗上仍被上一轮的 `cursor: none` 吃掉。
    _lookupOverlayActive.addListener(_applyControlsVisibilityFromMediaKit);
    // TODO-611：侧栏面板锁定不持久化。面板一关闭就把锁复位为 false，下次重开默认未锁
    // ——锁生命周期绑定可见性，关闭路径无需逐个复位。
    WidgetsBinding.instance.addObserver(this);
    _exitFlushCallback = ExitFlushRegistry.instance.register(
      _flushAllForProcessExit,
    );
    // TODO-057: 进入视频即快照系统屏幕亮度（移动端），供亮度手势初值与退出还原；
    // 桌面 no-op。
    unawaited(_ensureEnterBrightness());
    // BUG-2105：先登记「本页持有进程级显示态」（横屏锁 / 系统栏回调 / macOS 交通灯），
    // 再去设这三件。换集的窗口模式分支用 `pushReplacement`，旧页 dispose 晚于本页
    // initState —— 登记表让旧页释放时看到「还有人持有」而不还原，否则新页刚设好的
    // 横屏锁被放宽成含竖屏（旋转锁定下当即翻竖屏 = 掉出全屏）、刚注册的系统栏回调被
    // 置空。见 [VideoDisplayClaim] 与 [_releaseVideoDisplayClaim]。
    VideoDisplayClaim.claim(this);
    // TODO-099: 进入视频页强制横屏（移动端），退出 [dispose] 还原；桌面 no-op。
    unawaited(_lockLandscapeForVideo());
    // BUG-973: 进入视频页隐藏 macOS 系统交通灯（左上角三个圆点），退出 [dispose] 恢复。
    // 交通灯浮在透明标题栏 + 全尺寸内容视图之上，会遮住视频顶栏返回按钮 / 左上角 OSD
    // 提示（用户报告）。仅 macOS 有交通灯；Windows / Linux / 移动端恒 no-op。用户仍可
    // Esc / 顶栏返回按钮 / Cmd+Q / 进原生全屏退出，不损失退出口。
    unawaited(setMacOSTrafficLightsHidden(true));
    // TODO-158/BUG-219: 进入视频页显式持有「沉浸隐藏系统栏」所有权（移动端）。原先
    // 只靠 [AppModel.openMedia] 在打开媒体时一次性设 immersiveSticky（书 / 视频共用
    // 入口），从不重申 → 后台返回 / 通知栏交互 / 全屏路由后系统栏残留。退出由
    // [AppModel.closeMedia] 的 setHomeShellSystemUiMode 还原；桌面 no-op。
    unawaited(_applyVideoImmersiveMode());
    // TODO-658/BUG-383: 监听系统栏真实可见性，喂 [_videoBottomSystemInset] 的门控
    // （隐栏归零、可见才避让），根治手势导航下进度条被恒非零 viewPadding 顶高。
    _registerSystemBarsVisibilityCallback();
    _init();
  }

  /// app 进后台（[AppLifecycleState.inactive]/`.paused`/`.hidden`）时把当前播放
  /// 位置 **await 落库**：dispose 在硬杀进程时不会跑，周期保存是 fire-and-forget
  /// 且后台定时器会挂起。趁 controller 仍存活把退出瞬间位置写穿（对齐阅读器
  /// `_syncAndFlushPosition`）。
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
        // inactive 仅瞬态过渡（通知栏下拉 / 多任务切换）：落库即可，不停观看计时
        // （频繁误停丢真实时长）；clamp（[isContinuousWatchGap]）兜底任何残留异常间隔。
        unawaited(_controller?.flushPosition());
        unawaited(_flushPersistedVideoSpeed());
        unawaited(_flushPersistedVideoVolume());
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        // 真后台 / 熄屏：落库 + 暂停观看计时器，避免把后台时长计入。stop() 内部先 flush
        // 退出瞬间的部分窗口（≤60s）再 cancel，不丢已观看时长。
        unawaited(_controller?.flushPosition());
        unawaited(_flushPersistedVideoSpeed());
        unawaited(_flushPersistedVideoVolume());
        _watchTracker?.stop();
        // BUG-1863：记下「真的进过后台」。移动端在 app 不可见期间可能被系统回收硬件
        // 解码器，回来后解码从非关键帧继续、参考帧缺失 → 静止区域被 libavcodec 的
        // error concealment 填成中性灰。`inactive` 不置这个标记（那期间 app 仍持有
        // 解码器，白白刷新只是给用户一次无谓卡顿）。
        _enteredRealBackground = true;
      case AppLifecycleState.resumed:
        // 回前台：重启观看计时器（start() 重置 _tickStart=now，下一窗从此刻起算）。
        _watchTracker?.start();
        // BUG-1863：从真后台回来先把视频解码链重建一次（详见
        // [VideoPlayerController.shouldRefreshDecodeOnResume] 的判据与机制说明）。
        _refreshDecodeAfterResumeIfNeeded();
        // TODO-158/BUG-219: 回前台重申沉浸隐藏系统栏（移动端）。后台 / 通知栏下拉 /
        // 多任务切回后 Android 会把系统栏恢复显示，immersiveSticky 只在进入时设一次
        // 不会自动复申 → 这里主动重设，保证「一直隐藏」。桌面 no-op。
        unawaited(_applyVideoImmersiveMode());
        // 切窗 / 系统对话框返回（TODO-040 ①）：窗口重新激活时若键盘所有权仍属
        // 本页（页面或其全屏路由是当前路由、无查词浮层），把焦点收回视频——
        // OS 层焦点丢失后 Flutter 不保证归还到原节点。
        _focusOwnership.reclaim(FocusReclaimCause.appResumed);
      case AppLifecycleState.detached:
        break;
    }
  }

  /// BUG-1863：从真后台回前台后重建一次视频解码链（消除「静止的地方变成灰色」）。
  ///
  /// **每一次真后台返回都刷，不是「检测到灰了才刷」**——解码器被系统回收没有可读信号，
  /// 判据 [VideoPlayerController.shouldRefreshDecodeOnResume] 只排除「刷了没用 / 刷了
  /// 有害」的场合，不判断「这次是否真的需要」。取舍与代价见该判据的文档。
  ///
  /// 标记**无条件**清掉，判据不成立只是这一轮不刷新，不能让它攒到下一次 resume 才放
  /// （那会变成「某次切窗后莫名 seek 一下」）。刷新本身 fire-and-forget：它只是把播放
  /// 头 seek 回原地，失败（player 已释放 / 流不可 seek）也没有需要回滚的状态。
  void _refreshDecodeAfterResumeIfNeeded() {
    final bool wasBackgrounded = _enteredRealBackground;
    _enteredRealBackground = false;
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    final int? durationMs = controller.durationMs;
    if (!VideoPlayerController.shouldRefreshDecodeOnResume(
      enteredRealBackground: wasBackgrounded,
      hasVideo: controller.hasFirstFrame,
      seekable: durationMs != null && durationMs > 0,
    )) {
      return;
    }
    unawaited(controller.refreshDecodeAfterResume());
  }

  /// 进程退出统一 flush（TODO-086/BUG-191）。把当前播放位置写穿（[flushPosition]
  /// 读 libmpv position，退出期 player 仍存活，安全），并 stop 观看计时器把退出
  /// 瞬间的部分观看窗口落库。两步都 await，退出路径据此保证统计/进度在 exit(0)
  /// 前提交。未 load（无 controller / tracker）时 no-op 安全。
  Future<void> _flushAllForProcessExit() async {
    await _flushPersistedVideoSpeed();
    await _flushPersistedVideoVolume();
    await _controller?.flushPosition();
    await _watchTracker?.stop();
  }

  /// TODO-1063: 解析并应用绑定到视频（媒体类型 'video'）的 profile。
  /// 优先 per-book（[widget.bookUid]）绑定，其次媒体类型级 'video' 绑定，
  /// 都无则维持当前活跃 profile。镜像 [_ReaderAudiobook._resolveAndApplyProfile]
  /// 的非致命范式：失败只记日志、不打断视频加载。
  Future<void> _resolveAndApplyVideoProfile() =>
      ref.read(profileViewModelProvider.notifier).autoApplyBinding(
            bookUid: widget.bookUid,
            mediaType: ProfileMediaKind.video,
          );

  /// TODO-1213：切换加载阶段并刷新加载态 UI（mounted 守卫）。离开「下载字幕」阶段时
  /// 一并清字幕进度（其它阶段无确定性进度，转 indeterminate）。
  void _setLoadingPhase(_VideoLoadPhase phase) {
    if (!mounted) return;
    setState(() {
      _loadingPhase = phase;
      if (phase != _VideoLoadPhase.downloadingSubtitle) {
        _subtitleProgress = null;
      }
    });
  }

  /// TODO-1276/1297：首开时武装「就绪即挂载 [Video]」的监听 + 兜底定时器。
  ///
  /// [controller] 在宽高流（首帧解码出画）或缓冲流翻转时 [notifyListeners]，
  /// [_promoteVideoReadyOnFirstFrame] 据此重评 [isReadyForFirstPaint]（首帧已出画且
  /// 缓冲结束），就绪后把 [_videoReadyToShow] 翻真、挂载 media_kit（此刻已有帧、不缓冲
  /// → 单圈，不会接力出第二个缓冲圈）。若始终不就绪（解码异常机型 / 纯音频容器 /
  /// 缓冲久拖），[_firstFramePromoteTimer] 兜底超时仍切给 media_kit，绝不无限转圈。
  /// 幂等：重复武装先撤销旧监听/定时器。
  void _armFirstFramePromotion(VideoPlayerController controller) {
    _firstFramePromoteTimer?.cancel();
    controller.removeListener(_promoteVideoReadyOnFirstFrame);
    controller.addListener(_promoteVideoReadyOnFirstFrame);
    _firstFramePromoteTimer = Timer(
      const Duration(milliseconds: 2500),
      () => _promoteVideoReady(),
    );
  }

  /// [VideoPlayerController] 宽高流回调：首帧解码出画后即提升可见态。
  void _promoteVideoReadyOnFirstFrame() {
    if (_videoReadyToShow) return;
    // TODO-1297：就绪 = 首帧已出画**且**缓冲结束（[isReadyForFirstPaint]），而非仅
    // [hasFirstFrame]——否则解码出首帧但仍在缓冲时提前挂载 [Video]，media_kit 缓冲圈
    // 接力显示成「进度条已缓冲但还在加载」的第二个圈。
    if (_controller?.isReadyForFirstPaint ?? false) _promoteVideoReady();
  }

  /// 把 [_videoReadyToShow] 翻真（挂载 [Video]），并撤销首帧监听 + 兜底定时器。
  /// 一次性：已就绪则空转。首帧监听 / 兜底定时器 / 快路径三处都汇聚到此。
  void _promoteVideoReady() {
    if (_videoReadyToShow) return;
    _firstFramePromoteTimer?.cancel();
    _firstFramePromoteTimer = null;
    _controller?.removeListener(_promoteVideoReadyOnFirstFrame);
    if (!mounted) return;
    setState(() => _videoReadyToShow = true);
    // BUG-1266：慢路径必须在这里**补一次**焦点回收，否则本页整段时间都没有键盘所有者。
    //
    // [_videoFocusNode] 挂在 [Video] 上（`layout.part.dart`），而 [_buildScaffold] 用
    // `!_videoReadyToShow` 把首帧未就绪的首开挡在 [_buildLoadingBody] 分支——此刻
    // [Video] 尚未挂载，节点还没 attach 到焦点树。`_openVideo` 结尾那次
    // `reclaimAfterFrame(contentReady)` 正好落在这个窗口里，对孤儿节点
    // `requestFocus()` 是**静默 no-op**（请求直接丢失，无任何报错）。等这里把
    // [Video] 挂上、节点终于 attach 时，却没有人再请求一次焦点，于是焦点滞留在
    // 页面之外：手柄按键不冒泡经过 [_wrapVideoGamepadControls]，本页所有手柄绑定
    // （上一句/下一句/播放暂停…）全部失灵，直到用户随便点一下画面触发
    // [FocusReclaimCause.gesture] 才恢复——正是用户报的「必须先按一下暂停才能
    // 正常上下句」。更糟的是这段窗口里手柄 B 没人消费，会被 Android 合成成 BACK
    // 直接退页（见 [_swallowUnboundGamepadBack]）。
    //
    // 快路径（load 返回即出画）不进本方法，其 contentReady 那次回收时 [Video] 已挂载、
    // 本就有效，行为不变。
    _focusOwnership.reclaimAfterFrame(FocusReclaimCause.contentReady);
    // BUG-839：慢路径就绪后触发「换集保持全屏」的重进全屏（仅 initialFullscreen 新页生效）。
    _scheduleInitialFullscreenIfNeeded();
  }

  Future<void> _init() async {
    // TODO-1063: 视频毕业为常驻媒体类型后，配置方案的「媒体类型绑定」也支持
    // 绑定 profile 到 'video'。打开视频即解析并应用绑定的 profile（与阅读器
    // /有声书同构），使看视频时的查词浮层 / 制卡按绑定 profile 生效。与视频
    // 加载并行、失败非致命（unawaited + 内部 try/catch）。
    unawaited(_resolveAndApplyVideoProfile());
    if (_isRemote) {
      await _initRemote();
      return;
    }
    final VideoBookRow? row = await widget.repo.getByBookUid(widget.bookUid);
    if (row == null) {
      if (mounted) {
        setState(() {
          _failed = true;
          _failReason = t.video_load_failed_not_found;
        });
      }
      return;
    }
    _bookRow = row;

    // TODO-1157：书架里「粘贴 URL 导入」的流媒体书（videoPath 是 http/https）不走本地
    // 文件加载路径，而是按 videoPath/streamSpecJson 重建流客户端，复用与「导入即播」一致
    // 的远端播放路径（_initRemote）。YouTube 会在 buildStreamVideoLaunch 里重解析（临时流
    // URL 会过期）；重建失败按打开失败处理。放在读 row 后、本地字幕/进度恢复前短路。
    if (isStreamVideoBook(row)) {
      // 网页视频站（Netflix / YouTube 页 / TVer……）在 Windows 上交给内置网页播放器：
      // 站点自己的播放器播，Fushi 复用字幕面板 / 查词 / 进度登记。在这里分流而非各
      // push 点：书架 / 首页 / 合集 / 作品页 / app 外打开 8 处入口全部自动覆盖。
      // media_kit controller 尚未 load，pushReplacement 代价只是本页一次空 build。
      if (shouldOpenInWebVideoPlayer(row.videoPath)) {
        final BuildContext pageContext = context;
        if (!pageContext.mounted) return;
        unawaited(Navigator.of(pageContext).pushReplacement(
          adaptivePageRoute<void>(
            context: pageContext,
            builder: (_) => WebVideoFushiPage.neutralized(
              bookUid: widget.bookUid,
              repo: widget.repo,
            ),
          ),
        ));
        return;
      }
      // TODO-1307：把「正在连接视频流…」阶段反馈提前到 buildStreamVideoLaunch（YouTube 快
      // 解析 getManifest 有网络往返、慢网仍可数秒）之前，避免解析期页面裸转圈「点了没动静」。
      _setLoadingPhase(_VideoLoadPhase.connecting);
      try {
        // 来源库网络视频（WebDAV）：认证头按 sourceId 现解析（凭据不落行级
        // spec——改来源密码一处生效）；非来源书解析为空 map，零分支。
        // targetUrl 传本行真实流地址：来源根下的 m3u8 清单可以指向第三方主机，
        // 那些行同样带本来源的 sourceId，不按目标地址收口就会把 NAS 账号密码
        // 发给第三方（见 source_library/stream_auth_scope.dart）。
        final Map<String, String> sourceHeaders =
            await resolveSourceStreamHeaders(
          db: appModel.database,
          sourceId: row.sourceId,
          targetUrl: row.videoPath,
        );
        final ({UrlStreamVideoClient client, RemoteVideoInfo info}) launch =
            await buildStreamVideoLaunch(row,
                youtubeTargetHeight: appModel.youtubeQualityTargetHeightOrNull,
                sourceHttpHeaders: sourceHeaders);
        if (!mounted) return;
        _resolvedStreamInfo = launch.info;
        _resolvedStreamClient = launch.client;
      } catch (e) {
        debugPrint('[VideoFushiPage] stream book launch build failed: $e');
        if (mounted) {
          setState(() {
            _failed = true;
            _failReason = _describeLoadFailure(e);
          });
        }
        return;
      }
      await _initRemote();
      return;
    }

    // 记录持久化的字幕源（菜单高亮当前项用）+ 音轨偏好（换集复用）+ 音画延迟
    // （跨重启保留）+ 播放倍速（per-book 偏好，速度记忆）。
    _currentSubtitleSource = row.subtitleSource;
    _currentSecondarySubtitleSource = row.secondarySubtitleSource;
    _currentAudioTrackId = row.audioTrackId;
    _delayMs = row.delayMs;
    // TODO-2837：副字幕独立调轴（null = 跟随主字幕）。
    _secondaryDelayMs = row.secondaryDelayMs;
    _playbackSpeed = _readPersistedSpeed();
    _playbackVolume = _readPersistedVolume();
    _subtitleStyle = VideoSubtitleStyle.decode(appModel.videoSubtitleStyle);
    _asbConfig = VideoAsbplayerConfig.decode(appModel.videoAsbplayerConfig);
    _controlLayoutNotifier.value = appModel.videoControlLayout;
    _customActionBindingsNotifier.value = appModel.videoCustomActionBindings;
    _lockWindowAspectRatio = appModel.videoLockWindowAspectRatio;
    _videoFitMode = appModel.videoFitMode;
    _videoHdrOutputMode = appModel.videoHdrOutputMode;

    // 统一合集 Phase 3：本集若作为某 playlist 合集的一集打开（widget.playlistCollectionId
    // 非空），从合集成员建兄弟集列表（剧集面板 / 上下集 / 连播上下文）。每集是独立
    // VideoBooks 行，当前集照单视频路径加载（widget.bookUid 恒为当前集）。
    final int? collectionId = widget.playlistCollectionId;
    if (collectionId != null) {
      final MediaCollectionRow? col =
          await widget.repo.getMediaCollectionById(collectionId);
      // 同系列音轨/调轴记忆（schema v52）：系列（合集）级偏好优先，回退本集 per-book
      // 值（兼容统一合集迁移前已存的各集值，Never break userspace）。合集内任一集
      // 选音轨/调轴即写系列级，其余集加载时（含从书架直接进某集）共享同一值 —— 恢复
      // 统一合集迁移前「多集共享一行 → 整片一个音轨/一个调轴」的行为。
      _currentAudioTrackId =
          effectiveSeriesAudioTrackId(col?.audioTrackId, row.audioTrackId);
      _delayMs = effectiveSeriesDelayMs(col?.subtitleDelayMs, row.delayMs);
      // TODO-2837：副轨调轴同款系列级优先（两层都 null = 跟随主字幕）。
      _secondaryDelayMs = effectiveSeriesSecondaryDelayMs(
          col?.secondarySubtitleDelayMs, row.secondaryDelayMs);
      final List<MediaCollectionItemRow> members =
          await widget.repo.getCollectionItems(collectionId);
      // v68 Jellyfin 对齐：剧集面板要 ①集级刮削集名 ②合集横图回退链 ③看完/在看
      // 角标。作品名作集名判据（集名缺失时集级刮削会把作品名回填进 title，那不是
      // 集名——与合集详情页 `_scrapedEpisodeTitle` 同判据）。
      final CollectionScrapeMetaRow? colMeta =
          await widget.repo.collectionScrapeMeta(collectionId);
      _playlistCollectionImages =
          await widget.repo.collectionMediaImages(collectionId);
      final String? workTitle = colMeta?.title.trim();
      final List<_PlaylistEpisodeRef> refs = <_PlaylistEpisodeRef>[];
      for (final MediaCollectionItemRow m in members) {
        if (m.mediaType != MediaKind.video.dbValue) continue;
        final VideoBookRow? er = await widget.repo.getByBookUid(m.entryKey);
        if (er == null) continue; // 孤儿成员（集行已删）→ 读取期过滤。
        String? scrapedName;
        final VideoScrapeMetaRow? em =
            await widget.repo.episodeScrapeMeta(er.bookUid);
        if (em != null && em.episodeNumber != null) {
          final String t = em.title.trim();
          if (t.isNotEmpty && t != workTitle) scrapedName = t;
        }
        refs.add(_PlaylistEpisodeRef(
          bookUid: er.bookUid,
          title: er.title,
          displayTitle: scrapedName,
          path: er.videoPath,
          coverPath: er.coverPath,
          completed: er.completedAt != null,
          started: er.lastPositionMs > 0,
        ));
      }
      _episodes = refs;
      final int idx = refs
          .indexWhere((_PlaylistEpisodeRef e) => e.bookUid == widget.bookUid);
      _currentEpisode = idx >= 0 ? idx : 0;
      if (refs.length > 1) {
        // TODO-761（方案 B）：记系列名（合集名），制卡 documentTitle 据此拼「系列名 - 剧集名」。
        _playlistTitle = col?.name;
      }
    }

    // 当前集照单视频加载（每集是独立 VideoBooks 行；_loadSingle 已尊重
    // widget.initialCueStartMs 与该行 lastPositionMs 续播）。
    await _loadSingle(row);
  }

  Future<void> _initRemote() async {
    // 客户端合集连播：有序成员列表（>1 才成合集）。起播成员 = 首页点的那个（widget.remoteInfo，
    // 其下标 = initialEpisodeIndex）。
    _remoteMembers =
        widget.remoteCollectionMembers ?? const <RemoteVideoInfo>[];
    _activeRemoteMember = null;
    final RemoteVideoInfo info = _effectiveRemoteInfo!;
    _currentSubtitleSource = null;
    _currentSecondarySubtitleSource = null;
    // 远端音轨恢复（BUG-1636 → 播放偏好同步泛化批）：本地带戳选择与 host 下发值
    // 逐字段 LWW；都无 = null 跟随 libmpv 默认轨。_applyLoad 里 _restoreAudioTrack
    // 会按它选轨。
    _currentAudioTrackId =
        _resolveRemoteInitialAudioTrackId(info, widget.bookUid);
    // BUG-996：远端播放跟随 host 下发的字幕时序偏移（此前恒 0，字幕调轴不同步）。
    // 通道已就绪——_applyLoad 里 controller.setDelayMs(_delayMs) 会应用它。
    // 互联远端调轴不持久化 bug：host 值与本地 prefs 经 LWW 取严格较新者——本机调过
    // 的轴退出重进不再被 host 的 0 覆盖。
    _delayMs = _resolveRemoteInitialDelayMs(info, widget.bookUid);
    // TODO-2837 远端副字幕支持：先置中性值，真实来源/调轴在 [_loadRemoteEpisode]
    // 按 (uid, ep) 从本地 prefs 恢复（副字幕轨是本机自选的，host 不参与同步）。
    _secondaryDelayMs = null;
    _playbackSpeed = _readPersistedSpeed();
    _playbackVolume = _readPersistedVolume();
    _subtitleStyle = VideoSubtitleStyle.decode(appModel.videoSubtitleStyle);
    _asbConfig = VideoAsbplayerConfig.decode(appModel.videoAsbplayerConfig);
    _controlLayoutNotifier.value = appModel.videoControlLayout;
    _customActionBindingsNotifier.value = appModel.videoCustomActionBindings;

    // 客户端合集连播（Phase 3 合集 = N 个独立 VideoBooks 行）：host 不把兄弟集填进
    // RemoteVideoInfo.episodes（那是旧单行 playlistJson 模型），故由 client 用合集成员列表
    // 建 _episodes，绕开 info.isPlaylist 门控。换集换的是成员 id（见 _loadRemoteEpisode）。
    if (_isRemoteCollection) {
      final int startIndex =
          (widget.initialEpisodeIndex ?? 0).clamp(0, _remoteMembers.length - 1);
      _episodes = <_PlaylistEpisodeRef>[
        for (final RemoteVideoInfo m in _remoteMembers)
          // 远端合集成员自带封面（host 下发 coverUrl + 稳定 id 作缓存键）——
          // 此前这里只取 title，剧集列表因此对远端也恒无图。
          _PlaylistEpisodeRef(
            title: m.title,
            coverUrl: m.coverUrl,
            coverCacheKey: m.id,
            // 剧集面板看完/在看角标（互联完整支持批次）：host 下发 completedAt +
            // 断点即口径，与本地集（completedAt / lastPositionMs）对齐。
            completed: m.completedAt != null,
            started: m.positionMs > 0,
          ),
      ];
      _activeRemoteMember = _remoteMembers[startIndex];
      _delayMs = _resolveRemoteInitialDelayMs(
          _remoteMembers[startIndex], _remoteMembers[startIndex].id);
      _currentAudioTrackId = _resolveRemoteInitialAudioTrackId(
          _remoteMembers[startIndex], _remoteMembers[startIndex].id);
      await _loadRemoteEpisode(
        startIndex,
        startIntent: EpisodeStartIntent.initialOpen,
        initialPositionMsOverride: _resolveRemoteInitialPositionMs(
            _remoteMembers[startIndex], startIndex),
      );
      return;
    }

    // TODO-885: 远端播放列表（旧单行多集 playlistJson 模型）——把 host 下发的 episodes 映射成
    // _episodes（path 留空，切集靠 episodeIndex 向 host 重新建流），复用既有 _isPlaylist / 剧集
    // 面板 / 上下集。
    final int startIndex = info.isPlaylist
        ? (widget.initialEpisodeIndex ?? info.currentEpisode)
            .clamp(0, info.episodes.length - 1)
        : 0;
    if (info.isPlaylist) {
      _episodes = <_PlaylistEpisodeRef>[
        for (final RemoteVideoEpisode ep in info.episodes)
          _PlaylistEpisodeRef(title: ep.title),
      ];
    }
    await _loadRemoteEpisode(
      startIndex,
      startIntent: EpisodeStartIntent.initialOpen,
      // 起播集恢复其按集断点（host 真相 vs 本地 prefs 取较新者）。
      initialPositionMsOverride:
          _resolveRemoteInitialPositionMs(info, startIndex),
    );
  }

  /// 载入远端第 [index] 集（TODO-885）：向 host 按 episodeIndex 换流式 url + 字幕，
  /// 复用 [_applyLoad]。单视频 [index]==0。慢路径（下字幕）期间若已切走则放弃应用。
  Future<void> _loadRemoteEpisode(
    int index, {
    required EpisodeStartIntent startIntent,
    int? initialPositionMsOverride,
  }) async {
    // 合集连播模式：换集换的是**兄弟成员 id**（各自独立单视频，episodeIndex 恒 0），并把
    // 当前成员指针切到目标成员，使 _effectiveRemoteInfo / 断点键 / 字幕键 / host 上报跟随。
    // host-playlist / 单视频模式：同一 info.id 换 episodeIndex（旧行为，零变化）。
    final RemoteVideoInfo info;
    final int streamEpisodeIndex;
    if (_isRemoteCollection) {
      info = _remoteMembers[index.clamp(0, _remoteMembers.length - 1)];
      streamEpisodeIndex = 0;
      _activeRemoteMember = info;
      _delayMs = _resolveRemoteInitialDelayMs(info, info.id);
      _currentAudioTrackId = _resolveRemoteInitialAudioTrackId(info, info.id);
    } else {
      info = _effectiveRemoteInfo!;
      streamEpisodeIndex = index;
    }
    // TODO-2837 远端副字幕（播放偏好同步泛化批）：来源与独立调轴按 uid 做本地带戳
    // 值 vs host 下发值的逐字段 LWW。_applyLoad 内 setSecondaryDelayMs 应用调轴、
    // _restoreSecondarySubtitle 远端分支重放来源。
    final RemoteVideoInfo secInfo =
        _isRemoteCollection ? info : _effectiveRemoteInfo!;
    final (String secUid, _) = _remotePositionKeyForIndex(index);
    _currentSecondarySubtitleSource =
        _resolveRemoteInitialSecondarySource(secInfo, secUid);
    _secondaryDelayMs = _resolveRemoteInitialSecondaryDelayMs(secInfo, secUid);
    final RemoteVideoClient client = _effectiveRemoteClient!;
    final int seq = ++_episodeLoadSeq;
    // TODO-1307：新一集起播重置「用户已关字幕」标记（字幕后置自动应用的门控，见
    // [_resolveDeferredYoutubeCaptions]）。
    _remoteSubtitleUserDismissed = false;
    // BUG-1861：本会话导入 / 下载的字幕档按视频源作用域，远端换集一并清空（上一集下的
    // 档案不该继续挂在新集的字幕轨列表里）。本地换源在 [_applyLoad] 的
    // `clipExportSourceChanged` 分支清（远端 `_currentVideoPath` 恒 null，走不到那里）。
    _importedSubtitleSources = const <SubtitleSource>[];
    // YouTube 画质档是 per-video 懒解析：新一集起播先复位（下次点开画质菜单再懒解析）。
    _youtubeVariants = const <YoutubeVideoVariant>[];
    _selectedYoutubeVariantIndex = -1;
    _youtubeVariantsDefaultIndex = -1;
    _youtubeVariantsAudioUrl = null;
    _youtubeVariantsLoading = false;
    _youtubeVariantsResolved = false;
    final int initialPositionMs = initialPositionMsOverride ??
        _readPersistedRemotePositionForEpisode(index);
    // TODO-1213：先置「正在连接视频流…」（远端流须先向 host / 源建流，有网络往返）。
    _setLoadingPhase(_VideoLoadPhase.connecting);
    try {
      final RemoteVideoStreamUrls urls = await client.remoteVideoStreamUrls(
        info.id,
        episodeIndex: streamEpisodeIndex,
      );
      _remoteEmbeddedSubtitleTracks = urls.embeddedSubtitleTracks;
      String? externalSub;
      List<AudioCue> cues = const <AudioCue>[];
      // 优先恢复用户上次为该远端集手选的字幕：远端视频无本地 DB 行，字幕只进内存、退出即丢
      // （用户报「下载字幕没持久化退出影片就没了」的根因）。选择按 <bookUid>#ep 记忆在 prefs
      // （见 PreferencesRepository.remoteSubtitleSources），这里在落回 host 默认字幕之前重放。
      // 合集连播下按成员 id 记忆字幕选择（键 = (成员 id, 0)）；单视频/host-playlist 沿用
      // (widget.bookUid, index)。
      final (String subUid, int subEp) = _remotePositionKeyForIndex(index);
      final String? persistedSub =
          appModel.remoteSubtitleSource(subUid, episodeIndex: subEp);
      bool subtitleResolved = false;
      // 内嵌轨重放成功时的持久化编码（`embedded:<n>`）——_applyLoad 会把
      // _currentSubtitleSource 设成外挂文件路径（下载的临时抽取产物），须在其后
      // 改回本编码，否则字幕菜单的内嵌轨行高亮不上、再选一次还会重复下载。
      String? restoredPrimarySource;
      if (persistedSub != null) {
        if (SubtitleSource.isOff(persistedSub)) {
          // 上次显式关闭 → 保持关闭，不加载 host 默认字幕（尊重用户选择）。
          _currentSubtitleSource = null;
          subtitleResolved = true;
        } else if (subtitleFormatForPath(persistedSub) != null &&
            File(persistedSub).existsSync()) {
          // 本地已下载/导入的字幕文件仍在磁盘（Jimaku / 手动导入落 video_subtitles/）→ 重放。
          _setLoadingPhase(_VideoLoadPhase.downloadingSubtitle);
          cues = await _loadExternalSubtitleCues(persistedSub, info.id);
          if (cues.isNotEmpty) {
            externalSub = persistedSub;
            _remoteSubtitlePath = persistedSub;
            subtitleResolved = true;
          }
        } else if (persistedSub.startsWith(SubtitleSource.embeddedPrefix)) {
          // 远端内嵌轨选择重放（互联完整支持批次）：此前 `embedded:<n>` 不重放、
          // 重进落回 host 默认字幕（选内嵌轨的用户每次进影片都要重选一遍）。向
          // host 重新抽取该轨（与 [_applyRemoteEmbeddedSubtitle] 同端点）；抽取
          // 失败（轨已变 / 旧 host）静默落回 host 默认分支，不阻断起播。
          final int? streamIndex = int.tryParse(
              persistedSub.substring(SubtitleSource.embeddedPrefix.length));
          if (streamIndex != null) {
            _setLoadingPhase(_VideoLoadPhase.downloadingSubtitle);
            try {
              final Directory temp = await getTemporaryDirectory();
              final File subtitle = File(p.join(
                temp.path,
                _remoteSubtitleTempFileName(
                    '${info.id}_emb$streamIndex', 'embedded_$streamIndex.srt'),
              ));
              await client.getRemoteVideoSubtitle(
                info.id,
                subtitle,
                embeddedStreamIndex: streamIndex,
                episodeIndex: streamEpisodeIndex,
              );
              cues = await _loadExternalSubtitleCues(subtitle.path, info.id);
              if (cues.isNotEmpty) {
                externalSub = subtitle.path;
                _remoteSubtitlePath = subtitle.path;
                restoredPrimarySource = persistedSub;
                subtitleResolved = true;
              }
            } catch (e) {
              debugPrint(
                  '[VideoFushiPage] embedded subtitle replay failed: $e');
            }
          }
        }
        // host url / 文件已删 → 不在此解析，落回下方 host 默认分支。
      }
      // TODO-1000：YouTube 等预解析好 cue（timedtext→AudioCue）时直接用，跳过
      // subtitleUrl 下载+解析（YouTube XML 字幕现有解析器不识别）。
      if (subtitleResolved) {
        // 已由持久化选择解析：跳过默认字幕分支。
      } else if (client is UrlStreamVideoClient &&
          client.preresolvedCues.isNotEmpty) {
        cues = client.preresolvedCues;
        // TODO-1302：登记 YouTube 字幕轨。预解析 cue 直接注入 overlay，但既不是 host
        // 外挂字幕（不写 _remoteSubtitlePath）也不是内嵌轨枚举（_remoteEmbeddedSubtitleTracks
        // 空），故远端字幕菜单原来渲染不出它、_currentSubtitleSource 留 null 让「关闭」被
        // 误显选中、用户选不回来。用非空合成源哨兵 [_kYoutubeCaptionsSource] 标识它，让菜单
        // 渲染并高亮「YouTube 字幕」行、「关闭」不再被误选。_applyLoad 内 externalSubtitlePath
        // ==null 时保留 _currentSubtitleSource（见其 setState），故此处赋值在 load 后仍生效；
        // 关闭走既有 _clearRemoteSubtitle（置 null）。
        _currentSubtitleSource = _kYoutubeCaptionsSource;
      } else if (urls.subtitleUrl != null) {
        // TODO-1213：进入「正在下载字幕…」阶段（host 若回调 onProgress 则显确定性进度）。
        _setLoadingPhase(_VideoLoadPhase.downloadingSubtitle);
        final Directory temp = await getTemporaryDirectory();
        final File subtitle = File(
          p.join(
            temp.path,
            _remoteSubtitleTempFileName(
              '${info.id}_ep$index',
              urls.subtitleFileName,
            ),
          ),
        );
        await client.getRemoteVideoSubtitle(
          info.id,
          subtitle,
          episodeIndex: index,
          onProgress: (double progress) {
            // TODO-1213：字幕下载确定性进度 → 加载态显进度条 + 百分比。
            if (!mounted) return;
            setState(() => _subtitleProgress = progress);
          },
        );
        externalSub = subtitle.path;
        _remoteSubtitlePath = subtitle.path;
        cues = await _loadExternalSubtitleCues(subtitle.path, info.id);
      }
      if (seq != _episodeLoadSeq || !mounted) return;
      _currentEpisode = index;
      await _applyLoad(
        videoPath: null,
        mediaUri: urls.streamUrl,
        cues: cues,
        title: info.title,
        initialPositionMs: initialPositionMs,
        startIntent: startIntent,
        externalSubtitlePath: externalSub,
        // TODO-1280：分离流的 audio-only 流作为播放音轨，随 load 在恢复 seek + play() 之前
        // 外挂，libmpv 才会让它与视频时间轴同步出声（修「初始无声、跳转后才有声」）；不再等
        // load 返回后才挂（那时 play 已开始，新加音轨不会自动 seek 到当前位置 → 无声）。
        externalAudioTrackUrl: urls.audioStreamUrl,
      );
      if (restoredPrimarySource != null && mounted) {
        // 内嵌轨重放：把选择态改回 `embedded:<n>` 编码（见 restoredPrimarySource doc）。
        setState(() => _currentSubtitleSource = restoredPrimarySource);
      }
      // TODO-1301（BUG-600）：制卡音频源与批量制卡守卫（youtube_clip_miner.dart:67）完全
      // 一致——muxed 挖矿流自带音轨时置 null，让引擎回落 miningSource(muxed 360p) 抽音频
      // （实测 2s 出 AAC）；仅无 muxed 的纯分离流才指向 audio-only 流。此前无条件指向
      // audio-only DASH 流 → ffmpeg `-ss` HTTP seek stall→120s 超时→无句子音频，且
      // requireAudio 默认 true 致 mine 整卡 abort→已抽好的 GIF 连坐丢弃（既无音频也无 GIF）。
      // 播放音轨已在 _applyLoad→controller.load 内、seek/play 之前外挂（见上
      // externalAudioTrackUrl），此处只补制卡侧（时序无关）。
      _controller?.setMiningAudioSourceOverride(
        urls.miningVideoHasAudio ? null : urls.audioStreamUrl,
      );
      // TODO-1000（BUG-528）：制卡 GIF/帧改用低分辨率流（muxed 360p 等）。_applyLoad 已把
      // miningSource 设成了播放流（可达 4K）——从 4K 流网络抽 GIF 会超时，这里覆盖成小流。
      if (urls.miningVideoUrl != null) {
        _controller?.setMiningSourceOverride(urls.miningVideoUrl);
      }
      // TODO-1302/1307 track-list-first：快解析 gate 起播后（首帧就绪、不阻塞播放）异步解析
      // YouTube 字幕**轨列表**填字幕轨选择器 + 自动应用最佳轨（懒下载其 cue）。仅 YouTube 客户端
      // （youtubeCaptionsUrl 非空）触发；见 [_resolveDeferredYoutubeCaptionTracks]。
      if (client is UrlStreamVideoClient && client.youtubeCaptionsUrl != null) {
        unawaited(_resolveDeferredYoutubeCaptionTracks(client, seq));
      }
    } catch (e, stack) {
      debugPrint(
        '[VideoFushiPage] remote episode $index load failed: $e\n$stack',
      );
      if (mounted) {
        setState(() {
          _failed = true;
          _failReason = _describeLoadFailure(e);
        });
      }
    }
  }

  /// TODO-1302/1307 track-list-first：快解析 gate 起播后异步解析 YouTube 字幕**轨列表**
  /// （[resolveYoutubeCaptionTracks]，单次 getPlayerResponse，**不下载 cue 正文**），回填
  /// [UrlStreamVideoClient.youtubeCaptionTracks] 填字幕轨选择器——列表出现不依赖 cue 就绪，
  /// 修「快加载致字幕整个消失」的回归。再自动应用最佳轨（人工>ASR·精确语言，
  /// [pickBestYoutubeCaptionTrack]，懒下载其 cue）以保留「字幕默认显示」。
  ///
  /// 用户在解析间隙已关字幕 / 选别的（[_currentSubtitleSource]!=null 或
  /// [_remoteSubtitleUserDismissed]）时只填列表、不抢占。best-effort：无字幕轨静默返回，视频照播。
  Future<void> _resolveDeferredYoutubeCaptionTracks(
    UrlStreamVideoClient client,
    int seq,
  ) async {
    final String? captionsUrl = client.youtubeCaptionsUrl;
    if (captionsUrl == null) return;
    // 母语（autoTranslate 目标）= 当前 UI locale（TODO-1314 A3 母语对照）。
    final String nativeLang = LocaleSettings.currentLocale.languageCode;
    final List<YoutubeCaptionTrack> tracks = await resolveYoutubeCaptionTracks(
      captionsUrl,
      preferLang: _targetLangCode,
      autoTranslateTo: nativeLang,
    );
    if (!mounted || seq != _episodeLoadSeq) return;
    if (tracks.isEmpty) return;
    // 列表先立即可见（字幕轨选择器渲染这些轨；不依赖 cue 下载成败）。
    client.setYoutubeCaptionTracks(tracks);
    setState(() {});
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    final bool userChoseSubtitle =
        _currentSubtitleSource != null || _remoteSubtitleUserDismissed;
    // 用户已选别的字幕 / 关字幕：只填列表（可再选），不覆盖选择。
    if (userChoseSubtitle) return;
    // 默认自动应用最佳轨（等价「字幕默认可见」）：懒下载其 cue → overlay。
    final YoutubeCaptionTrack? best =
        pickBestYoutubeCaptionTrack(tracks, preferLang: _targetLangCode);
    if (best == null) return;
    await _applyYoutubeCaptionTrack(controller, best, loadSeq: seq);
  }

  /// per-book 播放倍速偏好 key（速度记忆，跨重启保留）。
  String get _speedPrefKey => 'video_speed_${widget.bookUid}';

  /// per-book 播放音量偏好 key（音量记忆，播放列表按整张 video book 共享）。
  String get _volumePrefKey => 'video_volume_${widget.bookUid}';

  /// 读 per-book 持久化倍速（无则 1.0）。
  double _readPersistedSpeed() {
    final double v =
        (appModel.prefsRepo.getPref(_speedPrefKey, defaultValue: 1.0) as num)
            .toDouble();
    return v.clamp(0.25, 4.0);
  }

  /// 读 per-book 持久化音量（无则 100）。
  double _readPersistedVolume() {
    final Object? raw =
        appModel.prefsRepo.getPref(_volumePrefKey, defaultValue: 100.0);
    final double v = raw is num
        ? raw.toDouble()
        : double.tryParse(raw?.toString() ?? '') ?? 100.0;
    return v.clamp(0.0, 100.0).toDouble();
  }

  /// 读 per-book/per-episode 远端断点位置（无则 0，从头）。
  ///
  /// 在线远端视频（[_isRemote]）在 client 本地 DB 没有 VideoBooks 行（书架不收录
  /// 远端在线视频，[home_video_page._openRemote] 直接 push 播放页不 upsert），因此本地
  /// 视频走 `VideoBooks.lastPositionMs` 的进度链路对远端不可用。沿用 speed/volume 同款
  /// per-book prefs 范式（落 Drift `preferences` 表，跨重启保留），key 用稳定的
  /// `widget.bookUid`（= 远端 `RemoteVideoInfo.id`，每次列举不变）。TODO-885：
  /// [episodeIndex]>0 用按集 key（`#ep<index>` 后缀），0 回退整书 key（向后兼容单视频 /
  /// 旧 TODO-559 prefs）。
  int _readPersistedRemotePositionForEpisode(int episodeIndex) {
    final (String uid, int ep) = _remotePositionKeyForIndex(episodeIndex);
    final Object? raw = appModel.prefsRepo
        .getPref(videoRemotePositionEpisodePrefKey(uid, ep), defaultValue: 0);
    final int v =
        raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '') ?? 0;
    return v < 0 ? 0 : v;
  }

  /// 读 per-book/per-episode 远端断点的本地「最后更新时间」（无则 0）。TODO-653 冲突解决用。
  int _readPersistedRemotePositionAtForEpisode(int episodeIndex) {
    final (String uid, int ep) = _remotePositionKeyForIndex(episodeIndex);
    final Object? raw = appModel.prefsRepo
        .getPref(videoRemotePositionEpisodeAtPrefKey(uid, ep), defaultValue: 0);
    final int v =
        raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '') ?? 0;
    return v < 0 ? 0 : v;
  }

  /// 读本地持久化的远端视频 [uid] 字幕调轴（prefs，无记录返回 0）。与断点同款
  /// per-uid prefs 范式（互联远端调轴不持久化 bug：远端无 VideoBooks 行，
  /// `updateDelayMs` 是静默 0 行 UPDATE，调轴必须落 prefs 才能跨重启保留）。
  int _readPersistedRemoteDelayMs(String uid) {
    final Object? raw = appModel.prefsRepo
        .getPref(videoRemoteDelayPrefKey(uid), defaultValue: 0);
    return raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '') ?? 0;
  }

  /// 读 [_readPersistedRemoteDelayMs] 对应的本地「最后更新时间」（无则 0）。LWW 用。
  int _readPersistedRemoteDelayAtMs(String uid) {
    final Object? raw = appModel.prefsRepo
        .getPref(videoRemoteDelayAtPrefKey(uid), defaultValue: 0);
    final int v =
        raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '') ?? 0;
    return v < 0 ? 0 : v;
  }

  /// 远端视频起播字幕调轴：host 下发值（[info].delayMs@delayUpdatedAtMs）与本地
  /// prefs 经 [resolveDelayLww]「严格较新者胜」。平局（两侧都无戳 = 本机从未调过、
  /// host 也无带戳记录）跟随 host（保留 BUG-996 行为）；本机调过而 host 无新主张
  /// 时本机值胜——这正是「退出重进归 0」的修复点。
  int _resolveRemoteInitialDelayMs(RemoteVideoInfo info, String uid) {
    final ({int delayMs, int updatedAtMs}) winner = resolveDelayLww(
      aDelayMs: info.delayMs,
      aUpdatedAtMs: info.delayUpdatedAtMs,
      bDelayMs: _readPersistedRemoteDelayMs(uid),
      bUpdatedAtMs: _readPersistedRemoteDelayAtMs(uid),
    );
    return winner.delayMs
        .clamp(-kVideoSubtitleDelayLimitMs, kVideoSubtitleDelayLimitMs);
  }

  // ── 远端播放偏好统一键对读写（播放偏好同步泛化批）───────────────────────────
  // 每偏好 = (值键, at 键) 一对；字符串值空串 = null（「显式清除」有 at 无值，与
  // 「从未设过」at==0 区分）。与 host 侧 getVideoPlayback 同一键、同一语义。

  /// 读远端播放偏好的字符串值键（缺失/空串 → null）。
  String? _readRemoteStringPref(String key) {
    final Object? raw = appModel.prefsRepo.getPref(key, defaultValue: '');
    final String s = raw?.toString() ?? '';
    return s.isEmpty ? null : s;
  }

  /// 读远端播放偏好的 at 键（缺失 → 0）。
  int _readRemoteAtPref(String key) {
    final Object? raw = appModel.prefsRepo.getPref(key, defaultValue: 0);
    final int v =
        raw is num ? raw.toInt() : int.tryParse(raw?.toString() ?? '') ?? 0;
    return v < 0 ? 0 : v;
  }

  /// 写远端播放偏好键对（值 null → 空串哨兵 = 显式清除；at = now）。返回盖下的 at。
  Future<int> _stampRemoteStringPref(
      String valueKey, String atKey, String? value) async {
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    await appModel.prefsRepo.setPref(valueKey, value ?? '');
    await appModel.prefsRepo.setPref(atKey, nowMs);
    return nowMs;
  }

  /// best-effort 上报播放偏好带戳字段到 host（能力探测 + 吞错；调整哪个字段就
  /// 只带哪个字段，host 逐字段 LWW 合并）。旧 host 无端点 / 离线只记日志。
  void _pushRemotePlayback(String uid, VideoPlaybackSyncState state) {
    // 经 Object? 中转促成类型提升：RemoteVideoPlaybackSync 是能力接口，不是
    // RemoteVideoClient 的子类型，直接 is 判断不会提升接收者。
    final Object? client = _effectiveRemoteClient;
    if (client is! RemoteVideoPlaybackSync) return;
    unawaited(() async {
      try {
        await client.putRemoteVideoPlayback(uid, state);
      } catch (e) {
        debugPrint('[VideoFushiPage] remote playback upload failed: $e');
      }
    }());
  }

  /// 远端起播音轨：本地带戳选择严格新于 host → 本地；否则跟随 host 下发
  /// （系列级 ?? row 基底或对端带戳值）。平局（双 0）= 都没选过 → host 基底。
  String? _resolveRemoteInitialAudioTrackId(RemoteVideoInfo info, String uid) =>
      _readRemoteAtPref(videoRemoteAudioTrackAtPrefKey(uid)) >
              info.audioTrackUpdatedAtMs
          ? _readRemoteStringPref(videoRemoteAudioTrackPrefKey(uid))
          : info.audioTrackId;

  /// 远端起播副字幕来源（TODO-2837 副字幕入同步通道）。值可能是对端设备的本地
  /// 文件路径——恢复侧文件不存在自然跳过，无特例分支。
  String? _resolveRemoteInitialSecondarySource(
          RemoteVideoInfo info, String uid) =>
      _readRemoteAtPref(videoRemoteSecondarySubtitleAtPrefKey(uid)) >
              info.secondarySubtitleUpdatedAtMs
          ? _readRemoteStringPref(videoRemoteSecondarySubtitlePrefKey(uid))
          : info.secondarySubtitleSource;

  /// 远端起播副字幕独立调轴（null = 跟随主字幕；「显式清除」也带戳同步）。
  int? _resolveRemoteInitialSecondaryDelayMs(RemoteVideoInfo info, String uid) {
    final int? winner = _readRemoteAtPref(
                videoRemoteSecondaryDelayAtPrefKey(uid)) >
            info.secondaryDelayUpdatedAtMs
        ? int.tryParse(
            _readRemoteStringPref(videoRemoteSecondaryDelayPrefKey(uid)) ?? '')
        : info.secondaryDelayMs;
    return winner?.clamp(
        -kVideoSubtitleDelayLimitMs, kVideoSubtitleDelayLimitMs);
  }

  /// 远端视频开播位置（TODO-653/885）：在 host 真相（[info] 随清单带回的整书 positionMs，
  /// 仅对起播集 [episodeIndex]==currentEpisode 有意义）与本地按集 prefs 之间「取较新时间
  /// 戳」（[resolvePositionLww]）。host 进度新于本地时跨设备恢复；本地新于 host 时
  /// 不被旧 host 回退。非起播集只用本地按集 prefs（host 清单只带整书/当前集进度）。
  int _resolveRemoteInitialPositionMs(RemoteVideoInfo info, int episodeIndex) {
    // host 的 info.positionMs 是整书/当前集进度，只对 host 的 currentEpisode 那集叠加；
    // 其它集 host 没带进度 → 退本地按集 prefs。
    final bool hostProgressApplies =
        !info.isPlaylist || episodeIndex == info.currentEpisode;
    final ({int positionMs, int updatedAtMs}) winner = resolvePositionLww(
      localPositionMs: _readPersistedRemotePositionForEpisode(episodeIndex),
      localUpdatedAtMs: _readPersistedRemotePositionAtForEpisode(episodeIndex),
      remotePositionMs: hostProgressApplies ? info.positionMs : 0,
      remoteUpdatedAtMs: hostProgressApplies ? info.positionUpdatedAtMs : 0,
    );
    return winner.positionMs < 0 ? 0 : winner.positionMs;
  }

  /// 远端视频断点位置持久化（controller 每秒至多一次回调 / flush / dispose）。
  ///
  /// 与本地 [_persistPosition] 对应：远端无播放列表（[_episodes] 恒空）也无 DB 行，
  /// 按稳定 bookUid 落 prefs（离线时仍可恢复）。controller 用 `widget.bookUid` 调
  /// [onPositionWrite]，故回调 [uid] 即构造 [_remotePositionPrefKey] 用的同一 bookUid。
  ///
  /// TODO-653：同时把进度 best-effort 上报到 host（跨设备同步真相源）。上报失败
  /// （离线 / 旧 host 无端点）只记日志不抛——本地 prefs 已写，不阻塞播放也不丢进度。
  Future<void> _persistRemotePosition(String uid, int posMs) async {
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    final int clamped = posMs < 0 ? 0 : posMs;
    // BUG-996：位置低于「真观看」阈值（近视频起点）时不落本地带戳断点、也不上报 host。
    // 否则慢远端流 resume 未落地（BUG-179 恢复守护耗尽兜底到 ~0）时写入的 ~0 断点带
    // now 戳，会在 LWW 里完胜 host 的真进度（host `lastPositionMs` 派生进度 updatedAtMs=0）
    // → 下次打开从头播放。近起点不算有效进度，跳过不写即可。
    const int kMeaningfulRemoteWatchMs = 5000;
    if (clamped < kMeaningfulRemoteWatchMs) return;
    // TODO-885 / 合集连播：按当前集 key 落库 + 上报。合集模式键 = (当前成员 id, 0)（成员天然
    // 隔离，与 host 按成员带回的 positionMs 对齐）；单视频/host-playlist = (widget.bookUid,
    // _currentEpisode)（此时 keyUid==uid，行为零变化）。传入的 [uid] 恒是 widget.bookUid。
    final (String keyUid, int episodeIndex) =
        _remotePositionKeyForIndex(_currentEpisode);
    await appModel.prefsRepo.setPref(
        videoRemotePositionEpisodePrefKey(keyUid, episodeIndex), clamped);
    await appModel.prefsRepo.setPref(
        videoRemotePositionEpisodeAtPrefKey(keyUid, episodeIndex), nowMs);
    // 书架流媒体书（YouTube/直链，TODO-1157）**有** VideoBooks 行（[_bookRow] 非空），
    // 只写 prefs 会让书架的「继续观看 / 在看筛选 / 合集续播选集」对它全部失明——那些
    // 读的是 `lastPositionMs` / `lastPlayedAt`。与本地 [_persistPosition] 对齐补写 DB 行
    // （resume 仍走上面的 prefs LWW，两者读写路径互不干扰）。互联远端无行，保持原样。
    if (_bookRow != null) {
      await widget.repo
          .updatePosition(widget.bookUid, clamped, playedAt: nowMs);
    }
    final RemoteVideoClient? client = _effectiveRemoteClient;
    if (client == null) return;
    try {
      await client.putRemoteVideoPosition(
        keyUid,
        clamped,
        nowMs,
        episodeIndex: episodeIndex,
      );
    } catch (e) {
      debugPrint('[VideoFushiPage] remote position upload failed: $e');
    }
  }

  /// 载入单视频（无播放列表）：优先用 DB 已存 cue；否则先尝试恢复用户上次选的
  /// 字幕源（[row.subtitleSource] 跨重启保留），无匹配再退默认 sidecar 探测。
  Future<void> _loadSingle(VideoBookRow row) async {
    final bool subtitleExplicitlyOff = SubtitleSource.isOff(row.subtitleSource);
    final ({
      String videoPath,
      String? subtitleSource,
    }) paths = await _relocateSingleMediaPaths(row);
    List<AudioCue> cues = await widget.repo.loadCues(widget.bookUid);
    String? externalSub = paths.subtitleSource;
    int? graphicStreamIndex;

    // TODO-1246：外挂文本字幕（.srt/.ass/.ssa/.vtt）的真相源是磁盘档案，不是 DB 缓存。
    // DB 里的 AudioCue **不携带**解析期的行内/cue 级样式 markup（[AudioCue.markup] 瞬态、
    // DB 往返丢弃，见 audiobook_model.dart），故单视频重开时 loadCues 命中的 cue 恒
    // `markup==null` → 字幕 overlay 的「尊重字幕自带样式」开关（respectAssStyle）拿不到
    // cueStyle，字幕永远退回 app 统一样式（用户报：开了开关 .ass 自带字体/主色/描边仍不
    // 生效）。当持久化字幕源是仍在磁盘上的外挂文本档案时，直接重解析档案拿回带 markup 的
    // cue（重解析文本档案廉价，不触发 BUG-081 关注的内嵌轨 ffmpeg 重抽取）；重解析空
    // （档案被删/损坏）时保留 DB 缓存 cue（内容仍在、仅缺样式），不倒退功能。
    // 播放列表换集走 _restorePersistedSubtitle→loadCuesForSource 已是重解析、天然带 markup，
    // 故只需修单视频路径。
    final String? rehydratePath = subtitleExplicitlyOff
        ? null
        : _rehydratableExternalSubtitlePath(externalSub);

    // TODO-1246 补全：**内嵌** ASS/SSA 轨（anime MKV 最常见）的样式真相源是视频容器，
    // 但抽取后的缓存档案（`sub_<n>.ass`，含 [V4+ Styles]）已是磁盘上物化的 .ass。外挂
    // 档案分支（[_rehydratableExternalSubtitlePath]）只认绝对路径、拒 `embedded:<n>`，故
    // 单视频重开内嵌轨仍拿 DB 缓存的无 markup cue（[loadCues] 命中且非空）→ cueStyle==null
    // → 「尊重字幕自带样式」(respectAssStyle) 对内嵌轨完全不生效（用户报「现在完全没用」）。
    // 修复：DB 命中的**文本** cue（cues 非空）且持久化源是内嵌轨时，经
    // [_restorePersistedSubtitle]（与播放列表换集同一重解析路径）重解析已抽取的缓存档案，
    // 恢复 cueStyle。缓存命中不触发 ffmpeg 重抽取；图形轨（无文本 cue → cues 为空）不进本
    // 分支，仍由下方 `cues.isEmpty` 分支经 libmpv 画面渲染恢复（不倒退 BUG-122）。
    final bool rehydrateEmbedded = !subtitleExplicitlyOff &&
        rehydratePath == null &&
        cues.isNotEmpty &&
        SubtitleSource.isEmbeddedPersisted(externalSub);

    // TODO-818：用户显式关闭字幕。哨幕短路两个自动重选向量（sidecar 探测 + 内嵌轨
    // 抽取），externalSub 保持哨兵原样传给 _applyLoad，恢复后仍是关闭态。
    if (subtitleExplicitlyOff) {
      cues = const <AudioCue>[];
    } else if (rehydratePath != null) {
      // 外挂文本字幕：重解析磁盘档案作为真相源，恢复 cue 级 / 行内样式 markup（TODO-1246）。
      final List<AudioCue> reparsed =
          await _loadExternalSubtitleCues(rehydratePath, widget.bookUid);
      if (reparsed.isNotEmpty) {
        cues = reparsed;
      }
      // reparsed 为空（档案被删/损坏）：保留上面的 DB 缓存 cues，仅缺样式不缺内容。
      // **但缓存本身可能就是空的**——合集里的每一集只落字幕源指针、不落 cue
      // （见 _selectSubtitleSource 的 `_episodes.isEmpty` 分支），所以这条支路解析
      // 失败时 cues 恒为空。下面那组兜底因此**不能**继续挂在同一条 else-if 链上，
      // 否则「解析一次没成功」就等于零字幕、零兜底、零提示（用户报：下载的字幕退出
      // 再进就没了，只能重下一次）。见 BUG-1848。
    } else if (rehydrateEmbedded) {
      // 内嵌文本轨：重解析已抽取的缓存档案恢复 cue 级 / 行内样式 markup（TODO-1246）。
      final ({
        String persisted,
        List<AudioCue> cues,
        int? graphicStreamIndex,
      })? restored = await _restorePersistedSubtitle(
        videoPath: paths.videoPath,
        persisted: externalSub,
        crossEpisode: false,
      );
      if (restored != null && restored.cues.isNotEmpty) {
        cues = restored.cues;
        externalSub = restored.persisted;
      }
      // restored 为空（缓存被清 / 容器不可读）：保留 DB 缓存 cues，仅缺样式不缺内容。
    }

    // 兜底链：只要**还没拿到 cue** 就逐级往下试。这里刻意独立于上面那条 else-if 链
    // ——上面任何一支「试过但没成功」都必须能落到这里。合集里的每一集没有 DB cue 缓存
    // 兜底（只落字幕源指针），一旦挂在同一条链上，「解析一次没成功」就直接空手收场
    // （BUG-1848）。
    if (!subtitleExplicitlyOff && cues.isEmpty) {
      // ① 优先恢复持久化的字幕源（精确匹配本视频的同一源）。
      if (paths.subtitleSource != null && paths.subtitleSource!.isNotEmpty) {
        final ({
          String persisted,
          List<AudioCue> cues,
          int? graphicStreamIndex,
        })? restored = await _restorePersistedSubtitle(
          videoPath: paths.videoPath,
          persisted: paths.subtitleSource,
          crossEpisode: false,
        );
        if (restored != null) {
          cues = restored.cues;
          externalSub = restored.persisted;
          graphicStreamIndex = restored.graphicStreamIndex;
        }
      }
      // ② 仍为空：退默认 sidecar 探测。判据只看「还没有 cue」——旧判据额外要求
      // `externalSub == null`，于是「有持久化源、但它恢复不出内容」时连 sidecar 都不试。
      if (cues.isEmpty) {
        final ({String path, List<AudioCue> cues})? sidecar =
            await _detectSidecar(paths.videoPath, widget.bookUid);
        if (sidecar != null) {
          cues = sidecar.cues;
          externalSub = sidecar.path;
        }
      }
      // ③ 还是空：别拿一个恢复不出任何内容的外挂源去挡住播放器的内封轨自动加载
      // （`VideoPlayerController.load` 只在「无外挂路径 + 无 cue」时才后台抽内封文本轨）。
      // 只影响本次加载，**不回写 DB**——用户选过的源仍在库里，下次仍会先试它。
      if (cues.isEmpty && !SubtitleSource.isEmbeddedPersisted(externalSub)) {
        externalSub = null;
      }
    }
    await _applyLoad(
      videoPath: paths.videoPath,
      cues: cues,
      title: row.title,
      initialPositionMs: widget.initialCueStartMs ?? row.lastPositionMs,
      startIntent: widget.initialCueStartMs == null
          ? EpisodeStartIntent.initialOpen
          : EpisodeStartIntent.explicitCue,
      externalSubtitlePath: externalSub,
      renderGraphicStreamIndex: graphicStreamIndex,
    );
  }

  Future<({String videoPath, String? subtitleSource})>
      _relocateSingleMediaPaths(VideoBookRow row) async {
    final String? relocatedVideo =
        await relocateMissingAppDocumentPath(row.videoPath);
    final String videoPath = relocatedVideo ?? row.videoPath;
    final String? subtitleSource = row.subtitleSource;
    final String? relocatedSubtitle =
        subtitleSource == null || subtitleSource.isEmpty
            ? null
            : await relocateMissingAppDocumentPath(subtitleSource);
    final String? effectiveSubtitle = relocatedSubtitle ?? subtitleSource;
    if (relocatedVideo != null || relocatedSubtitle != null) {
      await widget.repo.updateLocalMediaPaths(
        widget.bookUid,
        videoPath: relocatedVideo,
        subtitleSource: relocatedSubtitle,
      );
      debugPrint(
        '[VideoFushiPage] relocated app-owned media path(s): '
        'video=${relocatedVideo != null} subtitle=${relocatedSubtitle != null}',
      );
    }
    return (videoPath: videoPath, subtitleSource: effectiveSubtitle);
  }

  /// 尝试用持久化偏好 [persisted] 在 [videoPath] 的可用字幕源里选一个并加载 cue。
  ///
  /// [crossEpisode]=false（单视频重启恢复）：用 [SubtitleSource.matchesPersisted]
  /// 精确匹配同一源。[crossEpisode]=true（播放列表换集）：用
  /// [pickEpisodeSubtitleSource] 按「同类偏好」（内嵌同 streamIndex / 外挂同语言
  /// 后缀）从新集源里选。
  ///
  /// 返回所选源的「实际持久化值 + 解析出的 cue」；无匹配 / 解析空 cue 返回 null
  /// （调用方退默认 sidecar）。返回的 persisted 用作 [_applyLoad] 的
  /// externalSubtitlePath（内嵌源也走 `embedded:<n>` 字符串，与既有约定一致）。
  Future<({String persisted, List<AudioCue> cues, int? graphicStreamIndex})?>
      _restorePersistedSubtitle({
    required String videoPath,
    required String? persisted,
    required bool crossEpisode,
  }) async {
    if (persisted == null || persisted.isEmpty) return null;

    // BUG-132: 用户手动导入 / Jimaku 下载的外挂字幕被拷到 `<appDocs>/video_subtitles/`，
    // **不在剧集目录里**，而 [listAllSubtitleSources] 只扫视频同目录 + 内封轨 → 播放
    // 列表换集/重进时匹配不到，导致「退出后字幕又要重新导入」。这类源的持久化值就是
    // 它自己的绝对路径，且与剧集无关——只要文件还在磁盘上就按路径直接加载，无需经
    // listAllSubtitleSources 的同目录枚举。单视频路径已由 `_loadSingle` 的 loadCues
    // 命中、走不到这里；本捷径主要救播放列表（只存源指针不存 cue）。
    //
    // BUG-165: 换集（[crossEpisode]）时该捷径必须只接管**真正住在别处的导入字幕**
    // ——若持久化路径与新集视频**同目录**，那是上一集自带的同目录 sidecar
    // （如 `EP01.ja.srt`），不能原样沿用到 `EP02`，否则字幕卡在上一集。故换集时改用
    // [shouldReusePersistedSubtitleAcrossEpisode]（按目录归属区分），同目录 sidecar 落
    // 回下面的同目录枚举 + [pickEpisodeSubtitleSource] 按新集名重新匹配。单视频恢复
    // （非换集）同一视频本就该恢复同一字幕，保持原 [isImportedExternalSubtitlePath] 判定。
    final bool takeImportedShortcut = crossEpisode
        ? shouldReusePersistedSubtitleAcrossEpisode(persisted, videoPath)
        : isImportedExternalSubtitlePath(persisted);
    if (takeImportedShortcut && File(persisted).existsSync()) {
      final SubtitleSource external = SubtitleSource.external(
        externalPath: persisted,
        label: p.basename(persisted),
      );
      final List<AudioCue> cues = await loadCuesForSource(
        external,
        videoPath,
        widget.bookUid,
      );
      if (cues.isNotEmpty) {
        return (
          persisted: external.toPersistedValue(),
          cues: cues,
          graphicStreamIndex: null,
        );
      }
      // 文件在但解析空（坏字幕）：落回下面的同目录枚举，别让一个坏导入挡住别的源。
    }

    final List<SubtitleSource> sources = await listAllSubtitleSources(
      videoPath,
      langCode: _targetLangCode,
    );
    if (sources.isEmpty) return null;

    final SubtitleSource? chosen = crossEpisode
        ? pickEpisodeSubtitleSource(persisted, sources)
        : _firstMatching(sources, persisted);
    if (chosen == null) return null;

    // 图形内封轨（PGS 等位图）无文本 cue：返回 graphicStreamIndex，让 [_applyLoad]
    // 经 libmpv 画面渲染恢复（不走 loadCues→空→误退 sidecar）（BUG-122）。
    if (chosen.isGraphicEmbedded) {
      return (
        persisted: chosen.toPersistedValue(),
        cues: const <AudioCue>[],
        graphicStreamIndex: chosen.streamIndex,
      );
    }

    final List<AudioCue> cues = await loadCuesForSource(
      chosen,
      videoPath,
      widget.bookUid,
    );
    if (cues.isEmpty) return null;
    return (
      persisted: chosen.toPersistedValue(),
      cues: cues,
      graphicStreamIndex: null,
    );
  }

  /// 字幕菜单来源：保留当前视频枚举结果，再只补入「当前视频已持久化」的导入字幕。
  ///
  /// BUG-2094：主字幕与副字幕**两条**持久化指针都要补——只被选作副字幕的导入档否则
  /// 在重开视频后从列表里消失（画面还在显示它）。
  Future<List<SubtitleSource>> _subtitleSourcesForMenu({
    required String videoPath,
    required String? currentSubtitleSource,
    required List<AudioCue> currentCues,
    required String? currentSecondarySubtitleSource,
    required List<AudioCue> currentSecondaryCues,
  }) async {
    final List<SubtitleSource> sources = await listAllSubtitleSources(
      videoPath,
      langCode: _targetLangCode,
    );
    return includeCurrentPersistedSubtitleForMenu(
      sources,
      videoPath: videoPath,
      bookUid: widget.bookUid,
      currentSubtitleSource: currentSubtitleSource,
      currentCues: currentCues,
      currentSecondarySubtitleSource: currentSecondarySubtitleSource,
      currentSecondaryCues: currentSecondaryCues,
    );
  }

  /// 在 [sources] 中找第一个 [matchesPersisted] 命中的源（精确恢复用）。
  SubtitleSource? _firstMatching(
    List<SubtitleSource> sources,
    String persisted,
  ) {
    for (final SubtitleSource s in sources) {
      if (s.matchesPersisted(persisted)) return s;
    }
    return null;
  }

  /// 若 [source] 是仍在磁盘上的**外挂文本字幕档案**（.srt/.ass/.ssa/.vtt），返回其路径供
  /// 重解析拿回样式 markup（TODO-1246）；否则返回 null：内嵌轨（`embedded:<n>` 无扩展名，
  /// [subtitleFormatForPath] 判 null）、关闭哨兵、`null`/空、或档案已不在磁盘上（重解析无源）。
  /// 内嵌轨不在此重解析（避免 BUG-081 关注的 ffmpeg 重抽取），保留 DB 缓存 cue。
  String? _rehydratableExternalSubtitlePath(String? source) {
    if (source == null || source.isEmpty) return null;
    if (SubtitleSource.isOff(source)) return null;
    if (subtitleFormatForPath(source) == null) return null;
    if (!File(source).existsSync()) return null;
    return source;
  }

  /// 探测视频同目录 sidecar 字幕并解析为 cue（无则 null）。
  ///
  /// 按 app 学习语言优先（学日语 → `.ja.srt > .ja.ass > … > .srt > .ass …`，
  /// 见 [findSidecarSubtitle]）；按扩展名路由统一字幕 parser。IO + 解析失败静默返回 null。
  Future<({String path, List<AudioCue> cues})?> _detectSidecar(
    String videoPath,
    String bookUid,
  ) async {
    final String? sidecarPath = findSidecarSubtitle(
      videoPath,
      langCode: _targetLangCode,
    );
    if (sidecarPath == null) return null;
    try {
      final SubtitleFormat? format = subtitleFormatForPath(sidecarPath);
      if (format == null) return null;
      final String text = await readTextWithEncoding(File(sidecarPath));
      final List<AudioCue> cues = await parseSubtitleContentAsync(
        format,
        content: text,
        bookUid: bookUid,
      );
      if (cues.isEmpty) return null;
      return (path: sidecarPath, cues: cues);
    } catch (e) {
      debugPrint('[VideoFushiPage] sidecar parse failed: $e');
      return null;
    }
  }

  Future<List<AudioCue>> _loadExternalSubtitleCues(
    String path,
    String bookUid,
  ) async {
    try {
      final SubtitleFormat? format = subtitleFormatForPath(path);
      if (format == null) return const <AudioCue>[];
      final String text = await readTextWithEncoding(File(path));
      return await parseSubtitleContentAsync(
        format,
        content: text,
        bookUid: bookUid,
      );
    } catch (e) {
      debugPrint('[VideoFushiPage] external subtitle parse failed: $e');
      return const <AudioCue>[];
    }
  }

  /// 共享 load 装配：复用或新建 controller，载入视频 + cue，挂位置持久化回调。
  /// 单 URL 流（TODO-850 阶段①）的防盗链 header（Referer/User-Agent 等）。仅当远端
  /// client 是 [UrlStreamVideoClient] 时取其 [UrlStreamVideoClient.httpHeaderFields]；
  /// 其它远端/本地播放恒返回空 map（[applyHttpHeaderFieldsToPlayer] 据此 no-op，
  /// 既有播放路径零影响）。
  Map<String, String> get _streamHttpHeaderFields {
    final RemoteVideoClient? client = _effectiveRemoteClient;
    if (client is UrlStreamVideoClient) return client.httpHeaderFields;
    return const <String, String>{};
  }

  Future<void> _applyLoad({
    required String? videoPath,
    String? mediaUri,
    required List<AudioCue> cues,
    required String title,
    required int initialPositionMs,
    required EpisodeStartIntent startIntent,
    String? externalSubtitlePath,
    int? renderGraphicStreamIndex,
    // TODO-1280：YouTube 分离流的 audio-only 流 URL，透传给 controller.load 在 seek/play 之前
    // 外挂（null=无分离音轨）。
    String? externalAudioTrackUrl,
    // TODO-1158：常规载入（新视频/换集）默认探测 HLS master 画质档；画质切档自身的
    // 重载传 false，避免用 variant（media playlist）URL 重探测把档位列表清空。
    bool detectHls = true,
  }) async {
    // TODO-897：本地视频资源缺失（被移动 / 删除 / 所在盘未挂载）前置短路。
    // libmpv 对失效本地路径静默失败（不抛、不回调），下面的 try/catch 与页级
    // spinner 都救不了→media_kit 自带缓冲圈无限转。故在 controller.load 之前判定：
    // 缺失则不 load，置缺失态（[_buildScaffold] 在转圈判据前短路）+ 弹中性对话框。
    // 远端 / 流（videoPath==null 或 http(s) URL）天然豁免（见 video_resource_check）。
    if (await isLocalVideoResourceMissing(videoPath)) {
      debugPrint('[VideoFushiPage] local video resource missing: $videoPath');
      if (!mounted) return;
      setState(() {
        _failed = false;
        _failReason = null;
        _missingResource = true;
        _missingRow = _bookRow;
        _title = title;
        _titleNotifier.value = title;
      });
      await _promptMissingResource(title);
      return;
    }
    // TODO-1276：首开（此前无 controller）才把页级加载态保持到首帧就绪，杜绝与
    // media_kit 缓冲圈接力成「转两次圈」；换集复用同一 controller 不改动
    // [_videoReadyToShow]（维持既有行为、不碰全屏路由复用的同一实例，BUG-120/121）。
    final bool isInitialVideoOpen = _controller == null;
    final VideoPlayerController controller =
        _controller ?? VideoPlayerController();
    // HDR 直通模式 + 画面 fit 交给控制器（宿主窗模式下 fit 由 mpv 自己算）。
    controller.configureHdrOutput(
      mode: _videoHdrOutputMode,
      fitMode: _videoFitMode,
    );
    // BUG-772：首开新建的在途 controller 登记进字段，让页面 dispose 能主动取消它。
    // 换集复用同一 _controller 时不设，避免误 dispose 正在用的实例。
    if (isInitialVideoOpen) _pendingController = controller;
    final VideoMpvConfig mpvConfig = VideoMpvConfig.decode(
      appModel.videoMpvConfig,
    );
    // 解析启用的 mpv 着色器为绝对路径（桌面 libmpv 生效，移动端最终静默）。
    // 「画质增强」主开关关闭时保留持久化勾选，但运行时旁路所有 shader。
    final List<String> shaderPaths = mpvConfig.highQuality
        ? await resolveEnabledShaderPaths(
            decodeEnabledShaders(appModel.videoShadersEnabled),
          )
        : const <String>[];
    // 开关开启时装载 mpv_scripts 目录全部 Lua 脚本（每 Player 实例幂等，
    // 见 video_lua_script_manager.dart）。
    final List<String> luaScriptPaths = appModel.videoMpvLuaScriptsEnabled
        ? await listLuaScriptPaths()
        : const <String>[];
    controller.setOnCompleted(_handlePlaybackCompleted);
    // TODO-1119 / BUG-545：Windows 高显卡占用黑屏闪烁运行时提示。仅 Windows 挂回调
    // （其它平台 null＝控制器完全不采样，零开销）；判定持续迟帧后弹一次可关闭提示条。
    controller.onSuspectedBlackFlicker =
        Platform.isWindows ? _handleSuspectedBlackFlicker : null;
    // TODO-1213：进入「正在缓冲…」阶段——网络流 controller.load 内部连接 + 缓冲最久，
    // 页级 spinner 期间显阶段文案而非裸转圈。纯 UI 状态，不改 load 时序。
    _setLoadingPhase(_VideoLoadPhase.buffering);
    try {
      await controller.load(
        bookUid: widget.bookUid,
        videoFile: videoPath == null ? null : File(videoPath),
        mediaUri: mediaUri,
        cues: cues,
        initialPositionMs: initialPositionMs,
        startIntent: startIntent,
        initialSpeed: _playbackSpeed,
        initialVolume: _playbackVolume,
        externalSubtitlePath: externalSubtitlePath,
        // TODO-818：externalSubtitlePath 为「显式关闭」哨兵时，禁止 controller 后台
        // 自动抽取内嵌文本轨成 cue（否则关了字幕重启又被内嵌轨自动选上）。
        subtitleExplicitlyOff: SubtitleSource.isOff(externalSubtitlePath),
        renderGraphicStreamIndex: renderGraphicStreamIndex,
        shaderPaths: shaderPaths,
        luaScriptPaths: luaScriptPaths,
        mpvConfig: mpvConfig,
        httpHeaderFields: _streamHttpHeaderFields,
        autoPlay: true,
        externalAudioTrackUrl: externalAudioTrackUrl,
        onEmbeddedSubtitleAutoLoad: _handleEmbeddedSubtitleAutoLoad,
      );
    } catch (e, stack) {
      debugPrint('[VideoFushiPage] video load failed: $e\n$stack');
      ErrorLogService.instance.log('VideoFushi.load', e, stack);
      if (_controller == null) controller.dispose();
      _pendingController = null; // BUG-772：在途结束（失败），清标记
      if (mounted) {
        setState(() {
          _failed = true;
          _failReason = _describeLoadFailure(e);
        });
      }
      return;
    }
    _syncVolumeDisplay(controller.volume);
    // BUG-2032：随包 libmpv 有没有编 Lua 是按平台固定的二进制事实，探到就落 pref，
    // 让全局设置页（无播放器）也能如实说明脚本开关在本平台是否可用。
    if (controller.luaCapability != MpvLuaCapability.unknown) {
      unawaited(appModel.setVideoMpvLuaCapability(controller.luaCapability));
    }
    // TODO-1000：远端/流视频（videoPath==null）把制卡抽取源设为可 seek 的流 URL，使
    // ImmersionMiningEngine 能从流 URL 按时间戳裁 GIF/音频（本地视频仍用 videoPath）。
    // 覆盖是幂等的：本地/空时清除，避免换片残留上一条流 URL。
    controller.setMiningSourceOverride(videoPath == null ? mediaUri : null);
    // TODO-1158：探测当前流是否为 HLS master（多档画质），填充画质菜单。仅常规载入
    // 触发（画质切档的重载 detectHls=false）；网络 .m3u8 直链才 fetch，best-effort。
    if (detectHls) {
      unawaited(_detectHlsVariantsForLoad(mediaUri));
    }
    // 应用持久化的音画延迟（换集复用同一值；load 不重置 delay）。
    controller.setDelayMs(_delayMs);
    // TODO-2837：副字幕独立调轴同步应用（null = 跟随主字幕，controller 侧回退）。
    controller.setSecondaryDelayMs(_secondaryDelayMs);
    controller.setPauseAtSubtitleEnd(_asbConfig.pauseAtSubtitleEnd);
    // TODO-559: 远端断点保存——远端无 DB 行，按 bookUid 落 prefs（原为 null 不存）。
    controller.onPositionWrite =
        _isRemote ? _persistRemotePosition : _persistPosition;
    if (!mounted) {
      if (_controller == null) controller.dispose();
      _pendingController = null; // BUG-772：在途结束（页已卸载），清标记
      return;
    }
    controller.removeListener(_syncWindowAspectRatioLock);
    controller.addListener(_syncWindowAspectRatioLock);
    _attachControllerChapterListener(controller);
    // 标题先推给响应式 notifier，让全屏路由顶栏（不随页面 setState 重建）也跟上（BUG-120）。
    _titleNotifier.value = title;
    // 音量控件显示真相源对齐 controller 实际音量（换集复用同一 controller，TODO-377/438）。
    _syncVolumeDisplay(controller.volume);
    final bool clipExportSourceChanged = _currentVideoPath != videoPath;
    setState(() {
      if (clipExportSourceChanged) _clearClipExportState();
      _controller = controller;
      _pendingController = null; // BUG-772：首开成功，清在途标记（防 dispose 误取消）
      _hasChapters = controller.chapters.isNotEmpty;
      _title = title;
      _failed = false;
      _failReason = null;
      _missingResource = false;
      _missingRow = null;
      _currentVideoPath = videoPath;
      // BUG-939：换了视频源（含换集）→ 上一视频的字幕轨枚举缓存作废，清空并复位加载态
      // + 缓存 key，避免面板停留在「字幕」分类时残留上一集的字幕轨行，下次打开按新路径重枚举。
      if (clipExportSourceChanged) {
        _subtitleMenuSources = const <SubtitleSource>[];
        _subtitleMenuLoading = false;
        _subtitleMenuSourcesPath = null;
        // BUG-1861：导入档登记同样按视频源作用域，换源一并清空（换集后上一集下载的
        // 档案不该继续挂在新集的字幕轨列表里）。
        _importedSubtitleSources = const <SubtitleSource>[];
      }
      // externalSubtitlePath 即持久化值：外挂路径 / `embedded:<n>` / `off:`（显式关闭
      // 哨兵，TODO-818）都按原样写进 _currentSubtitleSource 供菜单高亮。内嵌自动加载
      // （externalSubtitlePath==null）时当前选中由 _currentSubtitleSource 保留（菜单
      // 切换时再写）。
      _currentSubtitleSource = externalSubtitlePath ?? _currentSubtitleSource;
      // TODO-1276/1297：首开时页级加载态保持到「首帧解码出画且缓冲结束」
      // （[isReadyForFirstPaint]）再让位给 media_kit——快路径（本地文件 load 返回时
      // 常已出画且不缓冲）此处即 true、立即挂载 [Video]；慢路径（仍在缓冲 / 首帧未就绪）
      // 保持 false，由下面 [_armFirstFramePromotion] 的宽高 + 缓冲监听在真正就绪时翻真，
      // 杜绝「进度条已缓冲但还在加载」的 media_kit 第二个圈。换集（`!isInitialVideoOpen`）
      // 不改动，维持既有行为。
      if (isInitialVideoOpen) {
        _videoReadyToShow = controller.isReadyForFirstPaint;
      }
    });
    // BUG-839：快路径（本地文件 load 即出画）就绪后触发「换集保持全屏」的重进全屏
    // （仅 initialFullscreen 新页生效；慢路径由 [_promoteVideoReady] 触发）。
    if (isInitialVideoOpen && _videoReadyToShow) {
      _scheduleInitialFullscreenIfNeeded();
    }
    if (isInitialVideoOpen && !_videoReadyToShow) {
      // load() 已返回但首帧尚未解码出画：进入「准备」阶段，页级加载态保持到首帧
      // 就绪，而非立刻把画面让给 media_kit 触发第二个缓冲圈（TODO-1276）。
      _setLoadingPhase(_VideoLoadPhase.preparing);
      _armFirstFramePromotion(controller);
    }
    _syncControllerChapterAvailability(controller);
    // TODO-669：建立 / 重置进度条 hover 缩略图预览（桌面本地文件实时取帧；远端流 /
    // 移动端降级）。在 _currentVideoPath 更新后调，按新路径绑离屏取帧器。
    _setupThumbnailPreview(videoPath);
    _focusOwnership.reclaimAfterFrame(FocusReclaimCause.contentReady);
    // BUG-370：视频就绪后重申沉浸隐藏系统栏（移动端）。沉浸模式在 initState 只申一次，
    // 而**远端视频**要先 await 网络流地址 + 下字幕才 load，controller 就绪得晚——若
    // immersiveSticky 在等待期被系统 / 用户触屏临时唤回导航栏，首个带进度条的帧会读到
    // 非零 MediaQuery.viewPadding.bottom（[_videoBottomSystemInset]），把进度条 / 字幕
    // 整体抬高（用户报「远端进度条偏高、字幕被顶高显大」；本地 load 快、过了这个窗口故
    // 正常）。在 controller 就绪即重隐导航栏，让 inset 回零、几何归位。对称惠及本地远端、
    // 不碰 BUG-184 的 inset 几何（导航栏真可见时进度条仍正确避让）。桌面 no-op。
    unawaited(_applyVideoImmersiveMode());
    _syncWindowAspectRatioLock();

    // 视频就绪后预热查词浮层（BUG-094）：seed 一个常驻隐藏热 WebView，全程复用，
    // 查词不再每次冷加载白屏。放成功分支（缺书/错误态不预热，无视频无需查词）。
    _seedWarmPopup();
    // TODO-301/BUG-264: fill the favorited-sentence cache once on video
    // open so the bottom subtitle overlay's favorite star
    // ([_isCueFavorited] reads [_favoritedVideoSentences]) shows for
    // already-favorited cues even before the subtitle list is ever opened.
    unawaited(_refreshFavoritedCueCache());
    if (videoPath != null) {
      // TODO-011: large REMUX containers can spend many seconds demuxing text
      // embedded subtitles on the first switch. Start the shared cache fill
      // only after playback has opened so UI/video startup is not blocked.
      unawaited(prewarmEmbeddedSubtitleCache(videoPath));
      unawaited(_loadDanmakuForVideo(videoPath));
      // 视频内嵌字体（对齐 mpv）：抽 MKV attachment 字体注册进引擎，字幕按 ASS Fontname
      // 命中真实字体。仅本地 + 开「尊重 .ass 样式」时做；远端/无 ffmpeg/无附件静默降级。
      unawaited(_maybeLoadEmbeddedSubtitleFonts(videoPath));
    } else {
      unawaited(_loadDanmakuForVideo(null));
    }
    _prewarmNextEpisodeSubtitleCache();

    // 首次 load 建观看统计采集器；换片复用同一 controller 实例，已 attach 不重建。
    // 判据 [_bookRow] 非空 = 书架书（本地视频 + TODO-1157 流媒体书都有 VideoBooks 行）：
    // 流媒体书（YouTube 等）在本机播放同样计观看时长/字幕字数/看完标记（用户在 app 内
    // 看油管也是沉浸时间）。互联远端（无行，媒体归 host）保持不采集。
    if (_bookRow != null && _watchTracker == null) {
      final FushiDatabase db = appModel.database;
      _watchTracker = VideoWatchTracker(
        bookUid: widget.bookUid,
        // v92：观看时长 + 字幕字数走唯一时钟 StudyClock。BUG-2108：视频面时钟是
        // 显式记账——时长由 tracker 按「位置推进到首次覆盖的片内区间」推入，回放 /
        // 拖回 / 重看不计；切走仍在播就照常计时（不设前台门）。
        // 按视频稳定身份键控（v39：同名不同视频统计不再互串）。本地视频每集独立
        // 页面（pushReplacement 换集）→ widget.bookUid 恒为当前集。
        clock: StudyClock(
          database: db,
          mediaKind: kActivityMediaVideo,
          mediaKey: widget.bookUid,
          title: title,
          accrual: StudyAccrual.explicit,
          onWriteError: (Object e, StackTrace st) =>
              ErrorLogService.instance.log('StudyClock.write(video)', e, st),
        ),
        // 已看过的片内区间并集按视频身份持久化：次日重看同样不计（BUG-2108）。
        loadCoverage: () =>
            db.getPref(videoWatchCoveragePrefKey(widget.bookUid)),
        saveCoverage: (String json) =>
            db.setPref(videoWatchCoveragePrefKey(widget.bookUid), json),
        markCompleted: (String uid) =>
            db.markVideoCompleted(uid, DateTime.now()),
        onEpisodeCompleted: () async {
          if (!kMediaTrackingEnabled) return;
          await appModel.mediaTrackingService.recordVideoCompleted(
            bookUid: widget.bookUid,
            collectionId: widget.playlistCollectionId,
            episodeIndex: _currentEpisode,
            seriesCompleted:
                _episodes.isNotEmpty && _currentEpisode == _episodes.length - 1,
          );
        },
      )
        ..attach(controller)
        ..start();
    }

    // 恢复用户选过的音轨（含多集换集复用）：audioTracks 在 player open 后才填充，
    // 延迟一拍再读，按 id 匹配；找不到（轨不存在/未选过）就跳过保留 libmpv 默认。
    unawaited(_restoreAudioTrack(controller));
    // TODO-857 / TODO-1312：恢复用户选过的副字幕轨（Flutter overlay 副层 cue 流）。与主
    // 字幕独立，仅内嵌轨；其内部 _waitUntilSubtitleTracksReady 等轨就绪。
    unawaited(_restoreSecondarySubtitle(controller));
  }

  /// TODO-897 / BUG-805：本地视频资源缺失时弹中性对话框（资源位置变化 → 重新导入 /
  /// 删除条目 / 取消）。措辞中性、不诱导直删；删除走二次确认
  /// [_confirmMissingResourceDelete]。
  ///
  /// BUG-805 根因修复：旧「重新导入」是空操作（只 `nav.pop()` 退回视频库、不做任何
  /// 导入），用户点了看着「没反应」；真正能修复的「重新选择文件」重链动作却藏在
  /// 独立按钮里、且只对单视频显示。现在收敛成用户预期的两个真按钮——
  /// 「重新导入」= 真动作（[_reimportMissingResource]：单视频重链选文件、播放列表
  /// 打开导入对话框），「删除」= 删条目；不再有空操作 pop 与重复的「重新选择文件」。
  ///
  /// 误删缓解（Never-break-userspace 红线）：外接盘 / 网络盘未挂载时 `exists()` 也
  /// 返 false（误报缺失）。故①文案中性（「位置可能变化或磁盘未连接」），不预设是
  /// 「文件被删」；②「取消」是默认 / 主动作（停在缺失态，可重连磁盘后退页重进），
  /// 「删除」是次要、且本身再过一道 [video_delete_confirm] 二次确认；③播放列表
  /// （多集）单集缺失不提供删除（删除粒度只有整张 video book，删一整部太重），
  /// 只给「重新导入 / 取消」。
  Future<void> _promptMissingResource(String title) async {
    final VideoBookRow? row = _missingRow;
    // 仅单视频条目（非播放列表、非远端）提供「删除条目」；缺 row 也不提供删除。
    final bool canDelete = row != null && !_isPlaylist && !_isRemote;
    final _MissingResourceChoice? choice =
        await showAppDialog<_MissingResourceChoice>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(t.video_resource_missing_title),
        content: Text(t.video_resource_missing_message(title: title)),
        actions: <Widget>[
          // 取消 = 默认 / 主动作：不删任何东西，停在缺失态。
          TextButton(
            onPressed: () => Navigator.pop(ctx, _MissingResourceChoice.cancel),
            child: Text(t.dialog_cancel),
          ),
          // 重新导入 = 主修复动作（真动作，见 [_reimportMissingResource]）。
          TextButton(
            onPressed: () =>
                Navigator.pop(ctx, _MissingResourceChoice.reimport),
            child: Text(t.video_resource_missing_reimport),
          ),
          // 删除是次要动作（非默认、不染红强调），且后接二次确认。
          if (canDelete)
            TextButton(
              onPressed: () =>
                  Navigator.pop(ctx, _MissingResourceChoice.delete),
              child: Text(t.dialog_delete),
            ),
        ],
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case _MissingResourceChoice.reimport:
        await _reimportMissingResource(row);
      case _MissingResourceChoice.delete:
        await _confirmMissingResourceDelete(row!);
      case _MissingResourceChoice.cancel:
      case null:
        // 停在缺失态（不转圈）。可重连磁盘 / 移回文件后退页重进。
        break;
    }
  }

  /// BUG-805：缺失态「重新导入」的真实动作——替代旧的空操作 `nav.pop()`。
  ///
  /// - **单个本地视频**（非播放列表、非远端）：走重链 [_relinkMissingResource]——让
  ///   用户重新选真实文件、重写 `videoPath` 并原地重载，保留进度 / 字幕 / 音轨 / 倍速
  ///   等既有状态。这正是用户对「重新导入」的预期（重新指定这个视频的文件）。
  /// - **播放列表 / 其它**：打开与视频库共用的 [VideoImportDialog] 走真实导入流程，
  ///   导入成功后退回视频库（库内出现新条目）。至少是可见的真实动作，不再空转。
  Future<void> _reimportMissingResource(VideoBookRow? row) async {
    if (row != null && !_isPlaylist && !_isRemote) {
      await _relinkMissingResource(row);
      return;
    }
    final NavigatorState nav = Navigator.of(context);
    final String? importedBookUid = await showAppDialog<String>(
      context: context,
      builder: (_) => VideoImportDialog(repo: widget.repo),
    );
    if (!mounted) return;
    // 导入成功（拿到新 bookUid）→ 退回视频库让用户从库里打开新条目；取消则停在缺失态。
    if (importedBookUid != null) nav.pop();
  }

  /// TODO-1133：缺失的本地视频「重新选择文件」——重链 [VideoBookRow.videoPath] 到
  /// 用户新选的真实文件并持久化，然后原地重新载入播放（保留进度 / 字幕 / 音轨 / 倍速
  /// 等所有既有状态，只换物理文件路径）。
  ///
  /// 泛化（好品味）：对**任意**缺失的本地视频都提供此动作，不对 app cache 目录加特例
  /// 分支——cache 被系统清空只是「文件失联」的一个子集。
  ///
  /// 拾取复用 [pickRealFilePath]（TODO-1112 已建的统一真实路径拾取：安卓有全文件访问
  /// 时走真实路径浏览器拿 content 之外的绝对路径、不复制到 cache；桌面 / iOS 及安卓降级
  /// 走 file_picker）。不新造第二套文件通道。
  ///
  /// 只处理单视频（非播放列表、非远端）；调用点已用 canDelete 判据门控。
  Future<void> _relinkMissingResource(VideoBookRow row) async {
    final String? newPath = await pickRealFilePath(
      context: context,
      appModel: appModel,
    );
    if (newPath == null || newPath.isEmpty || !mounted) return;
    // 持久化新路径（只写 videoPath，进度 / 字幕 / 音轨 / 倍速等其它列不动，
    // updateLocalMediaPaths 用 Value.absent() 保持未触及）。
    await widget.repo.updateLocalMediaPaths(row.bookUid, videoPath: newPath);
    // 重读最新行（承载新 videoPath + 其它未变列），清缺失态后原地重新载入播放。
    final VideoBookRow? updated = await widget.repo.getByBookUid(row.bookUid);
    if (updated == null || !mounted) return;
    setState(() {
      _bookRow = updated;
      _missingResource = false;
      _missingRow = null;
      _failed = false;
      _failReason = null;
    });
    _showOsd(t.video_resource_relink_success, severity: ToastSeverity.success);
    await _loadSingle(updated);
  }

  /// 缺失态删除：二次确认后复用 repository 的完整删除 operation，DB 行、app-owned
  /// 资产回收与压缩处在同一维护门边界内；删完退回视频库。
  Future<void> _confirmMissingResourceDelete(VideoBookRow row) async {
    final NavigatorState nav = Navigator.of(context);
    final bool? confirmed = await showAppDialog<bool>(
      context: context,
      builder: (BuildContext ctx) => AlertDialog(
        title: Text(t.video_delete_title),
        content: Text(t.video_delete_confirm(title: row.title)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.dialog_cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              t.dialog_delete,
              style: TextStyle(color: Theme.of(ctx).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await widget.repo.deleteVideoBookAndReclaimAssets(row.bookUid);
    if (mounted) nav.pop();
  }

  void _handleEmbeddedSubtitleAutoLoad(
    DefaultEmbeddedSubtitleLoadResult result,
  ) {
    if (!mounted) return;
    if (result.status == DefaultEmbeddedSubtitleLoadStatus.loaded) {
      final SubtitleSource? source = result.source;
      if (source != null) {
        setState(() => _currentSubtitleSource = source.toPersistedValue());
      }
      return;
    }
    if (!result.shouldNotifyFailure) return;
    final String label = result.source?.label ?? t.video_menu_subtitle_track;
    _showOsd(
      t.video_subtitle_load_failed(label: label),
      severity: ToastSeverity.error,
    );
  }

  /// 位置持久化（controller 每秒至多一次回调）。
  ///
  /// 播放列表：把进度记到**当前集**的 [PlaylistEntry.positionMs] 并回写整段
  /// playlistJson（每集各记自己的进度，换集互不干扰）。单视频：写
  /// VideoBook.lastPositionMs，并镜像到 `video_remote_position_<uid>` +
  /// `video_remote_position_at_<uid>` prefs（TODO-816 断点②）。
  ///
  /// 镜像目的：host 本机播放此视频时，client 拉清单经 host 的 getVideoPosition 读的是
  /// prefs 键空间；若本机播放只写 lastPositionMs / playlistJson 不写 prefs，host 自看
  /// 进度就进不了同步读取键 → client 拿不到（用户报「服务端看了视频，客户端再看进度是
  /// 0」）。镜像后与远端 resume 路径（[_persistRemotePosition]）统一键空间。TODO-885：
  /// 播放列表也按集镜像到 `video_remote_position_<uid>#ep<N>`，让 client 按集恢复 host
  /// 自看进度（与远端剧集列表的按集 key 同源）。
  Future<void> _persistPosition(String uid, int posMs) async {
    final int clamped = posMs < 0 ? 0 : posMs;
    final int nowMs = DateTime.now().millisecondsSinceEpoch;
    // 统一合集 Phase 3：每集是独立 VideoBooks 行 → 恒单视频持久化（写该集自己的
    // lastPositionMs + 按集 0 镜像远端进度键）。播放列表不再靠 playlistJson 存每集进度。
    await widget.repo.updatePosition(uid, posMs);
    await appModel.prefsRepo
        .setPref(videoRemotePositionEpisodePrefKey(uid, 0), clamped);
    await appModel.prefsRepo
        .setPref(videoRemotePositionEpisodeAtPrefKey(uid, 0), nowMs);
  }

  void _prewarmNextEpisodeSubtitleCache() {
    // 有下一集且其路径已知（本地）时后台预热其内嵌字幕缓存。远端集 path 为空（跳过）。
    final int cur = _currentEpisode;
    if (_episodes.length <= 1 || cur < 0 || cur >= _episodes.length - 1) return;
    final String path = _episodes[cur + 1].path;
    if (path.isEmpty || path == _lastPrewarmedEpisodePath) return;
    _lastPrewarmedEpisodePath = path;
    unawaited(prewarmEmbeddedSubtitleCache(path));
  }

  String _safeFileName(String input) =>
      input.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');

  String _remoteSubtitleTempFileName(String videoId, String? hostFileName) {
    final String fallback = 'hibiki_remote_${_safeFileName(videoId)}.srt';
    if (hostFileName == null || hostFileName.trim().isEmpty) return fallback;
    final String baseName = p.basename(hostFileName.trim());
    if (subtitleFormatForPath(baseName) == null) return fallback;
    final String stem = _safeFileName(p.basenameWithoutExtension(baseName));
    final String safeStem = stem.isEmpty ? _safeFileName(videoId) : stem;
    return 'hibiki_remote_$safeStem${p.extension(baseName)}';
  }

  /// 翻转锁定 / 沉浸模式（TODO-101；锁屏按钮 / Shift+L 快捷键 / 常驻解锁按钮共用）。
  ///
  /// 进入：抑制 media_kit 控制条对鼠标 hover / 点击的响应（[_buildVideoControlsInner]
  /// 里 gate `AdaptiveVideoControls` 的指针），顶/底栏按钮不再弹；查词与快捷键不受影响。
  /// 退出：恢复控制条响应，并 [_pokeControlsVisible] 立刻把控制条唤回一次（给用户「已解锁」
  /// 的即时反馈，且 poke 在解锁后才放行）。可见性走 [_immersiveLocked]（[ValueNotifier]，
  /// 全屏路由也生效）。
  void _toggleImmersiveLock() {
    final bool next = !_immersiveLocked.value;
    _clearRailHover();
    _immersiveLocked.value = next;
    // 翻转后把视频左侧锁 / 解锁按钮唤回一次（TODO-126）：进入沉浸即露出解锁口、退出沉浸
    // 即露出锁按钮，给用户即时反馈；随后照常 2s 淡出。
    _pokeLockButton();
    if (next) {
      _showOsd(t.video_immersive_locked, icon: Icons.lock_outline);
      // 锁定后 media_kit 控制条不再弹（指针被 IgnorePointer 挡），镜像同步收起、字幕
      // 落回用户位置基线（无控制条可遮挡，不需避让；TODO-129）。
      // _markControlsVisible(false) 在锁态分支里会同时 _setCursorHidden(true)（TODO-318）。
      _markControlsVisible(false);
    } else {
      _showOsd(t.video_immersive_unlocked, icon: Icons.lock_open_outlined);
      // 解锁瞬间把控制条唤回（poke 在 _immersiveLocked 复位后才放行），让用户立刻
      // 看到顶/底栏回来、确认已退出沉浸模式。光标也同步唤回（即时反馈，TODO-318）。
      _setCursorHidden(false);
      _pokeControlsVisible();
    }
  }

  VideoImmersiveMode get _videoImmersiveMode => appModel.videoImmersiveMode;

  // 「指针控制」门控（控制条按钮 / 滚轮 / 右键菜单等触摸/鼠标发起的完整控制）：
  // 沉浸锁定态仅 full 模式放行，防止误触。
  bool get _immersiveAllowsFullControls =>
      !_immersiveLocked.value || _videoImmersiveMode == VideoImmersiveMode.full;

  // 「快捷键」门控（键盘 / 手柄 / 裸空格发起的播放动作）：full 或 shortcutAndLookup
  // （快捷键+查词）放行。与 [_immersiveAllowsFullControls] 分离，使 shortcutAndLookup
  // 能在挡住触摸误触的同时放行显式快捷键输入。
  bool get _immersiveAllowsShortcuts =>
      !_immersiveLocked.value ||
      _videoImmersiveMode == VideoImmersiveMode.full ||
      _videoImmersiveMode == VideoImmersiveMode.shortcutAndLookup;

  // 触摸双击左右区 seek：沉浸锁定态仅 full 模式放行。shortcutAndLookup 不放行触摸
  // 跳转（跳转改由快捷键完成），故这里不含 shortcutAndLookup。
  bool get _immersiveAllowsDoubleTapSeek =>
      !_immersiveLocked.value || _videoImmersiveMode == VideoImmersiveMode.full;

  bool get _immersiveAllowsLookup =>
      !_immersiveLocked.value ||
      _videoImmersiveMode == VideoImmersiveMode.full ||
      _videoImmersiveMode == VideoImmersiveMode.shortcutAndLookup ||
      _videoImmersiveMode == VideoImmersiveMode.lookupOnly;

  // 键盘 / 手柄 / 裸空格快捷键统一门控：仅在 [_immersiveAllowsShortcuts] 时执行。
  void _runWhenImmersiveAllowsShortcuts(VoidCallback action) {
    if (!_immersiveAllowsShortcuts) return;
    action();
  }

  @override
  void dispose() {
    // BUG-2043：加载中就被退出（ESC / 系统返回）而还没压上全屏路由 → 接管来的原生
    // 全屏由本页亲自退，不能把窗口留在「原生全屏、栈上无全屏路由」的悬空态。
    _releaseHandedOverNativeFullscreen();
    if (Platform.isWindows) {
      WindowsImeSpaceChannel.clearHandler(this);
      // Abnormal route teardown must never leave the app frame hidden. The
      // normal fullscreen exit releases this owner only after HWND restoration.
      FushiWindowsTitleBar.setContentFullscreen(
        owner: this,
        enabled: false,
      );
    }
    WidgetsBinding.instance.removeObserver(this);
    // BUG-2105：进程级显示态（系统栏回调 / 横屏锁 / macOS 交通灯）统一在
    // [_releaseVideoDisplayClaim] 里按所有者记账还原——本页不是最后一个持有者
    // （换集期间新页已认领）就不得还原，否则会把新页刚设好的显示态掰掉。
    _releaseVideoDisplayClaim();
    final ExitFlushCallback? exitFlush = _exitFlushCallback;
    if (exitFlush != null) {
      ExitFlushRegistry.instance.unregister(exitFlush);
      _exitFlushCallback = null;
    }
    _volumePersistDebounce?.cancel();
    unawaited(_flushPersistedVideoVolume());
    _speedPersistDebounce?.cancel();
    unawaited(_flushPersistedVideoSpeed());
    // 先把根 Overlay 浮层 entry 摘除/释放，再 clear 浮层栈：entry 一旦移除就不会再被
    // 根 Overlay 重建 _buildPopupOverlay，杜绝销毁期用失效 State 重建浮层（退视频红屏）。
    final OverlayEntry? entry = _popupOverlayEntry;
    if (entry != null) {
      removeAndDisposeOwnedOverlayEntry(entry);
      _popupOverlayEntry = null;
    }
    _popup.clear();
    _volumeDisplay.dispose();
    _watchTracker?.dispose();
    _watchTracker = null;
    // TODO-1276：撤销首帧就绪监听 + 兜底定时器（回调读 _controller，须在 dispose 前摘）。
    _firstFramePromoteTimer?.cancel();
    _firstFramePromoteTimer = null;
    _controller?.removeListener(_promoteVideoReadyOnFirstFrame);
    _controller?.removeListener(_syncWindowAspectRatioLock);
    _detachControllerChapterListener();
    _controller?.setOnCompleted(null);
    unawaited(_clearWindowAspectRatioLock());
    // TODO-057: 退出播放器还原屏幕亮度——把进页快照写回（iOS 系统级亮度），未
    // 取过快照时 Android 侧设回「跟随系统」(-1)。防止把用户系统亮度永久留在拖动后值。
    unawaited(_brightness.restore(previous: _enterBrightness));
    // TODO-099 / BUG-973 / BUG-2105：方向允许态与 macOS 交通灯的还原已并入
    // [_releaseVideoDisplayClaim]（dispose 开头调用，按所有者记账），此处不再各自还原。
    _clearClipExportState();
    // TODO-669：销毁缩略图预览（作废在途取帧 + 销毁离屏 Player + 释放末帧）。
    _disposeThumbnailPreview();
    // BUG-772：首开在途 controller（尚未赋给 _controller）主动 dispose，触发 loadToken++
    // 让在途 load() 的 _isCurrentLoad 判据翻假、干净放弃后续原生下发，杜绝在已离开页面
    // 上把 libmpv/WGC 完整拉起再拆的 GPU churn。identical 守卫避免与 _controller 二次
    // dispose 同一实例（首开成功后 _pendingController 已置 null，二者不会同时非空同指）。
    if (_pendingController != null &&
        !identical(_pendingController, _controller)) {
      _pendingController!.dispose();
    }
    _pendingController = null;
    _controller?.dispose();
    _videoFocusNode.dispose();
    _titleNotifier.dispose();
    // TODO-364：先摘控制条可见性派生监听，再 dispose 各 notifier（监听回调读多个 notifier，
    // 顺序错会在 dispose 后回调里触碰已释放对象）。
    _mediaKitControlsVisible
        .removeListener(_applyControlsVisibilityFromMediaKit);
    _immersiveLocked.removeListener(_applyControlsVisibilityFromMediaKit);
    _videoSidePanel.removeListener(_applyControlsVisibilityFromMediaKit);
    _videoControlPopover.removeListener(_applyControlsVisibilityFromMediaKit);
    _subtitleListVisible.removeListener(_applyControlsVisibilityFromMediaKit);
    _episodeListVisible.removeListener(_applyControlsVisibilityFromMediaKit);
    _videoControlEditMode.removeListener(_applyControlsVisibilityFromMediaKit);
    // BUG-1798：与上面六个门控同批摘监听（顺序同理——回调读多个 notifier，先摘再 dispose）。
    _lookupOverlayActive.removeListener(_applyControlsVisibilityFromMediaKit);
    _lookupOverlayActive.dispose();
    _subtitleListVisible.dispose();
    _subtitleSearchRequests.dispose();
    _episodeListVisible.dispose();
    _videoSidePanel.dispose();
    _controlPopoverHideTimer?.cancel();
    _videoControlPopover.dispose();
    _videoControlEditMode.dispose();
    _controlLayoutNotifier.dispose();
    _customActionBindingsNotifier.dispose();
    _immersiveLocked.dispose();
    _lockButtonHideTimer?.cancel();
    _lockButtonVisible.dispose();
    _lockButtonHovered.dispose();
    _osdTimer?.cancel();
    _osdNotifier.dispose();
    _longPressSpeedBadge.dispose();
    _autoAdvanceCountdownTimer?.cancel();
    _autoAdvanceCountdownNotifier.dispose();
    _levelHudTimer?.cancel();
    _levelHudNotifier.dispose();
    _blackFlickerNoticeNotifier.dispose();
    _mediaKitControlsVisible.dispose();
    _restartHideTimerSignal.dispose();
    _videoControlsVisible.dispose();
    _railHovered.dispose();
    _cursorHidden.dispose();
    super.dispose();
  }

  /// 退出视频 / 退全屏的销毁期保护（BUG-121）。根 Overlay 的查词浮层 entry 跨路由生存，
  /// 比本 State 活得久；路由 pop 当帧本 State 先 `deactivate`，随后**同帧 layout 阶段**
  /// 根 Overlay 的 [LayoutBuilder] 仍会重建 entry → 内层经 `appModel`(ref.read) / `mixinTheme`
  /// (Theme.of) 做祖先查找，而 deactivated element 上的查找不安全 → 抛异常红屏。
  /// `OverlayEntry.remove()` 在 build/layout 阶段会延迟到 post-frame，摘除来不及拦本帧；
  /// 故置位此标志，让浮层 builder 在销毁期一律空渲染（[_buildPopupOverlay]）。
  bool _overlayInert = false;

  @override
  void deactivate() {
    _overlayInert = true;
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    // GlobalKey 重挂等重新激活场景：恢复正常渲染，下次 build 的 _syncPopupOverlay 重建浮层。
    _overlayInert = false;
  }

  /// 本页键盘焦点的单一所有者：所有「把焦点还给 media_kit [Video]」的回收都走
  /// 它，判据集中在 [_canOwnVideoFocus]。
  ///
  /// 取代原先散在 29 处的 `_refocusVideo()` / `_reclaimVideoFocusIfOwned()` 手写
  /// 补丁——那些补丁每个都自带一套略有出入的门控，漏一处就是一类「快捷键失灵」
  /// 用户报告（如字幕波形对轴弹窗关闭后没有归还）。覆盖层一律用
  /// [PageFocusOwnership.guardOverlay] 包裹，异常/取消路径也不会把键盘搁浅。
  late final PageFocusOwnership _focusOwnership = PageFocusOwnership(
    node: _videoFocusNode,
    canOwn: _canOwnVideoFocus,
  );

  /// 「视频此刻应当持有键盘」的统一判据。
  ///
  /// 前提：[_videoFocusNode] 必须仍在焦点树上。全屏期间窗口侧 controls 经
  /// [VideoControlsFocusGate] 卸载，保证退全屏后节点被窗口侧重新 attach——否则
  /// 节点是孤儿时任何请求都只会静默挂起（这正是 TODO-040 修掉的根因）。
  bool _canOwnVideoFocus(FocusReclaimCause cause) {
    if (!mounted) return false;
    // 播放器未就绪时 [Video] 尚未挂载、节点未 attach，请求焦点无意义。
    if (_controller == null) return false;
    // 查词浮层活动期间不抢焦点（用户在查词，不应让空格控制视频）。浮层栈**全空**
    // 是由关栈汇聚点 [_popNestedPopupAt] 以 [FocusReclaimCause.popupDismissed]
    // 通知的，那一刻栈已空，故该 cause 不受本门控约束。
    if (cause != FocusReclaimCause.popupDismissed && _hasVisiblePopup) {
      return false;
    }
    // 手柄重设计 P3：可导航浮层面板（剧集轨 / 侧栏）打开期间焦点归 PanelFocusScope
    // 所有，页面不抢。少了这一条就是纯回归：面板开着时画面仍可点，用户点一下画面
    // （reclaim(gesture)）或查完词关浮层（reclaim(popupDismissed)）焦点就被拽回页面
    // 节点，而 PanelFocusScope 只在 visible 边沿认领一次、不复领 ⇒ 面板仍开着，
    // _handleVideoGamepadButton 继续让 dpad/A 给焦点兜底，于是 dpad 既进不了面板、
    // 也不再调音量/seek —— 比 P3 之前更差（之前至少还能调音量）。面板关闭时通知先
    // 翻假，归还路径不受影响。字幕列表不在集内（BUG-2040）：它不领焦点，列表开着时
    // 页面照常收回焦点。
    if (_videoNavigablePanelOpen) return false;
    // 生命周期回前台是全局回调，本页上方可能压着设置对话框 / 菜单 / 导入遮罩
    // （键盘所有者路由：窗口模式=本页路由，全屏期间=全屏路由）。此时抢焦点会
    // 夺走对话框的键盘（Never break userspace）——那些覆盖层各自的 guardOverlay
    // 返回点会归还。
    if (cause == FocusReclaimCause.appResumed) {
      final ModalRoute<Object?>? owner = _videoFullscreenActive
          ? _videoFullscreenRoute
          : ModalRoute.of(context);
      if (owner != null && !owner.isCurrent) return false;
    }
    return true;
  }

  /// media_kit 控制条自动隐藏时长，与两端控制主题的 `controlsHoverDuration` 同源（2s）。
  static const Duration _videoControlsHoverDuration = Duration(seconds: 2);

  /// 控制条 / 侧边锁按钮 / 浮动 rail 的显隐淡入淡出时长（TODO-435），单一真相源。
  /// 与 media_kit 的 `controlsTransitionDuration` 默认对齐：桌面 150ms、移动 300ms。
  /// [_desktopControlsTheme] / [_mobileControlsTheme] / [_buildSideLockButton] /
  /// [_buildVideoSideActionRail] 都读它，将来调一处全部跟随，不再各写各的 200ms。
  /// eink 主题下经 [einkSafeDuration] 归零（墨水屏连续重绘=残影），控制条与全部
  /// 跟随者一次改单点全部生效（UI 巡检 PR-4）。
  Duration get _videoControlsTransitionDuration => einkSafeDuration(
        context,
        _isDesktopVideoControls
            ? const Duration(milliseconds: 150)
            : const Duration(milliseconds: 300),
      );

  /// 当前是否有承载光标操作的 overlay 打开（设置 / 音轨等浮层 [_videoSidePanel]，或
  /// 字幕跳转列表 [_subtitleListVisible]，TODO-329）。有 overlay 时光标不该被沉浸 /
  /// 自动隐藏定时吃掉（用户要在 overlay 上操作）；纯沉浸锁（无 overlay）静止超时仍隐藏
  /// 画面光标（BUG-258）。
  ///
  /// BUG-1798：**查词浮层栈**（根 Overlay 的 [_popupOverlayEntry]）此前漏在集外。它是本页
  /// 最需要光标的覆盖层——用户要在弹窗里点词、点发音、拖 resize 把手、滚正文——但查词期间
  /// 控制条照常 2s 自动淡出，`visible=false && !_hasVideoOverlay` 于是把 [_cursorHidden]
  /// 置真，[_buildCursorOverlay] 铺一层 `cursor: none` 盖满视频区。查词浮层子树除右下角
  /// resize 把手外不声明任何 cursor（`dictionary_popup_layer.dart` 唯一一处 MouseRegion），
  /// cursor 解析下穿到该层 → **鼠标悬在弹窗上时 OS 光标直接消失**。media_kit fork 侧的
  /// `hideMouseOnControlsRemoval`（`controls_theme.part.dart`）同样只排除了字幕列表 / 选集
  /// 列表，对查词弹窗也是漏项，两层 `none` 叠加。搜索中（[DictionaryPopupController.isSearchingUi]）
  /// 与已出结果同等对待：dismiss barrier 在搜索期就已挂上（见 [shouldShowLookupDismissBarrier]），
  /// 那一刻起指针语义就归浮层，光标不能消失。
  bool get _hasVideoOverlay =>
      _videoSidePanel.value != null ||
      _videoControlPopover.value != null ||
      _subtitleListVisible.value ||
      _episodeListVisible.value ||
      _videoControlEditMode.value ||
      _lookupOverlayActive.value;

  /// 「查词浮层此刻占着指针」的门控真值（BUG-1798）。
  ///
  /// 与 [_hasVideoOverlay] 其余五项一样是 [ValueNotifier]——[_applyControlsVisibilityFromMediaKit]
  /// 的输入必须全是可订阅的 notifier，否则值变了没有任何东西触发重跑派生（光标策略会停在
  /// 上一次的结论上）。真值由 [_syncPopupOverlay] 单向推入（那里是浮层栈变化的唯一收口），
  /// getter 一律读这里，不再各处直接读 [_popup]，避免两个真相源漂移。
  ///
  /// 判据与 [shouldShowLookupDismissBarrier] 同源：**有可见浮层或正在搜索**即为真。barrier
  /// 在搜索期就已挂上并接管全屏命中，那一刻起光标就该归浮层管。
  final ValueNotifier<bool> _lookupOverlayActive = ValueNotifier<bool>(false);

  /// 手柄重设计 P3：可用 D-pad 逐行浏览的两类面板任一打开（剧集轨 / 侧栏）。与
  /// [_hasVideoOverlay] 刻意不同集：控件 popover 与控制条编辑模式不是「行浏览」
  /// 表面，D-pad 在那里仍按 video scope 解析。
  ///
  /// 字幕列表（[_subtitleListVisible]）**刻意不在集内**（BUG-2040）：它不领焦点
  /// （subtitle.part.dart 里没包 PanelFocusScope），列表开着时焦点仍在画面上，裸方向键
  /// / D-pad 照常是 seek / 音量而不是在列表里选行。本 getter 是键盘 resolver 让位
  /// （[resolveVideoKeyboardShortcut]）、手柄让位（[_handleVideoGamepadButton]）与
  /// 页面拒抢焦（[_canOwnVideoFocus]）三条门的共同真相源，这里少一项三条门一起放开；
  /// 若把字幕列表加回来而不同时包 PanelFocusScope，就是「dpad 既进不了列表也不调音量」。
  bool get _videoNavigablePanelOpen =>
      _episodeListVisible.value || _videoSidePanel.value != null;

  // BUG-371：字幕跳转列表是 **push-aside** 侧栏（[_videoWithSubtitlePanel] 的
  // `Row[Expanded(video), 面板列]`，TODO-314），把画面挤窄到左侧、**不遮挡**叠在画面上
  // 的左 / 右浮动操作 rail。故强压制门控**不含**字幕列表显隐——开字幕列表时左 / 右控制
  // 按钮应继续可见可用（用户：「字幕列表只是侧边栏，左边的按钮应该还可以换出」）。仅真正盖在
  // 控制条之上的 overlay（[_videoSidePanel] 设置 / 音轨 / 倍速等）和编辑态才压制。
  bool get _videoSideActionRailStronglySuppressed =>
      _videoSidePanel.value != null || _videoControlEditMode.value;

  /// 是否当前用 media_kit 桌面控制条（仅桌面三端有 hover 自动隐藏语义）。
  bool get _isDesktopVideoControls {
    switch (Theme.of(context).platform) {
      case TargetPlatform.windows:
      case TargetPlatform.macOS:
      case TargetPlatform.linux:
        return true;
      case TargetPlatform.android:
      case TargetPlatform.iOS:
      case TargetPlatform.fuchsia:
        return false;
    }
  }

  /// seek bar hover 回调（TODO-669）：fork 桌面 seek bar 把 hover 比例（轨道内宽
  /// 权威值，null = onExit）回调到这里。仅桌面 theme 接此回调（移动端触屏无 hover）。
  ///
  /// 转发到取帧调度器：[fraction]==null → 隐藏浮层（作废在途取帧）；否则即时更新
  /// 浮层位置 + 时间戳，桌面本地文件（[_thumbnailPreview] 已建）取帧、远端流 /
  /// 取帧器缺失则 timestampOnly。调度器为 null（理论上桌面恒有，防御）时静默忽略。
  void _onSeekBarHover(double? fraction) {
    final VideoThumbnailPreviewController? preview = _thumbnailPreview;
    if (preview == null) return;
    // 远端流无离屏取帧器 → desktop:false 让调度器走 timestampOnly（只显时间戳）。
    final bool canGrab = _thumbnailGrabber != null;
    preview.request(fraction, desktop: canGrab);
  }

  /// 在 [load] 成功后建立 / 重置缩略图预览（TODO-669）。仅桌面构造调度器；本地
  /// 文件视频额外构造离屏取帧器（实时取帧），远端流不构造取帧器（走 timestampOnly）。
  /// 视频路径变（换集）时销毁旧取帧器 + 调度器、按新路径重建。
  void _setupThumbnailPreview(String? videoPath) {
    if (!_isDesktopVideoControls) {
      // 移动端：完全不创建（零新增运行时、零行为变化）。
      _disposeThumbnailPreview();
      return;
    }
    // 路径未变且已建好 → 复用（避免每次 load 丢掉已经攒起来的帧缓存）。
    final bool pathChanged = _thumbnailGrabber?.videoPath != videoPath;
    if (_thumbnailPreview != null && !pathChanged) return;

    _disposeThumbnailPreview();

    // 远端流（http/s）或无本地路径 → 不建取帧器（调度器仍建，走 timestampOnly）。
    final bool isLocalFile = videoPath != null &&
        !_isRemote &&
        Uri.tryParse(videoPath)?.scheme != 'http' &&
        Uri.tryParse(videoPath)?.scheme != 'https';
    final OffscreenVideoFrameGrabber? grabber =
        isLocalFile ? OffscreenVideoFrameGrabber(videoPath: videoPath) : null;
    _thumbnailGrabber = grabber;
    _thumbnailPreview = VideoThumbnailPreviewController(
      grabber: grabber != null
          ? grabber.grab
          // 无取帧器（远端流）：取帧函数恒返回 null，调度器据此 timestampOnly。
          : (int _) async => null,
      durationMsProvider: () => _controller?.durationMs ?? 0,
      // 已取过的位置同步命中，零延迟出图、不闪 spinner（回扫 / 抖动的常态路径）。
      cachedFrameLookup: grabber?.cachedFrame,
      // 首次 hover 就探明取帧可不可用并暖一格缓存，别让这段算进第一张图的等待。
      onWarmUp: grabber == null ? null : () => unawaited(grabber.warmUp()),
    );
  }

  void _disposeThumbnailPreview() {
    _thumbnailPreview?.dispose();
    _thumbnailPreview = null;
    _thumbnailGrabber?.dispose();
    _thumbnailGrabber = null;
  }

  /// 查词浮层顶部「当前字幕句」动作行（覆写 [DictionaryPageMixin.buildPopupHeaderFor]）。
  /// 仅顶层（[index] == 0，真查词那句）显示；嵌套递归查词层（index > 0）不属于某条字幕句，
  /// 返回 null。
  ///
  /// 四个动作都作用于**当前查词那句**（[_lastLookupCue]）：重播本句 / 跳到此句 / 复制 /
  /// 收藏。前三个与字幕跳转列表行尾的 ▶ ⧉ 同源（[VideoPlayerController.skipToCue] /
  /// 剪贴板），用户在浮层里不必先关浮层再去字幕列表找回那一行。
  ///
  /// 没有锚定 cue（无字幕轨 / gap 中查词）时重播与跳转无处可去，置灰而不是隐藏——
  /// 按钮位置恒定，不会因句而异地跳来跳去。复制仍可用（回落整句文本）。
  /// 星标实心=已收藏，空心=未收藏，点击 toggle。
  @override
  Widget? buildPopupHeaderFor(int index) {
    if (index != 0) return null;
    final ThemeData theme =
        appModel.overrideDictionaryTheme ?? Theme.of(context);
    final bool hasCue = _lastLookupCue != null && _controller != null;
    return Material(
      type: MaterialType.transparency,
      child: Container(
        // TODO-1187：header 底边框已移出 —— 分隔线改由 [DictionaryPopupLayer] 在
        // 「有词条」时才画（无结果/搜索中悬空的多余横线消除）。
        padding: const EdgeInsets.symmetric(vertical: 4),
        // BUG-826（视频端）：[DictionaryPopupLayer._buildTopBar] 只保证 header 拿到
        // 「左簇 A−/A+ 与右簇关闭之间的有界宽」，**收缩由内容侧负责**——reader 音频行
        // 早就用 [FittedBox]`(scaleDown)` 做了，视频端此前只有 1 颗星标（36px）永远放
        // 得下，加到 4 颗后必溢出：中段可用宽 = 弹窗宽 − 108（左 36×2 + 右 36），
        // 4 颗 [FushiIconButton]（icon 20 + padding gap 8 ×2 = 36）合计 144，
        // 而弹窗宽下限 [kLookupPopupMinWidth] = 250 ⇒ 142 < 144，实测
        // 「RenderFlex overflowed by 2.0 pixels」。界面缩放 <1 时更窄。
        // `mainAxisSize: min` 让行取按钮总宽（有限内在宽），FittedBox 才量得到并等比缩小。
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: <Widget>[
              FushiIconButton(
                key: const Key('video_popup_replay_cue_button'),
                tooltip: t.video_subtitle_replay,
                icon: Icons.replay,
                size: 20,
                enabled: hasCue,
                onTap: _replayLookupCue,
              ),
              FushiIconButton(
                key: const Key('video_popup_jump_to_cue_button'),
                // 复用字幕跳转列表行尾 ▶ 的图标与文案：同一动作同一表征，不造第二套说法。
                tooltip: t.video_subtitle_list_jump,
                icon: Icons.play_arrow,
                size: 20,
                enabled: hasCue,
                onTap: _jumpToLookupCue,
              ),
              // 复制后按钮就地切成 ✓ / 「已复制」——OSD 画在视频区，弹窗里看不见。
              CopyFeedback(
                builder: (
                  BuildContext _,
                  bool copied,
                  VoidCallback markCopied,
                ) {
                  return FushiIconButton(
                    key: const Key('video_popup_copy_sentence_button'),
                    tooltip: copied ? t.copied : t.copy,
                    icon: copied ? Icons.check : Icons.content_copy_outlined,
                    size: 20,
                    onTap: () {
                      if (_copyLookupSentence()) markCopied();
                    },
                  );
                },
              ),
              FushiIconButton(
                key: const Key('video_favorite_sentence_button'),
                // tooltip 用「句子收藏」（已有 i18n），描述按钮职责；不复用 toast 文案
                // favorite_added/removed——那是动作结果提示，做静态 tooltip 会反向误导。
                tooltip: t.collection_sentence,
                icon: _currentVideoSentenceIsFavorited
                    ? Icons.star
                    : Icons.star_border,
                size: 20,
                enabledColor: _currentVideoSentenceIsFavorited
                    ? theme.colorScheme.primary
                    : null,
                onTap: _toggleFavoriteSentenceForVideo,
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 关闭查词浮层栈中第 [index] 层及其之上（点遮罩 / 返回 / 浮层滑动·Esc 都汇聚到此）。
  ///
  /// 关栈后若整栈已空且本次是因查词暂停了播放，则恢复播放——这是恢复播放的唯一汇聚点，
  /// 覆盖所有关闭路径（BUG-072）。
  /// True while any popup layer is actually visible (the persistent warm slot,
  /// BUG-094, sits hidden in the stack between lookups so it never counts).
  bool get _hasVisiblePopup => _popup.hasVisiblePopup;

  /// Index of the top-most visible popup layer, or -1 when only the hidden warm
  /// slot remains.
  int get _topVisiblePopupIndex => _popup.lastVisibleIndex;

  /// TODO-1052：查词浮层 barrier 上「水平拖过阈关一层」。判轴/累积/阈值全部收在
  /// [LookupDismissBarrier] 内（BUG-1757：横拖不再进手势竞技场，判轴改为可单测的
  /// 显式规则）。过阈关一层 =
  /// [_popNestedPopupAt]（[_topVisiblePopupIndex]），与光标 B/Esc / 返回键逐层退回
  /// 同语义，不清整栈（清整栈仍是点真空白的 tap）。
  void _dismissTopNestedPopup() {
    _popNestedPopupAt(_topVisiblePopupIndex);
  }

  /// Shift-悬停在 barrier 上「连续切换查词」的节流锚 + 去重键（TODO-756a，与阅读器
  /// [ReaderFushiPage.onDismissBarrierHover] 同语义）。[Offset.zero] / 空句 / -1 表示
  /// 未进入（松开 Shift / 离开时复位），下次按 Shift 进入即触发。
  Offset _barrierHoverLastPos = Offset.zero;
  String _barrierHoverLastSentence = '';
  int _barrierHoverLastGrapheme = -1;

  /// 桌面 Shift-鼠标悬停在查词浮层 dismiss barrier 上「连续切换查词」（BUG-861，与阅读器
  /// [ReaderFushiPage.onDismissBarrierHover] 同语义）。
  ///
  /// 根因：首次查词打开浮层后，全屏 dismiss barrier（[_buildPopupOverlay]）盖在字幕之上，
  /// 字幕盒自己的 [MouseRegion.onHover]（[VideoSubtitleOverlay] 的 `_handleShiftHover`）被
  /// barrier 遮住收不到 hover——barrier 是此时**唯一**还能接 hover 的入口。阅读器早已在
  /// barrier 外层挂 `Listener(onPointerHover: onDismissBarrierHover)` 转发换词，视频页此前
  /// 只有 `GestureDetector`（无 hover 转发），故「按住 Shift 连续切换查词」在首弹后失效。
  ///
  /// 门控与字幕盒 `_handleShiftHover` 一致（TODO-756a/b）：按住 Shift 或开了「悬停即查词」
  /// 才换词；8px 平方阈值节流（与 `_kShiftHoverThresholdPx` 同构）避免每像素抖动都查；
  /// 命中同一字符（同句同 grapheme）短路去重，避免同词反复 `replaceStack` 闪烁 / 刷 FFI。
  /// 换词经 [_handleSubtitleLookupTap] → [_lookupAt]（`replaceStack: true` 复用热槽无缝替换）。
  void _onDismissBarrierHover(PointerHoverEvent event) {
    // BUG-1798：先滤掉[_pokeControlsVisible]派发的**合成** hover。它不是用户的鼠标：位置恒为
    // [_videoControlsContext]（整个视频区）的几何中心，设备是固定的 [_syntheticHoverDevice]。
    // 浮层一开，全屏 opaque 的 dismiss barrier 就接管了命中测试，合成 hover 再也到不了
    // media_kit 自己的 MouseRegion（poke 本该续命控制条，此时已必然哑火），却**全量落进本
    // 回调**被当成真实鼠标消费，三处污染：
    // ① `_lastGlobalPointerPos` 被写成画面正中 → BUG-880 的「静止光标 + 按 Shift 立即换词」
    //    改在画面中心反查，用户光标下的词查不到；
    // ② 未按 Shift 时下面那条分支把 `_barrierHoverLastPos/Sentence/Grapheme` 三个去重键清零
    //    → 用户鼠标在**同一个字**上再抖一下就被判成新词，`_lookupAt(replaceStack: true)` 整栈
    //    替换，正在看的弹窗内容被换掉、滚动位置丢失；
    // ③ 按住 Shift / 开了「悬停即查词」时更直接：合成位置若命中字幕字符就立即换词。
    // 且 [_handleSubtitleHover] 自己就调 [_pokeControlsVisible]，构成 hover→poke→hover 自激。
    // 同页 [_handleVideoControlsHover] 早就用同一判据滤过合成事件（controls_visibility.part.dart），
    // 本路径与它不对称纯属遗漏——这里补齐，语义即「合成事件不代表用户指针，不参与任何指针记账」。
    if (_isSyntheticControlsHover(event)) return;
    // BUG-880：浮层打开时 barrier 盖住一切、页面根 Listener 收不到 hover，故在此持续更新
    // 最后指针位置，让「静止光标 + 按 Shift」在浮层已开时也能立即换词（在 Shift 门控之前，
    // 未按 Shift 也照常记录）。
    _lastGlobalPointerPos = event.position;
    if (!HardwareKeyboard.instance.isShiftPressed &&
        !ReaderFushiSource.instance.hoverAutoLookup) {
      // 未按 Shift 且未开「悬停即查词」：复位节流锚 + 去重键，使下次按 Shift 进入即触发。
      _barrierHoverLastPos = Offset.zero;
      _barrierHoverLastSentence = '';
      _barrierHoverLastGrapheme = -1;
      return;
    }
    final double dx = event.position.dx - _barrierHoverLastPos.dx;
    final double dy = event.position.dy - _barrierHoverLastPos.dy;
    if (_barrierHoverLastPos != Offset.zero &&
        dx * dx + dy * dy <
            VideoFushiPage.barrierHoverThresholdPx *
                VideoFushiPage.barrierHoverThresholdPx) {
      return;
    }
    _barrierHoverLastPos = event.position;
    // 命中反查复用与 barrier 点击换词（[_onDismissBarrierTap]）同一命中句柄，全局坐标契约
    // 一致（[PointerHoverEvent.position] 已是全局坐标）。
    final SubtitleCharHit? hit = _subtitleHitTester.hitTest(event.position);
    // 非嵌套（仅顶层可见）且命中画面字幕字符才换词——与点 barrier 换词的
    // [shouldSwitchWordOnBarrierTap] 同门控（嵌套态换词会误把整栈 replaceStack 替换掉）。
    if (hit != null &&
        VideoFushiPage.shouldSwitchWordOnBarrierTap(
          topVisibleIndex: _topVisiblePopupIndex,
          hitSubtitle: true,
        )) {
      _handleSubtitleHoverLookup(
          hit.sentence, hit.graphemeIndex, hit.charRect, hit.cue);
      return;
    }
    // BUG-879/881：画面字幕没命中，再反查**字幕列表侧栏**——barrier 全屏盖在推挤式侧栏上，
    // 抢走 hover，故 Shift 悬停列表里下一个词若不在此反查就连续换不了词（与 barrier tap 的
    // 列表兜底 [_onDismissBarrierTap] 对称）。复用 barrier hover 的「同句同 grapheme」去重键
    // （cue.text 作句 key）避免同词反复 replaceStack 闪烁。
    final SubtitleListHit? listHit =
        _subtitleListHitTester.hitTest(event.position);
    if (listHit != null) {
      if (listHit.cue.text == _barrierHoverLastSentence &&
          listHit.graphemeIndex == _barrierHoverLastGrapheme) {
        return;
      }
      _barrierHoverLastSentence = listHit.cue.text;
      _barrierHoverLastGrapheme = listHit.graphemeIndex;
      _handleSubtitleListLookup(
        listHit.cue,
        listHit.graphemeIndex,
        listHit.charRect,
      );
    }
  }

  /// 悬停查词的统一去重入口（BUG-861）：字幕盒自己的 [MouseRegion]（`onCharHover` →
  /// `_handleShiftHover`）与浮层 barrier（[_onDismissBarrierHover]）两条 hover 路径都汇聚
  /// 到这里。首弹后 barrier 盖不住的字符可能被两条路径同时命中，用「同句同 grapheme」短路
  /// 去重，保证一次移动只换一次词（否则同词双 `replaceStack` 会闪烁 / 重复刷 FFI）。点击查词
  /// （`onCharTap` → [_handleSubtitleLookupTap]）不经此入口，故重复点同字仍照常重查。
  void _handleSubtitleHoverLookup(
    String sentence,
    int graphemeIndex,
    Rect charRect,
    AudioCue? cue,
  ) {
    if (sentence == _barrierHoverLastSentence &&
        graphemeIndex == _barrierHoverLastGrapheme) {
      return;
    }
    _barrierHoverLastSentence = sentence;
    _barrierHoverLastGrapheme = graphemeIndex;
    _handleSubtitleLookupTap(sentence, graphemeIndex, charRect, cue);
  }

  /// BUG-094: seed one persistent, hidden warm popup slot on open so its
  /// [DictionaryPopupWebView] cold-loads popup.html/JS/CSS ONCE while idle and
  /// is reused warm for every lookup — no per-lookup cold-load (white flash) in
  /// the video player. Low-memory mode keeps no warm slot (disposes on close).
  void _seedWarmPopup() {
    if (!mounted) return;
    // 成功路径调用，此刻 AppModel 必已初始化 → 安全读取真实 lowMemory 设入 controller
    // （seedWarmSlot/dismissAt 据此决定是否保留热槽）。
    _popup.lowMemory = appModel.lowMemoryMode;
    setState(() => _popup.seedWarmSlot());
    _syncPopupOverlay();
  }

  /// 查词浮层打开时，点根 Overlay 全屏 dismiss barrier 的处理：**非嵌套**（只有顶层可见）
  /// 时若点到同句另一个字幕字符则**切换查词**（对该字符走 [_lookupAt]：已暂停故不重复暂停、
  /// 不清 [_pausedForLookup]，`replaceStack` 替换可见浮层）→ 保持暂停、弹窗切到新词；否则
  /// （命中空白/控件区，或处于嵌套态）[_popNestedPopupAt] 逐层关并据 [_pausedForLookup]
  /// 恢复播放。门控判据见 [VideoFushiPage.shouldSwitchWordOnBarrierTap]。
  ///
  /// 根因 1（BUG-???，用户报）：barrier 全屏盖在字幕之上、抢走点击 → 单层查词点同句第二个
  /// 词只会关栈+恢复播放。barrier 先反查字幕字符命中即可「点词换词、保持暂停」。
  /// 根因 2（TODO-758 / BUG-410）：嵌套查词时底部字幕仍清晰渲染、字符矩形持续绑定，点第
  /// 2+ 个窗外面常落在字幕文字上 → 无条件反查会 `replaceStack` 把整栈替换掉（顶层窗没关而是
  /// 被换成新词）。故反查仅在 [_topVisiblePopupIndex] <= 0（非嵌套）时生效。
  void _onDismissBarrierTap(Offset globalPos) {
    // TODO-758 / BUG-410: 「点字幕换词」仅在非嵌套（只有顶层可见 / 仅剩隐藏热槽）时保留——
    // 单层查词点同句另一个字符切换查词是合理交互。嵌套态（存在父层）下底部字幕仍清晰渲染、
    // 其字符矩形持续绑定，点第 2+ 个窗外面常落在字幕文字上；若仍走反查会 replaceStack 把整栈
    // 替换掉（顶层窗没关而是被换成新词）。故仅当 [shouldSwitchWordOnBarrierTap] 为真才反查。
    //
    // BUG-910：反查用 `exactOnly: true`（只在点**落在字形矩形内**才算命中）。查词的胖手指裙边
    // 容差（TODO-971 半字宽 ≈18px + BUG-825 描边级垂直边）本服务「点小字好点中」，但 barrier
    // 判「关闭 vs 切词」若也吃这套 halo，字幕行周围约 18px 空白会被误判成「命中字幕」→ 把「点
    // 空白想关闭继续看」当成「切词重查」，暂停冻结字幕下反复重查同一句（用户报「点空白一直
    // 重复查一个词」）。exactOnly 让空白 halo 落回 dismiss+续播（恢复 BUG-410 备注承诺的「落
    // 纯空白正常」），点在字上仍切词。悬停换词 / Shift 查词是查词意图，仍用宽容差（不改）。
    final SubtitleCharHit? hit =
        _subtitleHitTester.hitTest(globalPos, exactOnly: true);
    if (VideoFushiPage.shouldSwitchWordOnBarrierTap(
      topVisibleIndex: _topVisiblePopupIndex,
      hitSubtitle: hit != null,
    )) {
      _handleSubtitleLookupTap(
          hit!.sentence, hit.graphemeIndex, hit.charRect, hit.cue);
      return;
    }
    // BUG-874：底部字幕没命中，再反查**字幕列表侧栏**——barrier 全屏盖在推挤式侧栏之上、
    // 抢走点击，故点列表里下一个词若不在此反查就只会关掉浮层。命中某行某字符即切换查词
    // （[_handleSubtitleListLookup] → [_lookupAt] 的 `replaceStack`，保持浮层与暂停）。这是
    // 列表行文本明确点在某字符上的显式换词意图，不吃底部字幕那条的嵌套门控
    // （[shouldSwitchWordOnBarrierTap]）——replaceStack 本就重置整栈，等价于一次新查词。
    //
    // BUG-910：反查同样用 `exactOnly: true`——列表面板占右半屏、行文本满宽，若吃半字格裙边
    // 容差，点面板行距 / 行尾空白想关闭浮层会被误判成「切列表里的词」反复重查（用户报「点半
    // 个屏幕外的空白一直重复查一个词」；截图里查到的词根本不在画面字幕里、只在列表面板里）。
    // exactOnly 只在点**落在列表字形盒内**才切词，点面板空白落回下方 dismiss+续播。
    final SubtitleListHit? listHit =
        _subtitleListHitTester.hitTest(globalPos, exactOnly: true);
    if (listHit != null) {
      _handleSubtitleListLookup(
        listHit.cue,
        listHit.graphemeIndex,
        listHit.charRect,
      );
      return;
    }
    // TODO-834（反转 TODO-720 / BUG-403）：点**所有弹窗外**的真空白 = 一次性清整栈
    // （[_popNestedPopupAt(0)] → controller.dismissAt(0) 保留隐藏热槽 BUG-092，并在关栈
    // 汇聚点触发会话收尾：恢复播放 / 清草稿 / 收回焦点）。落在字幕文字上的反查门控
    // [shouldSwitchWordOnBarrierTap]（TODO-758 / BUG-410）保持不变，已在上方先判。
    _popNestedPopupAt(0);
  }

  /// BUG-1592：[cue] 是被点字符**所属的那条 cue**，直接当查词/制卡锚点透传
  /// （`overrideCue`）。此前不传，锚点靠 [resolveVideoLookupAnchorCue] 去主字幕流按播放
  /// 位置猜——主字幕关掉只开副字幕时主流为空，锚点恒 null，制卡区间塌成 `0..0`（句子音频
  /// 空 + 封面抽第 0 秒的片头黑帧）；主副同开时点副字幕还会错锚到主字幕那句。
  void _handleSubtitleLookupTap(
    String sentence,
    int graphemeIndex,
    Rect charRect,
    AudioCue? cue,
  ) {
    if (!_immersiveAllowsLookup) return;
    unawaited(_lookupAt(sentence, graphemeIndex, charRect, overrideCue: cue));
  }

  void _popNestedPopupAt(int index) {
    debugPrint(
      '[video-lookup] dismiss popup index=$index '
      'visibleTop=$_topVisiblePopupIndex',
    );
    // Hide-and-keep the warm slot instead of clearing it, so its loaded WebView
    // survives for the next lookup (BUG-094): closing index 0 hides the warm
    // slot + drops children; closing a child drops from there up.
    // controller.dismissAt 已实现「index 0 保留并隐藏热槽 / 否则裁该层及之上」；
    // 这里额外清掉热槽 WebView 的选区（原 UI 副作用）。
    if (index <= 0 &&
        _popup.entries.isNotEmpty &&
        _popup.entries.first.isWarmSlot) {
      _popup.entries.first.webViewKey.currentState?.clearSelection();
    }
    setState(() => _popup.dismissAt(index));
    final bool stackEmpty = !_hasVisiblePopup;
    // videoEnterCaret：光标跟随弹窗栈——还有可见层则跟到新顶层；全关且光标在弹窗
    // 面上则回落字幕主面（环留在原字符上，保持暂停继续选词）。
    if (_videoCaret.active) {
      if (!stackEmpty) {
        _videoCaret.onDictionaryStackChanged();
      } else if (_videoCaret.onPopup) {
        _videoCaret.setSurface(CaretSurface.video);
      }
    }
    if (VideoFushiPage.shouldResumeAfterLookupDismiss(
      // "Effectively empty" = no visible popup; the hidden warm slot doesn't
      // block resume.
      stackEmpty: stackEmpty,
      pausedForLookup: _pausedForLookup,
      // 光标仍激活 = 用户还在选词，暂停由光标会话接管（退出光标时恢复）。
      caretHoldsPause: _videoCaretActive,
    )) {
      _pausedForLookup = false;
      unawaited(_controller?.play());
    }
    // 浮层栈全空 = 查词结束，键盘所有权回到视频。浮层 WebView（原生控件）/遮罩
    // 夺走的焦点不会自动归还；这里与「恢复播放」共用同一个关栈汇聚点，覆盖点遮罩 /
    // 返回键 / Esc / 滑动全部关闭路径（TODO-040 ①「点了外面后快捷键失灵」的查词
    // 浮层分支）。
    if (stackEmpty) {
      // TODO-270 E：整条查词浮层栈关闭 = 一次「查词会话」结束，丢弃未制卡的多句草稿
      // （避免下次查词带着上次没用掉的累积句）。制卡成功已在 onMineEntry/onUpdateEntry
      // 清过，这里兜住「攒了几句但没制卡就关掉」的情况（与 reader onAllPopupsDismissed
      // 同语义；视频用 DictionaryPageMixin 没有该钩子，故在关栈汇聚点清）。点同句另一
      // 字 / 字幕条另一句切换查词走 _lookupAt(replaceStack)，栈不空，草稿不被清。
      _miningDraft.clear();
      _focusOwnership.reclaim(FocusReclaimCause.popupDismissed);
      // BUG-861：查词会话结束，复位悬停切词去重键，使关掉浮层后再次悬停同一字符能重查。
      _barrierHoverLastPos = Offset.zero;
      _barrierHoverLastSentence = '';
      _barrierHoverLastGrapheme = -1;
    }
  }

  Widget _buildNestedPopupLayer(int index, Size screen) {
    return buildNestedPopupLayer(
      index: index,
      screen: screen,
      controller: _popup,
      onPush: (String text, Rect rect) {
        // 递归查词不属于某条字幕句：制卡例句仍用最近一次字幕句。
        // [rect] 已是中和后浮层坐标（父浮层 pos + WebView 局部 rect 叠出，均在同一
        // 真实视口空间），直接复用，无需任何缩放换算。
        // TODO-1190: return the matched char count so the mixin highlights the
        // clicked word in the parent card.
        return pushNestedPopup(
          query: text,
          selectionRect: rect,
          controller: _popup,
          autoRead: true,
        );
      },
      onPop: _popNestedPopupAt,
    );
  }

  /// 把查词浮层栈同步到根 Overlay：栈非空且未插入则插入、栈空则移除、否则
  /// `markNeedsBuild` 刷新。在 [build] 的 post-frame 调，使根 Overlay 总是反映
  /// 当前栈（[DictionaryPageMixin] 的 push/pop 都走 `setState` → 重 build → 本同步）。
  ///
  /// 用根 Overlay（而非本页 `Stack`）的原因：media_kit 全屏是推到根 navigator 的独立
  /// 路由，本页 `Stack` 会被全屏路由盖住；根 Overlay 浮在所有路由之上，窗口/全屏统一。
  void _syncPopupOverlay() {
    if (!mounted) return;
    // BUG-1798：把浮层栈的「占着指针」真值推给门控 notifier。这里是栈 push/pop/搜索态变化的
    // 唯一收口（[DictionaryPageMixin] 各路径都 setState → 重 build → post-frame 调本方法），
    // 故也是唯一写入点。[ValueNotifier] 自带同值去重，每帧调用不会产生多余通知；值真变时其
    // 监听（[_applyControlsVisibilityFromMediaKit]）重跑光标策略，弹窗一开光标即恢复可见。
    _lookupOverlayActive.value = _hasVisiblePopup || _popup.isSearchingUi;
    if (_popup.entries.isEmpty) {
      final OverlayEntry? entry = _popupOverlayEntry;
      if (entry != null) {
        removeAndDisposeOwnedOverlayEntry(entry);
        _popupOverlayEntry = null;
      }
      return;
    }
    if (_popupOverlayEntry != null) {
      _popupOverlayEntry!.markNeedsBuild();
      return;
    }
    final OverlayState? overlay = Overlay.maybeOf(context, rootOverlay: true);
    if (overlay == null) return;
    final OverlayEntry entry = OverlayEntry(builder: _buildPopupOverlay);
    _popupOverlayEntry = entry;
    overlay.insert(entry);
  }

  /// 根 Overlay 里的查词浮层栈内容：透明遮罩（点击关栈）+ 各层 [DictionaryPopupLayer]。
  ///
  /// 根 Overlay 在 [FushiAppUiScale] 的 `FittedBox` 之内＝缩放后的小画布，浮层 WebView
  /// 在此栅格化再被拉大会字糊（BUG-051）。用 [FushiAppUiScaleNeutralizer] 把整棵浮层
  /// 子树中和回真实视口尺寸、净缩放=1，WebView 按原生密度渲染＝清晰。中和后 `screen`
  /// （内层 [LayoutBuilder] 约束）即真实视口，与 [_lookupAt] 直接传入的 `localToGlobal`
  /// 屏幕 rect 同坐标系（净变换=1），定位自洽。
  Widget _buildPopupOverlay(BuildContext overlayContext) {
    // 这个 entry 插在根 Overlay（跨路由生存，比本页 State 活得久）。退出视频 / 退全屏
    // 时根 Overlay 可能在本 State 已 deactivate/dispose 之后重建此 entry——彼时再读
    // State 的 `context` / `appModel`(ref.read) 会抛异常 → Flutter ErrorWidget 红屏
    // （用户报「退视频红屏」）。故：State 失效就不渲染浮层；Theme 也改用 entry 自己的
    // `overlayContext`（与本 entry 同寿命）而非借用更短命的 State `context`。
    if (!mounted || _overlayInert) return const SizedBox.shrink();
    return FushiAppUiScaleNeutralizer(
      child: Theme(
        data: appModel.overrideDictionaryTheme ?? Theme.of(overlayContext),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            // LayoutBuilder 的 builder 在 layout 阶段运行，可能晚于本 State 的 deactivate
            // （退视频/退全屏同帧）；此刻读 appModel(ref.read)/mixinTheme 会做失效祖先查找
            // 抛异常红屏（BUG-121）。销毁期标志置位则空渲染兜底。
            if (!mounted || _overlayInert) return const SizedBox.shrink();
            final Size screen = Size(
              constraints.maxWidth,
              constraints.maxHeight,
            );
            return Stack(
              // BUG-135: 隐藏热槽被停到屏幕右外侧（buildNestedPopupLayer），默认
              // Clip.hardEdge 会把它裁掉 → 原生 WebView 可能不再渲染、丢失预热。用
              // Clip.none 让它在屏外照常栅格化保持温热（不盖任何控件）。
              clipBehavior: Clip.none,
              children: <Widget>[
                // Dismiss barrier while a popup is visible OR a lookup is
                // searching (搜索→就绪才显示：搜索期浮层还没显示，barrier 仍要拦点击
                // 并支持点同句另一字切换查词)。仅剩隐藏热槽时不拦，放行给视频。
                //
                // BUG-1327：对话框期间（[lookupPopupHiddenByDialog]）连 barrier 一起撤，
                // 否则它把落在对话框上的点击吃掉、还判成「点弹窗外面」清整栈。判据收口在
                // [shouldShowLookupDismissBarrier]（三个根 Overlay 表面共用）。
                if (shouldShowLookupDismissBarrier(
                  hasVisiblePopup: _hasVisiblePopup,
                  isSearching: _popup.isSearchingUi,
                  hiddenByDialog: lookupPopupHiddenByDialog,
                ))
                  Positioned.fill(
                    // BUG-861：barrier 转发 hover——首弹后 barrier 盖住字幕，字幕盒
                    // MouseRegion 收不到 hover，此处是「按住 Shift 连续切换查词」唯一
                    // 还能接 hover 的入口（与 reader onDismissBarrierHover 同语义）。
                    //
                    // BUG-1757：barrier 收口成唯一原语 [LookupDismissBarrier]，
                    // 横拖走它内部不入竞技场的 Listener 旁路 + 可单测的判轴。
                    child: LookupDismissBarrier(
                      // onTapDismiss 带坐标：点到同句另一个字幕字符时切换查词并保持
                      // 暂停，点其它区域才 dismiss + 恢复（见 _onDismissBarrierTap）。
                      onTapDismiss: _onDismissBarrierTap,
                      // TODO-1052：水平拖过阈关一层（_popNestedPopupAt，逐层关）。
                      onSwipeDismiss: _dismissTopNestedPopup,
                      swipeEnabled:
                          ReaderFushiSource.instance.enableSwipeToClose,
                      sensitivity:
                          ReaderFushiSource.instance.dismissSwipeSensitivity,
                      onPointerHover: _onDismissBarrierHover,
                      // BUG-1995：指针在**浮窗之外**按侧键时唯一还能接到事件的地方
                      // （barrier 命中行为 opaque，页面根 Listener 收不到）。
                      onNonPrimaryButtonDown: onDismissBarrierNonPrimaryButton,
                    ),
                  ),
                // 搜索期加载占位卡（与书内同观感：就绪才显示真正浮层）。
                if (_popup.isSearchingUi && _popup.pendingRect != null)
                  buildPopupLoadingPlaceholder(
                    rect: _popup.pendingRect!,
                    screen: screen,
                  ),
                for (int i = 0; i < _popup.entries.length; i++)
                  _buildNestedPopupLayer(i, screen),
                ...buildParkedRealmLayers(screen: screen, controller: _popup),
              ],
            );
          },
        ),
      ),
    );
  }

  /// 制卡（覆写 [DictionaryPageMixin.onMineEntry]）：在词典 [fields]（已含单词
  /// 发音 `{audio}`、例句字段等）基础上，注入视频专属上下文——当前帧截图
  /// coverPath（→`{book-cover}`）+ 当前字幕 cue 的音频片段（裁**当前选中音轨**）
  /// sasayakiAudioPath（→`{sentence-audio}`）+ 例句 sentence。复用现有 Anki 字段。
  /// 方法体搬到 [_VideoLookupMining] part（TODO-590 batch14），@override 留瘦转发器。
  @override
  Future<MinePopupResult> onMineEntry(Map<String, String> fields) =>
      _onMineEntryImpl(fields);

  /// TODO-270 D：覆盖「最新制的那张卡」（[noteId]）。视频页覆写了 [onMineEntry] 绕过
  /// mixin，故覆盖路径也在本页复用视频媒体链路（GIF 封面 + 区间音频），按 id 真实
  /// 覆盖而非删旧建新（[_mineVideoCard] 的 `updateNoteId` 分支）。覆盖同样吃多句合一
  /// 草稿（合并卡=一张卡，天然吃覆盖，与 270-D 正交）；覆盖成功后清空草稿。
  /// 方法体搬到 [_VideoLookupMining] part（TODO-590 batch14），@override 留瘦转发器。
  @override
  Future<MinePopupResult> onUpdateEntry(
    int noteId,
    Map<String, String> fields,
  ) =>
      _onUpdateEntryImpl(noteId, fields);

  /// 退出/返回汇聚点：前台浮层还开着就先关一层（逐级退出），一层都没开才发起落库
  /// 并 pop 路由。[PopScope]、Escape 快捷键、手柄 B、以及**屏幕上的返回箭头
  /// 按钮**（[_activateVideoControlItem] 的 [VideoControlItem.back]）共用同一份层级表
  /// [_dismissTopForegroundLayer]，四条通道行为一致。
  ///
  /// BUG-2119：落库与 pop 之间**不再有 await**。此前是 `await flushPosition()` 再
  /// `nav.pop()`，等于把「能不能离开视频页」押在一次数据库写入成功上——写入抛错
  /// 或永不完成（连接被一条 `SQLITE_BUSY` 后未 reset 的写语句毒化，之后每次 COMMIT
  /// 都抛「SQL statements in progress」）时，四条退出通道一起失灵，用户被锁在页里。
  /// 现在走 [exitAfterPersist]：同步发起落库（drift 请求已排进队列，后续页面读同一
  /// 行排在它之后），随即无条件 pop，落库失败只记 [ErrorLogService]。
  ///
  /// 「返回箭头也逐级退一层」是 BUG-1862 的**有意**取舍，不是顺带的副作用：收敛的意义
  /// 就是「返回上一级」只有一份语义，不为屏幕按钮再开第二套。用户可见变化：push-aside
  /// 字幕跳转列表打开时控制条与 rail 仍可见可用（BUG-371），此时点返回箭头**改前退出
  /// 视频页、改后先关字幕列表**。
  ///
  /// BUG-1862：此前本方法只关词典浮层，逐级退出的其余五层（控制布局编辑态 / 字幕跳转
  /// 列表 / 剧集列表 / 设置侧栏 / 沉浸锁）只写在 Escape 快捷键回调里，于是两条路径根本
  /// 不一致。而那份快捷键表装在 media_kit controls 子树内的 [CallbackShortcuts] 上
  /// （media_kit `material_desktop.dart`），本页自建的 overlay（[_buildVideoSidePanelOverlay]
  /// 等）在 controls builder 的 Stack 里是它的**兄弟**、不是后代——侧栏一打开就把键盘
  /// 焦点领进自己（`PanelFocusScope`），Esc 便绕过整张表冒泡到全局 back →
  /// `Navigator.maybePop` → 本页 [PopScope] → 本方法 → 直接 pop 整页。用户看到的就是
  /// 「设置侧栏开着按 Esc，视频页退了、侧栏没关」。Android 系统返回键与手柄 B 走同一条
  /// [PopScope] 路径，症状相同。层级判定收敛到 [_dismissTopForegroundLayer] 单点后，
  /// 键盘 / 系统返回 / 手柄三条输入通道共用同一份语义，不再各写一份。
  Future<void> _handleBackOrExit() async {
    if (_dismissTopForegroundLayer()) return;
    final NavigatorState nav = Navigator.of(context);
    final VideoPlayerController? controller = _controller;
    exitAfterPersist(
      persist: () => controller?.flushPosition() ?? Future<void>.value(),
      exit: nav.pop,
      onPersistError: (Object error, StackTrace stack) => ErrorLogService
          .instance
          .log('VideoFushiPage.exitFlushPosition', error, stack),
    );
  }

  /// 逐级退出的**唯一**层级表（BUG-1862）：从最前台到最后台关掉一层并返回 true；一层
  /// 都没开返回 false，调用方这才可以真正退全屏 / 退页。
  ///
  /// 顺序判据本身在纯函数 [topVideoForegroundLayer]（`video_foreground_layers.dart`）里，
  /// 可直接单测；本方法只负责「读页面状态 → 查表 → 执行对应关闭动作」，不再自带顺序。
  /// push-aside 字幕列表（TODO-314）、剧集列表（TODO-638）与侧栏是三条独立可见性，
  /// 分别关闭。控制按钮 popover（音量 / 倍速轻浮层）点击打开那次会被 pin 住常驻，
  /// 必须一并进表——漏掉它就是「pinned popover 开着按 Esc，页面退了、浮层还在」，
  /// 与 BUG-1862 的原始症状同形。
  bool _dismissTopForegroundLayer() {
    final VideoForegroundLayer? layer = topVideoForegroundLayer(
      hasVisibleDictionaryPopup: _hasVisiblePopup,
      controlEditActive: _videoControlEditMode.value,
      controlPopoverOpen: _videoControlPopover.value != null,
      subtitleListVisible: _subtitleListVisible.value,
      episodeListVisible: _episodeListVisible.value,
      sidePanelOpen: _videoSidePanel.value != null,
      immersiveLocked: _immersiveLocked.value,
    );
    switch (layer) {
      case null:
        return false;
      case VideoForegroundLayer.dictionaryPopup:
        _popNestedPopupAt(_topVisiblePopupIndex);
      case VideoForegroundLayer.controlEdit:
        _hideVideoControlEditOverlay(revealControls: false);
      case VideoForegroundLayer.controlPopover:
        _hideControlPopover();
      case VideoForegroundLayer.subtitleList:
        _toggleSubtitleJumpList();
      case VideoForegroundLayer.episodeList:
        _closeEpisodeList();
      case VideoForegroundLayer.sidePanel:
        _hideVideoSidePanel();
      case VideoForegroundLayer.immersiveLock:
        _toggleImmersiveLock();
    }
    return true;
  }

  /// 「点弹窗里的加号」的键盘入口（视频页）。阅读器有等价的
  /// [ShortcutAction.readerCreateCardFromPopup]（caret.part.dart），视频页此前完全没有，
  /// 是 app 内制卡快捷键最大的缺口。执行体与鼠标点击完全同源——回 WebView 点那颗
  /// `.mine-button`，复用它的三态（＋/✓/✓↩︎）、单飞门与查重逻辑，Dart 侧不另造制卡路径。
  void _mineFromTopPopup() {
    final int idx = _topVisiblePopupIndex;
    if (idx < 0) return; // 没有可见浮层：不消费，也没什么可制卡的
    final DictionaryPopupWebViewState? popup =
        _popup.entries[idx].webViewKey.currentState;
    if (popup == null) return;
    unawaited(popup.mineFirstVisibleEntry());
  }

  /// BUG-924：关掉当前顶层可见词典浮层（复用 [_handleBackOrExit] / [_onDismissBarrierTap]
  /// 同款逐层关调用，index 0 保留隐藏热槽 BUG-092）。键盘 / 手柄 / 裸空格三条输入通道在
  /// 浮层可见时统一调它先关浮层。
  void _dismissTopVisiblePopup() => _popNestedPopupAt(_topVisiblePopupIndex);

  /// BUG-1269：上面那三条输入通道全部走 Flutter 焦点，而词典浮层是**纯原生 WebView**
  /// ——点词后浮层就贴在光标旁，指针一落上去，键盘与鼠标事件就只存在于浮层 DOM 里，
  /// 这三条通道一条都收不到。于是「视频里关不掉词典」在浮层持焦时原样复发（BUG-924
  /// 只修好了 Flutter 持焦的那一半）。让浮层自己把这些输入交回来。
  @override
  ShortcutScope? get dictionaryPopupInputScope => ShortcutScope.video;

  /// 与 [guardVideoShortcutsWithPopupDismiss] 同语义：浮层可见时**任一**已映射的视频
  /// 快捷键都先关顶层浮层。故整份 video scope 都要转发——弹窗内动作
  /// （dictionaryPopup scope 的切词条 / 制卡）由 [dictionaryPopupInputSpecFor] 统一减掉，
  /// 不会被抢走，与守卫把制卡键排在守卫之外是同一条边界。
  @override
  Set<ShortcutAction> get dictionaryPopupForwardedActions => <ShortcutAction>{
        ...ShortcutAction.actionsForScope(ShortcutScope.video),
        // 「返回上一级」（默认 Esc / Alt+←）：浮层持焦时按它必须关浮层。它在
        // universal scope，不在 video 组里，漏掉就等于 BUG-1269 那半边重开。
        ShortcutAction.globalBack,
      };

  /// BUG-1995 的另一半：指针落在**浮窗矩形之外**按下鼠标非主键。
  ///
  /// 浮层可见时，那片区域被根 Overlay 的 [LookupDismissBarrier] 完全占住
  /// （`Positioned.fill` + 叶子 `ColoredBox`，命中行为 opaque），页面根的
  /// [Listener]（[_handleVideoPointerDown]）因此收不到任何指针事件——所以
  /// 「侧键压在浮窗上能关、把鼠标移开一点就关不掉」。这里把 barrier 上的那一半
  /// 接回**同一个**落地入口。
  ///
  /// 判据与弹窗表面那条路逐字相同：同一个 [dictionaryPopupInputSpec]（已减去
  /// dictionaryPopup scope 自己占用的按钮）、同一个 [dictionaryPopupPointerToken]
  /// 折 token、同一个 [onDictionaryPopupInputToken] 落地（含选词光标分流）。
  /// 两个表面共用一份判据，就不可能再出现「一半能用一半不能用」。
  ///
  /// 与弹窗表面天然互斥：barrier 只在弹窗矩形之外可命中（弹窗层在同一个 Stack 里
  /// 排在 barrier 之后＝更靠上），同一次按下不会两条路各触发一次。
  // 落地实现已上提到 [DictionaryPageMixin.onDismissBarrierNonPrimaryButton]：其余
  // 四个 barrier 宿主（阅读器基类 / 首页词典 / texthooker / 网页视频）此前都没接，
  // 症状同为「侧键压在浮窗上能关、移开一点就关不掉」。三行完全相同的实现留在各页 =
  // 下一个宿主照旧漏接，故收成一份，本页不再覆写。

  /// 视频的语义是「关**顶层**浮层」（逐层关，保留隐藏热槽 BUG-092），不是清整栈，
  /// 故不走基类默认的 `clearDictionaryResult()`，改用与守卫完全同一个执行体。
  @override
  bool onDictionaryPopupInputToken(String token) {
    // scope 未命中时函数内部回落 universal（「返回上一级」），与页面派发同口径。
    final ShortcutAction? action = resolveDictionaryPopupInputToken(
      registry: appModel.shortcutRegistry,
      token: token,
      scope: ShortcutScope.video,
    );
    if (action == null) return false;
    // videoEnterCaret：选词光标激活期不再「任一键先关浮层」（那会把正在手柄导航
    // 的弹窗关掉）；Enter=对光标查词/激活、Esc=光标语义退层，其余吞掉。
    if (_handleCaretPopupInputToken(action)) return true;
    _dismissTopVisiblePopup();
    return true;
  }

  /// TODO-1342：视频播放器动作回调集合的单一构造点。键盘
  /// （[buildVideoPlayerShortcutsFromRegistry]）与手柄（[_handleVideoGamepadButton]
  /// 经 [videoActionCallbacks]）共用同一份 [VideoPlayerShortcutActions]，保证两条输入
  /// 通道命中完全一致的执行体（含 [_runWhenImmersiveAllowsShortcuts] 沉浸门控与控制
  /// 条唤醒），不产生两套语义、不引入手柄专属特例分支。
  VideoPlayerShortcutActions _buildVideoShortcutActions(
    VideoPlayerController controller,
  ) {
    return VideoPlayerShortcutActions(
      togglePlayPause: () => _runWhenImmersiveAllowsShortcuts(
        () => unawaited(controller.playOrPause()),
      ),
      play: () => _runWhenImmersiveAllowsShortcuts(
        () => unawaited(controller.play()),
      ),
      pause: () => _runWhenImmersiveAllowsShortcuts(
        () => unawaited(controller.pause()),
      ),
      // Ctrl+←/→ = 上/下一句字幕（TODO-090）。**键盘方向键**语义：上一句太远时 Ctrl+←
      // 退化成回退 seekSeconds 秒（TODO-085，故 degradeFarCueToTimeSeek: true）；无 cue
      // 时也直接当回退键。下一句保持纯句子跳（无 cue 时前进 seekSeconds 秒）。
      // 底栏 / 手柄 / 双击的「上一句」按钮走 skipToPrevCueOrSeekBack 的默认（不退化，
      // 恒跳句，BUG-942）——按钮心智是「跳句」，不是方向键 seek。
      // 键盘 / 手柄跳句只**续命**控制条、不唤起（BUG-2030）：控制条本就在显示时连按跳句
      // 不该让它 2 秒消失（BUG-176 ②/BUG-215 的诉求），但它隐藏时按快捷键也不该把底栏弹
      // 出来 + 顶一次字幕（用户报「快捷键上下句字幕会弹出 OSC」）。两者的分界就是
      // [_keepControlsAliveIfVisible]。底栏按钮 / 双击那条路径仍走 _pokeControlsVisible
      // （见 [_skipCueAndPokeControls]）——那时用户的手就在控制条上。
      previousSubtitle: () {
        _runWhenImmersiveAllowsShortcuts(() {
          _keepControlsAliveIfVisible();
          unawaited(
            controller.skipToPrevCueOrSeekBack(
              seekSeconds: _asbConfig.seekSeconds,
              degradeFarCueToTimeSeek: true,
            ),
          );
        });
      },
      nextSubtitle: () {
        _runWhenImmersiveAllowsShortcuts(() {
          _keepControlsAliveIfVisible();
          // 无字幕时前进 seekSeconds 秒、有字幕时跳下一句，决策集中在
          // [skipToNextCueOrSeekForward]（与 previousSubtitle 的
          // skipToPrevCueOrSeekBack 对称，TODO-073）。
          unawaited(
            controller.skipToNextCueOrSeekForward(
              seekSeconds: _asbConfig.seekSeconds,
            ),
          );
        });
      },
      // 普通 ←/→ = 时间 seek（±seekSeconds 秒，TODO-090），与 J/A·I/D 同语义。
      seekBackward: () => _runWhenImmersiveAllowsShortcuts(() {
        _keepControlsAliveIfVisible();
        unawaited(controller.seekRelative(-_asbSeekMs));
      }),
      seekForward: () => _runWhenImmersiveAllowsShortcuts(() {
        _keepControlsAliveIfVisible();
        unawaited(controller.seekRelative(_asbSeekMs));
      }),
      toggleShaderCompare: () => _runWhenImmersiveAllowsShortcuts(
        () => unawaited(_toggleShaderCompare()),
      ),
      volumeUp: () => _runWhenImmersiveAllowsShortcuts(
        () => unawaited(_adjustVolume(_volumeStep)),
      ),
      volumeDown: () => _runWhenImmersiveAllowsShortcuts(
        () => unawaited(_adjustVolume(-_volumeStep)),
      ),
      toggleMute: () => _runWhenImmersiveAllowsShortcuts(
        () => unawaited(_toggleMute()),
      ),
      speedUp: () => _runWhenImmersiveAllowsShortcuts(
        () => unawaited(_adjustSpeed(_speedStep)),
      ),
      speedDown: () => _runWhenImmersiveAllowsShortcuts(
        () => unawaited(_adjustSpeed(-_speedStep)),
      ),
      resetSpeed: () => _runWhenImmersiveAllowsShortcuts(
        () => unawaited(_setSpeed(1.0)),
      ),
      // 手柄通道的按住临时倍速（键盘通道不经此表，见 _handleHoldSpeedKey）：
      // 手柄没有可靠的松开事件管线，退化成按一下开/再按恢复的翻转语义。
      toggleHoldSpeed: () => _runWhenImmersiveAllowsShortcuts(_toggleHoldSpeed),
      previousFrame: () => _runWhenImmersiveAllowsShortcuts(
        () => unawaited(controller.frameStep(forward: false)),
      ),
      nextFrame: () => _runWhenImmersiveAllowsShortcuts(
        () => unawaited(controller.frameStep(forward: true)),
      ),
      screenshot: () => _runWhenImmersiveAllowsShortcuts(
        () => unawaited(_saveScreenshot()),
      ),
      toggleFullscreen: () => _runWhenImmersiveAllowsShortcuts(() {
        final BuildContext? ctx = _videoControlsContext;
        if (ctx != null && ctx.mounted) {
          unawaited(_toggleVideoFullscreen(ctx));
        }
      }),
      // 'L' = 开/关字幕跳转列表（TODO-069）。
      toggleSubtitleList: () => _runWhenImmersiveAllowsShortcuts(
        _toggleSubtitleJumpList,
      ),
      // BUG-1907：Ctrl+F = 开字幕列表并聚焦搜索框。
      searchSubtitleList: () => _runWhenImmersiveAllowsShortcuts(
        _requestSubtitleListSearch,
      ),
      // Shift+L = 切换锁定 / 沉浸模式（TODO-101）。
      toggleImmersiveLock: _toggleImmersiveLock,
      // 'B' = 翻转字幕模糊（TODO-134：从内层独立 CallbackShortcuts 并入注册表）。
      toggleSubtitleBlur: () => _runWhenImmersiveAllowsShortcuts(
        () => unawaited(_toggleSubtitleBlur()),
      ),
      // TODO-840 Part B：Shift+B 循环遮蔽三态；H 开/关「隐藏主字幕」。
      cycleSubtitleObscure: () => _runWhenImmersiveAllowsShortcuts(
        () => unawaited(_cycleSubtitleObscure()),
      ),
      toggleSubtitleHide: () => _runWhenImmersiveAllowsShortcuts(
        () => unawaited(_toggleSubtitleHide()),
      ),
      // TODO-1382：Shift+G 循环副字幕遮蔽三态；Shift+H 开/关「隐藏副字幕」。
      cycleSecondarySubtitleObscure: () => _runWhenImmersiveAllowsShortcuts(
        () => unawaited(_cycleSecondarySubtitleObscure()),
      ),
      toggleSecondarySubtitleHide: () => _runWhenImmersiveAllowsShortcuts(
        () => unawaited(_toggleSecondarySubtitleHide()),
      ),
      toggleFavoriteSentence: () => _runWhenImmersiveAllowsShortcuts(
        () => unawaited(_toggleFavoriteCurrentCue()),
      ),
      replayCurrentSubtitle: () => _runWhenImmersiveAllowsShortcuts(
        () => unawaited(_replayCurrentCueAndKeepControls()),
      ),
      // 重播上一句（TODO-378，BUG-287，默认 Shift+R）：纯句子后退到上一条 cue 起点
      // 并播放（skipToPrevCue，不退化回退）。与「上一句字幕」(Ctrl+←) 区分——后者
      // gap 太远时按 BUG-185/TODO-085 退化时间 seek，是用户另一项有意设计，不动它。
      replayPreviousSubtitle: () => _runWhenImmersiveAllowsShortcuts(
        () => unawaited(_replayPreviousCueAndKeepControls()),
      ),
      // 内封章节上/下一章（TODO-424，默认 PageUp/PageDown）：seek 到相邻章起点，
      // 无章节时 controller no-op。与跳句同范式（BUG-2030）：只续命、不唤起；章节**面板**
      // 里点条目仍 poke（那是指针交互，见 [_buildChapterSidePanel]）。
      previousChapter: () => _runWhenImmersiveAllowsShortcuts(() {
        _keepControlsAliveIfVisible();
        unawaited(controller.previousChapter());
      }),
      nextChapter: () => _runWhenImmersiveAllowsShortcuts(() {
        _keepControlsAliveIfVisible();
        unawaited(controller.nextChapter());
      }),
      // 字幕对轴/匹配（用户请求）：Shift+A 一键弹波形对轴放大视图；z/x 整体平移字幕延迟
      // ±_kSubtitleDelayNudgeMs（走 _setDelayMs 写穿 delayMs 落盘 + OSD）。都过沉浸门控，
      // 与顶部快速设置面板同源、零第二套状态。TODO-2837：z/x 保持只调**主字幕轨**；
      // 副字幕独立调轴本轮只走快速设置面板（_setSecondaryDelayMs），不占新键位——
      // 加副轨微调快捷键前须查 docs/agent/shortcuts-inventory.md 撞键并走注册表新动作。
      openSubtitleAlign: () => _runWhenImmersiveAllowsShortcuts(
        () => unawaited(_openSubtitleWaveformAlign()),
      ),
      subtitleDelayIncrease: () => _runWhenImmersiveAllowsShortcuts(
        () => unawaited(_setDelayMs(_delayMs + _kSubtitleDelayNudgeMs)),
      ),
      subtitleDelayDecrease: () => _runWhenImmersiveAllowsShortcuts(
        () => unawaited(_setDelayMs(_delayMs - _kSubtitleDelayNudgeMs)),
      ),
      // asbplayer 式「字幕偏移对齐」（用户请求，默认 Ctrl+Shift+←/→）：把上一句 / 下一句
      // 字幕的起点整体平移到当前播放点。决策集中在纯函数 snapSubtitleDelayMs，写穿仍走
      // _setDelayMs（与 z/x 同一路径）。过沉浸门控，与 z/x 微调互补。
      alignSubtitleToPrev: () => _runWhenImmersiveAllowsShortcuts(
        () => _snapSubtitleDelayToCue(next: false),
      ),
      alignSubtitleToNext: () => _runWhenImmersiveAllowsShortcuts(
        () => _snapSubtitleDelayToCue(next: true),
      ),
      // videoEnterCaret：进入字级选词光标 / 已激活时对光标字符查词（双语义，
      // 沉浸查词门控在 _enterSubtitleCaret 内按 _immersiveAllowsLookup 判）。
      enterCaret: () => _handleEnterCaretAction(controller),
      escape: _handleVideoEscapeAction,
    );
  }

  /// 「返回上一级」（[ShortcutAction.globalBack]，默认 Esc / Alt+← / 手柄 B）在视频页的
  /// 执行体：逐级退出阶梯。
  ///
  /// 抽成具名方法、不留在 [_buildVideoShortcutActions] 的闭包里，是因为它是整张表里
  /// **唯一一个不碰 [VideoPlayerController] 的动作**，而那张表只能用一个非空 controller
  /// 构造。加载态 / 资源缺失态（`_controller == null`）下两条输入通道要能单独调到它——
  /// 否则转圈时按 Esc / 手柄 B 根本不经本页解析，一路落到全局 universal 兜底，而
  /// [_buildLoadingBody] 专门留了「转圈时随时可退出」的返回入口，那条可达性在键盘和
  /// 手柄上就断了。
  ///
  /// 逐级退出：字幕跳转列表 / 剧集列表 / 侧栏 / 沉浸锁等前台层开着时先关一层，
  /// 不退页也不退全屏。层级表是 [_dismissTopForegroundLayer] 单点（BUG-1862 起与
  /// [PopScope]、系统返回键、手柄 B、屏幕返回按钮共用同一份），这里只保留「没有前台
  /// 层可关」之后的两级：全屏 → 退全屏；窗口 → 退页。
  ///
  /// 「退全屏」这一级**只**能留在这里、进不了 [_handleBackOrExit]：全屏是推到根
  /// navigator 的独立路由，全屏期间栈顶是它、本页 [PopScope] 根本轮不到（框架先 pop
  /// 全屏路由），把它并进汇聚点等于写一条永远不执行的分支。
  void _handleVideoEscapeAction() {
    if (_dismissTopForegroundLayer()) return;
    final BuildContext? ctx = _videoControlsContext;
    if (ctx != null && ctx.mounted && isFullscreen(ctx)) {
      unawaited(_exitVideoFullscreen(ctx));
    } else {
      unawaited(_handleBackOrExit());
    }
  }

  /// TODO-1342：把一次手柄按键解析成视频动作并执行。桌面（GameInput/GameController
  /// 轮询）经外层 [Actions] 的 [GamepadButtonIntent] 派发到这里；Android/原生按键经
  /// [_handleVideoGamepadNativeKey] 走同一入口。仅解析 [ShortcutScope.video]
  /// 一个作用域——video 是独立 co-active 组，绝不与阅读器/主页的手柄导航冲突。命中
  /// 返回 true（消费该键、抑制 [GamepadService] 的 A=激活 / B=全局返回 / dpad=移焦
  /// 兜底）；未绑定返回 false，交回 [GamepadService] 的通用兜底（焦点移动等）。
  /// 执行体与键盘快捷键共用 [_buildVideoShortcutActions]，行为完全一致。
  bool _handleVideoGamepadButton(GamepadButton button) {
    // BUG-1453：Steam Input 等桌面映射可把一次手柄按键同时合成鼠标右键。先记录
    // 真实手柄边沿，让右键菜单入口把同源 secondary tap 去重；动作是否绑定不影响
    // 输入来源判定，故记录必须在注册表解析之前。
    _videoGamepadSecondaryTapDeduper.recordGamepadPress(
      _videoInputClock.elapsed,
    );
    final VideoPlayerController? controller = _controller;
    // videoEnterCaret：选词光标激活期，方向/确认/退出等在注册表解析**之前**截获
    // （阅读器 caret.part 同款 contextual 路由）；未激活返回 false 走正常解析
    // （进入光标本身是注册表动作 videoEnterCaret，经下方 callback 执行）。
    if (_handleCaretGamepadButton(button)) return true;
    // 手柄重设计 P3：浮层面板打开时，D-pad/A 让位给通用焦点导航（面板内选行）——
    // 返回 false 交给 GamepadService 的 dpad=移焦 / A=激活兜底，而不是解析成
    // 音量 / seek / 播放暂停。焦点由 PanelFocusScope 在面板打开时领进面板；其余
    // 按钮照常解析（LB/RB seek 仍可用），B 经下方 universal 兜底走逐级退出关面板。
    if (_videoNavigablePanelOpen && isVideoPanelFocusNavButton(button)) {
      return false;
    }
    final ShortcutAction? action = appModel.shortcutRegistry.resolveGamepad(
          button,
          scope: ShortcutScope.video,
        ) ??
        // 兜底「返回上一级」（universal，默认手柄 B）。video 专属键先解析，未命中才
        // 落到它——B 的逐级退出（原 videoEscape）现在就走这条。
        appModel.shortcutRegistry.resolveGamepad(
          button,
          scope: ShortcutScope.universal,
        );
    if (action == null) return false;
    // BUG-924：词典浮层可见时，任一已绑手柄键先关顶层浮层并消费（对齐阅读器 + 键盘通道），
    // 而非穿透控制后台视频。放在解析出 action 之后——未绑定的键仍交回 GamepadService 兜底
    // （焦点移动等），不误吞导航。
    if (_hasVisiblePopup) {
      // 手柄重设计 P2：先给浮层自己的 dictionaryPopup 绑定一次消费机会，再落到上面
      // 那条「已绑键 = 关浮层」。少了这一步，dpad 上下 / X / Y 在 video scope 全都
      // 有绑定（音量 / 上下条字幕），于是 P2 的词条导航 / 制卡 / 发音四个默认绑定在
      // 视频页**结构性不可达**——GamepadService 的弹窗兜底排在页面 Actions 之后，
      // 这里已经 return true 了，永远轮不到。设置里能配、按了没反应正是要禁的形态。
      // B 不在 dictionaryPopup 绑定里，逐级退出关浮层的行为不变。
      if (tryDictionaryPopupGamepadButton(appModel.shortcutRegistry, button)) {
        return true;
      }
      _dismissTopVisiblePopup();
      return true;
    }
    // 与键盘通道同款：「返回上一级」（手柄 B）的执行体不碰播放器，必须分流在
    // controller 门之前，否则加载态下手柄 B 退不出转圈中的视频页。
    if (action == ShortcutAction.globalBack) {
      _handleVideoEscapeAction();
      return true;
    }
    if (controller == null) return false;
    final VoidCallback? callback =
        videoActionCallbacks(_buildVideoShortcutActions(controller))[action];
    if (callback == null) return false;
    callback();
    return true;
  }

  /// TODO-1342：Android/原生手柄按键入口。控制器按键在移动端以 [KeyEvent] 到达，冒泡
  /// 到本页最外层的 [Focus]（[canRequestFocus] 为 false、不参与遍历、不夺焦，只旁观
  /// 冒泡）；仅当事件确实来自控制器类设备（[GamepadButton.fromKeyEvent] 非空）才接管，
  /// 其余键（普通键盘键、方向键光标编辑等）一律放行不消费，交回既有解析路径。
  KeyEventResult _handleVideoGamepadNativeKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final GamepadButton? button = GamepadButton.fromKeyEvent(event);
    if (button == null) return KeyEventResult.ignored;
    return _handleVideoGamepadButton(button)
        ? KeyEventResult.handled
        : KeyEventResult.ignored;
  }

  /// BUG-853 / TODO-847 对齐：Windows 微软 IME 激活时裸 Space 的 `logicalKey` 被引擎
  /// 改写成 [LogicalKeyboardKey.process]，视频页两条空格「播放/暂停」路径
  /// （旧 media_kit controls 表与页级空格兜底）都用
  /// `SingleActivator(LogicalKeyboardKey.space)` 匹配 `logicalKey`，故 IME 下按空格既不
  /// 被内层消费、也不被页级兜底消费，最终上浮到本最外层 [Focus]（[_wrapVideoGamepadControls]
  /// 是 [_videoFocusNode] 及所有子焦点节点的祖先，冒泡最后到这里）。这里按**物理键**
  /// 还原 Space 语义，触发与页级 press-time 通道完全一致的 togglePlayPause（同样
  /// 经 [_runWhenImmersiveAllowsShortcuts] 尊重沉浸锁门控）。
  ///
  /// 纯识别逻辑抽到可单测的 [isVideoImeSpacePlayPause]。文本框正在 composing 时
  /// （[focusedEditableText] 非空）不接管，避免 IME 变换候选词按空格误触暂停。BUG-936：
  /// 按**物理键** [PhysicalKeyboardKey.space] 判定（唯一不受 IME 改写的稳定信号），只要
  /// 逻辑键已被 IME 改写（非裸 `space`）即命中，覆盖 `process` 及任意其它 IME 改写值；
  /// 裸 Space 仍走既有 SingleActivator 路径不变（Never break userspace）。
  bool _handleVideoImeSpacePlayPause(KeyEvent event) {
    if (event is! KeyDownEvent) return false;
    final VideoPlayerController? controller = _controller;
    if (controller == null) return false;
    final bool hasModifier = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isShiftPressed ||
        HardwareKeyboard.instance.isAltPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    final bool hit = isVideoImeSpacePlayPause(
      logicalKey: event.logicalKey,
      physicalKey: event.physicalKey,
      hasModifier: hasModifier,
      hasEditableFocus: focusedEditableText() != null,
    );
    if (!hit) return false;
    _runWhenImmersiveAllowsShortcuts(
      () => unawaited(controller.playOrPause()),
    );
    return true;
  }

  /// BUG-1239：Windows runner 在 Flutter 丢掉 `VK_PROCESSKEY` 的 scan code 之前，
  /// 把「无修饰的物理 Space 按下沿」经专用 channel 送到这里。
  ///
  /// 这条入口绕过 Focus 冒泡，故必须显式复刻页面快捷键的所有权边界：只有当前视频
  /// 路由（窗口或 media_kit 全屏路由）可响应；文本框持焦时让给 IME；词典浮层可见时
  /// 只关浮层；其余才按沉浸模式门控播放/暂停。普通半角 Space 仍走既有 KeyEvent /
  /// SingleActivator 路径，本通道只接 native 已确认的 `VK_PROCESSKEY + Space scan code`。
  void _handleWindowsImeSpaceDown() {
    final ModalRoute<Object?>? owner = mounted
        ? (_videoFullscreenActive
            ? _videoFullscreenRoute
            : ModalRoute.of(context))
        : null;
    final WindowsImeSpaceDispatchAction action = resolveWindowsImeSpaceDispatch(
      mounted: mounted,
      hasController: _controller != null,
      isCurrentRoute: owner == null || owner.isCurrent,
      hasEditableFocus: focusedEditableText() != null,
      hasVisiblePopup: _hasVisiblePopup,
      immersiveAllowsShortcuts: _immersiveAllowsShortcuts,
    );
    switch (action) {
      case WindowsImeSpaceDispatchAction.ignore:
        return;
      case WindowsImeSpaceDispatchAction.dismissPopup:
        _dismissTopVisiblePopup();
        return;
      case WindowsImeSpaceDispatchAction.togglePlayPause:
        final VideoPlayerController controller = _controller!;
        unawaited(controller.playOrPause());
    }
  }

  /// 按住临时倍速的键盘入口（用户请求：与手机长按画面同语义——按下加速、松开
  /// 恢复）。按住语义需要 keyup 边沿，SingleActivator/CallbackShortcuts 表达不了，
  /// 故该动作的键盘绑定不进 activator 表（见 [buildVideoPlayerShortcutsFromRegistry]），
  /// 由本页最外层 [Focus] 的 onKeyEvent 直接判定：状态机是纯函数
  /// [resolveHoldSpeedKeyTransition]，绑定命中是 [keyDownMatchesHoldSpeed]（都在
  /// video_player_shortcuts.dart，可单测）。
  ///
  /// 与其它视频键语义对齐：词典浮层可见时先关浮层不执行（BUG-924 同款）；进入
  /// 动作过 [_runWhenImmersiveAllowsShortcuts] 沉浸锁门控；文本框持焦时不接管。
  /// keyup/repeat 只按触发键识别（不看修饰键/门控），保证任何情况下松开都能恢复。
  KeyEventResult _handleHoldSpeedKey(KeyEvent event) {
    final bool matches = event is KeyDownEvent &&
        _controller != null &&
        keyDownMatchesHoldSpeed(
          appModel.shortcutRegistry,
          event,
          hasEditableFocus: focusedEditableText() != null,
        );
    switch (resolveHoldSpeedKeyTransition(
      event: event,
      activeTriggerKey: _holdSpeedTriggerKey,
      matchesHoldSpeedBinding: matches,
    )) {
      case HoldSpeedKeyTransition.none:
        return KeyEventResult.ignored;
      case HoldSpeedKeyTransition.swallow:
        return KeyEventResult.handled;
      case HoldSpeedKeyTransition.release:
        _holdSpeedTriggerKey = null;
        _releaseHoldSpeed();
        return KeyEventResult.handled;
      case HoldSpeedKeyTransition.engage:
        // BUG-924 同语义：浮层可见时任何视频键先关顶层浮层、不执行原动作。
        if (_hasVisiblePopup) {
          _dismissTopVisiblePopup();
          return KeyEventResult.handled;
        }
        _holdSpeedTriggerKey = event.logicalKey;
        _runWhenImmersiveAllowsShortcuts(_engageHoldSpeed);
        return KeyEventResult.handled;
    }
  }

  /// 视频页鼠标通道的解析阶梯：**只有本页自己的 scope**。
  ///
  /// 与键盘的分层逐字一致：键盘在页内只解析 video（+ universal 兜底），没接就返回
  /// ignored 冒泡到 [wrapWithGlobalNavigation]，由那一层解析 universal / global 并
  /// 执行。鼠标没有冒泡，所以那一层改由 app 根的 `onPointerDown` 兜底
  /// （[MouseBindingDispatch] 负责两层互斥），**执行体仍然只有最外层那一份**——
  /// 每页各自复刻一遍 global 的执行体才是真正的重复。
  /// BUG-2031：阶梯必须与本页**键盘阶梯逐字相同**。第一版只放了本页 scope，于是
  /// `globalBack`（universal）在页内解析不到，只能落到 app 根那份平铺的
  /// `Navigator.maybePop()`——而键盘 / 手柄的 `globalBack` 走的是本页的**逐级退出**
  /// （先关面板 / 退全屏，最后才退页）。同一个动作两条通道两种行为，正是要禁的形态。
  static const List<ShortcutScope> kVideoMouseLadder = <ShortcutScope>[
    ShortcutScope.video,
    ShortcutScope.universal,
    // global 是 reader / manga / home 三条阶梯早就有的尾段，video 此前是唯一缺口。
    // 补上它才能让 [ShortcutAction.globalContextMenu]（住在 global）在视频页解析得到
    // ——否则视频画面上的右键菜单会整个消失。对既有动作零影响：视频页的执行体表
    // （videoActionCallbacks）里没有任何 global 动作，解析到也返回 false 不认领，
    // app 根的兜底照常有机会派发同一次按下。
    ShortcutScope.global,
  ];

  /// 视频页的**鼠标绑定通道**（BUG-1995）：页面根 [Listener] 的 `onPointerDown` 入口。
  ///
  /// 与键盘 / 手柄两条通道同构：按下当场问注册表要动作（press-time 解析，不冻结表），
  /// 命中后走与它们完全相同的执行体。解析与按钮号折叠收在共享的
  /// [resolveMouseBindingAction] 里（全表面同一份判据，也与设置页的按键录制同一个
  /// 折叠函数）；左键在那里恒折不出按钮号，故永不可绑，正常点击 / 划词零影响。
  ///
  /// ⚠️ **本入口只在词典浮层不可见时可达**，所以这里**不写**任何「关浮层」逻辑。
  ///
  /// 浮层可见（或查词搜索中）时，[_buildPopupOverlay] 会在**根 Overlay**里挂一层
  /// `Positioned.fill` 的 [LookupDismissBarrier]。它虽然自称 translucent，内层却是
  /// `ColoredBox`——`_RenderColoredBox` 的命中行为是 **opaque**（颜色透明 ≠ 命中透明），
  /// 于是整个 barrier 子树 hitTest 返回 true，Overlay 的 Stack 就此停止向下测试，
  /// 事件根本到不了本页面。实测：barrier 显示时页面根 Listener 收到 0 个 pointerDown。
  /// 守卫见 `test/shortcuts/video_pointer_channel_reachability_test.dart`。
  ///
  /// 「浮层可见时按侧键关词典」由**另一条**路承担：浮层是原生 WebView，指针落在它上面
  /// 时由 [DictionaryPopupLayer] 自己的 Listener 折出 token 回传
  /// （[dictionaryPopupForwardedActions] → [onDictionaryPopupInputToken]）。那条路读的是
  /// `bindingsFor` / `resolveMouse`，与本入口共用同一份绑定，但不经过这里。
  void _handleVideoPointerDown(PointerDownEvent event) {
    final ShortcutAction? action = resolveMouseBindingAction(
      registry: appModel.shortcutRegistry,
      buttons: event.buttons,
      ladder: kVideoMouseLadder,
    );
    if (action == null) return;
    dispatchClaimedMouseAction(event, () {
      // 「只关词典」在浮层不可见时按下 = 无事发生，这正是它存在的意义（给侧键一个
      // 没有副作用的落点）。返回 false = **不认领**，让 app 根兜底照常有机会解析同一
      // 个按钮上的 global 绑定（等价于键盘返回 ignored 让它冒泡）。
      if (action == ShortcutAction.videoDismissDict) return false;
      // BUG-2031：与键盘 / 手柄同款分流——「返回上一级」的执行体不碰播放器，必须排在
      // controller 门**之前**，否则加载态下侧键退不出转圈中的视频页。走的是本页的逐级
      // 退出 [_handleVideoEscapeAction]（先关面板 / 退全屏，最后才退页），与键盘 Esc、
      // 手柄 B 完全同一个执行体；此前阶梯里没有 universal，它只能落到 app 根那份平铺
      // 的 `maybePop()`，一按直接退整页，比键盘少了一级。
      if (action == ShortcutAction.globalBack) {
        _handleVideoEscapeAction();
        return true;
      }
      final VideoPlayerController? controller = _controller;
      if (controller == null) return false;
      // 动作不在回调表里（例如 popupMineEntry 这类页面另行分流的）就不算本层派发过。
      final VoidCallback? run =
          videoActionCallbacks(_buildVideoShortcutActions(controller))[action];
      if (run == null) return false;
      run();
      return true;
    });
  }

  /// 视频页键盘通道的**唯一**派发点（方案 D）：每次按键当场问注册表，与手柄
  /// [_handleVideoGamepadButton] 逐段同构。
  ///
  /// 挂在 [_wrapVideoGamepadControls] 的 `Focus.onKeyEvent` 上——窗口 `build()` 与
  /// 全屏路由 `pageBuilder` 的唯一共同外层，也是**所有**子焦点节点（视频画面、
  /// media_kit 控制条、字幕列表、[PanelFocusScope] 圈起来的剧集轨 / 侧栏）的共同
  /// 祖先。BUG-1864 的根因就是「注册表声明的作用域是整页（[ShortcutScope.video]），
  /// 挂载点却只在 media_kit controls 子树」——面板是 `Video` 的**兄弟**，焦点一进
  /// 面板，整张表就够不着了。scope 与挂载点在这里第一次对齐。
  ///
  /// 判据全在纯函数 [resolveVideoKeyboardShortcut] 里（可单测）；本方法只负责取页面
  /// 态、按判决执行。执行体与手柄通道共用 [videoActionCallbacks]，所以两条通道命中
  /// 同一动作时行为逐字一致（含 [_runWhenImmersiveAllowsShortcuts] 沉浸锁门控）。
  bool _handleVideoKeyboardShortcut(KeyEvent event) {
    final VideoPlayerController? controller = _controller;
    final VideoKeyboardResolution resolution = resolveVideoKeyboardShortcut(
      appModel.shortcutRegistry,
      event,
      modifiers: currentKeyboardModifiers(HardwareKeyboard.instance),
      hasEditableFocus: focusedEditableText() != null,
      hasVisiblePopup: _hasVisiblePopup,
      // 「视频画面精确持焦」与 [_focusOwnership] 是同一个真相源（它 reclaim 的就是
      // 这个节点）：焦点落到控制条按钮或面板行上时 hasPrimaryFocus 自然为 false。
      videoSurfaceHoldsFocus: _videoFocusNode.hasPrimaryFocus,
      videoNavigablePanelOpen: _videoNavigablePanelOpen,
    );
    switch (resolution.dispatch) {
      case VideoKeyboardDispatch.ignore:
        return false;
      case VideoKeyboardDispatch.swallowRepeat:
        // 吃掉，什么都不做——见 VideoKeyboardDispatch.swallowRepeat 的文档。
        return true;
      case VideoKeyboardDispatch.dismissPopup:
        _dismissTopVisiblePopup();
        return true;
      case VideoKeyboardDispatch.run:
        final ShortcutAction action = resolution.action!;
        // 制卡属于 dictionaryPopup scope，执行体不在 videoActionCallbacks 里。
        if (action == ShortcutAction.popupMineEntry) {
          _mineFromTopPopup();
          return true;
        }
        // 「返回上一级」的执行体是本页的逐级退出阶梯，整条不碰播放器
        // （[_handleVideoEscapeAction]），所以它必须分流在下面那道 controller 门**之前**：
        // 加载态 / 资源缺失态下 `_controller` 恒为 null，跟着整表一起被挡在门外就等于
        // 转圈时 Esc 不再走本页阶梯（[_buildLoadingBody] 的「随时可退出」在键盘上够不着）。
        if (action == ShortcutAction.globalBack) {
          _handleVideoEscapeAction();
          return true;
        }
        // 其余动作的执行体全部从 [_buildVideoShortcutActions] 取，而它要求一个非空
        // controller——播放器还没建好时那些动作本来也无事可做。不消费，交回既有路径。
        if (controller == null) return false;
        final Map<ShortcutAction, VoidCallback> callbacks =
            videoActionCallbacks(_buildVideoShortcutActions(controller));
        final VoidCallback? callback = callbacks[action];
        // 解析到了但本页没接线（universal scope 里 globalBack 之外的动作）：不消费，
        // 交回既有路径——与 [_handleVideoGamepadButton] 的 `callback == null` 同款。
        if (callback == null) return false;
        callback();
        return true;
    }
  }

  /// TODO-1342：把整页子树包进手柄输入层。外层 [Actions] 接桌面轮询派发的
  /// [GamepadButtonIntent]；内层 [Focus] 只旁观 Android 原生手柄按键的冒泡（不夺焦、
  /// 不参与焦点遍历，故不干扰 [_videoFocusNode] 的键盘持焦与既有 [autofocus] 时序）。
  Widget _wrapVideoGamepadControls(Widget child) {
    return Actions(
      actions: <Type, Action<Intent>>{
        GamepadButtonIntent: CallbackAction<GamepadButtonIntent>(
          onInvoke: (GamepadButtonIntent intent) =>
              _handleVideoGamepadButton(intent.button),
        ),
        // 手柄长按 A：选词光标在弹窗面上时等价阅读器「长按标记词典」；其余情况
        // 返回 false 交回 GamepadService 全局兜底（与阅读器同款接线）。
        GamepadLongPressIntent: CallbackAction<GamepadLongPressIntent>(
          onInvoke: (GamepadLongPressIntent intent) =>
              _handleCaretGamepadLongPress(intent.button),
        ),
      },
      child: Focus(
        canRequestFocus: false,
        skipTraversal: true,
        onKeyEvent: (FocusNode node, KeyEvent event) {
          // videoEnterCaret：选词光标激活期，光标键（方向 / Enter / Esc / Tab /
          // [ ] / , .）先于注册表解析被截获——选词是模态操作，裸方向键在这时是移动
          // 光标而不是 seek / 调音量。带硬修饰的组合键（Ctrl+← 上一句等）不算光标键，
          // 由 [_handleCaretUnboundKey] 自己放行、落到下面的注册表解析。
          if (_handleCaretUnboundKey(event)) {
            return KeyEventResult.handled;
          }
          // BUG-880：Shift 按下瞬间在最后指针位置反查字幕字符立即查词，根治「光标停在词上
          // 不动、按 Shift 却不触发」（查词只在鼠标移动的 hover 事件上派发）。不消费按键，
          // Shift 组合键 / 其它快捷键行为不变。
          if (event is KeyDownEvent &&
              (event.logicalKey == LogicalKeyboardKey.shiftLeft ||
                  event.logicalKey == LogicalKeyboardKey.shiftRight)) {
            _triggerShiftLookupAtLastPointer();
          }
          // 按住临时倍速（按下加速/松开恢复）需要 keyup 边沿，activator 表达不了，
          // 故按下 / 松开都在这里按注册表绑定判定（见 _handleHoldSpeedKey）。必须排在
          // 主通道之前：主通道只看按下 / 重复沿，松开沿只有这里认。
          if (_handleHoldSpeedKey(event) == KeyEventResult.handled) {
            return KeyEventResult.handled;
          }
          // 视频快捷键主通道（方案 D）：press-time 问注册表，整页唯一挂载点。
          if (_handleVideoKeyboardShortcut(event)) {
            return KeyEventResult.handled;
          }
          // BUG-853 / BUG-936：IME 把裸空格的 logicalKey 改写成非 space 值，主通道
          // 按逻辑键匹配不到，在此按**物理键**还原播放/暂停。放在主通道之后，两条路径
          // 互斥不会双触发。
          if (_handleVideoImeSpacePlayPause(event)) {
            return KeyEventResult.handled;
          }
          return _handleVideoGamepadNativeKey(node, event);
        },
        // BUG-880：页面根持续记录全局指针位置（不消费、不影响下层控制条 / 查词手势），供
        // Shift 按下时反查。浮层打开后 barrier 盖住这里收不到 hover，由 [_onDismissBarrierHover]
        // 接力更新同一字段。
        // BUG-1798：与那个接力点用同一条判据滤掉合成 hover——[_pokeControlsVisible] 的合成事件
        // 位置恒为视频区几何中心，写进来就是把「用户光标在哪」记成画面正中，Shift 反查随即查错
        // 位置。合成事件不代表用户指针，两个记账点必须同时滤，只滤一个仍会从另一个漏进来。
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerHover: (PointerHoverEvent event) {
            if (_isSyntheticControlsHover(event)) return;
            _lastGlobalPointerPos = event.position;
          },
          // BUG-1995：视频页此前**没有**「PointerDownEvent → MouseBinding → 派发」
          // 这条链路（video scope 的 mouse 通道因此是关的，设置页连绑定入口都不给）。
          // reader 能用鼠标侧键关词典，靠的是它正文是 WebView、侧键走 DOM mousedown
          // 回传 Dart —— 视频页没有 WebView 正文，那条路复制不过来，只能把这条链路
          // 真的建出来。挂在已有的页面根 Listener 上，不新增层级。
          //
          // `Listener` 不进手势 arena、不消费点击，media_kit 控件 / 进度条 / 字幕
          // 查词的既有手势行为零变化。
          onPointerDown: _handleVideoPointerDown,
          child: child,
        ),
      ),
    );
  }

  /// media_kit 桌面控制主题。底部胶囊条改成居中传输组
  /// `[−10s][上一句][暂停][下一句][+10s]`（清空中央 primaryButtonBar 避免重复），
  /// 左端进度、右端全屏；顶栏右侧放 截图/字幕/音轨/倍速/设置 图标（参照截图）。
  /// 上/下一句走 cue 导航（无字幕/转场段对称回退/前进，
  /// [VideoPlayerController.skipToPrevCueOrSeekBack]/[VideoPlayerController.skipToNextCueOrSeekForward]）。

  /// TODO-399 decision 3b: every chip-renderable button (learning keys PLUS the
  /// transport / nav keys: play/pause, seek +/-, cue nav, screenshot, subtitle /
  /// audio track, episode list, fullscreen) that the user placed into [slot],
  /// in order. Non-chip special renders ([volume], [title],
  /// [positionIndicator]) stay on their dedicated render paths.
  List<VideoControlItem> _slotChipItems(VideoControlSlot slot) {
    return <VideoControlItem>[
      for (final VideoControlItem item in _controlLayout.itemsIn(slot))
        if (item.isChipRenderable &&
            item != VideoControlItem.volume &&
            _shouldRenderControlItem(item))
          item,
    ];
  }

  List<Widget> _bottomSlotButtons(
    VideoControlSlot slot,
    VideoPlayerController controller, {
    required bool desktop,
    required bool roomyBottomBar,
  }) {
    // **一次遍历**，按用户在槽内摆的真实顺序出控件。
    //
    // 旧写法是「先画完所有 chip，再把 volume 追加到槽尾」：`itemsIn(slot)` 里
    // volume 的真实下标被整个丢掉，用户在底栏槽内怎么拖音量都零视觉变化。默认
    // 布局出厂就已经分叉——bottomRight 是 `[volume, fullscreen, speed, …]`，
    // 编辑器按真实下标画、音量排**第一**，播放器却把它画在**最后**。
    //
    // 音量与其它按钮的差别只在**用哪个 widget 画**（它有浮层、要按槽位做几何避让），
    // 不在**画在第几位**。位置逻辑因此不该为它分叉：分派在循环体内做，顺序由
    // 唯一真相源 `itemsIn(slot)` 决定。
    //
    // volume 不经 [_shouldRenderControlItem]：与旧行为一致（旧写法问的是未经过滤
    // 的原始槽列表「在不在」），本次只改顺序、不改「画不画」。
    return <Widget>[
      for (final VideoControlItem item in _controlLayout.itemsIn(slot))
        if (item == VideoControlItem.volume)
          _buildVolumeButton(controller, desktop: desktop, slot: slot)
        else if (item.isChipRenderable && _shouldRenderControlItem(item))
          _buildBottomSlotButton(
            item,
            controller,
            desktop: desktop,
            slot: slot,
            roomyBottomBar: roomyBottomBar,
          ),
    ];
  }

  /// 标题项落在顶部哪个槽（用户可把它拖到 topLeft / topCenter / topRight）；没放置
  /// 或被移除时返回 null。标题是单实例项（[VideoControlItem.isSingleInstance]），
  /// `VideoControlLayout` 保证它最多出现在一个槽里。
  VideoControlSlot? _topBarTitleSlot() {
    for (final VideoControlSlot slot in const <VideoControlSlot>[
      VideoControlSlot.topLeft,
      VideoControlSlot.topCenter,
      VideoControlSlot.topRight,
    ]) {
      if (_controlLayout.itemsIn(slot).contains(VideoControlItem.title)) {
        return slot;
      }
    }
    return null;
  }

  /// 标题在顶栏里夹在哪两段按钮之间（喂给 [VideoTopBarSlots]）。
  VideoTopBarTitlePlacement _topBarTitlePlacement() {
    switch (_topBarTitleSlot()) {
      case VideoControlSlot.topLeft:
        return VideoTopBarTitlePlacement.left;
      case VideoControlSlot.topRight:
        return VideoTopBarTitlePlacement.right;
      default:
        return VideoTopBarTitlePlacement.center;
    }
  }

  Widget _topBarTitle() {
    final VideoControlSlot? slot = _topBarTitleSlot();
    if (slot == null) {
      // 标题项没配置：交回零宽占位，整条顶栏宽都归两侧按钮组。绝不能返回 Spacer
      // （= Expanded/FlexFit.tight）——那会让「空的中段」硬占一份顶栏宽，用户把标题
      // 关掉后中间明明是空白、右上角按钮却照旧被挤进滚动区裁掉（本轮修复的现象）。
      return const SizedBox.shrink();
    }
    // TODO-642 → 本轮：标题不再参与 Row 的 flex 分配（旧实现是 Flexible(loose)，与
    // 左右按钮组各占 flex:1 → Flex 把整宽**平分**成三份，loose 用不完的空间又不回流，
    // 所以右侧按钮组无论如何最多只拿 1/3 顶栏宽、多出来的按钮被裁进横滚区）。改由
    // [VideoTopBarSlots] 按「按钮按需优先、标题吃剩余」的固定优先级分宽：按钮永远完整
    // 可见，标题只在剩余宽里显示、靠 maxLines:1 + ellipsis 优雅截断。
    //
    // 标题被拖进按钮槽时也走这里（不再有 220 宽的内联块跟同组按钮抢位）：位置由
    // [_topBarTitlePlacement] 交给顶栏布局还原，对齐跟随所在槽——落在 topRight 就靠
    // 右贴住它后面那段按钮，其余靠左。
    //
    // 标题走 ValueListenableBuilder（BUG-120）：全屏路由不随页面 setState 重建，
    // 监听 _titleNotifier 才能在全屏换集后刷新标题。
    return _topBarTitleText(
      alignment: slot == VideoControlSlot.topRight
          ? AlignmentDirectional.centerEnd
          : AlignmentDirectional.centerStart,
    );
  }

  Widget _topBarTitleText({required AlignmentGeometry alignment}) {
    return Align(
      alignment: alignment,
      child: ValueListenableBuilder<String?>(
        valueListenable: _titleNotifier,
        builder: (BuildContext _, String? title, __) => Text(
          title ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: alignment == AlignmentDirectional.centerEnd
              ? TextAlign.end
              : TextAlign.start,
          style: _videoControlTitleStyle(),
        ),
      ),
    );
  }

  Widget _buildBottomSlotButton(
    VideoControlItem item,
    VideoPlayerController controller, {
    required bool desktop,
    required VideoControlSlot slot,
    required bool roomyBottomBar,
  }) {
    final VideoControlButton? legacy = item.legacyButton;
    if (legacy != null) {
      return _buildVideoControlButton(
        controller,
        legacy,
        desktop: desktop,
        slot: slot,
      );
    }
    switch (item) {
      case VideoControlItem.playPause:
        return Tooltip(
          message: t.video_bottom_play_pause,
          child: desktop
              ? MaterialDesktopPlayOrPauseButton(
                  iconSize: _videoPlayPauseIconSize,
                )
              : Listener(
                  // TODO-1059：media_kit 自带的播放/暂停按钮走它自己的 onPressed，无宿主
                  // 续命路径。Listener 的 onPointerDown 在每次按下续命控制条，且不吞手势
                  // （Listener 不参与手势 arena、不消费点击），按钮的播放/暂停照常触发。
                  onPointerDown: (_) => _pokeControlsVisible(),
                  child: MaterialPlayOrPauseButton(
                    iconSize: _videoPlayPauseIconSize,
                  ),
                ),
        );
      case VideoControlItem.previousCue:
        return Tooltip(
          message: t.video_bottom_prev_cue,
          child: desktop
              ? MaterialDesktopCustomButton(
                  icon: Icon(Icons.skip_previous, size: _videoControlIconSize),
                  onPressed: () => _skipCueAndPokeControls(forward: false),
                )
              : MaterialCustomButton(
                  icon: Icon(Icons.skip_previous, size: _videoControlIconSize),
                  onPressed: () => _skipCueAndPokeControls(forward: false),
                ),
        );
      case VideoControlItem.nextCue:
        return Tooltip(
          message: t.video_bottom_next_cue,
          child: desktop
              ? MaterialDesktopCustomButton(
                  icon: Icon(Icons.skip_next, size: _videoControlIconSize),
                  onPressed: () => _skipCueAndPokeControls(forward: true),
                )
              : MaterialCustomButton(
                  icon: Icon(Icons.skip_next, size: _videoControlIconSize),
                  onPressed: () => _skipCueAndPokeControls(forward: true),
                ),
        );
      case VideoControlItem.seekBackward:
        if (roomyBottomBar) {
          return _seekLabelButton(
            icon: Icons.fast_rewind_rounded,
            label: t.video_bottom_seek_back_label,
            tooltip: t.video_bottom_seek_back,
            color: _videoChromeAccent(Theme.of(context).colorScheme),
            onPressed: () => _seekRelative(-10000),
          );
        }
        return _plainSlotButton(item, controller, desktop: desktop, slot: slot);
      case VideoControlItem.seekForward:
        if (roomyBottomBar) {
          return _seekLabelButton(
            icon: Icons.fast_forward_rounded,
            label: t.video_bottom_seek_forward_label,
            tooltip: t.video_bottom_seek_forward,
            color: _videoChromeAccent(Theme.of(context).colorScheme),
            onPressed: () => _seekRelative(10000),
          );
        }
        return _plainSlotButton(item, controller, desktop: desktop, slot: slot);
      case VideoControlItem.frameBackward:
        return _frameStepButton(controller, forward: false);
      case VideoControlItem.frameForward:
        return _frameStepButton(controller, forward: true);
      case VideoControlItem.fullscreen:
        return _buildFullscreenButton(desktop: desktop);
      case VideoControlItem.back:
      case VideoControlItem.immersiveLock:
      case VideoControlItem.screenshot:
      case VideoControlItem.clipExport:
      case VideoControlItem.subtitleTrack:
      case VideoControlItem.audioTrack:
      case VideoControlItem.previousEpisode:
      case VideoControlItem.nextEpisode:
      case VideoControlItem.episodeList:
      case VideoControlItem.previousChapter:
      case VideoControlItem.nextChapter:
      case VideoControlItem.chapterList:
      // 自定义「快捷键」按钮就是一个普通图标按钮：图标 / tooltip 由绑定动作决定
      // （见 `_videoControlItemIcon` / `_videoControlItemTooltip`），点击走
      // `_activateVideoControlItem` 查动作表。没有任何专属渲染需求。
      case VideoControlItem.customAction1:
      case VideoControlItem.customAction2:
      case VideoControlItem.customAction3:
      case VideoControlItem.customAction4:
        return _plainSlotButton(item, controller, desktop: desktop, slot: slot);
      case VideoControlItem.volume:
      case VideoControlItem.title:
      case VideoControlItem.positionIndicator:
      case VideoControlItem.speed:
      case VideoControlItem.subtitleList:
      case VideoControlItem.favoriteSentence:
      case VideoControlItem.settings:
        return const SizedBox.shrink();
    }
  }

  Widget _plainSlotButton(
    VideoControlItem item,
    VideoPlayerController controller, {
    required bool desktop,
    required VideoControlSlot slot,
  }) {
    final Widget icon = Icon(
      _videoControlItemIcon(item),
      size: _videoControlIconSize,
    );
    return Tooltip(
      message: _videoControlItemTooltip(item),
      child: desktop
          ? MaterialDesktopCustomButton(
              icon: icon,
              onPressed: () => _activateVideoControlItem(
                item,
                controller,
                sourceSlot: slot,
              ),
            )
          : MaterialCustomButton(
              icon: icon,
              onPressed: () => _activateVideoControlItem(
                item,
                controller,
                sourceSlot: slot,
              ),
            ),
    );
  }

  bool _shouldRenderControlItem(VideoControlItem item) {
    // 自定义「快捷键」按钮：**已绑的照常显示，未绑的只露一个加号**（用户拍板改口，
    // 此前是 4 个空槽全摆——一排一模一样的图标既占地方又看不出差别）。
    //
    // 空槽仍不是死按钮：露出来的那个加号点一下就地弹动作选择器（见
    // `_activateVideoControlItem`），这是手机上最短的配置路径——看得见 → 点得到 →
    // 当场配好，不用先翻进设置面板找编辑器；配完下一个空槽自动接上加号的位置。
    //
    // 想让快捷键按钮**彻底**消失（连加号都不要），走控件编辑器把槽位拖进隐藏托盘
    // （和其它按钮同一套操作）。编辑器不经本门控（它读 `layout.itemsIn`），所以 4 个
    // 槽位在那里永远都在、随时可配，不会因为播放器上只画一个而变得不可达。
    //
    // 已知边界：单独把「加号所在的那个槽位」拖进隐藏托盘（比如只藏快捷键1、留着
    // 2/3/4 都不绑），播放器上就一个加号也不剩——加号取的是绑定表里序号最小的空位，
    // 不去问它在哪个 slot。这是有意的：判据一旦掺进布局，就得回答「藏了 1 该由 2 顶上
    // 吗、2 也藏了呢」这类没有正确答案的问题。隐藏是用户自己的操作，托盘里随时拖回来。
    //
    // 本分支的形状被 video_custom_action_bindings_test 的源码守卫钉死（退回无条件
    // 显示全部槽位会变红），改这里请连它一起改。
    final int? customSlot = item.customActionSlotIndex;
    if (customSlot != null) {
      return _customActionBindings.actionAt(customSlot) != null ||
          customSlot == _customActionBindings.firstUnboundSlotIndex;
    }
    switch (item) {
      case VideoControlItem.previousEpisode:
      case VideoControlItem.nextEpisode:
      case VideoControlItem.episodeList:
        return _isPlaylist;
      case VideoControlItem.previousChapter:
      case VideoControlItem.nextChapter:
      case VideoControlItem.chapterList:
        return _hasChapters;
      case VideoControlItem.volume:
      case VideoControlItem.title:
      case VideoControlItem.positionIndicator:
        return false;
      // 逐帧后退 / 前进：libmpv frame-step / frame-back-step 只在桌面可用（移动端
      // media_kit 后端不支持，点了无反应）。仅桌面控制条渲染，避免移动端出现死按钮。
      case VideoControlItem.frameBackward:
      case VideoControlItem.frameForward:
        return _isDesktopVideoControls;
      case VideoControlItem.back:
      case VideoControlItem.immersiveLock:
      case VideoControlItem.speed:
      case VideoControlItem.subtitleList:
      case VideoControlItem.favoriteSentence:
      case VideoControlItem.settings:
      case VideoControlItem.playPause:
      case VideoControlItem.seekBackward:
      case VideoControlItem.seekForward:
      case VideoControlItem.previousCue:
      case VideoControlItem.nextCue:
      case VideoControlItem.fullscreen:
      case VideoControlItem.screenshot:
      case VideoControlItem.clipExport:
      case VideoControlItem.subtitleTrack:
      case VideoControlItem.audioTrack:
        return true;
      case VideoControlItem.customAction1:
      case VideoControlItem.customAction2:
      case VideoControlItem.customAction3:
      case VideoControlItem.customAction4:
        // 不可达：函数开头对 isCustomAction 无条件返回 true。保留分支维持穷举检查。
        return false;
    }
  }

  /// TODO-421 phase 1: render the buttons the user placed into the **top** slots
  /// ([VideoControlSlot.topLeft] / [topRight]) as media_kit chrome buttons so
  /// they live INSIDE the fixed top bar row (`topButtonBar`), not in a separate
  /// floating strip below it. The user picked "Top bar (left/right)" expecting
  /// the real top bar, so the buttons are injected into the same [topButtonBar]
  /// array as the back / title / track-track chrome — they inherit the theme's
  /// `buttonBarButtonColor` / `buttonBarButtonSize` and fade in / out with the
  /// rest of the controls (a plain Hibiki [IconButton] would not).
  ///
  /// Renders **every** chip-renderable item in the slot ([_slotChipItems]), not
  /// just the five learning keys: the customization editor's palette
  /// ([VideoControlItem.customizableItems]) lets users drop transport / nav keys
  /// (screenshot, audio track, seek, …) into the top slots too, so filtering to
  /// learning keys here would silently drop those placements off the player after
  /// the floating top rail is removed. The shared [_activateVideoControlItem]
  /// dispatcher handles both learning and transport / nav activation.
  ///
  /// The whole slot is one flex child of the fixed top bar. In particular,
  /// [VideoControlSlot.topRight] must stay a single right-aligned button group:
  /// if every button is injected as its own [Flexible] child of the outer row,
  /// Flutter spreads the right-side buttons toward the title/middle on narrow
  /// windows. The group scrolls horizontally when squeezed, so buttons remain
  /// reachable without painting past the edge.
  Widget _topBarSlotGroup(
    VideoControlSlot slot,
    VideoPlayerController controller, {
    required VideoControlLayout layout,
    required bool desktop,
    required VideoTopBarSegment segment,
  }) {
    final List<VideoControlItem> rawItems = layout.itemsIn(slot);
    // 标题项被拖进按钮槽时，它在槽内的索引位置有语义（`VideoControlLayout` 保序），
    // 所以按标题把该槽切成 lead / tail 两段按钮，标题本身由顶栏的 title 槽渲染、
    // **最后**才分宽（[VideoTopBarSlots]）。此前标题是组内一个 220 宽的内联块，会跟
    // 同组按钮抢横向空间、把按钮挤进横滚区——那正是「名称挡住按钮」的另一半根因。
    final int titleIndex = rawItems.indexOf(VideoControlItem.title);
    final List<VideoControlItem> scoped;
    if (titleIndex < 0) {
      scoped = segment == VideoTopBarSegment.lead
          ? rawItems
          : const <VideoControlItem>[];
    } else {
      scoped = segment == VideoTopBarSegment.lead
          ? rawItems.sublist(0, titleIndex)
          : rawItems.sublist(titleIndex + 1);
    }
    final List<VideoControlItem> items = <VideoControlItem>[
      for (final VideoControlItem item in scoped)
        if (item.isChipRenderable && _shouldRenderControlItem(item)) item,
    ];
    if (items.isEmpty) return const SizedBox.shrink();

    Widget buttonFor(VideoControlItem item) {
      final LayerLink? popoverLink = item == VideoControlItem.speed
          ? _controlPopoverLinkFor(slot, item)
          : null;
      final Widget button = Tooltip(
        message: _videoControlItemTooltip(item),
        child: desktop
            ? MaterialDesktopCustomButton(
                icon: Icon(
                  _videoControlItemIcon(item),
                  size: _videoControlIconSize,
                ),
                onPressed: () => _activateVideoControlItem(
                  item,
                  controller,
                  popoverLink: popoverLink,
                  sourceSlot: slot,
                ),
              )
            : MaterialCustomButton(
                icon: Icon(
                  _videoControlItemIcon(item),
                  size: _videoControlIconSize,
                ),
                onPressed: () => _activateVideoControlItem(
                  item,
                  controller,
                  popoverLink: popoverLink,
                  sourceSlot: slot,
                ),
              ),
      );
      if (popoverLink == null) return button;
      return _controlPopoverAnchor(
        kind: _VideoControlPopoverKind.speed,
        link: popoverLink,
        desktop: desktop,
        sourceSlot: slot,
        sourceItem: VideoControlItem.speed,
        child: button,
      );
    }

    // 按钮组按**内容固有宽**收缩（`widthFactor: 1` + `shrinkWrap: true`），不再撑满
    // 分到的那份宽：这样 [_TopBarSlots] 才能先把两侧按钮要的宽度足额给出去、把真正
    // 剩下的宽度交给标题。用 ListView 而不是 SingleChildScrollView，正是因为后者的
    // viewport 在主轴上恒撑满约束（拿不到内容宽），窄窗仍靠横滚兜底按钮可达性。
    return Align(
      alignment: slot == VideoControlSlot.topRight
          ? Alignment.centerRight
          : Alignment.centerLeft,
      widthFactor: 1,
      child: HorizontalDragScrollable(
        child: ListView(
          scrollDirection: Axis.horizontal,
          shrinkWrap: true,
          padding: EdgeInsets.zero,
          reverse: slot == VideoControlSlot.topRight,
          children: <Widget>[
            Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: slot == VideoControlSlot.topRight
                  ? MainAxisAlignment.end
                  : MainAxisAlignment.start,
              children: <Widget>[
                for (final VideoControlItem item in items) buttonFor(item),
              ],
            ),
          ],
        ),
      ),
    );
  }

  String get _clipExportTooltip {
    if (_clipExporting) return t.video_clip_exporting;
    if (_clipExportMarking) return t.video_clip_export_stop;
    return t.video_clip_export_start;
  }

  IconData get _clipExportIcon {
    if (_clipExporting) return Icons.hourglass_top;
    if (_clipExportMarking) return Icons.stop_circle_outlined;
    return Icons.movie_creation_outlined;
  }

  /// Icon for any chip-renderable [VideoControlItem] (learning + transport/nav).
  IconData _videoControlItemIcon(VideoControlItem item) {
    // 自定义「快捷键」按钮没有固定图标：长相 = 当前绑定动作的图标（未绑定时是通用
    // 闪电图标）。这条与编辑器 chip 共用 [videoControlItemIcon]，两处永远同款。
    if (item.isCustomAction) {
      return videoControlItemIcon(item, bindings: _customActionBindings);
    }
    final VideoControlButton? legacy = item.legacyButton;
    if (legacy != null) return _videoControlButtonIcon(legacy);
    switch (item) {
      case VideoControlItem.playPause:
        return Icons.play_arrow_rounded;
      case VideoControlItem.back:
        return Icons.arrow_back;
      case VideoControlItem.immersiveLock:
        return _immersiveLocked.value
            ? Icons.lock_outline
            : Icons.lock_open_outlined;
      case VideoControlItem.seekBackward:
        return Icons.fast_rewind;
      case VideoControlItem.seekForward:
        return Icons.fast_forward;
      case VideoControlItem.frameBackward:
        return Icons.arrow_left;
      case VideoControlItem.frameForward:
        return Icons.arrow_right;
      case VideoControlItem.previousCue:
        return Icons.skip_previous;
      case VideoControlItem.nextCue:
        return Icons.skip_next;
      case VideoControlItem.fullscreen:
        return Icons.fullscreen;
      case VideoControlItem.screenshot:
        return Icons.photo_camera_outlined;
      case VideoControlItem.clipExport:
        return _clipExportIcon;
      case VideoControlItem.subtitleTrack:
        return Icons.subtitles;
      case VideoControlItem.audioTrack:
        return Icons.audiotrack;
      case VideoControlItem.previousEpisode:
        return Icons.skip_previous;
      case VideoControlItem.nextEpisode:
        return Icons.skip_next;
      case VideoControlItem.episodeList:
        return Icons.playlist_play;
      case VideoControlItem.previousChapter:
        return Icons.first_page;
      case VideoControlItem.nextChapter:
        return Icons.last_page;
      case VideoControlItem.chapterList:
        return Icons.format_list_numbered;
      // Non-chip special renders never reach here (filtered by isChipRenderable).
      case VideoControlItem.volume:
      case VideoControlItem.title:
      case VideoControlItem.positionIndicator:
      case VideoControlItem.speed:
      case VideoControlItem.subtitleList:
      case VideoControlItem.favoriteSentence:
      case VideoControlItem.settings:
        return Icons.tune;
      case VideoControlItem.customAction1:
      case VideoControlItem.customAction2:
      case VideoControlItem.customAction3:
      case VideoControlItem.customAction4:
        // 不可达：函数开头已委托 [videoControlItemIcon] 按绑定解析。
        return Icons.add;
    }
  }

  /// Tooltip for any chip-renderable [VideoControlItem].
  String _videoControlItemTooltip(VideoControlItem item) {
    // 自定义「快捷键」按钮：tooltip = 绑定动作的名字（未绑定时是「快捷键 N」槽位名）。
    if (item.isCustomAction) {
      return videoControlItemLabel(
        item,
        context,
        bindings: _customActionBindings,
      );
    }
    final VideoControlButton? legacy = item.legacyButton;
    if (legacy != null) return _videoControlButtonTooltip(legacy);
    switch (item) {
      case VideoControlItem.playPause:
        return t.video_control_play_pause;
      case VideoControlItem.back:
        return MaterialLocalizations.of(context).backButtonTooltip;
      case VideoControlItem.immersiveLock:
        return _immersiveLocked.value
            ? t.video_immersive_unlock
            : t.video_menu_lock;
      case VideoControlItem.seekBackward:
        return t.video_control_seek_backward;
      case VideoControlItem.seekForward:
        return t.video_control_seek_forward;
      case VideoControlItem.frameBackward:
        return t.shortcut_action_video_previous_frame;
      case VideoControlItem.frameForward:
        return t.shortcut_action_video_next_frame;
      case VideoControlItem.previousCue:
        return t.video_control_previous_cue;
      case VideoControlItem.nextCue:
        return t.video_control_next_cue;
      case VideoControlItem.fullscreen:
        return t.video_control_fullscreen;
      case VideoControlItem.screenshot:
        return t.video_control_screenshot;
      case VideoControlItem.clipExport:
        return _clipExportTooltip;
      case VideoControlItem.subtitleTrack:
        return t.video_control_subtitle_track;
      case VideoControlItem.audioTrack:
        return t.video_control_audio_track;
      case VideoControlItem.previousEpisode:
        return t.video_prev_episode;
      case VideoControlItem.nextEpisode:
        return t.video_next_episode;
      case VideoControlItem.episodeList:
        return t.video_control_episode_list;
      case VideoControlItem.previousChapter:
        return t.shortcut_action_video_previous_chapter;
      case VideoControlItem.nextChapter:
        return t.shortcut_action_video_next_chapter;
      case VideoControlItem.chapterList:
        return t.video_chapters;
      case VideoControlItem.volume:
      case VideoControlItem.title:
      case VideoControlItem.positionIndicator:
      case VideoControlItem.speed:
      case VideoControlItem.subtitleList:
      case VideoControlItem.favoriteSentence:
      case VideoControlItem.settings:
        return '';
      case VideoControlItem.customAction1:
      case VideoControlItem.customAction2:
      case VideoControlItem.customAction3:
      case VideoControlItem.customAction4:
        // 不可达：函数开头已委托 [videoControlItemLabel] 按绑定解析。
        return '';
    }
  }

  /// Activate any chip-renderable [VideoControlItem] (rail tap handler). Learning
  /// keys go through the legacy dispatcher; transport / nav keys call the same
  /// page methods the media_kit chrome uses, so behaviour is identical wherever
  /// the user places the button.
  void _activateVideoControlItem(
    VideoControlItem item,
    VideoPlayerController controller, {
    LayerLink? popoverLink,
    VideoControlSlot? sourceSlot,
  }) {
    // 自定义「快捷键」按钮，两种语义按是否绑过动作分流：
    //   · 已绑定 → 查**键盘 / 手柄用的同一张动作表**并执行。这里刻意不写第二套
    //     switch——[videoActionCallbacks] 已是「动作 → 本页具体操作」的唯一接线，屏幕
    //     按钮再抄一份就等于承诺两份实现永远一致（沉浸门控、防重入都在回调里）。
    //   · 未绑定 → 就地弹动作选择器配置它。播放器上只有第一个空槽会渲染成加号（见
    //     `_shouldRenderControlItem`），靠这条分流它才不至于变成按了没反应的死按钮。
    final int? slotIndex = item.customActionSlotIndex;
    if (slotIndex != null) {
      final ShortcutAction? action = _customActionBindings.actionAt(slotIndex);
      // 与其它控制条按钮一致：按一下续命控制条，否则 3s 到点隐藏、手指还在按钮上。
      // 弹选择器那条路尤其需要——弹窗期间控制条不该在背后自己消失。
      _pokeControlsVisible();
      if (action == null) {
        unawaited(_pickVideoCustomAction(slotIndex));
        return;
      }
      final VoidCallback? callback =
          videoActionCallbacks(_buildVideoShortcutActions(controller))[action];
      // 表里没有该动作（动作在新版被删）时静默 no-op，不崩。
      if (callback == null) return;
      callback();
      return;
    }
    final VideoControlButton? legacy = item.legacyButton;
    if (legacy != null) {
      _activateVideoControlButton(
        legacy,
        popoverLink: popoverLink,
        sourceSlot: sourceSlot,
      );
      return;
    }
    switch (item) {
      case VideoControlItem.back:
        unawaited(_handleBackOrExit());
        break;
      case VideoControlItem.immersiveLock:
        _toggleImmersiveLock();
        break;
      case VideoControlItem.playPause:
        // TODO-1059：按播放/暂停按钮也续命控制条（否则 3s 到点隐藏、手指还在按钮 = 误触）。
        _pokeControlsVisible();
        unawaited(controller.playOrPause());
        break;
      case VideoControlItem.seekBackward:
        unawaited(_seekRelative(-10000));
        break;
      case VideoControlItem.seekForward:
        unawaited(_seekRelative(10000));
        break;
      case VideoControlItem.frameBackward:
        _pokeControlsVisible();
        unawaited(controller.frameStep(forward: false));
        break;
      case VideoControlItem.frameForward:
        _pokeControlsVisible();
        unawaited(controller.frameStep(forward: true));
        break;
      case VideoControlItem.previousCue:
        unawaited(controller.skipToPrevCueOrSeekBack(
          seekSeconds: _asbConfig.seekSeconds,
        ));
        break;
      case VideoControlItem.nextCue:
        unawaited(controller.skipToNextCueOrSeekForward(
          seekSeconds: _asbConfig.seekSeconds,
        ));
        break;
      case VideoControlItem.fullscreen:
        // 控制条按钮属指针控制，沉浸锁定态走 full-controls 门控（非快捷键门控）。
        if (_immersiveAllowsFullControls) {
          final BuildContext? ctx = _videoControlsContext;
          if (ctx != null && ctx.mounted) {
            unawaited(_toggleVideoFullscreen(ctx));
          }
        }
        break;
      case VideoControlItem.screenshot:
        unawaited(_saveScreenshot());
        break;
      case VideoControlItem.clipExport:
        unawaited(_toggleClipExport());
        break;
      case VideoControlItem.subtitleTrack:
        unawaited(
          _showSubtitleSourceMenu(controller, sourceSlot: sourceSlot),
        );
        break;
      case VideoControlItem.audioTrack:
        _showAudioTrackMenu(controller, sourceSlot: sourceSlot);
        break;
      case VideoControlItem.previousEpisode:
        if (_isPlaylist && _currentEpisode > 0) {
          _switchEpisode(
            _currentEpisode - 1,
            intent: EpisodeStartIntent.manualPrevious,
          );
        }
        break;
      case VideoControlItem.nextEpisode:
        if (_isPlaylist && _currentEpisode < _episodes.length - 1) {
          _switchEpisode(
            _currentEpisode + 1,
            intent: EpisodeStartIntent.manualNext,
          );
        }
        break;
      case VideoControlItem.episodeList:
        _showEpisodeList();
        break;
      case VideoControlItem.previousChapter:
        _pokeControlsVisible();
        unawaited(controller.previousChapter());
        break;
      case VideoControlItem.nextChapter:
        _pokeControlsVisible();
        unawaited(controller.nextChapter());
        break;
      case VideoControlItem.chapterList:
        _showChapterPanel(controller, sourceSlot: sourceSlot);
        break;
      // Non-chip / handled-by-legacy items never reach here.
      case VideoControlItem.volume:
      case VideoControlItem.title:
      case VideoControlItem.positionIndicator:
      case VideoControlItem.speed:
      case VideoControlItem.subtitleList:
      case VideoControlItem.favoriteSentence:
      case VideoControlItem.settings:
      // 不可达：函数开头已按绑定查 [videoActionCallbacks] 执行并 return。
      case VideoControlItem.customAction1:
      case VideoControlItem.customAction2:
      case VideoControlItem.customAction3:
      case VideoControlItem.customAction4:
        break;
    }
  }

  /// 底栏传输组：`[−10s][上一句][play][下一句][+10s]`，[play] 钉在几何正中（BUG-257）。
  ///
  /// 根因：旧底栏 `[时间] Spacer [seek 簇] Spacer [尾部按钮…]` 用两个 [Spacer] 在「时间」
  /// 与「尾部按钮」间均分，尾部按钮越多 seek 簇离整条几何中心越远 → play 偏左。改用 [Stack]
  /// 三区绝对定位：左区时间、右区尾部按钮、[Center] 居中 seek 簇，play 恒处几何中心、两侧
  /// seek 对称，与尾部按钮数量无关。桌面/移动共用本布局（仅控件类型与播放暂停按钮不同）。
  Widget _centeredBottomControlBar(
    VideoPlayerController controller, {
    required bool desktop,
  }) {
    // 底栏时间前景走 chrome 固定亮色强调色（压固定深色 scrim，不随 colorScheme）。
    final Color chromeAccent =
        _videoChromeAccent(Theme.of(context).colorScheme);
    final bool roomyBottomBar = _hasRoomyVideoBottomBar();
    final Widget positionIndicator = desktop
        ? MaterialDesktopPositionIndicator(
            style: TextStyle(
              height: 1.0,
              fontSize: 12.0 * _videoUiScale,
              color: chromeAccent,
            ),
          )
        : MaterialPositionIndicator(
            style: TextStyle(
              height: 1.0,
              fontSize: 12.0 * _videoUiScale,
              color: chromeAccent,
            ),
          );
    final List<Widget> rightCluster = <Widget>[
      ..._bottomSlotButtons(
        VideoControlSlot.bottomRight,
        controller,
        desktop: desktop,
        roomyBottomBar: roomyBottomBar,
      ),
    ];
    // seek 传输簇（居中绝对定位）：从 bottomCenter slot 取真实顺序。默认仍是
    // `[−10s][上一句][play][下一句][+10s]`，移动后不再硬编码重复。
    final Widget transport = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ..._bottomSlotButtons(
          VideoControlSlot.bottomCenter,
          controller,
          desktop: desktop,
          roomyBottomBar: roomyBottomBar,
        ),
      ],
    );
    // 左区：时间指示器 + bottomLeft slot 按钮。与中心簇绝对独立，宽度变化不挤偏 play。
    final List<Widget> leftCluster = <Widget>[
      if (_controlLayout
          .itemsIn(VideoControlSlot.bottomLeft)
          .contains(VideoControlItem.positionIndicator))
        positionIndicator,
      ..._bottomSlotButtons(
        VideoControlSlot.bottomLeft,
        controller,
        desktop: desktop,
        roomyBottomBar: roomyBottomBar,
      ),
    ];
    return Stack(
      alignment: Alignment.center,
      children: <Widget>[
        // 居中传输簇：play 恒处整条底栏几何中心。
        Center(child: transport),
        // 左区：时间指示器 + bottomLeft 自定义按钮。
        Align(
          alignment: Alignment.centerLeft,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: leftCluster,
          ),
        ),
        // 右区：自定义按钮 + 音量 + 全屏（宽度变化不挤偏 play）。
        Align(
          alignment: Alignment.centerRight,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: rightCluster,
          ),
        ),
      ],
    );
  }

  /// 带可见标注的 seek 按钮（图标 + `−10s`/`+10s`）。media_kit 的 `MaterialCustomButton`
  /// 只接受单 icon、无可见文字，用户看不懂图标（BUG-257）；这里用 [InkWell] 自绘
  /// 图标 + 紧凑标注，颜色对齐 `buttonBarButtonColor`（cs.primary），仍带 [Tooltip]。
  ///
  /// TODO-1098：单击 seek 一次，长按连续 seek（[_VideoRepeatGestureButton]：先触发
  /// 一次 + 500ms 后每 100ms 一次，松手停）。画面区长按已被临时变速占用（speed.part），
  /// 这里只包按钮自身的手势，不影响画面层。
  Widget _seekLabelButton({
    required IconData icon,
    required String label,
    required String tooltip,
    required Color color,
    required VoidCallback onPressed,
  }) {
    return _VideoRepeatGestureButton(
      onTrigger: onPressed,
      child: _seekLabelButtonContent(
        icon: icon,
        label: label,
        tooltip: tooltip,
        color: color,
        onTap: onPressed,
      ),
    );
  }

  /// [_seekLabelButton] 的视觉体（[InkWell] 单击 + 图标/标注）。抽出以便长按包装器
  /// [_VideoRepeatGestureButton] 复用同一视觉，单击路径不变。
  Widget _seekLabelButtonContent({
    required IconData icon,
    required String label,
    required String tooltip,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        customBorder: const StadiumBorder(),
        child: Padding(
          padding: EdgeInsets.symmetric(
            horizontal: 6 * _videoUiScale,
            vertical: 4 * _videoUiScale,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(icon, size: _videoControlIconSize * 0.82, color: color),
              SizedBox(width: 2 * _videoUiScale),
              Text(
                label,
                style: TextStyle(
                  height: 1.0,
                  fontSize: 11.0 * _videoUiScale,
                  fontWeight: FontWeight.w600,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 逐帧后退 / 前进按钮（桌面专属，[_shouldRenderControlItem] 已门控）。图标按钮，
  /// 单击步进一帧，长按连续步进（[_VideoRepeatGestureButton]，与 seek 按钮同款节律）。
  /// [forward] true=下一帧、false=上一帧。底层 [VideoPlayerController.frameStep] 内部
  /// 先 pause 再走 mpv frame-step / frame-back-step。
  Widget _frameStepButton(
    VideoPlayerController controller, {
    required bool forward,
  }) {
    final IconData icon = forward ? Icons.arrow_right : Icons.arrow_left;
    final String tooltip = forward
        ? t.shortcut_action_video_next_frame
        : t.shortcut_action_video_previous_frame;
    void trigger() {
      _pokeControlsVisible();
      unawaited(controller.frameStep(forward: forward));
    }

    return _VideoRepeatGestureButton(
      onTrigger: trigger,
      child: Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: trigger,
          customBorder: const CircleBorder(),
          child: Padding(
            padding: EdgeInsets.all(4 * _videoUiScale),
            child: Icon(
              icon,
              size: _videoControlIconSize * 0.9,
              color: _videoChromeAccent(Theme.of(context).colorScheme),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVideoControlButton(
    VideoPlayerController controller,
    VideoControlButton button, {
    required bool desktop,
    required VideoControlSlot slot,
  }) {
    final LayerLink? popoverLink = button == VideoControlButton.speed
        ? _controlPopoverLinkFor(slot, VideoControlItem.speed)
        : null;
    final Widget icon = Icon(
      _videoControlButtonIcon(button),
      size: _videoControlIconSize,
    );
    final Widget controlButton = desktop
        ? MaterialDesktopCustomButton(
            icon: icon,
            onPressed: () => _activateVideoControlButton(
              button,
              popoverLink: popoverLink,
              sourceSlot: slot,
            ),
          )
        : MaterialCustomButton(
            icon: icon,
            onPressed: () => _activateVideoControlButton(
              button,
              popoverLink: popoverLink,
              sourceSlot: slot,
            ),
          );
    if (popoverLink == null) return controlButton;
    return _controlPopoverAnchor(
      kind: _VideoControlPopoverKind.speed,
      link: popoverLink,
      desktop: desktop,
      sourceSlot: slot,
      sourceItem: VideoControlItem.speed,
      child: controlButton,
    );
  }

  IconData _videoControlButtonIcon(VideoControlButton button) {
    switch (button) {
      case VideoControlButton.speed:
        return Icons.speed;
      case VideoControlButton.subtitleList:
        return Icons.format_list_bulleted;
      case VideoControlButton.favoriteSentence:
        return Icons.star_border_rounded;
      case VideoControlButton.settings:
        return Icons.tune;
    }
  }

  String _videoControlButtonTooltip(VideoControlButton button) {
    switch (button) {
      case VideoControlButton.speed:
        return t.video_control_speed;
      case VideoControlButton.subtitleList:
        return t.video_control_subtitle_list;
      case VideoControlButton.favoriteSentence:
        return t.video_control_favorite_sentence;
      case VideoControlButton.settings:
        return t.video_control_settings;
    }
  }

  void _activateVideoControlButton(
    VideoControlButton button, {
    LayerLink? popoverLink,
    VideoControlSlot? sourceSlot,
  }) {
    switch (button) {
      case VideoControlButton.speed:
        _showSpeedMenu(popoverLink: popoverLink, sourceSlot: sourceSlot);
        break;
      case VideoControlButton.subtitleList:
        _toggleSubtitleJumpList();
        break;
      case VideoControlButton.favoriteSentence:
        unawaited(_toggleFavoriteCurrentCue());
        break;
      case VideoControlButton.settings:
        _showPlayerSettings(sourceSlot: sourceSlot);
        break;
    }
  }

  bool _hasRoomyVideoBottomBar() => MediaQuery.of(context).size.width >= 600;

  /// 系统底部安全区 inset（BUG-184 / TODO-658·BUG-383）：导航栏 / 手势条**真正可见时**
  /// 的物理高度，用来把进度条与底部按钮条抬离系统栏。视频打开后走 immersiveSticky 隐藏
  /// 导航栏，常态下系统栏不可见 → 返回 0（基线 [_videoBottomChromeBaseline] 仍保证进度条
  /// 不贴最底）；导航栏真显示（三键导航 / 上划临时唤出）时返回 `viewPadding.bottom`，进度
  /// 条随之上移避开（保 BUG-184 本意）。
  ///
  /// **为何先判 [_systemBarsVisible] 而非直接读 inset**（TODO-658 根因）：targetSdk 35
  /// 强制 edge-to-edge + 手势导航下，`viewPadding.bottom`（与 `padding.bottom` 同源，仅
  /// 差键盘）即便 immersiveSticky 已隐栏仍恒上报手势条高度，单读 inset 会把进度条永久顶高
  /// （BUG-370）。故用 [SystemChrome.setSystemUIChangeCallback] 喂的真实可见性当门控：隐栏
  /// 时直接归零，可见时才取物理 inset。桌面 [_systemBarsVisible] 恒 false（不注册回调）→
  /// 始终 0，桌面无系统栏，符合预期。
  double _videoBottomSystemInset() =>
      _systemBarsVisible ? MediaQuery.of(context).viewPadding.bottom : 0.0;

  /// 系统顶部安全区 inset（BUG-463）：把视频内顶栏（media_kit 控制条 [topButtonBar]）
  /// 抬离状态栏 / 刘海，否则顶栏左右按钮被遮挡、点不到（用户报「顶栏的按钮会被挡住」）。
  ///
  /// **为何顶栏需要而底栏另有 helper**：fork 的 [MaterialVideoControls] 只在**全屏**时给
  /// 顶栏 Column 套 `MediaQuery.padding` 顶部内缩（material.dart 的
  /// `isFullscreen ? MediaQuery.padding : EdgeInsets.zero`），窗口态外层 padding 恒
  /// `EdgeInsets.zero`。而移动端视频**永不进 media_kit 全屏路由**（BUG-221，
  /// [_toggleVideoFullscreen] 移动端 no-op）→ 顶栏始终落在窗口分支、顶部 inset 从不生效，
  /// 顶栏按钮永远贴 `y=0`，被状态栏 / 刘海盖住。故在 [_mobileControlsTheme] 的
  /// `topButtonBarMargin.top` 显式补这一段，与底栏 [_videoBottomSystemInset] 对称。
  ///
  /// **为何同时读 `padding` / `viewPadding` 并用 [_systemBarsVisible] 门控 top**
  /// （BUG-556）：immersiveSticky 隐栏后 `viewPadding.top` 仍可恒上报状态栏区高度，单读它
  /// 会把顶栏永久顶低一段空白；但 iOS 横竖屏切换 / 系统栏临时显隐期间，`padding.top`
  /// 也可能带着过渡态旧值，单读它会让顶栏“有时候”被下压到不准位置。故顶部与底栏
  /// [_videoBottomSystemInset] 对齐：只有系统栏真实可见时才吃 `viewPadding.top`，隐栏时
  /// 归零。左右 cutout 不受系统栏显隐影响，持续用 viewPadding/padding 逐边取 max。
  ///
  /// 左 / 右用 `max(16, padding/viewPadding.left/right)`：与浮动侧栏 [_mergeRailSafeAreaPadding] 同款
  /// 逐边取 max——横屏刘海手机（cutout 落在短边 = 左 / 右）下顶栏左 / 右按钮也避开刘海，
  /// 又不在无刘海时把默认 16 叠加成双重留白。几何收敛进纯函数 [videoTopBarMargin]
  /// （页面与测试同源调用）。
  EdgeInsets _videoTopBarMargin() => videoTopBarMargin(
        systemPadding: MediaQuery.of(context).padding,
        systemViewPadding: MediaQuery.of(context).viewPadding,
        systemBarsVisible: _systemBarsVisible,
      );

  /// 字幕动态避让的「进度条上缘」高度（BUG-238 / BUG-901）：控制条可见时字幕底缘对它取
  /// 下限（`max(bottomPadding, reserve)`，见 [VideoSubtitleOverlay]）。由当前平台真实控制条
  /// 几何加总（同名 getter 已 ×[_videoUiScale]），故随界面缩放一起变大——旧默认常量 56
  /// 既不随缩放、又低于默认基线 75，移动端 `max(75,56)=75` 把字幕留在被抬高的进度条
  /// 下面被遮。桌面进度条骑按钮行上沿 → 只让一个按钮行高（保 BUG-228 观感）；移动端
  /// 进度条整体被 [_mobileControlsTheme] 抬到按钮行上方 → 让出其**触摸热区上缘**（含轨道
  /// 上方那段透明可点区），字幕命中区整体清出 seek 命中区、不再挨太近误触（BUG-901）。
  double _subtitleControlsBottomReserve() {
    return videoSubtitleControlsReserve(
      isDesktop: _isDesktopVideoControls,
      buttonBarHeight: _videoButtonBarHeight,
      seekBarButtonGap: _videoSeekBarButtonGap,
      // BUG-901：用**触摸热区全高**（进度条真正可点目标，含可见轨道上方那段透明 seek
      // 命中区）+ 呼吸间距，让字幕命中区整体骑在进度条整段可点区上方，与 seek 不重叠。
      // 只让可见轨道高（旧 TODO-568）会让字幕落进那段透明热区、两命中区在同一竞技场误触。
      // BUG-1224：必须取**当前平台 theme 真实生效**的热区高（桌面 36 不随缩放 / 移动
      // 40×缩放），并减去桌面把进度条下压骑按钮行上沿的重叠量，才是真的热区上缘。
      seekBarContainerHeight: _activeSeekBarContainerHeight,
      seekBarBottomButtonBarOverlap: _activeSeekBarButtonBarOverlap,
      subtitleBreathingGap: _videoSubtitleSeekBarBreathingGap,
      bottomChromeBaseline: _videoBottomChromeBaseline,
      bottomSystemInset: _videoBottomSystemInset(),
    );
  }

  /// 字幕动态避让的「顶栏下缘」高度（BUG-1069）：控制条可见时**顶部锚字幕**顶缘对它取
  /// 下限（`max(用户顶距, reserve)`，见 [VideoSubtitleOverlay._paddingFor]），躲开视频内嵌
  /// 顶栏（标题栏 + 右上角菜单，替代被删的 AppBar，BUG-102），避免字幕把 UI 盖住。与
  /// [_subtitleControlsBottomReserve] 对称：顶栏下缘 = 顶部系统 inset（`_videoTopBarMargin`，
  /// 桌面为 0；移动端抬离状态栏/刘海）+ 一个（已缩放）按钮行高 + 字幕呼吸间距。
  double _subtitleControlsTopReserve() {
    return videoSubtitleControlsTopReserve(
      buttonBarHeight: _videoButtonBarHeight,
      topSystemInset: _videoTopBarMargin().top,
      subtitleBreathingGap: _videoSubtitleSeekBarBreathingGap,
    );
  }

  /// 设置音画延迟（毫秒）：即时调 controller（字幕 cue 同步偏移立即生效，BUG-373：
  /// controller 侧 [VideoPlayerController.setDelayMs] 已立即重算当前 cue + notify）+
  /// 持久化到 VideoBook.delayMs（换集复用、跨重启保留）+ 刷新面板显示 + 左上角 OSD
  /// 即时反馈（BUG-373：与调速 [Icons.speed] 同范式，让快速设置面板外也看得到调整生效）。
  Future<void> _setDelayMs(int delayMs) async {
    final int clamped =
        delayMs.clamp(-kVideoSubtitleDelayLimitMs, kVideoSubtitleDelayLimitMs);
    if (clamped == _delayMs) return;
    _delayMs = clamped;
    _controller?.setDelayMs(clamped);
    // BUG-373：左上角 OSD 即时反馈。带显式正负号（与面板内 +N ms 回显一致），
    // 让用户在不打开快速设置面板时也能看到字幕同步已调整、调多少。
    final String signed = clamped >= 0 ? '+$clamped' : '$clamped';
    _showOsd(
      t.video_subtitle_delay_osd(ms: signed),
      icon: Icons.sync_outlined,
    );
    // 同系列调轴记忆（schema v52）：合集内调轴写系列级，全系列共享（换集/从书架重进
    // 任一集都读到同一值）；单文件视频（无合集）仍走 per-book，行为与旧版一致。所有
    // 调轴入口（z/x 微调、asbplayer 对齐、面板滑条/输入/自动对轴）都汇聚到此，写入
    // 分流一处覆盖全部。
    //
    // 互联远端调轴不持久化 bug 根因修复：远端播放（[_isRemote]）在 client 无
    // VideoBooks 行，旧路径 `updateDelayMs(远端uid)` 是**静默 0 行 UPDATE**（调轴落
    // 在空气里），重进又被 host 清单值覆盖归 0。改按稳定远端 uid 落 prefs（断点
    // TODO-559/653 同款范式，跨重启保留）+ best-effort 上报 host（host 侧「严格较新
    // 时间戳者胜」+ 写穿行值，使 host 本机与其它设备跟随；失败/旧 host 无端点只记
    // 日志——本地 prefs 已写，不阻塞播放）。合集连播键 = 当前成员 id（与断点键
    // [_remotePositionKeyForIndex] 同构，成员天然隔离）。
    if (_isRemote) {
      final int nowMs = DateTime.now().millisecondsSinceEpoch;
      final (String uid, _) = _remotePositionKeyForIndex(_currentEpisode);
      await appModel.prefsRepo.setPref(videoRemoteDelayPrefKey(uid), clamped);
      await appModel.prefsRepo.setPref(videoRemoteDelayAtPrefKey(uid), nowMs);
      _pushRemotePlayback(
          uid, VideoPlaybackSyncState(delayMs: clamped, delayAt: nowMs));
    } else {
      final int? collectionId = widget.playlistCollectionId;
      if (collectionId != null) {
        // 系列级写入内聚盖戳：repo 会把值 + now 镜像进**全体视频成员**的
        // `video_remote_delay_` prefs 对（互联 LWW 用，见 repo doc），此处无需重复。
        await widget.repo
            .updateCollectionSubtitleDelayMs(collectionId, clamped);
      } else {
        await widget.repo.updateDelayMs(widget.bookUid, clamped);
        // 本机调轴镜像盖戳（断点 TODO-816 同范式）：调轴 + now 写进与互联同一键
        // 空间，使 host 侧 getVideoDelay / 清单以带戳值参与 LWW——否则对端上报过
        // 一次后，本机后续调轴（row 无戳恒 0）永远输给旧戳、再也传不出去。
        await appModel.prefsRepo
            .setPref(videoRemoteDelayPrefKey(widget.bookUid), clamped);
        await appModel.prefsRepo.setPref(
            videoRemoteDelayAtPrefKey(widget.bookUid),
            DateTime.now().millisecondsSinceEpoch);
      }
    }
    if (mounted) setState(() {});
  }

  /// 设置**副字幕**独立调轴（毫秒，TODO-2837）：null = 清除独立值、回到跟随主字幕
  /// [_delayMs]。即时调 controller（副字幕活动集立即按新轴重算）+ 两层持久化镜像
  /// [_setDelayMs]（合集内写系列级、否则写 per-book）+ 左上角 OSD 即时反馈。
  ///
  /// 「重置为跟随」在合集内**两层都清**（系列级 + 本集 per-book）：决议是
  /// `系列级 ?? per-book`，只清系列级会让本集在单集时代留下的旧独立值复活——
  /// 「跟随」的语义是两层皆 null，一次写干净，不留特例。
  Future<void> _setSecondaryDelayMs(int? delayMs) async {
    final int? clamped = delayMs?.clamp(-600000, 600000);
    if (clamped == _secondaryDelayMs) return;
    _secondaryDelayMs = clamped;
    _controller?.setSecondaryDelayMs(clamped);
    if (clamped == null) {
      _showOsd(
        t.video_subtitle_secondary_delay_follow_osd,
        icon: Icons.sync_outlined,
      );
    } else {
      final String signed = clamped >= 0 ? '+$clamped' : '$clamped';
      _showOsd(
        t.video_subtitle_secondary_delay_osd(ms: signed),
        icon: Icons.sync_outlined,
      );
    }
    // TODO-2837 副字幕调轴入同步通道（播放偏好同步泛化批）：远端按 uid 落带戳
    // 键对 + 上报 host；null（回跟随）也是一次带戳写，清除同样跨设备收敛。
    if (_isRemote) {
      final (String uid, _) = _remotePositionKeyForIndex(_currentEpisode);
      final int nowMs = await _stampRemoteStringPref(
          videoRemoteSecondaryDelayPrefKey(uid),
          videoRemoteSecondaryDelayAtPrefKey(uid),
          clamped?.toString());
      _pushRemotePlayback(
          uid,
          VideoPlaybackSyncState(
              secondaryDelayMs: clamped, secondaryDelayAt: nowMs));
      if (mounted) setState(() {});
      return;
    }
    final int? collectionId = widget.playlistCollectionId;
    if (collectionId != null) {
      await widget.repo
          .updateCollectionSecondarySubtitleDelayMs(collectionId, clamped);
      if (clamped == null) {
        // 重置为跟随：连本集 per-book 旧值一起清（见 doc，消除回退复活特例）。
        await widget.repo.updateSecondaryDelayMs(widget.bookUid, null);
      }
    } else {
      await widget.repo.updateSecondaryDelayMs(widget.bookUid, clamped);
    }
    // 本机镜像盖戳（互联 LWW 载体；断点 TODO-816 同范式）：使 host 侧
    // getVideoPlayback / 清单以带戳值参与逐字段 LWW。
    await _stampRemoteStringPref(
        videoRemoteSecondaryDelayPrefKey(widget.bookUid),
        videoRemoteSecondaryDelayAtPrefKey(widget.bookUid),
        clamped?.toString());
    if (mounted) setState(() {});
  }

  /// TODO-099: 进入视频页时锁横屏（移动端）。只锁本页，不动全 app
  /// 默认方向策略（保护竖排小说能竖屏）；退出由 [_restoreOrientationOnExit] 还原。
  /// 桌面门控 no-op（桌面窗口不走设备方向）。
  Future<void> _lockLandscapeForVideo() async {
    if (!isMobilePlatform) return;
    await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  /// TODO-158/BUG-219: 视频页持有「沉浸隐藏系统栏」所有权（移动端）。在 [initState]
  /// 显式设、在 [didChangeAppLifecycleState] 的 `resumed` 重申，让系统栏在视频期间
  /// **持续隐藏**，而非只靠 [AppModel.openMedia] 打开媒体时一次性设、从不复申。
  ///
  /// 用 [SystemUiMode.immersiveSticky]（与 openMedia 既有基线一致）：上划仍可临时
  /// 唤出系统栏，但随后自动重隐；配合 `resumed` 重申覆盖后台返回 / 通知栏交互后的
  /// 残留。严格限本页：不动 openMedia（书 / 视频共用入口，竖排小说由 reader 自设
  /// edgeToEdge 覆盖、首页由 setHomeShellSystemUiMode 接管），退出由 [AppModel.closeMedia]
  /// 的 setHomeShellSystemUiMode 统一还原。桌面门控 no-op（桌面无系统栏）。
  Future<void> _applyVideoImmersiveMode() async {
    if (!isMobilePlatform) return;
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  /// TODO-099: 退出视频页时还原为 app 默认允许态（竖屏 + 两个横屏，
  /// 与 [main] 初始化一致），而非空列表（空列表会放开 4 向含倒置）。在
  /// 同步 [dispose] 里可靠还原，不把阅读器 / 首页锁死在横屏。桌面门控 no-op。
  Future<void> _restoreOrientationOnExit() async {
    if (!isMobilePlatform) return;
    await SystemChrome.setPreferredOrientations(<DeviceOrientation>[
      DeviceOrientation.portraitUp,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  /// BUG-2105：释放本页对**进程级显示态**的所有权，并**仅在本页是最后一个持有者时**
  /// 还原它们（系统栏可见性回调 / 屏幕方向允许态 / macOS 交通灯）。
  ///
  /// 三件都是进程唯一的全局单槽，谁最后设谁生效。换集的窗口模式分支
  /// （[_VideoEpisode._switchEpisode]）用 `pushReplacement`，Flutter 语义下旧路由要等
  /// 新页入场动画结束才被移除并 `dispose` —— 于是真实顺序是「新页 initState 认领并设好
  /// 三件 → 旧页 dispose」。旧实现在 dispose 里无条件还原，等于把新页刚设的显示态掀掉：
  /// 方向集被放宽成含 `portraitUp`（移动端开着自动旋转锁定时会退回用户锁定的竖屏，
  /// 观感就是「换集后掉出全屏播放」）、系统栏可见性回调被置空（此后
  /// [_systemBarsVisible] 再不更新，进度条 / 字幕避让几何回到 BUG-383 的错态）。
  ///
  /// 判据交给 [VideoDisplayClaim.release]（纯 Dart 登记表，真值可单测），这里只消费
  /// 布尔结论，不在页面里手写「还有没有别人持有」。释放幂等：`release` 对没认领过的
  /// owner 返回 false。
  void _releaseVideoDisplayClaim() {
    if (!VideoDisplayClaim.release(this)) return;
    // TODO-658/BUG-383: 摘除系统栏可见性回调（全局单例，避免退页后仍回调已释放 State）。
    if (isMobilePlatform) {
      unawaited(SystemChrome.setSystemUIChangeCallback(null));
    }
    // TODO-099: 还原屏幕方向允许态（移动端），不把其他页锁死在横屏；桌面 no-op。
    unawaited(_restoreOrientationOnExit());
    // BUG-973: 恢复 macOS 系统交通灯（与 initState 的隐藏对称）；非 macOS 恒 no-op。
    unawaited(setMacOSTrafficLightsHidden(false));
  }

  Future<void> _setLockWindowAspectRatio(bool value) async {
    if (_lockWindowAspectRatio == value) return;
    _lockWindowAspectRatio = value;
    await appModel.setVideoLockWindowAspectRatio(value);
    await _syncWindowAspectRatioLock();
    if (mounted) setState(() {});
  }

  /// 切画面缩放/比例模式（TODO-152 子B）：落盘 + setState 重建窗口 Video（fit 换算变化）。
  /// 全屏路由的 Video 在其 builder 内读 [_videoFitMode] 经 [videoFitModeToBoxFit] 换算，
  /// 故全屏在栈上时本 setState 不重建它，但下次进全屏/退回窗口都跟随新偏好。
  Future<void> _setVideoFitMode(VideoFitMode mode) async {
    if (_videoFitMode == mode) return;
    _videoFitMode = mode;
    _controller?.configureHdrOutput(fitMode: mode);
    await appModel.setVideoFitMode(mode);
    if (mounted) setState(() {});
  }

  /// 切 HDR 直通 / 10-bit 输出模式：落盘 + 控制器当场重判（切宿主窗不重建播放器）。
  Future<void> _setVideoHdrOutputMode(VideoHdrOutputMode mode) async {
    if (_videoHdrOutputMode == mode) return;
    _videoHdrOutputMode = mode;
    _controller?.configureHdrOutput(mode: mode);
    await appModel.setVideoHdrOutputMode(mode);
  }

  /// Persist + apply a new 9-slot control button layout (TODO-274/312 phase 2).
  /// This is the single write path the quick-settings editor calls; it stores
  /// the v3 layout (same pref key, auto-migrating old v1/v2 blobs). Keep the
  /// notifier update before persistence so the active controls rebuild
  /// immediately after quick settings or the on-player editor saves.
  Future<void> _setVideoControlLayout(VideoControlLayout layout) async {
    _controlLayoutNotifier.value = layout;
    await appModel.setVideoControlLayout(layout);
    if (mounted) setState(() {});
  }

  /// 落盘 + 即时生效「快捷键 1..4」按钮的新绑定。与 [_setVideoControlLayout] 同款：
  /// 先推 notifier（控制层与全屏子树立刻重建，图标/行为当场变），再持久化。
  Future<void> _setVideoCustomActionBindings(
    VideoCustomActionBindings bindings,
  ) async {
    _customActionBindingsNotifier.value = bindings;
    await appModel.setVideoCustomActionBindings(bindings);
    if (mounted) setState(() {});
  }

  /// 在播放器上直接点空的「快捷键 N」按钮 → 就地选动作。手机上最短的配置路径：
  /// 看得见、点得到、当场配好，不用先翻进设置面板找控件编辑器。选择器与编辑器共用
  /// [showVideoCustomActionPicker]，列表与选中态两处必然一致。
  ///
  /// guardOverlay：弹窗走 root navigator 会夺走视频键盘焦点，任何退出路径（选完 /
  /// Esc / 点外部 / 抛异常）都必须归还，否则关掉弹窗后空格等快捷键要等到下次点画面
  /// 才恢复——这是本页所有覆盖层的既有范式（见 [_openSubtitleWaveformAlign]）。
  Future<void> _pickVideoCustomAction(int slotIndex) async {
    final ShortcutAction? current = _customActionBindings.actionAt(slotIndex);
    final VideoCustomActionPick? pick = await _focusOwnership.guardOverlay(
      () => showVideoCustomActionPicker(
        context: context,
        slotNumber: slotIndex + 1,
        current: current,
      ),
    );
    // null = 取消（点外部 / 返回键）；显式选「不绑定」是 VideoCustomActionPick(null)。
    if (pick == null || !mounted) return;
    final VideoCustomActionBindings next =
        _customActionBindings.withAction(slotIndex, pick.action);
    if (next == _customActionBindings) return;
    await _setVideoCustomActionBindings(next);
  }

  // 原 `_showVideoControlEditOverlay`（TODO-440 画面内拖拽编辑入口）已删：旧面板只
  // 声明了 onEditControlsOnscreen 参数从未渲染入口，方法早已不可达；schema 投影版
  // 不再保留死参数。关闭路径（_hideVideoControlEditOverlay）仍被浮层互斥逻辑使用。
  void _hideVideoControlEditOverlay({bool revealControls = true}) {
    if (!_videoControlEditMode.value) return;
    _videoControlEditMode.value = false;
    if (revealControls) _pokeControlsVisible();
    _focusOwnership.reclaim(FocusReclaimCause.overlayClosed);
  }

  Future<void> _clearWindowAspectRatioLock() async {
    if (!isDesktopPlatform || _appliedWindowAspectRatio == null) return;
    _appliedWindowAspectRatio = null;
    try {
      await windowManager.setAspectRatio(0);
    } catch (e, stack) {
      ErrorLogService.instance.log('VideoFushi.windowAspect.clear', e, stack);
    }
  }

  Future<void> _setAsbConfig(VideoAsbplayerConfig config) async {
    _asbConfig = config;
    _controller?.setPauseAtSubtitleEnd(config.pauseAtSubtitleEnd);
    await appModel.setVideoAsbplayerConfig(VideoAsbplayerConfig.encode(config));
    if (mounted) setState(() {});
  }

  Future<void> _syncWindowAspectRatioLock() async {
    if (!isDesktopPlatform) return;
    final VideoPlayerController? controller = _controller;
    if (!_lockWindowAspectRatio || controller == null) {
      await _clearWindowAspectRatioLock();
      return;
    }
    final int? width = controller.videoWidth;
    final int? height = controller.videoHeight;
    if (width == null || height == null || width <= 0 || height <= 0) return;
    final double aspectRatio = width / height;
    if (_appliedWindowAspectRatio != null &&
        (_appliedWindowAspectRatio! - aspectRatio).abs() < 0.0001) {
      return;
    }
    _appliedWindowAspectRatio = aspectRatio;
    try {
      await windowManager.setAspectRatio(aspectRatio);
    } catch (e, stack) {
      ErrorLogService.instance.log('VideoFushi.windowAspect.set', e, stack);
    }
  }

  /// 持久化字幕外观并刷新 overlay（纯 Flutter overlay，不碰 mpv）。
  /// TODO-1105：持久化「尊重 .ass 自带样式」开关并重建，使字幕 overlay 即时按新开关渲染。
  /// 遮蔽态「悬停 / 点击显形」总闸（设置面板 / 全局设置页共用）：落盘后重建本页，
  /// overlay 立刻按新值决定悬停 / 点击是否还能揭开遮蔽。
  Future<void> _setVideoSubtitleObscureReveal(bool value) async {
    await appModel.setVideoSubtitleObscureReveal(value);
    if (!mounted) return;
    _rebuild(() {});
  }

  Future<void> _setVideoRespectAssStyle(bool value) async {
    await appModel.setVideoRespectAssStyle(value);
    if (!mounted) return;
    _rebuild(() {});
  }

  Future<void> _persistSubtitleStyle(VideoSubtitleStyle style) async {
    _subtitleStyle = style;
    await appModel.setVideoSubtitleStyle(VideoSubtitleStyle.encode(style));
    if (mounted) setState(() {});
  }

  /// 切换字幕模糊（'B' 热键 + 设置面板共用）。TODO-840 Part B：在「模糊」与「不遮蔽」
  /// 之间切换——若当前是模糊则关掉，否则置为模糊（从隐藏态按 B 也回到模糊，符合「B 管
  /// 模糊」直觉）。隐藏态由 [_toggleSubtitleHide] / [_cycleSubtitleObscure] 管理。
  Future<void> _toggleSubtitleBlur() async {
    final VideoSubtitleObscureMode next =
        appModel.videoSubtitleObscureMode == VideoSubtitleObscureMode.blur
            ? VideoSubtitleObscureMode.none
            : VideoSubtitleObscureMode.blur;
    await _setSubtitleObscureMode(next);
  }

  /// 循环字幕遮蔽三态（Shift+B，TODO-840 Part B）：不遮蔽 → 模糊 → 隐藏 → …。
  Future<void> _cycleSubtitleObscure() async {
    await _setSubtitleObscureMode(appModel.videoSubtitleObscureMode.next);
  }

  /// 开/关「隐藏主字幕」（H，TODO-840 Part B）：隐藏态按 H 回到不遮蔽，否则置为隐藏。
  Future<void> _toggleSubtitleHide() async {
    final VideoSubtitleObscureMode next =
        appModel.videoSubtitleObscureMode == VideoSubtitleObscureMode.hide
            ? VideoSubtitleObscureMode.none
            : VideoSubtitleObscureMode.hide;
    await _setSubtitleObscureMode(next);
  }

  /// 落盘字幕遮蔽模式并刷新页面 overlay（热键 + 快速设置面板共用，TODO-840 Part B）。
  ///
  /// **先刷 UI、再等落盘**：[PreferencesRepository.setPrefs] 的同步段已把两个 key 一起
  /// 写进内存缓存，故 setState 这一帧 getter 就返回完整的新三态。旧写法 `await 落盘;
  /// setState()` 让按键到画面变化白等一次 sqlite 事务提交（Windows/WAL 实测中位 12.3ms、
  /// p90 20ms、最坏 113ms，真实繁忙库上还得排在在途写之后）——用户报的「切换遮罩模式
  /// 好卡」的一半。Future 仍 await 住：落盘失败照旧抛给调用方，不吞异常。
  Future<void> _setSubtitleObscureMode(VideoSubtitleObscureMode mode) async {
    final Future<void> persisted = appModel.setVideoSubtitleObscureMode(mode);
    if (mounted) setState(() {});
    await persisted;
  }

  /// 循环**副字幕**遮蔽三态（Shift+G，TODO-1382）：不遮蔽 → 模糊 → 隐藏 → …。
  Future<void> _cycleSecondarySubtitleObscure() async {
    await _setSecondarySubtitleObscureMode(
        appModel.videoSecondarySubtitleObscureMode.next);
  }

  /// 开/关「隐藏副字幕」（Shift+H，TODO-1382）：隐藏态再按回到不遮蔽，否则置为隐藏。
  Future<void> _toggleSecondarySubtitleHide() async {
    final VideoSubtitleObscureMode next =
        appModel.videoSecondarySubtitleObscureMode ==
                VideoSubtitleObscureMode.hide
            ? VideoSubtitleObscureMode.none
            : VideoSubtitleObscureMode.hide;
    await _setSecondarySubtitleObscureMode(next);
  }

  /// 落盘副字幕遮蔽模式并刷新页面 overlay（热键 + 快速设置面板共用，TODO-1382）。
  /// 先刷 UI 再等落盘，理由与主字幕 [_setSubtitleObscureMode] 同构。
  Future<void> _setSecondarySubtitleObscureMode(
      VideoSubtitleObscureMode mode) async {
    final Future<void> persisted =
        appModel.setVideoSecondarySubtitleObscureMode(mode);
    if (mounted) setState(() {});
    await persisted;
  }

  /// **一键画质档位应用**（无/低/中/高/极高）：原子写两套正交状态——mpv 内置缩放开关
  /// （[highQuality] → videoMpvConfig）+ GLSL 启用集（[enabledNames] →
  /// videoShadersEnabled），再一次性 applyMpvConfig + applyShaders 实时生效。
  ///
  /// 着色器文件已由着色器视图在调用本方法前下载到目录；这里只负责持久化 + 应用。
  /// highQuality 关时旁路 GLSL（与既有 onApplyShaders/onMpvConfigChanged 同语义）。
  Future<void> _applyShaderTier(
    bool highQuality,
    List<String> enabledNames,
  ) async {
    final VideoMpvConfig cfg = VideoMpvConfig.decode(
      appModel.videoMpvConfig,
    ).copyWith(highQuality: highQuality);
    await appModel.setVideoMpvConfig(VideoMpvConfig.encode(cfg));
    await appModel.setVideoShadersEnabled(encodeEnabledShaders(enabledNames));
    await _controller?.applyMpvConfig(cfg);
    final List<String> paths = highQuality
        ? await resolveEnabledShaderPaths(enabledNames)
        : const <String>[];
    await _controller?.applyShaders(paths);
  }

  /// 着色器「对比原画」：切换旁路态（临时关掉着色器看原画，再切回），保留启用集。
  /// B：缺效果预览/对比——桌面控制条对比按钮 + `C` 快捷键都走这里，OSD 提示当前态。
  Future<void> _toggleShaderCompare() async {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    final bool bypassed = await controller.toggleShaderBypass();
    if (!mounted) return;
    _showOsd(
      bypassed
          ? t.video_shader_showing_original
          : t.video_shader_showing_shaded,
    );
  }

  /// 相对当前位置 seek（±[deltaMs]，底部胶囊条 / 快捷键共用）。每次都唤醒控制条并
  /// 重置自动隐藏计时（BUG-175 ②；底部 ±10 按钮是 tap，media_kit 也不重置计时）。
  Future<void> _seekRelative(int deltaMs) async {
    _pokeControlsVisible();
    await _controller?.seekRelative(deltaMs);
  }

  /// 跳上/下一句并唤醒控制条（底部胶囊条「上/下一句」按钮，BUG-175 ②）。
  /// [forward] true=下一句、false=上一句。
  Future<void> _skipCueAndPokeControls({required bool forward}) async {
    _pokeControlsVisible();
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    // 按钮 / 双击语义：有字幕时恒跳到相邻上/下一句（**不**因上一句太远退化成 3 秒
    // seek，BUG-942——skipToPrevCueOrSeekBack 默认 degradeFarCueToTimeSeek:false）。
    // 无字幕/转场段：下一句前进 seekSeconds 秒(TODO-073)、上一句对称回退 seekSeconds
    // 秒(TODO-119，BUG-198)，两侧都不再在没字幕时 no-op 卡住。
    await (forward
        ? controller.skipToNextCueOrSeekForward(
            seekSeconds: _asbConfig.seekSeconds,
          )
        : controller.skipToPrevCueOrSeekBack(
            seekSeconds: _asbConfig.seekSeconds,
          ));
  }

  AudioCue? _currentCueForAction() {
    final VideoPlayerController? controller = _controller;
    if (controller == null) return null;
    return controller.currentCue ??
        resolveMiningCueForPosition(
          cues: controller.cues,
          positionMs: controller.positionMs ?? 0,
          delayMs: _delayMs,
        );
  }

  Future<void> _toggleFavoriteCurrentCue() async {
    final AudioCue? cue = _currentCueForAction();
    if (cue == null || cue.text.trim().isEmpty) {
      _showOsd(t.no_sentence_selected, severity: ToastSeverity.error);
      return;
    }
    // BUG-931：收藏不再唤起 media_kit 控制条——原先那句 poke 会派发合成 hover 把底栏
    // 进度条弹出来（用户报「碍眼」）。收藏结果走左上角 OSD 即可，无需显现控制条。
    // BUG-2030 之后这已不是收藏一处的特例：所有键盘 / 手柄入口（跳句 / seek / 跳章 /
    // 重播）都改走 [_keepControlsAliveIfVisible]，隐藏态一律不唤起；收藏这处更进一步，
    // 连续命都不需要（它压根不动播放位置）。
    await _toggleFavoriteCueForVideo(cue);
  }

  Future<void> _replayCurrentCueAndKeepControls() async {
    final AudioCue? cue = _currentCueForAction();
    if (cue == null) return;
    _keepControlsAliveIfVisible();
    await _controller?.skipToCue(cue);
  }

  /// 重播上一句（TODO-378，BUG-287）：跳到上一条 cue 起点并播放，**不**退化成回退几秒
  /// （走纯 [VideoPlayerController.skipToPrevCue]，与底栏「上一句」按钮同语义）。
  Future<void> _replayPreviousCueAndKeepControls() async {
    _keepControlsAliveIfVisible();
    await _controller?.skipToPrevCue();
  }

  /// 弹快捷倍速浮层（TODO-438）：有按钮触发源时锚定 speed 按钮、按其槽位自适应方向
  /// （TODO-560：[sourceSlot] 决定上/下/左/右弹），复用 [_speedMenuPresets] 与
  /// [_setSpeed]。右键菜单没有稳定按钮锚点，退回可见 side panel，避免打开
  /// showWhenUnlinked=false 的不可见 follower。
  void _showSpeedMenu({LayerLink? popoverLink, VideoControlSlot? sourceSlot}) {
    if (popoverLink == null) {
      _showVideoSidePanel(_VideoSidePanelKind.speed);
      return;
    }
    _toggleControlPopover(
      _VideoControlPopoverKind.speed,
      popoverLink: popoverLink,
      sourceSlot: sourceSlot,
      sourceItem: VideoControlItem.speed,
    );
  }

  List<double> _speedMenuPresets() {
    final Set<double> values = <double>{};
    for (double speed = 0.5; speed <= 2.0001; speed += _speedStep) {
      values.add(double.parse(speed.toStringAsFixed(2)));
    }
    values.add(1.0);
    return values.toList()..sort();
  }

  Widget _buildSpeedSidePanel() {
    final ColorScheme cs = _videoChromeColorScheme(context);
    final List<double> speedPresets = _speedMenuPresets();
    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: speedPresets.length,
      itemBuilder: (BuildContext ctx, int i) {
        final double speed = speedPresets[i];
        final bool selected = (speed - _playbackSpeed).abs() < 0.001;
        return ListTile(
          dense: true,
          title: Text('${speed}x'),
          trailing: selected ? Icon(Icons.check, color: cs.primary) : null,
          onTap: () => unawaited(_setSpeed(speed)),
        );
      },
    );
  }

  /// 弹视频播放设置面板（阶段 B：schema 投影版）：面板行全部来自
  /// settings_schema_video.dart 的单一声明，本方法只构造 [VideoQuickSettingsHost]
  /// 能力槽——把页面权威值 getter 与既有回调（[_setDelayMs] / [_setSpeed] /
  /// [_persistSubtitleStyle] 等，均即时生效 + 持久化 + 实时预览）接进去。关闭后把
  /// 键盘焦点还给 Video（覆盖层夺焦后不会自动归还），恢复空格等快捷键。
  Widget _buildVideoQuickSettingsSheet() {
    return VideoQuickSettingsSheet(
      appModel: appModel,
      ref: ref,
      initialCategory: _settingsInitialCategory,
      host: _buildVideoQuickSettingsHost(),
    );
  }

  /// 播放页能力槽：schema 投影的视频项经它读页面状态 / 走页面回调实时应用。
  VideoQuickSettingsHost _buildVideoQuickSettingsHost() {
    return VideoQuickSettingsHost(
      uiScale: _videoUiScale,
      isTouchControls: !_isDesktopVideoControls,
      delayMs: () => _delayMs,
      speed: () => _playbackSpeed,
      subtitleStyle: () => _subtitleStyle,
      danmakuStyle: () => _danmakuStyle,
      controlLayout: () => _controlLayout,
      customActionBindings: () => _customActionBindings,
      onCustomActionBindingsChanged: _setVideoCustomActionBindings,
      onSetDelay: _setDelayMs,
      // TODO-2837：副字幕独立调轴（null = 跟随主字幕）。行只在副字幕轨激活
      // （secondaryCues 非空）时显示——hasSecondarySubtitle 是活值 getter，
      // 面板内切换副字幕轨后经 controller 通知即时显隐。
      secondaryDelayMs: () => _secondaryDelayMs,
      onSetSecondaryDelay: _setSecondaryDelayMs,
      hasSecondarySubtitle: () =>
          _controller?.secondaryCues.isNotEmpty ?? false,
      // TODO-701 阶段1：仅当当前有字幕 cue + 视频本地路径时给自动对轴按钮（否则
      // 无可对齐对象/无音频源），否则置 null 让面板不显示该按钮。
      onAutoAlign: (_controller?.cues.isNotEmpty ?? false) &&
              (_controller?.videoPath?.isNotEmpty ?? false)
          ? _autoAlignSubtitle
          : null,
      // 「上/下一句对齐到当前时间」按钮：与键盘 Ctrl+Shift+←/→ 同一执行体。只要有
      // 字幕 cue 就能对齐（纯按 cue 时间轴求偏移，**不需要**视频本地路径 / 音频探测，
      // 故门条件比自动对轴松一档）；无 cue 时置 null 让面板不显示按钮。
      onSnapDelayToCue: (_controller?.cues.isNotEmpty ?? false)
          ? _snapSubtitleDelayToCue
          : null,
      // TODO-1051 阶段B：字幕对轴波形面板输入。有 cue + 本地视频路径时给波形抽取回调
      // （否则 null，面板不显示）；面板拖动预览、松手才经 onSetDelay(_setDelayMs) 落盘。
      subtitleWaveformCues: _controller?.cues ?? const <AudioCue>[],
      videoDurationMs: _controller?.durationMs ?? 0,
      loadSubtitleWaveform: (_controller?.cues.isNotEmpty ?? false) &&
              (_controller?.videoPath?.isNotEmpty ?? false)
          ? _loadSubtitleWaveformEnvelope
          : null,
      subtitlePositionListenable: _controller,
      currentSubtitlePositionMs: () => _controller?.positionMs ?? -1,
      // TODO-1244：波形对轴视图逐句试听——seek 到该句时间并播放，复用现有播放器（不新建栈）。
      onPlaySubtitleCue: (int startMs) async {
        final VideoPlayerController? controller = _controller;
        if (controller == null) return;
        await controller.seekMs(startMs);
        await controller.play();
      },
      // 波形对轴视图内的播放/暂停按钮：读实时播放态 + 切换，复用现有播放器（不新建栈）。
      subtitleIsPlaying: () => _controller?.isPlaying ?? false,
      onToggleSubtitlePlayPause: () async {
        await _controller?.togglePlayPause();
      },
      // 波形对轴弹窗内的键盘快捷键：复用视频页 registry 驱动的整表（尊重用户重映射），
      // 让空格暂停 / 方向键 seek / `,``.` 帧步进等在弹窗打开时照常生效。排除会破坏弹窗
      // 自身的动作（Escape 关弹窗 / 全屏 / 打开字幕列表 / 沉浸锁）。
      subtitleAlignShortcuts: _controller == null
          ? null
          : buildVideoPlayerShortcutsFromRegistry(
              appModel.shortcutRegistry,
              _buildVideoShortcutActions(_controller!),
              exclude: const <ShortcutAction>{
                ShortcutAction.globalBack,
                ShortcutAction.videoToggleFullscreen,
                ShortcutAction.videoToggleSubtitleList,
                ShortcutAction.videoToggleImmersiveLock,
                // 对轴弹窗内再按「打开对轴」不叠第二层弹窗（与键盘直达路径一致）。
                ShortcutAction.videoOpenSubtitleAlign,
              },
            ),
      // 点击字幕波形把播放头跳过去（seek 到该 x 对应的时间，不强制播放，保留当前播放态）。
      onSeekSubtitleWaveform: (int ms) async {
        await _controller?.seekMs(ms);
      },
      onPreviewSpeed: (double v) => _setSpeed(v, persist: false),
      onSetSpeed: _setSpeed,
      onSetSubtitleObscureMode: _setSubtitleObscureMode,
      onSetSecondarySubtitleObscureMode: _setSecondarySubtitleObscureMode,
      onAsbConfigChanged: _setAsbConfig,
      onSubtitleStylePreview: (VideoSubtitleStyle s) {
        if (mounted) setState(() => _subtitleStyle = s);
      },
      onSubtitleStyleCommit: _persistSubtitleStyle,
      // TODO-2838：进入「拖拽调整字幕位置」模式（关设置侧栏 + 开拖拽，见 layout.part）。
      onEnterSubtitleDragAdjust: _enterSubtitleDragAdjust,
      // TODO-1105：尊重 .ass 自带样式切换回调（持久化 + 重建让 overlay 即时生效）。
      onSubtitleObscureRevealChanged: _setVideoSubtitleObscureReveal,
      onRespectAssStyleChanged: _setVideoRespectAssStyle,
      // 着色器/mpv 配置面板内嵌（不弹独立对话框）：着色器勾选 → 持久化启用集 +
      // 解析绝对路径 + 实时应用；mpv 配置即改即生效。
      onApplyShaders: (List<String> enabledNames) async {
        await appModel.setVideoShadersEnabled(
          encodeEnabledShaders(enabledNames),
        );
        final VideoMpvConfig cfg = VideoMpvConfig.decode(
          appModel.videoMpvConfig,
        );
        final List<String> paths = cfg.highQuality
            ? await resolveEnabledShaderPaths(enabledNames)
            : const <String>[];
        await _controller?.applyShaders(paths);
      },
      onMpvConfigChanged: (VideoMpvConfig cfg) async {
        await appModel.setVideoMpvConfig(VideoMpvConfig.encode(cfg));
        await _controller?.applyMpvConfig(cfg);
        final List<String> paths = cfg.highQuality
            ? await resolveEnabledShaderPaths(
                decodeEnabledShaders(appModel.videoShadersEnabled),
              )
            : const <String>[];
        await _controller?.applyShaders(paths);
      },
      // mpv Lua 脚本开关：落 pref；开启时把脚本目录即时装载进活播放器（幂等，
      // 已装载路径跳过）。关闭不可卸载（mpv 无 unload-script），下次进入生效。
      onLuaScriptsEnabledChanged: (bool enabled) async {
        await appModel.setVideoMpvLuaScriptsEnabled(enabled);
        if (!enabled) return;
        await _controller?.applyLuaScripts(await listLuaScriptPaths());
      },
      luaScriptStates: _controller?.luaScriptStates,
      onLockWindowAspectRatioChanged: _setLockWindowAspectRatio,
      onVideoFitModeChanged: _setVideoFitMode,
      onHdrOutputModeChanged: _setVideoHdrOutputMode,
      onImmersiveModeChanged: appModel.setVideoImmersiveMode,
      onDanmakuEnabledChanged: _setVideoDanmakuEnabled,
      onDanmakuOnlineEnabledChanged: _setVideoDanmakuOnlineEnabled,
      onDanmakuMaxActiveChanged: _setVideoDanmakuMaxActive,
      // TODO-1376：弹幕样式（拖动即时预览，松手落盘）+ 屏蔽词/正则过滤 + 手动匹配入口。
      onDanmakuStylePreview: _previewVideoDanmakuStyle,
      onDanmakuStyleCommit: _setVideoDanmakuStyle,
      onDanmakuBlockRulesChanged: _setVideoDanmakuBlockRules,
      onManualDanmakuMatch: _openDanmakuManualMatch,
      // 「从本机 mpv 导入」找不到时用户手动指定的 mpv 目录，记住下次优先扫。
      onMpvShaderDirChanged: (String dir) => appModel.setVideoMpvShaderDir(dir),
      // 一键画质档位：原子落「mpv 内置缩放开关 + 启用集」并实时应用（着色器文件由
      // 着色器视图在回调前已下载到目录）。统一在此一处写两套 pref，消除两回调顺序耦合。
      onSelectShaderTier:
          (VideoShaderTier tier, bool highQuality, List<String> enabledNames) =>
              _applyShaderTier(highQuality, enabledNames),
      onControlLayoutChanged: _setVideoControlLayout,
      // TODO-1158 / TODO-1159：多档画质入口（跨平台，经设置面板「播放」分类可达）。HLS
      // master variant 或 YouTube 流（懒解析多档）时给入口；点开画质侧栏（替换设置侧栏）。
      qualityOptionCount: _qualityOptionCount,
      qualityCurrentLabel: _qualityCurrentLabel,
      onOpenQuality: _hasQualityMenu ? _showQualityMenu : null,
      // TODO-1232 / BUG-597：视频黑屏（有声无画）降级入口——仅当渲染 channel 已接线
      // （Android）、本次运行确实跑 Impeller、且用户尚未选 Skia 时接线（=可能中招黑屏
      // 的人群）；否则 null 不显示该行。点按走确认弹窗 → 关 Impeller → 重启。
      onSwitchToSkiaRenderer: (RenderBackendService.instance.isSupported &&
              !RenderBackendService.instance.impellerDisabled &&
              !RenderBackendService.instance.activeImpellerDisabled)
          ? _switchToSkiaAndRestart
          : null,
      // TODO-1351：轨切换收进设置面板对应 tab（音频轨在「音频」、字幕轨在「字幕」顶部），
      // 由页面构建内容（复用既有切轨/切源方法与数据），删掉外面浮的轨切换侧栏。
      audioTrackSection: _controller != null
          ? _buildAudioTrackSettingsSection(_controller!)
          : null,
      subtitleTrackSection: _controller != null
          ? _buildSubtitleTrackSettingsSection(_controller!)
          : null,
      // TODO-1350（字幕轨即时加载）：进入「字幕」分类时（重新）枚举当前视频字幕源，让
      // 字幕轨列表在打开分类那一刻就加载，不再依赖「字幕轨」按钮预填 / 关掉重开。
      onSubtitleCategoryShown: _ensureSubtitleMenuSourcesLoaded,
      // 主题不再在视频设置里单列：主题属于全局「外观」设置，视频画面自动继承 app 主题
      // （含自定义主题），无需在此重复暴露「视频主题」。
    );
  }

  /// TODO-1232 / BUG-597：播放器设置面板「切 Skia 并重启」降级行的动作。视频「有声无画」
  /// 黑屏根因是本机 GPU 上 Impeller 合成不了 media_kit 外部纹理（SurfaceProducer）；Android
  /// 默认已保持 Impeller（多数机型性能优先），本动作给受影响机型一个显式降级：确认弹窗 →
  /// 写 native pref 关 Impeller（下次启动走 Skia）→ 重启 app 使其生效。渲染后端只能在引擎
  /// 启动那一刻定，故必须重启；不支持重启的平台降级为 toast 提示手动重开。仅在
  /// [_buildVideoQuickSettingsSheet] 判定本次跑 Impeller + channel 已接线时才接线此动作。
  Future<void> _switchToSkiaAndRestart() async {
    final bool confirmed = await showDialog<bool>(
          context: context,
          builder: (BuildContext ctx) => AlertDialog(
            title: Text(t.video_render_skia_fix_confirm_title),
            content: Text(t.video_render_skia_fix_confirm_body),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(t.dialog_cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: Text(t.video_render_skia_fix_confirm_action),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed) return;
    final bool ok =
        await RenderBackendService.instance.setImpellerDisabled(true);
    if (!ok || !appModel.platformServices.lifecycle.supportsRestart) {
      // pref 未写成（非 Android）或平台不支持自动重启：降级提示手动重开。
      if (mounted) {
        _showOsd(t.render_restart_required, severity: ToastSeverity.warning);
      }
      return;
    }
    try {
      await appModel.platformServices.lifecycle.restartApp();
    } catch (e) {
      // 起新进程失败（Process.start 抛错等）→ 降级提示手动重开。
      debugPrint('[render] switch to Skia restart failed: $e');
      if (mounted) {
        _showOsd(t.render_restart_required, severity: ToastSeverity.warning);
      }
    }
  }

  void _showPlayerSettings({
    VideoControlSlot? sourceSlot,
    String? initialCategory,
  }) {
    // TODO-1351：记住目标分类（音频轨/字幕轨按钮传 'audio'/'subtitle'，设置按钮传 null），
    // 供 _buildVideoQuickSettingsSheet 读；面板 didUpdateWidget 据其变化跳分类。
    _settingsInitialCategory = initialCategory;
    _showVideoSidePanel(
      _VideoSidePanelKind.settings,
      sourceSlot: sourceSlot,
    );
  }

  /// 把用户挑选/拖入的外部字幕文件 [srcPath] 拷到持久化
  /// `<appDocs>/video_subtitles/`（与 Jimaku 下载同目录），构造外挂
  /// [SubtitleSource] 后经 [_selectSubtitleSource] 应用（复用 cue 解析/切换/
  /// 持久化/失败提示全链路）。
  ///
  /// 拷贝到持久目录而非直接用原路径：原文件可能在临时/缓存区或后续被移动，落盘后
  /// 持久化的 `subtitleSource` 路径才稳定可恢复。格式不支持或拷贝失败时弹提示、
  /// 不切换。源路径已在持久目录内时跳过自拷贝（File.copy 自拷会报错）。
  ///
  /// 落点是 `video_subtitles/<basename>`：同 basename 直接覆盖，是「当前集导入
  /// 覆盖」语义，有意不做去重——避免堆积同名副本，且换集恢复按文件名匹配，去重
  /// 后缀反而干扰匹配。
  /// 正在导入中的源路径（去重防护）。窗口模式下页级 + controls 内层两个拖放目标
  /// 可能对同一次拖放都触发 onDrop（BUG-133）；同一 srcPath 在途时忽略二次调用，
  /// 避免重复拷贝 / 重复弹加载遮罩 / 重复 SnackBar。
  final Set<String> _subtitleImportsInFlight = <String>{};

  void _handlePlaybackDrop(
    VideoPlayerController controller,
    List<String> paths,
  ) {
    final DroppedFiles files = classifyDroppedFiles(paths);
    debugPrint(
      '[fushi-drop] [video-playback] classified '
      'subtitles=${files.subtitles.length} audios=${files.audios.length} '
      'videos=${files.videos.length} books=${files.books.length} '
      'dictionaries=${files.dictionaries.length} unknown=${files.unknown.length}',
    );
    final String? sub = firstSubtitlePath(paths);
    if (sub != null) {
      unawaited(_importExternalSubtitle(controller, sub));
      return;
    }
    if (files.subtitles.isNotEmpty) {
      debugPrint('[fushi-drop] [video-playback] intent=unsupportedSubtitle');
      _showOsd(
        t.video_subtitle_import_unsupported,
        severity: ToastSeverity.error,
      );
      return;
    }
    if (files.audios.isNotEmpty && files.videos.isEmpty) {
      debugPrint('[fushi-drop] [video-playback] intent=unsupportedAudio');
      _showOsd(t.video_drop_audio_unsupported, severity: ToastSeverity.error);
      return;
    }
    if (files.hasAny) {
      debugPrint('[fushi-drop] [video-playback] intent=unsupportedSurface');
      _showOsd(t.video_drop_subtitle_only, severity: ToastSeverity.error);
    }
  }

  /// 字幕抽取/解析当前是否在进行。状态显示在右侧半透明字幕源面板里，画面仍可见；
  /// 底层 ffmpeg/文件解析 Future 目前没有取消契约，关闭面板只是不再打断观看。
  bool _subtitleLoadingShown = false;

  @override
  Widget build(BuildContext context) {
    final VideoPlayerController? controller = _controller;
    final VideoController? videoController = controller?.videoController;
    final ColorScheme cs = Theme.of(context).colorScheme;
    // 视频页是**窗口全屏的合法宿主**之一：全屏键（默认 F11）只在小说 / 漫画 / 视频
    // 里能进入全屏，靠的就是这层声明（见 [WindowFullscreenHosts]）。它零布局、零行为，
    // 只在挂载期间登记自己所在的路由。
    //
    // TODO-1342：最外层包一层手柄输入层，让桌面轮询的 [GamepadButtonIntent] 与
    // Android 原生手柄按键都能落到本页的视频动作（play/pause、seek、音量、字幕、全屏、
    // 返回）。放在 [PopScope] 之上 ⇒ 是 [_videoFocusNode] 及所有子焦点节点的祖先，
    // 冒泡/派发都能命中；wrapper 自身不夺焦（见 [_wrapVideoGamepadControls]）。
    return WindowFullscreenHost(
      child: _wrapVideoGamepadControls(
        PopScope(
          // 始终 `canPop: false` 自管退出：① 浮层栈非空时 back 先关栈（一层一层退），
          // 浮层在根 Overlay 退出视频路由不会自动清它，必须在 pop 前拦截；② 栈空真退出
          // 时，先**同步发起** `flushPosition()` 把退出瞬间位置排进 drift 队列，再手动
          // pop（BUG-2119：不 await——退出不能被落库成败绑架；写请求一旦发出就在后台
          // 完成，不随 State 销毁消失，后续页面对同一行的读排在它之后）。
          canPop: false,
          onPopInvokedWithResult: (bool didPop, Object? _) async {
            if (didPop) return;
            await _handleBackOrExit();
          },
          child: _buildScaffold(controller, videoController, cs),
        ),
      ),
    );
  }

  Widget _buildScaffold(
    VideoPlayerController? controller,
    VideoController? videoController,
    ColorScheme cs,
  ) {
    // 不再用 Scaffold AppBar：媒体播放器自带「视频内顶栏」（media_kit controls 的
    // topButtonBar），外层再叠一条 AppBar 等于两条顶栏、互相重复（BUG-102）。改为
    // 把返回/标题/剧集导航全部并入视频内顶栏（见 [_desktopControlsTheme] /
    // [_mobileControlsTheme]），与播放控制一起随鼠标/触摸显隐，单一顶栏。
    // HDR 直通（video_hdr_output.dart）：libmpv 宿主窗钉在主窗正后方，视频洞必须
    // 一路透到底，页面底色随之透明；失败 / 加载 / 缺资源态与非 HDR 播放不受影响。
    return ValueListenableBuilder<bool>(
      valueListenable: controller?.hdrHostActive ?? _kHdrHostInactive,
      builder: (BuildContext _, bool hdrHost, Widget? body) => Scaffold(
        backgroundColor: hdrHost ? Colors.transparent : cs.surface,
        body: body,
      ),
      child: _failed
          ? _buildFailedBody(cs)
          // TODO-897：本地资源缺失态——必须在转圈判据之前短路（缺失时不调 load，
          // _controller 维持 null 也会落进下面的 spinner 分支无限转圈）。
          : _missingResource
              ? _buildMissingResourceBody(cs)
              // TODO-1276：首开时把 `!_videoReadyToShow` 并入转圈判据——页级加载态
              // 保持到首帧真正解码出画再挂载 [Video]，杜绝与 media_kit 缓冲圈接力成
              // 「转两次圈」。换集 [_videoReadyToShow] 恒 true 不进此分支（行为不变）。
              : (controller == null ||
                      videoController == null ||
                      !_videoReadyToShow)
                  ? _buildLoadingBody()
                  // BUG-1864：裸空格覆盖不再挂这里——它已上提到窗口与全屏共用的
                  // [_wrapVideoGamepadControls]（全屏是独立路由，不经过本 Scaffold）。
                  : _pageDropTarget(
                      controller,
                      _buildVideoBody(controller, videoController),
                    ),
    );
  }

  /// TODO-1213：有上下文加载态（替代裸 `CircularProgressIndicator`）。标题（让用户知道
  /// 在加载哪个视频）+ 顶部返回入口（加载中随时可退出、不卡死，走 [_handleBackOrExit]
  /// 与正常退出同路径）+ 阶段文案（连接流 / 下载字幕 / 缓冲 / 准备）+ 字幕下载确定性
  /// 进度。纯 UI，不碰 controller.load 时序。
  Widget _buildLoadingBody() {
    final String title = _titleNotifier.value ??
        _title ??
        _effectiveRemoteInfo?.title ??
        _bookRow?.title ??
        '';
    return VideoLoadingOverlay(
      title: title,
      phaseText: _loadingPhaseLabel(_loadingPhase),
      progress: _loadingPhase == _VideoLoadPhase.downloadingSubtitle
          ? _subtitleProgress
          : null,
      onBack: () => unawaited(_handleBackOrExit()),
    );
  }

  /// TODO-1213：加载阶段 → 本地化文案。
  String _loadingPhaseLabel(_VideoLoadPhase phase) {
    switch (phase) {
      case _VideoLoadPhase.connecting:
        return t.video_loading_connecting;
      case _VideoLoadPhase.downloadingSubtitle:
        return t.video_loading_subtitle;
      case _VideoLoadPhase.buffering:
        return t.video_loading_buffering;
      case _VideoLoadPhase.preparing:
        return t.video_loading_preparing;
    }
  }

  /// TODO-897 / BUG-805：本地资源缺失态正文（不转圈）。中性图标 + 文案 + 「重新导入 /
  /// 删除条目（仅单视频）/ 返回」三个真按钮，对应 [_promptMissingResource] 的选项；首帧若
  /// 对话框被取消，用户仍能从这里再次触发。「重新导入」走 [_reimportMissingResource]
  /// 真动作（BUG-805 前是空操作 pop）。
  ///
  /// 「返回」是**唯一退出入口**，不可省（BUG-2229）：本页有意不挂 AppBar（BUG-102，
  /// 退出/标题/剧集导航全并进 media_kit controls 的视频内顶栏），而缺失态根本没有
  /// controller ⇒ 内顶栏不存在；桌面端又没有系统返回键，少了这颗按钮用户进来就出不去。
  /// 与失败态 [_buildFailedBody]、加载态 [_buildLoadingBody] 的退出走同一条
  /// [_handleBackOrExit]（同样会 flush 播放位置、清浮层栈）。
  Widget _buildMissingResourceBody(ColorScheme cs) {
    final VideoBookRow? row = _missingRow;
    final bool canDelete = row != null && !_isPlaylist && !_isRemote;
    final String title = _title ?? row?.title ?? '';
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.video_file_outlined, color: cs.error, size: 48),
            const SizedBox(height: 16),
            Text(
              t.video_resource_missing_message(title: title),
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: <Widget>[
                // 重新导入 = 主修复动作（真动作：单视频重链选文件 / 播放列表打开导入对话框）。
                FilledButton.tonal(
                  onPressed: () => unawaited(_reimportMissingResource(row)),
                  child: Text(t.video_resource_missing_reimport),
                ),
                if (canDelete)
                  TextButton(
                    onPressed: () =>
                        unawaited(_confirmMissingResourceDelete(row)),
                    child: Text(t.dialog_delete),
                  ),
                // BUG-2229：退出入口。缺失态没有视频内顶栏，这是唯一的出口。
                TextButton(
                  onPressed: () => unawaited(_handleBackOrExit()),
                  child: Text(t.back),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 把加载失败的异常映射成一句用户可读的原因文案。YouTube/网络流最常见的三类失败
  /// （解析/连接超时、网络错误、视频不可用/受限）各给出可指导的说明；无法归类时回退
  /// 通用文案。纯字符串判据（异常类型 + 消息关键词），best-effort、绝不抛。
  String _describeLoadFailure(Object? error) {
    if (error is TimeoutException) return t.video_load_failed_timeout;
    // BUG-1693：互联对端一台都探不到（对端未运行 Fushi / 离线）有类型可依，
    // 优先分派——它既不是「视频不可用」也不是「本机网络故障」。
    if (error is SyncPeerUnreachableError) return t.sync_err_peer_unreachable;
    final String s = error?.toString().toLowerCase() ?? '';
    // 网络判据先行（BUG-1693 顺带修）：旧序里 'age'/'unavailable' 排在前面且
    // 'age' 是裸子串——'message'/'package'/'storage' 这类传输错误文本都含 'age'，
    // 真网络故障会被误标成「视频不可用/受限」。'age' 加词界（age-restricted /
    // age_verification / " age "），并把可归因的网络关键词放到它之前。
    if (s.contains('socket') ||
        s.contains('network') ||
        s.contains('connection') ||
        s.contains('handshake') ||
        s.contains('failed host lookup') ||
        s.contains('timed out')) {
      return t.video_load_failed_network;
    }
    if (s.contains('403') ||
        s.contains('forbidden') ||
        s.contains('manifest failed') ||
        s.contains('unavailable') ||
        s.contains('unplayable') ||
        RegExp(r'\bage[ _-]').hasMatch(s) ||
        s.contains('private')) {
      return t.video_load_failed_unavailable;
    }
    return t.video_load_failed_generic;
  }

  /// 加载失败态「重试」：清失败标记后从头重跑 [_init]（本地重读 row、流媒体重解析
  /// getManifest——临时流 URL 过期也会自愈）。与首次打开同一路径，覆盖所有失败点。
  void _retryLoad() {
    if (!mounted) return;
    setState(() {
      _failed = false;
      _failReason = null;
    });
    _setLoadingPhase(_VideoLoadPhase.connecting);
    unawaited(_init());
  }

  /// 加载失败态正文（替代旧的「一个居中红叹号、无任何说明」）。图标 + 标题 + 具体
  /// 原因（[_failReason]，缺省回退通用文案）+ 「重试 / 返回」按钮，让用户知道为何失败、
  /// 能一键重试或退出，不再对着孤零零的叹号发懵。
  Widget _buildFailedBody(ColorScheme cs) {
    final String title = _titleNotifier.value ??
        _title ??
        _effectiveRemoteInfo?.title ??
        _bookRow?.title ??
        '';
    final String reason = _failReason ?? t.video_load_failed_generic;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(Icons.error_outline, color: cs.error, size: 48),
            const SizedBox(height: 16),
            Text(
              t.video_load_failed_title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (title.isNotEmpty) ...<Widget>[
              const SizedBox(height: 4),
              Text(
                title,
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(color: cs.onSurfaceVariant),
              ),
            ],
            const SizedBox(height: 12),
            Text(
              reason,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium,
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 8,
              alignment: WrapAlignment.center,
              children: <Widget>[
                FilledButton.tonalIcon(
                  onPressed: _retryLoad,
                  icon: const Icon(Icons.refresh),
                  label: Text(t.video_load_failed_retry),
                ),
                TextButton(
                  onPressed: () => unawaited(_handleBackOrExit()),
                  child: Text(t.video_load_failed_back),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  /// 页级字幕拖放目标（BUG-133）。controls 内层也挂了一个（[_buildVideoControls]）供
  /// **全屏**用（media_kit 全屏是另推的根路由、复用同一 controls builder）；但窗口
  /// 模式下那个深埋在 media_kit `Video`→controls 子树里，实测 Windows OS 拖放在视频
  /// 区「完全没反应」。这里在页面顶层（与书架/视频库同款已验证可用的高层挂载点）再挂
  /// 一个，保证窗口模式可靠收到拖放；与内层重复触发由 [_importExternalSubtitle] 的
  /// 去重防护兜住。全屏时本页被全屏路由 Offstage、renderBox 尺寸归零 → 本目标不命中，
  /// 只剩内层生效，不会双触发。
  Widget _pageDropTarget(VideoPlayerController controller, Widget child) {
    return FushiFileDropTarget(
      debugLabel: 'video-playback-page',
      onDrop: (List<String> paths, Offset _) {
        _handlePlaybackDrop(controller, paths);
      },
      child: child,
    );
  }

  void _handleVideoPointerUp(PointerUpEvent event) {
    // 点视频区任意位置 = 用户把交互意图交还播放器：顺手收回键盘焦点（TODO-040 ①
    // 「点了外面/焦点丢失后」的恢复路径——与原生播放器一致，点一下画面即恢复键盘）。
    // 查词浮层打开时点击被根 Overlay barrier 拦截、到不了这里，guard 仅兜底；点
    // 控制条按钮随后弹出的菜单/对话框会再夺焦，其 whenComplete 自会归还，不冲突。
    _focusOwnership.reclaim(FocusReclaimCause.gesture);
    // 触屏点画面唤回视频左侧锁 / 解锁按钮（TODO-126）。沉浸态下控制条指针被 gate，但本
    // 外层 Listener 在 gate 之外仍收到指针，故沉浸态点画面也能唤回解锁按钮（移动端无 hover）。
    _pokeLockButton();
    // 选集横轨打开时，视频区由 dismiss barrier 接管这次点击并只关闭横轨；外层
    // Listener 仍会先收到 pointer-up，必须在 barrier 的 onTap 执行前早返回，否则同一次
    // 点击还会进入双击 / 暂停 / 全屏判定（BUG-1501）。点横轨自身也会经过本 Listener，
    // 同样早返回才能保证选集卡片只执行换集、不误触播放器手势。
    if (_episodeListVisible.value) {
      _lastVideoPointerUpAt = null;
      _lastVideoPointerUpPosition = null;
      return;
    }
    // 侧栏（设置 / 字幕列表 / 音轨等）打开时，点面板本身不应被误判成「点画面」（BUG-246）：
    // 侧栏 overlay 是本 Stack 的子节点，但本外层 [Listener] 用 translucent 命中行为，仍会
    // 收到落在面板上的 pointer-up；若放行下方逻辑，连续两次点面板会被 400ms/48px 双击判据
    // 误判成「双击画面」→ 桌面触发 [_toggleVideoFullscreen]、移动触发暂停。这里对齐沉浸锁
    // 的早返回门控：任意侧栏开着时一律不参与控制条 toggle / 双击 / 暂停 / 全屏判定，并清掉
    // 双击追踪，避免关闭面板后残留时间戳被下一次真点画面误配成双击。
    if (_videoSidePanel.value != null) {
      _lastVideoPointerUpAt = null;
      _lastVideoPointerUpPosition = null;
      return;
    }
    final BuildContext? controlsContext = _videoControlsContext;
    if (controlsContext == null ||
        !controlsContext.mounted ||
        _isVideoChromePointer(controlsContext, event.position)) {
      _lastVideoPointerUpAt = null;
      _lastVideoPointerUpPosition = null;
      return;
    }

    // 移动端点画面（非控制条按钮）的控制条显隐 toggle 不再在 Hibiki 侧另做镜像
    // （TODO-364）：本外层 [Listener] 是 translucent，同一次点击会继续命中下方 media_kit
    // 移动控制条自己的手势层 → 其 `onTap` 翻 `visible` 并推送 [_mediaKitControlsVisible]，
    // 字幕避让由 [_applyControlsVisibilityFromMediaKit] 派生，与真实控制条同相位（旧实现在此
    // 用 Hibiki 镜像独立 toggle，与 media_kit 各自计时 → 并发操作时方向反，是本 BUG 根因）。

    final DateTime now = DateTime.now();
    final DateTime? lastAt = _lastVideoPointerUpAt;
    final Offset? lastPosition = _lastVideoPointerUpPosition;
    _lastVideoPointerUpAt = now;
    _lastVideoPointerUpPosition = event.position;
    if (lastAt == null || lastPosition == null) return;
    if (now.difference(lastAt) > _videoDoubleClickInterval) return;
    if ((event.position - lastPosition).distance > _videoDoubleClickSlop) {
      return;
    }
    _lastVideoPointerUpAt = null;
    _lastVideoPointerUpPosition = null;
    if (_immersiveLocked.value && !_immersiveAllowsDoubleTapSeek) {
      return;
    }
    // TODO-173/BUG-231: 双击左/右区先尝试快进/快退（或跳上/下一句）。落在左 / 右
    // 区（且双击行为已开启）则在此早返回。未锁定或 full 模式下，中带（中间 1/3）
    // 落空继续走下方平台分流，保留 BUG-221 的双击暂停（移动）/ 全屏（桌面）。
    final bool doubleTapHandled =
        _handleDoubleTapSeek(controlsContext, event.position);
    if (doubleTapHandled) return;
    // 走到这里若仍处沉浸锁定态，则必为 full 模式（其余模式已在上方
    // [_immersiveAllowsDoubleTapSeek] 门控早返回：shortcutAndLookup 的跳转改由快捷键
    // 完成，触摸双击不再 seek，也不落入暂停 / 全屏 fallback）。
    // BUG-221: 双击命中（中带）后按平台分流。
    // - 移动端：双击 = 播放/暂停。原先双击 → [_toggleVideoFullscreen] → media_kit 全屏路由，
    //   退出时弹回竖屏，用户感知为「双击 = 竖屏」。移动端横屏沉浸态即唯一形态、无「全屏」
    //   语义，双击应等同原生播放器的暂停手势。
    // - 桌面：保留双击全屏（窗口全屏有意义，走 native window 不碰设备方向）。
    if (_isDesktopVideoControls) {
      unawaited(_toggleVideoFullscreen(controlsContext));
    } else {
      // 用户设置关掉「点击画面播放/暂停」后，移动端双击中带不再切播放态（与桌面单击
      // 的 playAndPauseOnTap 读同一个开关，两端语义一致）。桌面双击 = 全屏，与播放态
      // 无关，故不受本开关影响。
      if (!_asbConfig.tapTogglesPlayback) return;
      unawaited(_controller?.playOrPause() ?? Future<void>.value());
    }
  }

  /// TODO-1058：桌面在视频画面上滚鼠标滚轮调音量（上滚增、下滚减，[_volumeStep] 步进，
  /// 复用 [_onVolumeWheel] → [_adjustVolume] → 现有音量通道 + level HUD 反馈）。
  ///
  /// 门控（诚实降级、不与既有语义冲突）：
  /// - 仅桌面（[_isDesktopVideoControls]）——移动端无滚轮；
  /// - 沉浸锁非 full 模式不放行（[_immersiveAllowsFullControls]，滚轮属指针控制，
  ///   与控制条按钮 / 右键菜单同门控；键盘 / 手柄快捷键另走 [_immersiveAllowsShortcuts]）；
  /// - 落在控制条 chrome（底栏 / 顶栏 / 侧栏）上的滚轮不接管：底栏音量控件已有自己的
  ///   [_onVolumeWheel] Listener、进度条 / 列表各有滚动语义，画面级只处理**画面区**的
  ///   滚轮，避免双触发或抢走 chrome 滚动。侧栏打开时一律不接管。
  /// 滚轮是 [PointerSignalEvent]（不进手势竞技场），与长按横拖 seek（TODO-756）、单击
  /// 暂停正交，互不干扰。
  void _handleVideoWheelSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (!_isDesktopVideoControls) return;
    if (!_immersiveAllowsFullControls) return;
    if (_videoSidePanel.value != null) return;
    final VideoPlayerController? controller = _controller;
    if (controller == null) return;
    final BuildContext? controlsContext = _videoControlsContext;
    if (controlsContext != null &&
        controlsContext.mounted &&
        _isVideoChromePointer(controlsContext, event.position)) {
      return; // 落在控制条 chrome 上：交回 chrome 自己的滚轮/滚动语义。
    }
    _onVolumeWheel(controller, event.scrollDelta.dy);
  }

  /// 双击左 / 右区快退 / 快进（TODO-173/BUG-231）。返回 true=已处理（左 / 右区），
  /// 调用方应早返回、不再走平台默认的暂停 / 全屏；false=落在中带（中间 1/3）或功能
  /// 关闭，调用方继续走 BUG-221 的暂停 / 全屏分流。
  ///
  /// 用 [_videoControlsContext] 的 [RenderBox] 把双击点 [globalPosition] 换成本地坐标
  /// 拿 dx 与可视区宽度（复用 [_isVideoChromePointer] 的 `globalToLocal` 范式），按
  /// 三等分判定：左 1/3 → 后退、右 1/3 → 前进、中间 1/3 → 中带（保留暂停 / 全屏）。
  /// [VideoAsbplayerConfig.doubleTapSeekSeconds]：0=关（整体跳过分区）、3/5/10=相对
  /// seek 该秒数、[VideoAsbplayerConfig.kDoubleTapSubtitle]=跳上 / 下一句。
  bool _handleDoubleTapSeek(
    BuildContext controlsContext,
    Offset globalPosition,
  ) {
    final int action = _asbConfig.doubleTapSeekSeconds;
    if (action == 0) return false; // 关：双击全部走暂停/全屏（向后兼容默认）。
    final RenderObject? renderObject = controlsContext.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return false;
    final double width = renderObject.size.width;
    if (width <= 0) return false;
    final double localDx = renderObject.globalToLocal(globalPosition).dx;
    final bool left = localDx < width / 3;
    final bool right = localDx > width * 2 / 3;
    if (!left && !right) return false; // 中带：落空，交回平台分流。
    final bool forward = right;
    if (action == VideoAsbplayerConfig.kDoubleTapSubtitle) {
      // 字幕模式：双击左/右 = 跳上/下一句（无字幕段回退/前进 seekSeconds 秒，TODO-119/073）。
      unawaited(_skipCueAndPokeControls(forward: forward));
      _showOsd(
        forward ? t.video_double_tap_next_cue : t.video_double_tap_prev_cue,
        icon: forward ? Icons.fast_forward : Icons.fast_rewind,
      );
    } else {
      // 秒数模式：相对 seek ±action 秒。
      final int deltaMs = (forward ? action : -action) * 1000;
      unawaited(_seekRelative(deltaMs));
      _showOsd(
        '${forward ? '+' : '-'}${action}s',
        icon: forward ? Icons.fast_forward : Icons.fast_rewind,
      );
    }
    return true;
  }

  bool _isVideoChromePointer(
    BuildContext controlsContext,
    Offset globalPosition,
  ) {
    final RenderObject? renderObject = controlsContext.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return false;
    final Offset local = renderObject.globalToLocal(globalPosition);
    if (local.dx < 0 ||
        local.dy < 0 ||
        local.dx > renderObject.size.width ||
        local.dy > renderObject.size.height) {
      return false;
    }
    final EdgeInsets padding = MediaQuery.of(controlsContext).padding;
    final double topChromeBottom = padding.top + _videoButtonBarHeight;
    final double bottomChromeTop =
        renderObject.size.height - padding.bottom - _videoButtonBarHeight;
    return local.dy <= topChromeBottom || local.dy >= bottomChromeTop;
  }

  /// 桌面右键 = 视频上下文菜单（TODO-048c）。右键松手处 [globalPosition] 作锚点弹
  /// [showMenu] PopupMenu，项全部复用既有动作 helper（不重造）。锚定到
  /// [_videoControlsContext]——它在全屏期间是全屏路由子树的 context（见
  /// [_buildVideoControlsInner] / [VideoControlsFocusGate]），故 showMenu 找到的是
  /// 全屏路由的 Overlay，菜单在窗口与全屏两种场景都能正确浮出（与字幕跳转列表 /
  /// 锁定层同源的全屏安全范式，TODO-069/101）。移动端无次按钮、此回调不触发，且
  /// 这里再门控一次（[_isDesktopVideoControls]）双保险。右键菜单含完整播放控制，沉浸锁
  /// 仅 full 模式允许打开；shortcutAndLookup / lookupOnly / unlockOnly 均不能绕过四段 gate。
  ///
  /// 界面缩放坐标对齐（BUG-260）：视频页整页被 [FushiAppUiScaleNeutralizer] 中和回
  /// 净缩放=1 的**真实视口空间**（见 [VideoFushiPage.neutralized]），故
  /// [_videoControlsContext] 的 RenderBox 在真实屏幕坐标系；而 [showMenu] 把
  /// [RelativeRect] 解读为路由 **Overlay** 的坐标系——该 Overlay 在全局
  /// [FushiAppUiScale] 的 `FittedBox(BoxFit.fill)` 之内＝缩放后的画布空间。两套坐标差
  /// 一个 factor=scale，原实现直接拿 controls 盒子的 `globalToLocal` 当锚点（真实空间），
  /// 界面大小≠100% 时菜单偏离鼠标 factor≈scale（用户报「调界面大小后右键菜单不在鼠标处」）。
  ///
  /// 修复与查词浮层（[_lookupAt]/[_buildPopupOverlay]）同范式：不读 scale 数值逆算
  /// （界面大小「自动」模式下生效 scale 由视口/平台动态算出，≠ `appModel.appUiScale`），
  /// 而用 `localToGlobal(..., ancestor: overlay)` 把右键点从 controls 盒子的本地（真实）
  /// 空间沿真实渲染变换链一路映射到 **Overlay 盒子** 坐标系——其间的 FittedBox 缩放被
  /// render transform 链自动吸收，对任意 scale（含自动模式）都自洽、无残差；缩放=1 时
  /// `ancestor` 变换为单位阵，与原行为逐像素等价（向后兼容）。
  void _handleSecondaryTap(Offset globalPosition) {
    if (!_isDesktopVideoControls) return;
    if (!_immersiveAllowsFullControls) return;
    // BUG-1453：桌面手柄映射器可能先投递 synthetic right-click，GameInput 轮询再在
    // 下一 tick 投递真实按钮。等一个略大于 60 ms poll interval 的有界窗口，再与
    // [_handleVideoGamepadButton] 记录的边沿合并；真实鼠标右键不与手柄边沿重合，照常弹。
    final Duration secondaryTapAt = _videoInputClock.elapsed;
    unawaited(
      Future<void>.delayed(VideoGamepadSecondaryTapDeduper.settleDelay)
          .then<void>((_) {
        if (!mounted ||
            _videoGamepadSecondaryTapDeduper.shouldSuppressSecondaryTap(
              secondaryTapAt,
            )) {
          return;
        }
        _showVideoContextMenu(globalPosition);
      }),
    );
  }

  /// 在 secondary tap / gamepad 双投递去重后，同步解析当前 controls 几何并打开菜单。
  /// 延迟窗口之后才读取 [BuildContext]，全屏切换或退页时会自然读到最新 context / null，
  /// 也不让任何 context 跨 async gap 生存。
  void _showVideoContextMenu(Offset globalPosition) {
    final VideoPlayerController? controller = _controller;
    final BuildContext? ctx = _videoControlsContext;
    if (controller == null || ctx == null || !ctx.mounted) return;
    final RenderObject? renderObject = ctx.findRenderObject();
    if (renderObject is! RenderBox || !renderObject.hasSize) return;
    // showMenu 用 [ctx] 最近的 Navigator（rootNavigator:false）的 Overlay 作菜单宿主；
    // [RelativeRect] 须落在该 Overlay 的坐标系。取同一个 Overlay 的 RenderBox 作变换
    // 目标，使锚点与菜单宿主同系（FittedBox 缩放残差被 ancestor 变换吸收，BUG-260）。
    final RenderObject? overlayObject =
        Overlay.of(ctx).context.findRenderObject();
    if (overlayObject is! RenderBox || !overlayObject.hasSize) return;
    // 右键点：globalPosition 先回 controls 本地（真实空间），再沿真实渲染变换链映射到
    // Overlay 坐标系（吃掉中和器还原 + 全局 FittedBox 缩放的所有变换）。
    final Offset localInControls = renderObject.globalToLocal(globalPosition);
    final Offset anchor = renderObject.localToGlobal(
      localInControls,
      ancestor: overlayObject,
    );
    final Size overlaySize = overlayObject.size;
    final RelativeRect position = RelativeRect.fromLTRB(
      anchor.dx,
      anchor.dy,
      overlaySize.width - anchor.dx,
      overlaySize.height - anchor.dy,
    );
    unawaited(
      showMenu<VoidCallback>(
        context: ctx,
        position: position,
        items: _buildVideoContextMenuItems(controller),
      ).then((VoidCallback? action) {
        action?.call();
        // 菜单关闭后把键盘焦点还给 Video（覆盖层夺焦后不会自动归还，与其它 sheet
        // 同样的 guardOverlay 收尾）。点中项时其 helper 可能再弹 sheet 并各自归还，
        // 不冲突；未点中（点外部关闭）时这一下把焦点收回。
        _focusOwnership.reclaim(FocusReclaimCause.overlayClosed);
      }),
    );
  }

  /// 构造桌面右键上下文菜单项（TODO-048c）。每项 value 是该项动作回调，菜单关闭后由
  /// [_handleSecondaryTap] 统一执行——避免在 onTap 里立刻 pop 再异步执行的时序问题。
  /// 项集对齐桌面控制条按钮（播放/暂停、全屏、速度、字幕轨、音轨、截图、字幕列表、
  /// 锁定、跨字幕制卡），全部复用既有 helper。
  ///
  /// 着色器「对比原画」已从右键菜单移除（BUG-261，用户要求）：该功能改只走 `C` 快捷键
  /// （`ShortcutAction.videoToggleShaderCompare`，见 video_player_shortcuts.dart）与设置页
  /// 进入。[_toggleShaderCompare] 方法与 `C` 接线保留，只删右键这一项；右键不再依赖
  /// 「是否启用着色器」的判定（原 `_hasShadersEnabled` getter 随该项一并移除）。
  List<PopupMenuEntry<VoidCallback>> _buildVideoContextMenuItems(
    VideoPlayerController controller,
  ) {
    PopupMenuItem<VoidCallback> item(
      IconData icon,
      String label,
      VoidCallback onSelected,
    ) {
      return PopupMenuItem<VoidCallback>(
        value: onSelected,
        child: Row(
          children: <Widget>[
            Icon(icon, size: _videoControlIconSize),
            const SizedBox(width: 12),
            Expanded(child: Text(label)),
          ],
        ),
      );
    }

    return <PopupMenuEntry<VoidCallback>>[
      item(
        Icons.play_arrow,
        t.video_menu_play_pause,
        () => unawaited(controller.playOrPause()),
      ),
      item(Icons.fullscreen, t.video_menu_fullscreen, () {
        final BuildContext? ctx = _videoControlsContext;
        if (ctx != null && ctx.mounted) {
          unawaited(_toggleVideoFullscreen(ctx));
        }
      }),
      item(Icons.speed, t.video_setting_speed, _showSpeedMenu),
      const PopupMenuDivider(),
      item(
        Icons.subtitles,
        t.video_menu_subtitle_track,
        () => _showSubtitleSourceMenu(controller),
      ),
      item(
        Icons.format_list_bulleted,
        t.video_subtitle_list,
        _toggleSubtitleJumpList,
      ),
      item(
        Icons.audiotrack,
        t.video_audio_track,
        () => _showAudioTrackMenu(controller),
      ),
      // TODO-1158/1159：HLS master（多档码率）或 YouTube 流（懒解析多档）才给画质入口。
      if (_hasQualityMenu)
        item(Icons.high_quality, t.video_quality, _showQualityMenu),
      const PopupMenuDivider(),
      item(Icons.photo_camera_outlined, t.video_screenshot, _saveScreenshot),
      item(
        Icons.movie_creation_outlined,
        t.video_clip_export,
        () => unawaited(_toggleClipExport()),
      ),
      item(Icons.lock_outline, t.video_menu_lock, _toggleImmersiveLock),
      // 设置入口（TODO-389）：右键菜单补一项打开视频设置侧栏，与桌面右侧 rail 的
      // `VideoControlButton.settings` 走同一个 [_showPlayerSettings]（→
      // [_showVideoSidePanel](_VideoSidePanelKind.settings)）。图标用 `Icons.tune`
      // 与可配置 settings 按钮（[_controlButtonIcon] 的 VideoControlButton.settings 分支）
      // 保持一致；标签复用既有 `video_settings_title`（侧栏标题同 key，见
      // [_videoSidePanelTitle]）。
      item(Icons.tune, t.video_settings_title, _showPlayerSettings),
    ];
  }
}

/// TODO-1098：把任意视觉体升级为「单击一次 + 长按连触」按钮。用于底栏 seek 前进/后退
/// 与逐帧前进/后退（用户诉求：这些按钮该支持长按）。范式照搬有声书快捷设置的
/// `_RepeatIconButton`（[ReaderQuickSettingsSheet]）：[onLongPressStart] 先触发一次、
/// 500ms 后 `Timer.periodic(100ms)` 连续触发，[onLongPressEnd] 停，dispose 清 Timer。
///
/// 只包按钮自身的手势层，不动画面区 [GestureDetector]（画面长按 = 临时变速，见
/// speed.part.dart）。[child] 自身保留其单击语义（[onTrigger] 同一回调），因此单击
/// 走 child 的 onTap、长按走本包装器的连触 Timer，两者不冲突。
class _VideoRepeatGestureButton extends StatefulWidget {
  const _VideoRepeatGestureButton({
    required this.onTrigger,
    required this.child,
  });

  /// 单次步进回调（长按时按节律重复调用）。
  final VoidCallback onTrigger;

  /// 视觉体（自带单击 onTap → [onTrigger]，长按由本包装器接管）。
  final Widget child;

  /// 长按后首次连触前的延迟（区分单击与长按）。
  static const Duration _initialDelay = Duration(milliseconds: 500);

  /// 连触间隔。
  static const Duration _repeatInterval = Duration(milliseconds: 100);

  @override
  State<_VideoRepeatGestureButton> createState() =>
      _VideoRepeatGestureButtonState();
}

class _VideoRepeatGestureButtonState extends State<_VideoRepeatGestureButton> {
  Timer? _timer;

  void _start() {
    widget.onTrigger();
    _timer = Timer(_VideoRepeatGestureButton._initialDelay, () {
      _timer = Timer.periodic(
        _VideoRepeatGestureButton._repeatInterval,
        (_) => widget.onTrigger(),
      );
    });
  }

  void _stop() {
    _timer?.cancel();
    _timer = null;
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onLongPressStart: (_) => _start(),
      onLongPressEnd: (_) => _stop(),
      onLongPressCancel: _stop,
      child: widget.child,
    );
  }
}
