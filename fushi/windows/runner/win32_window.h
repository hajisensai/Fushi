#ifndef RUNNER_WIN32_WINDOW_H_
#define RUNNER_WIN32_WINDOW_H_

#include <windows.h>

#include <functional>
#include <memory>
#include <string>

// A class abstraction for a high DPI-aware Win32 Window. Intended to be
// inherited from by classes that wish to specialize with custom
// rendering and input handling
class Win32Window {
 public:
  struct Point {
    unsigned int x;
    unsigned int y;
    Point(unsigned int x, unsigned int y) : x(x), y(y) {}
  };

  struct Size {
    unsigned int width;
    unsigned int height;
    Size(unsigned int width, unsigned int height)
        : width(width), height(height) {}
  };

  Win32Window();
  virtual ~Win32Window();

  // Creates and shows a win32 window with |title| and position and size using
  // |origin| and |size|. New windows are created on the default monitor. Window
  // sizes are specified to the OS in physical pixels, hence to ensure a
  // consistent size to will treat the width height passed in to this function
  // as logical pixels and scale to appropriate for the default monitor. Returns
  // true if the window was created successfully.
  bool CreateAndShow(const std::wstring& title,
                     const Point& origin,
                     const Size& size);

  // Release OS resources associated with window.
  void Destroy();

  // Inserts |content| into the window tree.
  void SetChildContent(HWND content);

  // Returns the backing Window handle to enable clients to set icon and other
  // window properties. Returns nullptr if the window has been destroyed.
  HWND GetHandle();

  // If true, closing this window will quit the application.
  void SetQuitOnClose(bool quit_on_close);

  // Return a RECT representing the bounds of the current client area.
  RECT GetClientArea();

  // BUG-1916: sets the colour this window paints its own surface with. Before
  // the first Flutter frame that is what the user sees (the TODO-959 splash
  // fill); afterwards the surface sits underneath the Flutter view and only
  // shows through during maximize / restore / DPI transitions. Dart pushes
  // the live theme surface colour here so those transitions show the app
  // background instead of a teal "backdrop layer". |color| is a COLORREF
  // (0x00BBGGRR).
  void SetBackdropColor(COLORREF color);

 protected:
  // Processes and route salient window messages for mouse handling,
  // size change and DPI. Delegates handling of these to member overloads that
  // inheriting classes can handle.
  virtual LRESULT MessageHandler(HWND window,
                                 UINT const message,
                                 WPARAM const wparam,
                                 LPARAM const lparam) noexcept;

  // Called when CreateAndShow is called, allowing subclass window-related
  // setup. Subclasses should return false if setup fails.
  virtual bool OnCreate();

  // Called when Destroy is called.
  virtual void OnDestroy();

  // Called when the OS reports the display(s) came back: a monitor powered on
  // (GUID_MONITOR_POWER_ON via WM_POWERBROADCAST) or the display topology/mode
  // changed (WM_DISPLAYCHANGE). The base implementation is a no-op; subclasses
  // hosting a renderer override it to force a fresh frame so the window does
  // not stay blank after the monitor returns (TODO-689).
  virtual void OnDisplayRecovered();

 private:
  friend class WindowClassRegistrar;

  // OS callback called by message pump. Handles the WM_NCCREATE message which
  // is passed when the non-client area is being created and enables automatic
  // non-client DPI scaling so that the non-client area automatically
  // responsponds to changes in DPI. All other messages are handled by
  // MessageHandler.
  static LRESULT CALLBACK WndProc(HWND const window,
                                  UINT const message,
                                  WPARAM const wparam,
                                  LPARAM const lparam) noexcept;

  // Retrieves a class instance pointer for |window|
  static Win32Window* GetThisFromHandle(HWND const window) noexcept;

  bool quit_on_close_ = false;

  // window handle for top level window.
  HWND window_handle_ = nullptr;

  // window handle for hosted content.
  HWND child_content_ = nullptr;

  // BUG-1916: fills |dc| over the whole client rect with |backdrop_brush_|.
  // Whether the Flutter view is excluded depends on the DC: a BeginPaint /
  // GetDC DC honours WS_CLIPCHILDREN and skips it; see FillSurfaceBackdrop
  // for the deliberate unclipped variant.
  void PaintBackdrop(HDC dc);

  // BUG-1916: repaints this window's own redirection surface — including
  // underneath the Flutter view — with |backdrop_brush_|. On the hardware
  // path the view is composed as its own layer over that surface, so the
  // surface colour is normally hidden, but maximize / restore / DPI
  // transitions momentarily show the surface (DWM animates the window's
  // surface, not the view). Keeping it uniformly theme-coloured is what
  // removes the "backdrop layer" there. Under the engine's software-rendering
  // fallback the view paints into this same surface, so a fill can show as at
  // most one theme-coloured frame until the next present.
  void FillSurfaceBackdrop();

  // Owned solid brush used by PaintBackdrop. Starts as the TODO-959 splash
  // colour and is replaced by SetBackdropColor; released in the destructor.
  HBRUSH backdrop_brush_ = nullptr;

  // Registration handle for GUID_MONITOR_POWER_ON power-setting notifications.
  // Held so it can be unregistered on Destroy() (avoids a handle leak). nullptr
  // when no registration is active.
  HPOWERNOTIFY power_notify_ = nullptr;
};

#endif  // RUNNER_WIN32_WINDOW_H_
