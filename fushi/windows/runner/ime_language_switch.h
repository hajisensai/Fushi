#ifndef RUNNER_IME_LANGUAGE_SWITCH_H_
#define RUNNER_IME_LANGUAGE_SWITCH_H_

#include <windows.h>

#include <string>
#include <vector>

// 查词输入框的输入法语言（Windows）。用户在设置里选了语言后，打开查词页面时把
// 输入法切过去，离开时切回来。
//
// 三条硬约束，每条都对应一种会真正坑到用户的失败：
//
// 1) 只在**已安装**的键盘布局里找（GetKeyboardLayoutList），绝不 LoadKeyboardLayout。
//    后者会往用户系统里装一个他没装的布局——那是改系统配置，不是查词功能该做的事。
//    找不到就什么都不做。
//
// 2) 切换必须 PostMessage(WM_INPUTLANGCHANGEREQUEST) 给窗口，不能直接调
//    ActivateKeyboardLayout：那个 API 作用于**调用线程**，而 Dart 代码跑在 UI
//    isolate 线程、窗口消息循环在 platform 线程，直接调会切到错的线程上。
//
// 3) 必须记住原来的布局并还原。Win8 起输入法状态是 per-user 而不是 per-thread
//    （见 MS 文档 "Switch text input changed from per-thread to per-user"），
//    我们切成日语后用户 Alt-Tab 到别的应用也会是日语。除非用户开了「允许为每个应用
//    窗口使用不同的输入法」，而那个开关不能假设。

// BCP-47 标签（ja / zh-Hans / ko / en…）是否匹配某个键盘布局的 LANGID。
//
// 主语言经 Win32 LocaleNameToLCID 解析，不自带映射表。sublang 只对中文比较——
// 简繁是两套输入法，装了拼音打不出繁体；其它语言的 sublang 只是地区变体
// （en-GB 还是 en-US 都能打英文），强行比较只会让匹配失败。
bool LanguageTagMatchesLangId(const std::wstring& tag, LANGID langid);

// 当前已安装的键盘布局。
std::vector<HKL> InstalledKeyboardLayouts();

// 在 layouts 里找第一个匹配 tag 的；没有就返回 nullptr。
HKL FindLayoutForTag(const std::wstring& tag, const std::vector<HKL>& layouts);

// 请求把 hwnd 的输入语言切到 hkl（见上面第 2 条）。
bool RequestInputLanguage(HWND hwnd, HKL hkl);

using RequestInputLanguageFn = bool (*)(HWND hwnd, HKL hkl, void* context);

enum class ImeLanguageUpdate {
  kUnchanged,   // 已经是这个状态
  kApplied,     // 真切了
  kUnavailable, // 系统里没装这个语言的输入法——什么都没做
  kFailed,      // 平台调用失败
};

// 状态机：记住进入查词前的布局，离开时还原。与 Win32 解耦，便于自测。
class ImeLanguageSwitcher {
 public:
  ImeLanguageSwitcher() = default;
  explicit ImeLanguageSwitcher(RequestInputLanguageFn fn, void* context = nullptr)
      : request_(fn), context_(context) {}

  // 切到 tag 指定的语言。`current` 是调用时的当前布局（第一次切换前会被记下来，
  // 用于还原）；`layouts` 是已安装布局清单。tag 为空等价于 Restore()。
  ImeLanguageUpdate Activate(HWND hwnd,
                             const std::wstring& tag,
                             HKL current,
                             const std::vector<HKL>& layouts);

  // 还原到进入查词前的布局。没切过就什么都不做。
  ImeLanguageUpdate Restore(HWND hwnd);

  bool active() const { return active_; }
  HKL previous_layout() const { return previous_; }

 private:
  RequestInputLanguageFn request_ = nullptr;
  void* context_ = nullptr;
  bool active_ = false;
  HKL previous_ = nullptr;
  HKL applied_ = nullptr;
};

#endif  // RUNNER_IME_LANGUAGE_SWITCH_H_
