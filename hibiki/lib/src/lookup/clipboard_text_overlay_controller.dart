// 真透明剪切板文字窗控制器（Windows-only）。
//
// DesktopLookupDispatcher 的 textWindow 分区入口：把剪贴板文本推进逐像素透明的
// 悬浮文字窗（native = FloatingLyricWindow 第二实例 text-only 模式），点字时经
// native lookupText 回调 → 复用 [tryFloatingLyricGlobalLookup] 弹 app 内查词覆盖
// 窗（同一套分词，零漂移）。窗口本身不做词典查询，只显示文本 + 转发点字坐标。

import 'dart:io' show Platform;

import 'package:hibiki/i18n/strings.g.dart';
import 'package:hibiki/src/media/audiobook/floating_lyric_lookup_routing.dart';
import 'package:hibiki/src/models/app_model.dart';
import 'package:hibiki/src/platform/clipboard_text_overlay_channel.dart';
import 'package:hibiki/src/sync/desktop_lookup_service.dart';

/// 背景不透明度（0.0–1.0）→ ARGB 背景色：alpha=opacity*255 的纯黑；opacity=0 即
/// `0x00000000` 完全透明背景（文字始终由 native textColor 决定，恒实心）。纯函数，
/// 便于单测这条「滑杆 0% = 真透明」的核心契约。
int clipboardTextWindowBgColor(double opacity) {
  final double clamped = opacity.clamp(0.0, 1.0);
  final int alpha = (clamped * 255).round().clamp(0, 255);
  return alpha << 24;
}

/// 「一键透明」按钮的下一档背景不透明度（Luna #7 语义，纯函数便于单测）：当前有
/// 底色（>0）→ 切到 0（纯透明）；当前已是 0 → 恢复上一档非 0 值 [lastNonZero]，
/// 从没设过则用 [fallback]。
double toggledTextWindowBgOpacity({
  required double current,
  required double lastNonZero,
  double fallback = 0.35,
}) {
  if (current > 0.0) return 0.0;
  return lastNonZero > 0.0 ? lastNonZero : fallback;
}

class ClipboardTextOverlayController {
  ClipboardTextOverlayController._();
  static final ClipboardTextOverlayController instance =
      ClipboardTextOverlayController._();

  /// native 后端仅 Windows（复用 FloatingLyricWindow layered 窗）。
  static bool get isSupported => Platform.isWindows;

  /// 一键透明按钮从「透明」切回时用的默认背景不透明度（用户从没设过非 0 值时）。
  static const double _defaultBackdropOpacity = 0.35;

  AppModel? _appModel;
  bool _started = false;
  bool _visible = false;

  /// 一键透明按钮记住的上一档非 0 背景不透明度，供从 0 切回时恢复。
  double _lastNonZeroBgOpacity = _defaultBackdropOpacity;

  /// main.dart 桌面块启动一次（幂等）：接线 native 点字 + 一键透明回调。窗口到首个
  /// textWindow 分区请求才真正显示。
  Future<void> start({required AppModel appModel}) async {
    if (!isSupported || _started) return;
    _started = true;
    _appModel = appModel;
    ClipboardTextOverlayChannel.setEventHandlers(
      onLookupText: _onLookup,
      onToggleTransparency: _onToggleTransparency,
    );
  }

  /// 剪贴板请求入口（dispatcher 的 textWindow 分区）：显示透明窗并推入文本。
  /// 空文本忽略（不弹空窗）。
  Future<void> update(DesktopLookupRequest request) async {
    if (!_started) return;
    final String text = request.text.trim();
    if (text.isEmpty) return;
    await ClipboardTextOverlayChannel.show(
      bgColor: _bgColor(),
      textColor: _textColor(),
      windowTitle: t.clipboard_text_window_title,
    );
    await ClipboardTextOverlayChannel.updateText(text);
    _visible = true;
  }

  /// 背景不透明度滑杆改动、或主题明暗/配色切换后即时重刷（窗口在显示时才需要）。
  Future<void> refreshStyle() async {
    if (!_started || !_visible) return;
    await ClipboardTextOverlayChannel.updateStyle(
      bgColor: _bgColor(),
      textColor: _textColor(),
    );
  }

  /// 顶栏「一键透明」按钮（Luna #7 语义）：在「当前背景不透明度」与「0（纯透明）」
  /// 间切换，记住上一档非 0 值供切回；切到 0 之外时更新记忆。写穿 pref 让设置滑杆
  /// 同步，并即时重刷窗口。
  Future<void> _onToggleTransparency() async {
    final AppModel? model = _appModel;
    if (model == null) return;
    final double current = model.clipboardTextWindowBgOpacity;
    if (current > 0.0) _lastNonZeroBgOpacity = current;
    final double next = toggledTextWindowBgOpacity(
      current: current,
      lastNonZero: _lastNonZeroBgOpacity,
      fallback: _defaultBackdropOpacity,
    );
    await model.setClipboardTextWindowBgOpacity(next);
    await refreshStyle();
  }

  /// 切走去向 / 关剪贴板监听时收起窗口（不留孤儿透明窗）。
  Future<void> hide() async {
    if (!_started) return;
    await ClipboardTextOverlayChannel.hide();
    _visible = false;
  }

  /// 由背景不透明度 pref 折算 ARGB 背景色（见 [clipboardTextWindowBgColor]）。
  int _bgColor() => clipboardTextWindowBgColor(
      _appModel?.clipboardTextWindowBgOpacity ?? 0.0);

  /// 文字颜色：用户实测拍板「先一律默认黑底白字」，恒实心白。曾跟随主题
  /// onSurface，但浅/深色主题下 onSurface 可能是深色，压在黑底上看不清——故改回
  /// 固定白色（配黑底=最稳的可读基线）。主题跟随留 [AppModel.clipboardTextWindowTextColor]
  /// 备用，暂不接。
  int _textColor() => 0xFFFFFFFF;

  Future<void> _onLookup(String text, int index) async {
    final AppModel? model = _appModel;
    if (model == null) return;
    // 与桌面悬浮字幕点词共用同一路由：整句 [text] + 命中字符 [index] → 分词 →
    // GlobalLookupController.lookupText（瞬态卡弹在光标处，整句作句子横幅/制卡
    // sentence）。覆盖窗不可用时内部返回 false，点字静默 no-op（不崩）。
    await tryFloatingLyricGlobalLookup(
      appModel: model,
      text: text,
      index: index,
    );
  }
}
