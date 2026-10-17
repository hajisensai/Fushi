#ifndef RUNNER_CAPTION_SNAP_BUTTON_H_
#define RUNNER_CAPTION_SNAP_BUTTON_H_

#include <windows.h>
#include <commctrl.h>

#include <functional>
#include <optional>

#pragma comment(lib, "comctl32.lib")

// Windows 11 Snap Layouts for the app-drawn maximize button.
//
// The native caption is hidden (window_manager TitleBarStyle.hidden) and the
// Flutter title bar draws its own window controls, so the system never sees a
// maximize button and the Snap Layouts flyout cannot appear. The documented
// way back is hit testing: return HTMAXBUTTON from WM_NCHITTEST over the
// button. The Flutter view is a child HWND covering the whole client area,
// so the hit test first lands on it; the child answers HTTRANSPARENT inside
// the button rect (same-thread windows only, which this is) and the
// top-level then answers HTMAXBUTTON.
//
// Consequences handled here:
// - Over the button the pointer is in the top-level's non-client area, so
//   Flutter sees the mouse leave. Hover / press are relayed back to Dart
//   ([notify_]) so the Flutter button still draws its state layer.
// - WM_NCLBUTTONDOWN/UP on HTMAXBUTTON are consumed: DefWindowProc would run
//   the classic caption-button tracking loop. The click is relayed to Dart,
//   which owns maximize / restore (and its state sync).
//
// Dart reports the button rect in physical pixels of the Flutter view (=
// child client coordinates); an empty rect disables everything (content
// fullscreen, frame hidden, button unmounted).
class CaptionSnapButton {
 public:
  using Notify = std::function<void(const char* event)>;

  CaptionSnapButton() = default;
  CaptionSnapButton(const CaptionSnapButton&) = delete;
  CaptionSnapButton& operator=(const CaptionSnapButton&) = delete;
  ~CaptionSnapButton() { Detach(); }

  void Attach(HWND top, HWND child, Notify notify) {
    Detach();
    top_ = top;
    child_ = child;
    notify_ = std::move(notify);
    if (child_ != nullptr) {
      SetWindowSubclass(child_, &CaptionSnapButton::ChildProc, kSubclassId,
                        reinterpret_cast<DWORD_PTR>(this));
    }
  }

  void Detach() {
    if (child_ != nullptr) {
      RemoveWindowSubclass(child_, &CaptionSnapButton::ChildProc,
                           kSubclassId);
    }
    child_ = nullptr;
    top_ = nullptr;
    enabled_ = false;
    hover_ = false;
    pressed_ = false;
    notify_ = nullptr;
  }

  // [rect] in child client (Flutter physical) pixels; empty = disabled.
  void SetRect(const RECT& rect) {
    rect_ = rect;
    enabled_ = rect.right > rect.left && rect.bottom > rect.top;
    if (!enabled_) {
      SetPressed(false);
      SetHover(false);
    }
  }

  // Top-level window messages. Returns a result when consumed.
  std::optional<LRESULT> HandleTopLevel(HWND hwnd, UINT message, WPARAM wparam,
                                        LPARAM lparam) {
    if (!enabled_ || hwnd != top_) {
      return std::nullopt;
    }
    switch (message) {
      case WM_NCHITTEST: {
        const POINT screen = PointFromLParam(lparam);
        if (HitsScreenPoint(screen)) {
          return HTMAXBUTTON;
        }
        return std::nullopt;
      }
      case WM_NCMOUSEMOVE: {
        if (wparam == HTMAXBUTTON) {
          SetHover(true);
          if (!tracking_) {
            TRACKMOUSEEVENT track{};
            track.cbSize = sizeof(track);
            track.dwFlags = TME_LEAVE | TME_NONCLIENT;
            track.hwndTrack = top_;
            tracking_ = TrackMouseEvent(&track) != FALSE;
          }
        } else {
          SetPressed(false);
          SetHover(false);
        }
        // Not consumed: the Snap Layouts flyout is driven by the system's own
        // non-client hover handling.
        return std::nullopt;
      }
      case WM_NCMOUSELEAVE:
        tracking_ = false;
        SetPressed(false);
        SetHover(false);
        return std::nullopt;
      case WM_NCLBUTTONDOWN:
      case WM_NCLBUTTONDBLCLK:
        if (wparam != HTMAXBUTTON) {
          return std::nullopt;
        }
        SetPressed(true);
        return 0;
      case WM_NCLBUTTONUP:
        if (wparam != HTMAXBUTTON) {
          SetPressed(false);
          return std::nullopt;
        }
        if (pressed_) {
          SetPressed(false);
          Emit("click");
        }
        return 0;
      default:
        return std::nullopt;
    }
  }

 private:
  static constexpr UINT_PTR kSubclassId = 0x46534342;  // 'FSCB'

  static LRESULT CALLBACK ChildProc(HWND hwnd, UINT message, WPARAM wparam,
                                    LPARAM lparam, UINT_PTR /*id*/,
                                    DWORD_PTR ref) {
    auto* self = reinterpret_cast<CaptionSnapButton*>(ref);
    if (message == WM_NCHITTEST && self != nullptr && self->enabled_) {
      const POINT screen = PointFromLParam(lparam);
      if (self->HitsScreenPoint(screen)) {
        return HTTRANSPARENT;
      }
    }
    if (message == WM_NCDESTROY && self != nullptr) {
      RemoveWindowSubclass(hwnd, &CaptionSnapButton::ChildProc, kSubclassId);
      if (self->child_ == hwnd) {
        self->child_ = nullptr;
        self->enabled_ = false;
      }
    }
    return DefSubclassProc(hwnd, message, wparam, lparam);
  }

  static POINT PointFromLParam(LPARAM lparam) {
    // GET_X_LPARAM / GET_Y_LPARAM without pulling windowsx.h macros in.
    return POINT{static_cast<LONG>(static_cast<short>(LOWORD(lparam))),
                 static_cast<LONG>(static_cast<short>(HIWORD(lparam)))};
  }

  bool HitsScreenPoint(POINT screen) const {
    if (child_ == nullptr) {
      return false;
    }
    POINT local = screen;
    if (!ScreenToClient(child_, &local)) {
      return false;
    }
    return PtInRect(&rect_, local) != FALSE;
  }

  void SetHover(bool hover) {
    if (hover_ == hover) {
      return;
    }
    hover_ = hover;
    Emit(hover ? "hover" : "leave");
  }

  void SetPressed(bool pressed) {
    if (pressed_ == pressed) {
      return;
    }
    pressed_ = pressed;
    Emit(pressed ? "press" : "release");
  }

  void Emit(const char* event) {
    if (notify_) {
      notify_(event);
    }
  }

  HWND top_ = nullptr;
  HWND child_ = nullptr;
  RECT rect_{};
  bool enabled_ = false;
  bool hover_ = false;
  bool pressed_ = false;
  bool tracking_ = false;
  Notify notify_;
};

#endif  // RUNNER_CAPTION_SNAP_BUTTON_H_
