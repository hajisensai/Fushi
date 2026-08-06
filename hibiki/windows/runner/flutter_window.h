#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

#include "floating_lyric_window.h"
#include "global_lookup_window.h"
#include "ime_association_guard.h"
#include "win32_window.h"

// A window that does nothing but host a Flutter view.
class FlutterWindow : public Win32Window {
 public:
  // Creates a new FlutterWindow hosting a Flutter view running |project|.
  explicit FlutterWindow(const flutter::DartProject& project);
  virtual ~FlutterWindow();

 protected:
  // Win32Window:
  bool OnCreate() override;
  void OnDestroy() override;
  void OnDisplayRecovered() override;
  LRESULT MessageHandler(HWND window, UINT const message, WPARAM const wparam,
                         LPARAM const lparam) noexcept override;

 private:
  // The project to run.
  flutter::DartProject project_;

  // The Flutter instance hosted by this window.
  std::unique_ptr<flutter::FlutterViewController> flutter_controller_;

  // Receives title-bar colors pushed from Dart (app.fushi/window channel).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      caption_channel_;

  // Copies decoded reader images to the Windows clipboard as CF_DIB.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      clipboard_image_channel_;

  // TODO-904 P0 回归：单实例守卫下，第二实例用 WM_COPYDATA 把「用 Hibiki 打开视频」
  // 的路径转交给首实例。首实例在 MessageHandler 收到 WM_COPYDATA 后经此 channel 把
  // UTF-8 路径推给 Dart（app.fushi/external_video → _openExternalVideo），复用既有
  // external-video 打开链路，不另造第二套。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      external_video_channel_;

  // TODO-1092: 系统强调色/主题色实时变更通知出口。runner 收到 Windows 的
  // WM_DWMCOLORIZATIONCOLORCHANGED / WM_SETTINGCHANGE("ImmersiveColorSet") /
  // WM_THEMECHANGED 后经此 channel 把 onSystemColorChanged 推给 Dart，触发
  // 动态取色实时刷新（不再等 app 生命周期 resumed）。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      system_theme_channel_;

  // BUG-1239: forwards an unmodified IME-owned physical Space press before
  // Flutter turns VK_PROCESSKEY into a KeyEvent with physical/logical key 0.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      windows_ime_space_channel_;

  // BUG-1450: Dart tells us whether anything editable holds focus; while
  // nothing does we detach the window's IME context so a CJK IME stops eating
  // every shortcut key. See ime_association_guard.h.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      windows_ime_guard_channel_;
  ImeAssociationGuard ime_association_guard_;

  // Wires the ime_guard MethodChannel to ime_association_guard_.
  void RegisterImeGuardChannel();

  // Drives the standalone always-on-top desktop lyric strip (the Windows
  // counterpart of Android's FloatingLyricService). See floating_lyric_window.h.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      floating_lyric_channel_;
  std::unique_ptr<FloatingLyricWindow> floating_lyric_window_;

  // Wires the floating_lyric MethodChannel to floating_lyric_window_.
  void RegisterFloatingLyricChannel();

  // The transparent clipboard text window: a SECOND FloatingLyricWindow instance
  // put in text-only mode (SetTextOnly(true)) — no transport / lock / close
  // buttons, no resize grip, just draggable + tappable text over a per-pixel
  // transparent background. Independent of the audiobook lyric strip so both can
  // be shown at once. Tap lookup routes back over "lookupText" into the in-app
  // dictionary overlay, exactly like the lyric strip.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      clipboard_text_channel_;
  std::unique_ptr<FloatingLyricWindow> clipboard_text_window_;

  // Wires the clipboard_text MethodChannel to clipboard_text_window_.
  void RegisterClipboardTextChannel();

  // Dedicated galgame Hook text box: a THIRD FloatingLyricWindow instance in
  // rich text-only mode. It must never contend with the clipboard destination.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      gal_hook_text_channel_;
  std::unique_ptr<FloatingLyricWindow> gal_hook_text_window_;
  void RegisterGalHookTextChannel();

  // TODO-617: drives the global lookup overlay (bare WebView2 window). The main
  // Dart engine pushes popupJson over this channel; image:// + JS messages route
  // back. See global_lookup_window.h.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      global_lookup_channel_;
  std::unique_ptr<GlobalLookupWindow> global_lookup_window_;
  void RegisterGlobalLookupChannel();

  // spec 2026-07-10: the persistent clipboard-lookup panel — a SECOND
  // GlobalLookupWindow instance (no dismiss hooks, own WebView2 user-data
  // folder) driven by its own channel. See global_lookup_window.h.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      clipboard_panel_channel_;
  std::unique_ptr<GlobalLookupWindow> clipboard_panel_window_;
  void RegisterClipboardPanelChannel();

  // TODO-1030 M0: Windows UIA foreground-selection context capture channel.
  // Dart calls captureContext; the UIA work runs on a worker thread and the
  // result is marshalled back via WM_FGSEL_CAPTURE_DONE (see flutter_window.cpp).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      foreground_selection_channel_;
  void RegisterForegroundSelectionChannel();

  // TODO-1162 M0: window_capture channel (Windows-only external-window mining).
  // listWindows enumerates top-level windows; captureWindow grabs a single WGC
  // frame (PNG) off a worker thread. See window_capture.cpp / .h.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      window_capture_channel_;
  void RegisterWindowCaptureChannel();

  // Magpie 缩放状态监听（仅 Windows）：Magpie 通过
  // RegisterWindowMessage(L"MagpieScalingChanged") 向所有顶层窗口广播缩放状态。
  // runner 收到后经此 channel 把 onScalingChanged 单向推给 Dart（见
  // lib/src/mining/magpie_scaling_channel.dart）。纯 native -> Dart，不注册
  // MethodCallHandler。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      magpie_channel_;
  void RegisterMagpieChannel();

  // RegisterWindowMessageW(L"MagpieScalingChanged") 拿到的运行时消息号。
  // 0 = 尚未注册 / 注册失败，MessageHandler 据此永不误匹配。
  UINT magpie_scaling_message_ = 0;

  // 把一条 MagpieScalingChanged 广播翻译成 Dart 事件推出去。channel 未建好时
  // 静默 no-op。
  void NotifyMagpieScalingChanged(WPARAM wparam, LPARAM lparam);

  // galgame 一键制卡 A 阶段（docs/specs/galgame-mining，仅 Windows）：WASAPI loopback
  // 采集系统混音进环形缓冲。start/stop 管采集，grabRecent 拉最近 N 毫秒 PCM。
  // 见 audio_loopback_capture.cpp / .h。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      audio_loopback_channel_;
  void RegisterAudioLoopbackChannel();

  // galgame 一键制卡 C 阶段（docs/specs/galgame-mining，仅 Windows）：引擎级 voice hook
  // 读侧。open 按游戏 PID 打开隔离组件建好的共享内存，status 轮询 hook 是否就绪，
  // grabRecent 拉最近 N 毫秒干净语音 PCM，close 解除映射。见 voice_hook_reader.cpp / .h。
  // 注入/挂钩代码不在本体，只读共享内存（读不是注入、不被杀软标记）。
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      voice_hook_channel_;
  void RegisterVoiceHookChannel();

  // Applies DWM caption/text colors to the top-level window. Persists across
  // focus changes, so the unfocused title bar keeps following the app theme.
  void ApplyCaptionColors(uint32_t caption_argb, uint32_t text_argb);

  // TODO-1092: notify Dart (system_theme_channel_) that the OS accent/theme
  // color changed so ThemeNotifier.refreshSystemPalette() re-reads it live.
  // Safe to call before the channel exists (null-guarded no-op).
  void NotifySystemColorChanged();

  // Loads an image file via WIC, builds big/small HICONs and applies them to
  // the top-level window (WM_SETICON). Returns true if at least one icon was
  // applied. The previous HICONs are destroyed on replacement and in OnDestroy.
  bool ApplyWindowIcon(const std::wstring& path);

  // Owned window icons set via ApplyWindowIcon. nullptr until first applied.
  HICON icon_big_ = nullptr;
  HICON icon_small_ = nullptr;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
