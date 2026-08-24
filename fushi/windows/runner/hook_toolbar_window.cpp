#include "hook_toolbar_window.h"

#include <d2d1helper.h>
#include <dwrite_3.h>
#include <windowsx.h>

#include <algorithm>
#include <cmath>
#include <utility>
#include <vector>

#pragma comment(lib, "d2d1.lib")
#pragma comment(lib, "dwrite.lib")
// TOOLTIPS_CLASS / InitCommonControlsEx / TTM_* —— 工具条槽位悬停提示。
#pragma comment(lib, "comctl32.lib")

namespace {

constexpr wchar_t kWindowClassName[] = L"FushiHookToolbarWindow";

// A press must travel this far (physical px at 96 DPI, scaled by the owner via
// Layout::button_px staying proportional) before it becomes an owner drag
// rather than a button-miss. Same idea as the body window's kDragThresholdDip.
constexpr float kDragThresholdPx = 6.0f;

// Opacity of the toolbar while the cursor is elsewhere. Unlike the in-body
// toolbar (which is invisible until hovered, because the body itself is a
// visible bar the user can aim at), this window is the ONLY way out of
// pass-through: an invisible escape hatch over a fully transparent overlay is
// an escape hatch the user cannot find. So it stays dimly visible at rest.
constexpr float kRestOpacity = 0.42f;
constexpr float kHoverOpacity = 1.0f;

std::wstring MaterialSymbolsRoundedFontPath() {
  std::wstring module_path(32768, L'\0');
  const DWORD length = GetModuleFileNameW(
      nullptr, module_path.data(), static_cast<DWORD>(module_path.size()));
  if (length == 0 || length >= module_path.size()) {
    return std::wstring();
  }
  module_path.resize(length);
  const size_t separator = module_path.find_last_of(L"\\/");
  if (separator == std::wstring::npos) {
    return std::wstring();
  }
  module_path.resize(separator + 1);
  module_path.append(
      L"data\\flutter_assets\\assets\\fonts\\MaterialSymbolsRounded.ttf");
  return module_path;
}

// ARGB (0xAARRGGBB) -> D2D1_COLOR_F (straight alpha).
D2D1_COLOR_F ColorFromArgb(uint32_t argb) {
  const float a = ((argb >> 24) & 0xFF) / 255.0f;
  const float r = ((argb >> 16) & 0xFF) / 255.0f;
  const float g = ((argb >> 8) & 0xFF) / 255.0f;
  const float b = (argb & 0xFF) / 255.0f;
  return D2D1::ColorF(r, g, b, a);
}

bool SameLayout(const hook_toolbar::Layout& a, const hook_toolbar::Layout& b) {
  return a.rect.left == b.rect.left && a.rect.top == b.rect.top &&
         a.rect.right == b.rect.right && a.rect.bottom == b.rect.bottom &&
         a.owner_origin.x == b.owner_origin.x &&
         a.owner_origin.y == b.owner_origin.y && a.button_px == b.button_px &&
         a.gap_px == b.gap_px && a.margin_px == b.margin_px;
}

bool SameStyle(const hook_toolbar::Style& a, const hook_toolbar::Style& b) {
  return a.button_text_color == b.button_text_color &&
         a.button_bg_color == b.button_bg_color &&
         a.active_color == b.active_color && a.bg_color == b.bg_color;
}

bool SameStates(const hook_toolbar::States& a, const hook_toolbar::States& b) {
  return a.replaying == b.replaying && a.recapturing == b.recapturing &&
         a.playing == b.playing && a.pass_through == b.pass_through &&
         a.locked == b.locked && a.topmost == b.topmost;
}

}  // namespace

namespace hook_toolbar {

bool SlotActive(int slot, const States& states) {
  switch (slot) {
    case 0:
      return states.replaying;
    case 1:
      return states.recapturing;
    case 2:
      return !states.playing;
    case 3:
      return states.pass_through;
    case 5:
      return states.locked;
    case 7:
      return states.topmost;
    default:
      return false;
  }
}

const wchar_t* SlotGlyph(int slot, const States& states) {
  switch (slot) {
    case 0:
      return L"\uE042";  // replay
    case 1:
      return L"\uE31D";  // mic
    case 2:
      return states.playing ? L"\uE034" : L"\uE037";  // pause / play_arrow
    case 3:
      return L"\uE323";  // mouse
    case 4:
      return L"\uE91C";  // opacity
    case 5:
      return states.locked ? L"\uE899" : L"\uE898";  // lock / lock_open
    case 6:
      return L"\uE99B";  // dashboard_customize
    case 7:
      return L"\uF10D";  // push_pin
    case 8:
      return L"\uE5CD";  // close
    default:
      return L"";
  }
}

bool LoadMaterialSymbolsRoundedFontCollection(
    IDWriteFactory* factory, IDWriteFontCollection** collection) {
  if (factory == nullptr || collection == nullptr) {
    return false;
  }
  *collection = nullptr;
  const std::wstring path = MaterialSymbolsRoundedFontPath();
  if (path.empty() ||
      GetFileAttributesW(path.c_str()) == INVALID_FILE_ATTRIBUTES) {
    return false;
  }

  Microsoft::WRL::ComPtr<IDWriteFactory5> factory5;
  Microsoft::WRL::ComPtr<IDWriteFontSetBuilder1> builder;
  Microsoft::WRL::ComPtr<IDWriteFontFile> font_file;
  Microsoft::WRL::ComPtr<IDWriteFontSet> font_set;
  Microsoft::WRL::ComPtr<IDWriteFontCollection1> font_collection;
  if (FAILED(factory->QueryInterface(IID_PPV_ARGS(factory5.GetAddressOf()))) ||
      FAILED(factory5->CreateFontSetBuilder(builder.GetAddressOf())) ||
      FAILED(factory5->CreateFontFileReference(path.c_str(), nullptr,
                                               font_file.GetAddressOf())) ||
      FAILED(builder->AddFontFile(font_file.Get())) ||
      FAILED(builder->CreateFontSet(font_set.GetAddressOf())) ||
      FAILED(factory5->CreateFontCollectionFromFontSet(
          font_set.Get(), font_collection.GetAddressOf()))) {
    return false;
  }
  *collection = font_collection.Detach();
  return true;
}

void DrawSlotIcon(ID2D1RenderTarget* target, ID2D1Factory* factory, int slot,
                  const States& states, const D2D1_RECT_F& bounds,
                  ID2D1Brush* brush) {
  if (target == nullptr || factory == nullptr || brush == nullptr) {
    return;
  }
  const float width = bounds.right - bounds.left;
  const float height = bounds.bottom - bounds.top;
  const float size = std::min(width, height);
  if (size <= 0.0f) {
    return;
  }
  const float ox = bounds.left + (width - size) * 0.5f;
  const float oy = bounds.top + (height - size) * 0.5f;
  const float stroke = std::max(1.0f, size * 0.055f);
  auto point = [ox, oy, size](float x, float y) {
    return D2D1::Point2F(ox + size * x, oy + size * y);
  };
  auto rect = [ox, oy, size](float left, float top, float right, float bottom) {
    return D2D1::RectF(ox + size * left, oy + size * top, ox + size * right,
                       oy + size * bottom);
  };

  D2D1_STROKE_STYLE_PROPERTIES stroke_properties = {};
  stroke_properties.startCap = D2D1_CAP_STYLE_ROUND;
  stroke_properties.endCap = D2D1_CAP_STYLE_ROUND;
  stroke_properties.dashCap = D2D1_CAP_STYLE_ROUND;
  stroke_properties.lineJoin = D2D1_LINE_JOIN_ROUND;
  stroke_properties.miterLimit = 10.0f;
  stroke_properties.dashStyle = D2D1_DASH_STYLE_SOLID;
  Microsoft::WRL::ComPtr<ID2D1StrokeStyle> round_stroke;
  factory->CreateStrokeStyle(&stroke_properties, nullptr, 0,
                             round_stroke.GetAddressOf());

  auto draw_path = [&](ID2D1PathGeometry* geometry) {
    if (geometry != nullptr) {
      target->DrawGeometry(geometry, brush, stroke, round_stroke.Get());
    }
  };

  switch (slot) {
    case 0: {  // Replay captured voice.
      Microsoft::WRL::ComPtr<ID2D1PathGeometry> arc;
      if (SUCCEEDED(factory->CreatePathGeometry(arc.GetAddressOf()))) {
        Microsoft::WRL::ComPtr<ID2D1GeometrySink> sink;
        if (SUCCEEDED(arc->Open(sink.GetAddressOf()))) {
          sink->BeginFigure(point(0.30f, 0.50f), D2D1_FIGURE_BEGIN_HOLLOW);
          sink->AddArc(D2D1::ArcSegment(
              point(0.50f, 0.28f), D2D1::SizeF(size * 0.22f, size * 0.22f),
              0.0f, D2D1_SWEEP_DIRECTION_CLOCKWISE, D2D1_ARC_SIZE_SMALL));
          sink->AddArc(D2D1::ArcSegment(
              point(0.72f, 0.50f), D2D1::SizeF(size * 0.22f, size * 0.22f),
              0.0f, D2D1_SWEEP_DIRECTION_CLOCKWISE, D2D1_ARC_SIZE_SMALL));
          sink->AddArc(D2D1::ArcSegment(
              point(0.50f, 0.72f), D2D1::SizeF(size * 0.22f, size * 0.22f),
              0.0f, D2D1_SWEEP_DIRECTION_CLOCKWISE, D2D1_ARC_SIZE_SMALL));
          sink->EndFigure(D2D1_FIGURE_END_OPEN);
          sink->Close();
          draw_path(arc.Get());
        }
      }
      target->DrawLine(point(0.30f, 0.50f), point(0.29f, 0.32f), brush, stroke,
                       round_stroke.Get());
      target->DrawLine(point(0.30f, 0.50f), point(0.46f, 0.46f), brush, stroke,
                       round_stroke.Get());
      break;
    }
    case 1: {  // Recapture voice: microphone, not an ambiguous text dot.
      target->DrawRoundedRectangle(
          D2D1::RoundedRect(rect(0.43f, 0.24f, 0.57f, 0.56f), size * 0.07f,
                            size * 0.07f),
          brush, stroke, round_stroke.Get());
      Microsoft::WRL::ComPtr<ID2D1PathGeometry> cradle;
      if (SUCCEEDED(factory->CreatePathGeometry(cradle.GetAddressOf()))) {
        Microsoft::WRL::ComPtr<ID2D1GeometrySink> sink;
        if (SUCCEEDED(cradle->Open(sink.GetAddressOf()))) {
          sink->BeginFigure(point(0.34f, 0.47f), D2D1_FIGURE_BEGIN_HOLLOW);
          sink->AddBezier(D2D1::BezierSegment(
              point(0.34f, 0.70f), point(0.66f, 0.70f), point(0.66f, 0.47f)));
          sink->EndFigure(D2D1_FIGURE_END_OPEN);
          sink->Close();
          draw_path(cradle.Get());
        }
      }
      target->DrawLine(point(0.50f, 0.67f), point(0.50f, 0.76f), brush, stroke,
                       round_stroke.Get());
      target->DrawLine(point(0.41f, 0.76f), point(0.59f, 0.76f), brush, stroke,
                       round_stroke.Get());
      break;
    }
    case 2: {  // Follow / pause.
      if (states.playing) {
        target->FillRoundedRectangle(
            D2D1::RoundedRect(rect(0.35f, 0.29f, 0.45f, 0.71f), size * 0.02f,
                              size * 0.02f),
            brush);
        target->FillRoundedRectangle(
            D2D1::RoundedRect(rect(0.55f, 0.29f, 0.65f, 0.71f), size * 0.02f,
                              size * 0.02f),
            brush);
      } else {
        Microsoft::WRL::ComPtr<ID2D1PathGeometry> play;
        if (SUCCEEDED(factory->CreatePathGeometry(play.GetAddressOf()))) {
          Microsoft::WRL::ComPtr<ID2D1GeometrySink> sink;
          if (SUCCEEDED(play->Open(sink.GetAddressOf()))) {
            sink->BeginFigure(point(0.39f, 0.28f), D2D1_FIGURE_BEGIN_FILLED);
            sink->AddLine(point(0.39f, 0.72f));
            sink->AddLine(point(0.70f, 0.50f));
            sink->EndFigure(D2D1_FIGURE_END_CLOSED);
            sink->Close();
            target->FillGeometry(play.Get(), brush);
          }
        }
      }
      break;
    }
    case 3: {  // Mouse pass-through: a proper pointer silhouette.
      Microsoft::WRL::ComPtr<ID2D1PathGeometry> cursor;
      if (SUCCEEDED(factory->CreatePathGeometry(cursor.GetAddressOf()))) {
        Microsoft::WRL::ComPtr<ID2D1GeometrySink> sink;
        if (SUCCEEDED(cursor->Open(sink.GetAddressOf()))) {
          sink->BeginFigure(point(0.29f, 0.24f), D2D1_FIGURE_BEGIN_FILLED);
          sink->AddLine(point(0.30f, 0.73f));
          sink->AddLine(point(0.43f, 0.60f));
          sink->AddLine(point(0.53f, 0.78f));
          sink->AddLine(point(0.64f, 0.72f));
          sink->AddLine(point(0.54f, 0.55f));
          sink->AddLine(point(0.73f, 0.53f));
          sink->EndFigure(D2D1_FIGURE_END_CLOSED);
          sink->Close();
          target->FillGeometry(cursor.Get(), brush);
        }
      }
      break;
    }
    case 4: {  // Background transparency.
      const D2D1_ELLIPSE circle =
          D2D1::Ellipse(point(0.50f, 0.50f), size * 0.23f, size * 0.23f);
      target->PushAxisAlignedClip(rect(0.25f, 0.25f, 0.50f, 0.75f),
                                  D2D1_ANTIALIAS_MODE_PER_PRIMITIVE);
      target->FillEllipse(circle, brush);
      target->PopAxisAlignedClip();
      target->DrawEllipse(circle, brush, stroke, round_stroke.Get());
      break;
    }
    case 5: {  // Position lock / unlock.
      target->DrawRoundedRectangle(
          D2D1::RoundedRect(rect(0.31f, 0.44f, 0.69f, 0.74f), size * 0.05f,
                            size * 0.05f),
          brush, stroke, round_stroke.Get());
      Microsoft::WRL::ComPtr<ID2D1PathGeometry> shackle;
      if (SUCCEEDED(factory->CreatePathGeometry(shackle.GetAddressOf()))) {
        Microsoft::WRL::ComPtr<ID2D1GeometrySink> sink;
        if (SUCCEEDED(shackle->Open(sink.GetAddressOf()))) {
          const float left = states.locked ? 0.39f : 0.43f;
          const float right = states.locked ? 0.61f : 0.66f;
          sink->BeginFigure(point(left, 0.44f), D2D1_FIGURE_BEGIN_HOLLOW);
          sink->AddLine(point(left, 0.37f));
          sink->AddBezier(D2D1::BezierSegment(
              point(left, 0.23f), point(right, 0.23f), point(right, 0.37f)));
          if (states.locked) {
            sink->AddLine(point(right, 0.44f));
          } else {
            sink->AddLine(point(right, 0.40f));
          }
          sink->EndFigure(D2D1_FIGURE_END_OPEN);
          sink->Close();
          draw_path(shackle.Get());
        }
      }
      break;
    }
    case 6: {  // Capture workbench / panel.
      target->DrawRoundedRectangle(
          D2D1::RoundedRect(rect(0.27f, 0.28f, 0.73f, 0.72f), size * 0.04f,
                            size * 0.04f),
          brush, stroke, round_stroke.Get());
      target->DrawLine(point(0.28f, 0.41f), point(0.72f, 0.41f), brush, stroke,
                       round_stroke.Get());
      target->DrawLine(point(0.47f, 0.42f), point(0.47f, 0.71f), brush, stroke,
                       round_stroke.Get());
      target->DrawLine(point(0.53f, 0.51f), point(0.66f, 0.51f), brush, stroke,
                       round_stroke.Get());
      target->DrawLine(point(0.53f, 0.60f), point(0.63f, 0.60f), brush, stroke,
                       round_stroke.Get());
      break;
    }
    case 7: {  // Always-on-top pin.
      Microsoft::WRL::ComPtr<ID2D1PathGeometry> pin;
      if (SUCCEEDED(factory->CreatePathGeometry(pin.GetAddressOf()))) {
        Microsoft::WRL::ComPtr<ID2D1GeometrySink> sink;
        if (SUCCEEDED(pin->Open(sink.GetAddressOf()))) {
          sink->BeginFigure(point(0.35f, 0.28f), D2D1_FIGURE_BEGIN_FILLED);
          sink->AddLine(point(0.65f, 0.28f));
          sink->AddLine(point(0.60f, 0.38f));
          sink->AddLine(point(0.58f, 0.51f));
          sink->AddLine(point(0.68f, 0.60f));
          sink->AddLine(point(0.32f, 0.60f));
          sink->AddLine(point(0.42f, 0.51f));
          sink->AddLine(point(0.40f, 0.38f));
          sink->EndFigure(D2D1_FIGURE_END_CLOSED);
          sink->Close();
          target->FillGeometry(pin.Get(), brush);
        }
      }
      target->DrawLine(point(0.50f, 0.60f), point(0.50f, 0.77f), brush, stroke,
                       round_stroke.Get());
      break;
    }
    case 8: {  // Close.
      target->DrawLine(point(0.31f, 0.31f), point(0.69f, 0.69f), brush, stroke,
                       round_stroke.Get());
      target->DrawLine(point(0.69f, 0.31f), point(0.31f, 0.69f), brush, stroke,
                       round_stroke.Get());
      break;
    }
    default:
      break;
  }
}

namespace {

std::vector<std::wstring>& SlotTooltipStore() {
  static std::vector<std::wstring> store;
  return store;
}

}  // namespace

void SetSlotTooltips(std::vector<std::wstring> tooltips) {
  SlotTooltipStore() = std::move(tooltips);
}

const std::wstring& SlotTooltip(int slot) {
  static const std::wstring empty;
  const std::vector<std::wstring>& store = SlotTooltipStore();
  if (slot < 0 || slot >= static_cast<int>(store.size())) {
    return empty;
  }
  return store[static_cast<size_t>(slot)];
}

SlotTooltipHost::~SlotTooltipHost() {
  if (hwnd_ != nullptr) {
    DestroyWindow(hwnd_);
    hwnd_ = nullptr;
  }
}

bool SlotTooltipHost::EnsureWindow(HWND owner) {
  if (hwnd_ != nullptr) {
    return true;
  }
  // TOOLTIPS_CLASS 归 comctl32 管；tooltip 与 tab 同属 ICC_TAB_CLASSES。只需
  // 初始化一次（function-local static 保证），失败（极老系统 / 缺 comctl32）
  // 就当没有 tooltip —— 功能静默降级，工具条本身照常可点，绝不崩。
  static const bool common_controls_ready = [] {
    INITCOMMONCONTROLSEX icc = {sizeof(INITCOMMONCONTROLSEX), ICC_TAB_CLASSES};
    return InitCommonControlsEx(&icc) != FALSE;
  }();
  if (!common_controls_ready) {
    return false;
  }
  hwnd_ = CreateWindowExW(WS_EX_TOPMOST | WS_EX_NOACTIVATE, TOOLTIPS_CLASSW,
                          nullptr, WS_POPUP | TTS_ALWAYSTIP | TTS_NOPREFIX,
                          CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT,
                          CW_USEDEFAULT, owner, nullptr,
                          GetModuleHandleW(nullptr), nullptr);
  if (hwnd_ == nullptr) {
    return false;
  }
  tool_ = {};
  tool_.cbSize = sizeof(tool_);
  // TTF_TRACK|TTF_ABSOLUTE：位置完全由宿主的 TTM_TRACKPOSITION 决定——宿主窗
  // 是 WS_EX_NOACTIVATE 的自绘分层窗，标准的矩形工具 + 子类化在这里拿不到可靠
  // 的鼠标节奏，手动追踪反而最简单。
  tool_.uFlags = TTF_TRACK | TTF_ABSOLUTE;
  tool_.hwnd = owner;
  tool_.uId = 1;
  current_text_.clear();
  tool_.lpszText = current_text_.data();
  SendMessageW(hwnd_, TTM_ADDTOOLW, 0, reinterpret_cast<LPARAM>(&tool_));
  return true;
}

void SlotTooltipHost::Update(HWND owner, int slot, int screen_x,
                             int screen_y) {
  const std::wstring& text = SlotTooltip(slot);
  if (slot < 0 || text.empty() || owner == nullptr) {
    Hide();
    return;
  }
  if (slot == active_slot_) {
    return;  // 同一颗按钮上抖动不重摆位置，提示钉在初次进入处。
  }
  if (!EnsureWindow(owner)) {
    return;
  }
  active_slot_ = slot;
  // 自持一份文案再指过去：SetSlotTooltips 是整表 move 赋值，指向共享表内部
  // 缓冲的 lpszText 会在下一次下发时变成悬垂指针。
  current_text_ = text;
  tool_.lpszText = current_text_.data();
  SendMessageW(hwnd_, TTM_UPDATETIPTEXTW, 0, reinterpret_cast<LPARAM>(&tool_));
  // TTM_TRACKPOSITION 的 x / y 是**有符号**的：副屏摆在主屏左边或上边时屏幕
  // 坐标为负，直接 static_cast<WORD> 会把 -8 截成 65528，提示被甩到屏幕外几万
  // 像素处。先窄化成 SHORT（保留符号位模式）再取无符号位模式，MAKELPARAM 打包
  // 出来的 16 位才会被 comctl32 按 GET_X_LPARAM 还原成原来的负值。
  SendMessageW(hwnd_, TTM_TRACKPOSITION, 0,
               MAKELPARAM(static_cast<WORD>(static_cast<SHORT>(screen_x)),
                          static_cast<WORD>(static_cast<SHORT>(screen_y))));
  SendMessageW(hwnd_, TTM_TRACKACTIVATE, TRUE,
               reinterpret_cast<LPARAM>(&tool_));
}

void SlotTooltipHost::Hide() {
  active_slot_ = -1;
  if (hwnd_ == nullptr) {
    return;
  }
  SendMessageW(hwnd_, TTM_TRACKACTIVATE, FALSE,
               reinterpret_cast<LPARAM>(&tool_));
}

}  // namespace hook_toolbar

HookToolbarWindow::HookToolbarWindow() = default;

HookToolbarWindow::~HookToolbarWindow() {
  if (hwnd_ != nullptr) {
    DestroyWindow(hwnd_);
    hwnd_ = nullptr;
  }
  if (class_registered_) {
    UnregisterClassW(kWindowClassName, GetModuleHandle(nullptr));
  }
}

void HookToolbarWindow::EnsureWindowClass() {
  if (class_registered_) {
    return;
  }
  WNDCLASSEXW wc = {};
  wc.cbSize = sizeof(wc);
  wc.style = CS_HREDRAW | CS_VREDRAW;
  wc.lpfnWndProc = HookToolbarWindow::WndProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  wc.lpszClassName = kWindowClassName;
  RegisterClassExW(&wc);
  class_registered_ = true;
}

bool HookToolbarWindow::EnsureDeviceResources() {
  if (d2d_factory_ == nullptr) {
    if (FAILED(D2D1CreateFactory(D2D1_FACTORY_TYPE_SINGLE_THREADED,
                                 d2d_factory_.GetAddressOf()))) {
      return false;
    }
  }
  if (dwrite_factory_ == nullptr) {
    if (FAILED(DWriteCreateFactory(
            DWRITE_FACTORY_TYPE_SHARED, __uuidof(IDWriteFactory),
            reinterpret_cast<IUnknown**>(dwrite_factory_.GetAddressOf())))) {
      return false;
    }
  }
  if (icon_font_collection_ == nullptr) {
    hook_toolbar::LoadMaterialSymbolsRoundedFontCollection(
        dwrite_factory_.Get(), icon_font_collection_.GetAddressOf());
  }
  if (render_target_ == nullptr) {
    D2D1_RENDER_TARGET_PROPERTIES props = D2D1::RenderTargetProperties(
        D2D1_RENDER_TARGET_TYPE_DEFAULT,
        D2D1::PixelFormat(DXGI_FORMAT_B8G8R8A8_UNORM,
                          D2D1_ALPHA_MODE_PREMULTIPLIED),
        0, 0, D2D1_RENDER_TARGET_USAGE_NONE, D2D1_FEATURE_LEVEL_DEFAULT);
    if (FAILED(d2d_factory_->CreateDCRenderTarget(
            &props, render_target_.GetAddressOf()))) {
      render_target_.Reset();
      return false;
    }
  }
  return true;
}

bool HookToolbarWindow::Show(const hook_toolbar::Layout& layout,
                             const hook_toolbar::Style& style,
                             const hook_toolbar::States& states) {
  const int width = layout.rect.right - layout.rect.left;
  const int height = layout.rect.bottom - layout.rect.top;
  if (width <= 0 || height <= 0) {
    return false;
  }
  EnsureWindowClass();
  if (!EnsureDeviceResources()) {
    return false;
  }
  if (hwnd_ == nullptr) {
    // Deliberately WITHOUT WS_EX_TRANSPARENT: this window is the escape hatch
    // out of pass-through and must be clickable at every instant. WS_EX_LAYERED
    // for per-pixel alpha (rounded pill over the game), WS_EX_TOPMOST to float
    // above both the game and the overlay body, WS_EX_NOACTIVATE so clicking a
    // button never steals keyboard focus from the game, WS_EX_TOOLWINDOW to
    // stay out of the taskbar / Alt+Tab.
    hwnd_ = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
        kWindowClassName, L"Fushi Hook Toolbar", WS_POPUP, layout.rect.left,
        layout.rect.top, width, height, nullptr, nullptr,
        GetModuleHandle(nullptr), this);
    if (hwnd_ == nullptr) {
      return false;
    }
  }
  layout_ = layout;
  style_ = style;
  states_ = states;
  has_layout_ = true;
  SetWindowPos(hwnd_, HWND_TOPMOST, layout.rect.left, layout.rect.top, width,
               height, SWP_NOACTIVATE);
  ShowWindow(hwnd_, SW_SHOWNOACTIVATE);
  visible_ = true;
  Render();
  return true;
}

void HookToolbarWindow::CancelPointerGesture() {
  pressed_ = false;
  dragging_ = false;
  if (hwnd_ != nullptr && GetCapture() == hwnd_) {
    ReleaseCapture();
  }
}

void HookToolbarWindow::Hide() {
  visible_ = false;
  hovered_ = false;
  hovered_slot_ = -1;
  tracking_mouse_leave_ = false;
  // 隐藏后收不到 WM_MOUSELEAVE：提示留着就是一块浮在桌面上的孤儿。
  tooltip_.Hide();
  CancelPointerGesture();
  if (hwnd_ != nullptr) {
    ShowWindow(hwnd_, SW_HIDE);
  }
}

bool HookToolbarWindow::IsShowing() const {
  return visible_ && hwnd_ != nullptr && IsWindowVisible(hwnd_);
}

void HookToolbarWindow::Sync(const hook_toolbar::Layout& layout,
                             const hook_toolbar::Style& style,
                             const hook_toolbar::States& states) {
  if (hwnd_ == nullptr || !visible_) {
    return;
  }
  const bool moved = !has_layout_ || !SameLayout(layout, layout_);
  const bool repaint =
      moved || !SameStyle(style, style_) || !SameStates(states, states_);
  if (!repaint) {
    // Still re-assert Z: the body window raises itself to HWND_TOPMOST on show
    // / clamp / DPI change, which would otherwise tint this pill from above.
    SetWindowPos(hwnd_, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    return;
  }
  layout_ = layout;
  style_ = style;
  states_ = states;
  has_layout_ = true;
  if (moved) {
    SetWindowPos(hwnd_, HWND_TOPMOST, layout.rect.left, layout.rect.top,
                 layout.rect.right - layout.rect.left,
                 layout.rect.bottom - layout.rect.top, SWP_NOACTIVATE);
  } else {
    SetWindowPos(hwnd_, HWND_TOPMOST, 0, 0, 0, 0,
                 SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  }
  Render();
}

int HookToolbarWindow::SlotAt(float x, float y) const {
  if (!has_layout_ || layout_.button_px <= 0.0f) {
    return -1;
  }
  const float top = layout_.margin_px;
  if (y < top || y > top + layout_.button_px) {
    return -1;
  }
  for (int slot = 0; slot < hook_toolbar::kSlotCount; ++slot) {
    const float bx =
        layout_.margin_px + slot * (layout_.button_px + layout_.gap_px);
    if (x >= bx && x <= bx + layout_.button_px) {
      return slot;
    }
  }
  return -1;
}

LRESULT CALLBACK HookToolbarWindow::WndProc(HWND hwnd, UINT message,
                                            WPARAM wparam,
                                            LPARAM lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto* create = reinterpret_cast<CREATESTRUCT*>(lparam);
    SetWindowLongPtr(hwnd, GWLP_USERDATA,
                     reinterpret_cast<LONG_PTR>(create->lpCreateParams));
    auto* self = static_cast<HookToolbarWindow*>(create->lpCreateParams);
    self->hwnd_ = hwnd;
    return DefWindowProc(hwnd, message, wparam, lparam);
  }
  auto* self =
      reinterpret_cast<HookToolbarWindow*>(GetWindowLongPtr(hwnd, GWLP_USERDATA));
  if (self != nullptr) {
    return self->HandleMessage(message, wparam, lparam);
  }
  return DefWindowProc(hwnd, message, wparam, lparam);
}

LRESULT HookToolbarWindow::HandleMessage(UINT message, WPARAM wparam,
                                         LPARAM lparam) noexcept {
  switch (message) {
    case WM_MOUSEMOVE: {
      const int next_hovered_slot =
          SlotAt(static_cast<float>(GET_X_LPARAM(lparam)),
                 static_cast<float>(GET_Y_LPARAM(lparam)));
      const bool slot_changed = next_hovered_slot != hovered_slot_;
      hovered_slot_ = next_hovered_slot;
      if (!hovered_) {
        hovered_ = true;
        Render();
      } else if (slot_changed && !dragging_) {
        Render();
      }
      if (!tracking_mouse_leave_) {
        TRACKMOUSEEVENT tme = {};
        tme.cbSize = sizeof(tme);
        tme.dwFlags = TME_LEAVE;
        tme.hwndTrack = hwnd_;
        if (TrackMouseEvent(&tme)) {
          tracking_mouse_leave_ = true;
        }
      }
      if (dragging_) {
        POINT cursor;
        GetCursorPos(&cursor);
        if (on_drag_) {
          on_drag_(cursor.x - owner_drag_anchor_.x,
                   cursor.y - owner_drag_anchor_.y);
        }
        return 0;
      }
      if (pressed_) {
        POINT cursor;
        GetCursorPos(&cursor);
        const int dx = cursor.x - press_origin_.x;
        const int dy = cursor.y - press_origin_.y;
        if (dx * dx + dy * dy >=
            static_cast<int>(kDragThresholdPx * kDragThresholdPx)) {
          dragging_ = true;
        }
        return 0;
      }
      {
        // 槽位悬停提示：摆在光标右下（不遮按钮本身）。文案表与正文内工具条
        // 共用（hook_toolbar::SlotTooltip），空文案 / 空槽自动隐藏。
        POINT cursor;
        GetCursorPos(&cursor);
        tooltip_.Update(hwnd_, hovered_slot_, cursor.x + 12, cursor.y + 22);
      }
      return 0;
    }
    case WM_MOUSELEAVE: {
      tracking_mouse_leave_ = false;
      tooltip_.Hide();
      if (hovered_ && !dragging_) {
        hovered_ = false;
        hovered_slot_ = -1;
        Render();
      }
      return 0;
    }
    case WM_LBUTTONDOWN: {
      // 按下即操作：提示的活儿到此为止，留着会盖在刚变过状态的按钮上。
      tooltip_.Hide();
      const float x = static_cast<float>(GET_X_LPARAM(lparam));
      const float y = static_cast<float>(GET_Y_LPARAM(lparam));
      const int slot = SlotAt(x, y);
      if (slot >= 0) {
        // Buttons fire on press, exactly like the in-body toolbar, so the
        // escape hatch responds to the same gesture the user already knows.
        if (on_action_) {
          on_action_(hook_toolbar::kSlotActions[slot]);
        }
        return 0;
      }
      // A press on the pill background starts a move of the OWNER window: while
      // pass-through is on the body takes no mouse input at all, so this is the
      // only remaining way to reposition the overlay.
      POINT cursor;
      GetCursorPos(&cursor);
      pressed_ = true;
      dragging_ = false;
      press_origin_ = cursor;
      // Anchor on the OWNER's top-left, which the owner pushes down with the
      // layout. Anchoring on the toolbar rect instead would make the first drag
      // move jump the body by the (centred-row) toolbar offset — several
      // hundred px — which also yanks the pill out from under the cursor and
      // kills the drag, since a WS_EX_NOACTIVATE window only gets background
      // capture while the cursor is over it.
      owner_drag_anchor_.x = cursor.x - layout_.owner_origin.x;
      owner_drag_anchor_.y = cursor.y - layout_.owner_origin.y;
      SetCapture(hwnd_);
      return 0;
    }
    // BUG-1471: capture revoked out from under us (foreground window changed).
    // The button-up will never arrive; end the gesture here or `pressed_` stays
    // true and every later move is treated as an owner-drag.
    case WM_CAPTURECHANGED: {
      CancelPointerGesture();
      return 0;
    }
    case WM_LBUTTONUP: {
      const bool was_dragging = dragging_;
      CancelPointerGesture();
      if (was_dragging && on_drag_end_) {
        on_drag_end_();
      }
      return 0;
    }
    case WM_NCHITTEST:
      // Everything is client area: this window has no resize grip and never
      // hands anything to the system loops. It also never returns
      // HTTRANSPARENT — that is precisely the cross-process no-op this whole
      // window exists to replace.
      return HTCLIENT;
    default:
      return DefWindowProc(hwnd_, message, wparam, lparam);
  }
}

void HookToolbarWindow::Render() {
  if (hwnd_ == nullptr || !has_layout_ || !EnsureDeviceResources()) {
    return;
  }
  RECT rc;
  GetClientRect(hwnd_, &rc);
  const int width = rc.right - rc.left;
  const int height = rc.bottom - rc.top;
  if (width <= 0 || height <= 0) {
    return;
  }

  HDC screen_dc = GetDC(nullptr);
  HDC mem_dc = CreateCompatibleDC(screen_dc);
  BITMAPINFO bmi = {};
  bmi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bmi.bmiHeader.biWidth = width;
  bmi.bmiHeader.biHeight = -height;  // top-down
  bmi.bmiHeader.biPlanes = 1;
  bmi.bmiHeader.biBitCount = 32;
  bmi.bmiHeader.biCompression = BI_RGB;
  void* bits = nullptr;
  HBITMAP dib =
      CreateDIBSection(mem_dc, &bmi, DIB_RGB_COLORS, &bits, nullptr, 0);
  HBITMAP old_bmp = static_cast<HBITMAP>(SelectObject(mem_dc, dib));

  RECT bind_rect = {0, 0, width, height};
  if (FAILED(render_target_->BindDC(mem_dc, &bind_rect))) {
    SelectObject(mem_dc, old_bmp);
    DeleteObject(dib);
    DeleteDC(mem_dc);
    ReleaseDC(nullptr, screen_dc);
    return;
  }

  const float opacity = hovered_ ? kHoverOpacity : kRestOpacity;
  const float corner = std::max(2.0f, layout_.margin_px * 1.5f);

  render_target_->BeginDraw();
  render_target_->Clear(D2D1::ColorF(0, 0, 0, 0));

  // Pill background. The alpha comes from the overlay's own background colour
  // so the escape hatch matches the caption bar the user configured; it is
  // floored to a visible value because a fully transparent escape hatch over a
  // fully transparent overlay cannot be found.
  uint32_t pill = style_.bg_color;
  if ((pill >> 24) < 0x99) {
    pill = 0x99000000u | (pill & 0x00FFFFFFu);
  }
  Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> pill_brush;
  render_target_->CreateSolidColorBrush(ColorFromArgb(pill),
                                        pill_brush.GetAddressOf());
  if (pill_brush != nullptr) {
    pill_brush->SetOpacity(opacity);
    render_target_->FillRoundedRectangle(
        D2D1::RoundedRect(D2D1::RectF(0, 0, static_cast<float>(width),
                                      static_cast<float>(height)),
                          corner, corner),
        pill_brush.Get());
  }

  Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> btn_bg;
  Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> btn_fg;
  Microsoft::WRL::ComPtr<ID2D1SolidColorBrush> btn_active;
  render_target_->CreateSolidColorBrush(ColorFromArgb(style_.button_bg_color),
                                        btn_bg.GetAddressOf());
  render_target_->CreateSolidColorBrush(ColorFromArgb(style_.button_text_color),
                                        btn_fg.GetAddressOf());
  render_target_->CreateSolidColorBrush(ColorFromArgb(style_.active_color),
                                        btn_active.GetAddressOf());
  if (btn_bg != nullptr) btn_bg->SetOpacity(opacity);
  if (btn_fg != nullptr) btn_fg->SetOpacity(opacity);
  if (btn_active != nullptr) btn_active->SetOpacity(opacity);

  const float btn = layout_.button_px;
  Microsoft::WRL::ComPtr<IDWriteTextFormat> icon_format;
  if (icon_font_collection_ != nullptr) {
    dwrite_factory_->CreateTextFormat(
        L"Material Symbols Rounded", icon_font_collection_.Get(),
        DWRITE_FONT_WEIGHT_NORMAL, DWRITE_FONT_STYLE_NORMAL,
        DWRITE_FONT_STRETCH_NORMAL, btn * 0.68f, L"",
        icon_format.GetAddressOf());
    if (icon_format != nullptr) {
      icon_format->SetTextAlignment(DWRITE_TEXT_ALIGNMENT_CENTER);
      icon_format->SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER);
    }
  }
  for (int slot = 0; slot < hook_toolbar::kSlotCount; ++slot) {
    const float bx = layout_.margin_px + slot * (btn + layout_.gap_px);
    const float by = layout_.margin_px;
    const D2D1_RECT_F cell = D2D1::RectF(bx, by, bx + btn, by + btn);
    const bool active = hook_toolbar::SlotActive(slot, states_);
    if (active && btn_active != nullptr) {
      btn_active->SetOpacity(opacity * 0.16f);
      render_target_->FillRoundedRectangle(
          D2D1::RoundedRect(cell, corner * 0.65f, corner * 0.65f),
          btn_active.Get());
      btn_active->SetOpacity(opacity);
    } else if (slot == hovered_slot_ && btn_bg != nullptr) {
      btn_bg->SetOpacity(opacity * 0.55f);
      render_target_->FillRoundedRectangle(
          D2D1::RoundedRect(cell, corner * 0.65f, corner * 0.65f),
          btn_bg.Get());
      btn_bg->SetOpacity(opacity);
    }
    ID2D1SolidColorBrush* brush = active ? btn_active.Get() : btn_fg.Get();
    if (brush != nullptr) {
      if (icon_format != nullptr) {
        const wchar_t* glyph = hook_toolbar::SlotGlyph(slot, states_);
        render_target_->DrawTextW(glyph, 1, icon_format.Get(), cell, brush);
      } else {
        hook_toolbar::DrawSlotIcon(render_target_.Get(), d2d_factory_.Get(),
                                   slot, states_, cell, brush);
      }
    }
  }

  render_target_->EndDraw();

  POINT dst = {layout_.rect.left, layout_.rect.top};
  POINT src = {0, 0};
  SIZE size = {width, height};
  BLENDFUNCTION blend = {};
  blend.BlendOp = AC_SRC_OVER;
  blend.SourceConstantAlpha = 255;
  blend.AlphaFormat = AC_SRC_ALPHA;
  UpdateLayeredWindow(hwnd_, screen_dc, &dst, &size, mem_dc, &src, 0, &blend,
                      ULW_ALPHA);

  SelectObject(mem_dc, old_bmp);
  DeleteObject(dib);
  DeleteDC(mem_dc);
  ReleaseDC(nullptr, screen_dc);
}
