#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

#include "floating_lyric_window.h"
#include "global_lookup_window.h"
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

  // Receives title-bar colors pushed from Dart (app.hibiki/window channel).
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      caption_channel_;

  // Copies decoded reader images to the Windows clipboard as CF_DIB.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      clipboard_image_channel_;

  // Drives the standalone always-on-top desktop lyric strip (the Windows
  // counterpart of Android's FloatingLyricService). See floating_lyric_window.h.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      floating_lyric_channel_;
  std::unique_ptr<FloatingLyricWindow> floating_lyric_window_;

  // Wires the floating_lyric MethodChannel to floating_lyric_window_.
  void RegisterFloatingLyricChannel();

  // TODO-617: drives the global lookup overlay (bare WebView2 window). The main
  // Dart engine pushes popupJson over this channel; image:// + JS messages route
  // back. See global_lookup_window.h.
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>
      global_lookup_channel_;
  std::unique_ptr<GlobalLookupWindow> global_lookup_window_;
  void RegisterGlobalLookupChannel();

  // Applies DWM caption/text colors to the top-level window. Persists across
  // focus changes, so the unfocused title bar keeps following the app theme.
  void ApplyCaptionColors(uint32_t caption_argb, uint32_t text_argb);

  // Loads an image file via WIC, builds big/small HICONs and applies them to
  // the top-level window (WM_SETICON). Returns true if at least one icon was
  // applied. The previous HICONs are destroyed on replacement and in OnDestroy.
  bool ApplyWindowIcon(const std::wstring& path);

  // Owned window icons set via ApplyWindowIcon. nullptr until first applied.
  HICON icon_big_ = nullptr;
  HICON icon_small_ = nullptr;
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
