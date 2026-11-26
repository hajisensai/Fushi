#ifndef RUNNER_TRAY_ICON_H_
#define RUNNER_TRAY_ICON_H_

#include <windows.h>

#include <functional>
#include <optional>
#include <string>
#include <vector>

namespace fushi {

// 主窗口被「关闭到托盘」藏起来时挂在它身上的窗口属性。第二实例启动（再点一次桌面
// 图标）靠它判断要不要把隐藏的主窗口重新显示出来——不能只看 IsWindowVisible：
// 冷启动时主窗口在首帧前也是隐藏的，那时提前显示会露出空白窗口。
inline constexpr wchar_t kTrayHiddenWindowProp[] = L"FushiHiddenToTray";

// 主窗口的系统托盘图标（通知区域图标）+ 右键菜单。
//
// 菜单内容与「关闭时最小化到托盘」开关都由 Dart 经 app.fushi/tray 推过来
// （标签要跟 app 内语言、条目要跟「功能模块」开关走），这里只负责 Win32 侧：
// Shell_NotifyIcon 的增删改、Explorer 重启（TaskbarCreated）后重新挂图标、
// 弹出原生菜单、把点击结果回调出去。
//
// 原生菜单而不是 Flutter 画的菜单：主窗口可能正藏在托盘里，Flutter 没有可画的
// 窗口；原生菜单也是用户在别的托盘程序里见到的样子（跟随系统深浅色）。
class TrayIcon {
 public:
  struct MenuItem {
    std::string id;
    std::wstring label;
    bool enabled = true;
    bool separator = false;
    // 默认项（粗体），双击 / 单击图标执行的就是它。
    bool is_default = false;
    // 点了之后要先把主窗口带回前台。必须在原生侧、在菜单命令返回的同一调用栈里
    // 做：托盘交互给了本进程前台权，等 Dart 再绕一圈回来调 SetForegroundWindow
    // 可能已被前台锁定降级成任务栏闪烁。
    bool reveal_window = false;
  };

  // [on_activate]：单击 / 键盘选中图标（不弹菜单）。
  // [on_menu_item]：选中了某个菜单项，参数是 Dart 给的 id。
  TrayIcon(HWND owner,
           std::function<void()> on_activate,
           std::function<void(const std::string&)> on_menu_item);
  ~TrayIcon();

  TrayIcon(const TrayIcon&) = delete;
  TrayIcon& operator=(const TrayIcon&) = delete;

  // 显示 / 移除托盘图标。重复调用幂等。
  void SetVisible(bool visible);
  bool visible() const { return added_; }

  void SetTooltip(const std::wstring& tooltip);
  void SetMenu(std::vector<MenuItem> items);

  // 用户换了应用图标（ApplyWindowIcon）后跟着换；nullptr = 回到 exe 内嵌图标。
  // 不接管所有权：调用方保证在下一次 SetIcon 之前不销毁它。
  void SetIcon(HICON icon);

  // 托盘气泡（Windows 10/11 上显示为系统通知）。图标不可见时什么也不做。
  void ShowNotification(const std::wstring& title, const std::wstring& body);

  // 主窗口消息过程里先调它：是托盘回调 / TaskbarCreated 就处理并返回结果。
  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam,
                                       LPARAM lparam);

  // 把主窗口从托盘里带回来：显示、必要时还原、抢前台。
  static void RevealWindow(HWND window);

 private:
  bool Add();
  void Remove();
  void Modify(UINT flags);
  void ShowMenu(int x, int y);
  void FillData(NOTIFYICONDATAW* data, UINT flags) const;
  HICON CurrentIcon() const;

  HWND owner_;
  std::function<void()> on_activate_;
  std::function<void(const std::string&)> on_menu_item_;
  std::vector<MenuItem> items_;
  std::wstring tooltip_ = L"Fushi";
  HICON default_icon_ = nullptr;
  HICON override_icon_ = nullptr;
  UINT taskbar_created_message_ = 0;
  bool want_visible_ = false;
  bool added_ = false;
  bool menu_open_ = false;
};

}  // namespace fushi

#endif  // RUNNER_TRAY_ICON_H_
