// 真透明剪切板文字窗控制器（Windows-only）。
//
// DesktopLookupDispatcher 的 textWindow 分区入口：把剪贴板文本推进逐像素透明的
// 悬浮文字窗（native = FloatingLyricWindow 第二实例 text-only 模式），点字时经
// native lookupText 回调 → 复用 [tryFloatingLyricGlobalLookup] 弹 app 内查词覆盖
// 窗（同一套分词，零漂移）。窗口本身不做词典查询，只显示文本 + 转发点字坐标。

import 'dart:io' show Platform;

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

class ClipboardTextOverlayController {
  ClipboardTextOverlayController._();
  static final ClipboardTextOverlayController instance =
      ClipboardTextOverlayController._();

  /// native 后端仅 Windows（复用 FloatingLyricWindow layered 窗）。
  static bool get isSupported => Platform.isWindows;

  AppModel? _appModel;
  bool _started = false;
  bool _visible = false;

  /// main.dart 桌面块启动一次（幂等）：接线 native 点字回调。窗口到首个
  /// textWindow 分区请求才真正显示。
  Future<void> start({required AppModel appModel}) async {
    if (!isSupported || _started) return;
    _started = true;
    _appModel = appModel;
    ClipboardTextOverlayChannel.setEventHandlers(onLookupText: _onLookup);
  }

  /// 剪贴板请求入口（dispatcher 的 textWindow 分区）：显示透明窗并推入文本。
  /// 空文本忽略（不弹空窗）。
  Future<void> update(DesktopLookupRequest request) async {
    if (!_started) return;
    final String text = request.text.trim();
    if (text.isEmpty) return;
    await ClipboardTextOverlayChannel.show(bgColor: _bgColor());
    await ClipboardTextOverlayChannel.updateText(text);
    _visible = true;
  }

  /// 背景不透明度滑杆改动后即时重刷（窗口在显示时才需要）。
  Future<void> refreshStyle() async {
    if (!_started || !_visible) return;
    await ClipboardTextOverlayChannel.updateStyle(bgColor: _bgColor());
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
