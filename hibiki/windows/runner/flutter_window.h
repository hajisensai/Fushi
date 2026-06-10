#ifndef RUNNER_FLUTTER_WINDOW_H_
#define RUNNER_FLUTTER_WINDOW_H_

#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <flutter/method_channel.h>
#include <flutter/standard_method_codec.h>

#include <memory>

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

  // Applies DWM caption/text colors to the top-level window. Persists across
  // focus changes, so the unfocused title bar keeps following the app theme.
  void ApplyCaptionColors(uint32_t caption_argb, uint32_t text_argb);
};

#endif  // RUNNER_FLUTTER_WINDOW_H_
