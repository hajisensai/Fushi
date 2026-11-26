#include "tray_icon.h"

#include <shellapi.h>
#include <windowsx.h>

#include <utility>

#include "resource.h"

namespace fushi {
namespace {

// 托盘回调消息号。WM_APP 段已用：0x03 / 0x31 / 0x51-0x63 / 0x70-0x71 / 0x235。
constexpr UINT kTrayCallbackMessage = WM_APP + 0x80;
constexpr UINT kTrayIconUid = 1;

// 原生弹出菜单默认永远是浅色。uxtheme 的 SetPreferredAppMode（序号 135，1903 起；
// 1809 上同一序号是 AllowDarkModeForApp(BOOL)，传 1 语义一致）设成 AllowDark 后，
// 菜单跟随系统「应用模式」深浅色——记事本、资源管理器同一做法。未公开 API，按序号
// 取不到就保持浅色菜单，不影响功能。
void AllowDarkPopupMenus() {
  static bool applied = false;
  if (applied) return;
  applied = true;
  HMODULE uxtheme =
      LoadLibraryExW(L"uxtheme.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
  if (uxtheme == nullptr) return;
  using SetPreferredAppModeFn = int(WINAPI*)(int);
  using FlushMenuThemesFn = void(WINAPI*)();
  auto set_mode = reinterpret_cast<SetPreferredAppModeFn>(
      GetProcAddress(uxtheme, MAKEINTRESOURCEA(135)));
  auto flush = reinterpret_cast<FlushMenuThemesFn>(
      GetProcAddress(uxtheme, MAKEINTRESOURCEA(136)));
  if (set_mode != nullptr) {
    constexpr int kAllowDark = 1;
    set_mode(kAllowDark);
    if (flush != nullptr) flush();
  }
}

void CopyTruncated(wchar_t* dest, size_t capacity, const std::wstring& src) {
  if (capacity == 0) return;
  const size_t n = src.size() < capacity - 1 ? src.size() : capacity - 1;
  wmemcpy(dest, src.c_str(), n);
  dest[n] = L'\0';
}

}  // namespace

TrayIcon::TrayIcon(HWND owner,
                   std::function<void()> on_activate,
                   std::function<void(const std::string&)> on_menu_item)
    : owner_(owner),
      on_activate_(std::move(on_activate)),
      on_menu_item_(std::move(on_menu_item)) {
  default_icon_ = static_cast<HICON>(
      LoadImageW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON),
                 IMAGE_ICON, GetSystemMetrics(SM_CXSMICON),
                 GetSystemMetrics(SM_CYSMICON), LR_DEFAULTCOLOR));
  taskbar_created_message_ = RegisterWindowMessageW(L"TaskbarCreated");
  AllowDarkPopupMenus();
}

TrayIcon::~TrayIcon() {
  Remove();
  if (default_icon_ != nullptr) DestroyIcon(default_icon_);
}

HICON TrayIcon::CurrentIcon() const {
  return override_icon_ != nullptr ? override_icon_ : default_icon_;
}

void TrayIcon::FillData(NOTIFYICONDATAW* data, UINT flags) const {
  ZeroMemory(data, sizeof(*data));
  data->cbSize = sizeof(*data);
  data->hWnd = owner_;
  data->uID = kTrayIconUid;
  data->uFlags = flags;
  data->uCallbackMessage = kTrayCallbackMessage;
  data->hIcon = CurrentIcon();
  CopyTruncated(data->szTip, ARRAYSIZE(data->szTip), tooltip_);
}

bool TrayIcon::Add() {
  if (added_) return true;
  NOTIFYICONDATAW data;
  FillData(&data, NIF_MESSAGE | NIF_ICON | NIF_TIP | NIF_SHOWTIP);
  if (!Shell_NotifyIconW(NIM_ADD, &data)) return false;
  // v4：回调的 lParam 低字是事件、wParam 是锚点坐标；键盘与鼠标的「选中」统一成
  // NIN_SELECT / NIN_KEYSELECT，右键 / Shift+F10 / 菜单键统一成 WM_CONTEXTMENU。
  data.uVersion = NOTIFYICON_VERSION_4;
  Shell_NotifyIconW(NIM_SETVERSION, &data);
  added_ = true;
  return true;
}

void TrayIcon::Remove() {
  if (!added_) return;
  NOTIFYICONDATAW data;
  FillData(&data, 0);
  Shell_NotifyIconW(NIM_DELETE, &data);
  added_ = false;
}

void TrayIcon::Modify(UINT flags) {
  if (!added_) return;
  NOTIFYICONDATAW data;
  FillData(&data, flags | NIF_SHOWTIP);
  Shell_NotifyIconW(NIM_MODIFY, &data);
}

void TrayIcon::SetVisible(bool visible) {
  want_visible_ = visible;
  if (visible) {
    Add();
  } else {
    Remove();
  }
}

void TrayIcon::SetTooltip(const std::wstring& tooltip) {
  tooltip_ = tooltip.empty() ? L"Fushi" : tooltip;
  Modify(NIF_TIP);
}

void TrayIcon::SetMenu(std::vector<MenuItem> items) {
  items_ = std::move(items);
}

void TrayIcon::SetIcon(HICON icon) {
  override_icon_ = icon;
  Modify(NIF_ICON);
}

void TrayIcon::ShowNotification(const std::wstring& title,
                                const std::wstring& body) {
  if (!added_) return;
  NOTIFYICONDATAW data;
  FillData(&data, NIF_INFO);
  CopyTruncated(data.szInfoTitle, ARRAYSIZE(data.szInfoTitle), title);
  CopyTruncated(data.szInfo, ARRAYSIZE(data.szInfo), body);
  data.dwInfoFlags = NIIF_NONE | NIIF_RESPECT_QUIET_TIME;
  Shell_NotifyIconW(NIM_MODIFY, &data);
}

void TrayIcon::RevealWindow(HWND window) {
  if (window == nullptr) return;
  if (!IsWindowVisible(window)) ShowWindow(window, SW_SHOW);
  if (IsIconic(window)) ShowWindow(window, SW_RESTORE);
  SetForegroundWindow(window);
}

void TrayIcon::ShowMenu(int x, int y) {
  if (menu_open_ || items_.empty()) return;
  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) return;
  // 命令号 = 下标 + 1（0 是 TrackPopupMenu 的「没选」）。
  for (size_t i = 0; i < items_.size(); ++i) {
    const MenuItem& item = items_[i];
    if (item.separator) {
      AppendMenuW(menu, MF_SEPARATOR, 0, nullptr);
      continue;
    }
    UINT flags = MF_STRING | (item.enabled ? MF_ENABLED : MF_GRAYED);
    AppendMenuW(menu, flags, static_cast<UINT_PTR>(i + 1), item.label.c_str());
    if (item.is_default) {
      SetMenuDefaultItem(menu, static_cast<UINT>(i + 1), FALSE);
    }
  }
  // 菜单要求宿主窗口是前台窗口，否则点菜单外不会收起（KB135788）。主窗口藏在托盘
  // 里时也照样成立：SetForegroundWindow 对隐藏窗口只转移前台、不显示它。
  SetForegroundWindow(owner_);
  menu_open_ = true;
  UINT align = GetSystemMetrics(SM_MENUDROPALIGNMENT) != 0 ? TPM_RIGHTALIGN
                                                           : TPM_LEFTALIGN;
  const UINT command = static_cast<UINT>(
      TrackPopupMenuEx(menu, align | TPM_BOTTOMALIGN | TPM_RIGHTBUTTON |
                                 TPM_RETURNCMD | TPM_NONOTIFY,
                       x, y, owner_, nullptr));
  menu_open_ = false;
  PostMessageW(owner_, WM_NULL, 0, 0);
  DestroyMenu(menu);
  if (command == 0 || command > items_.size()) return;
  // 拷一份：回调可能经 Dart 同步改写 items_。
  const MenuItem item = items_[command - 1];
  if (!item.enabled || item.separator) return;
  if (item.reveal_window) RevealWindow(owner_);
  if (on_menu_item_) on_menu_item_(item.id);
}

std::optional<LRESULT> TrayIcon::HandleMessage(UINT message, WPARAM wparam,
                                               LPARAM lparam) {
  if (taskbar_created_message_ != 0 && message == taskbar_created_message_) {
    // Explorer 重启后通知区域是空的，按当前期望重新挂上。不消费：其它监听者
    // （如果有）也需要这条广播。
    added_ = false;
    if (want_visible_) Add();
    return std::nullopt;
  }
  if (message != kTrayCallbackMessage) return std::nullopt;
  switch (LOWORD(lparam)) {
    case NIN_SELECT:
    case NIN_KEYSELECT:
      if (on_activate_) on_activate_();
      return 0;
    case WM_CONTEXTMENU:
      ShowMenu(GET_X_LPARAM(wparam), GET_Y_LPARAM(wparam));
      return 0;
    default:
      return 0;
  }
}

}  // namespace fushi
