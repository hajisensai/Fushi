#include "ime_language_switch.h"

#include <algorithm>

namespace {

std::wstring ToLowerAscii(std::wstring value) {
  std::transform(value.begin(), value.end(), value.begin(), [](wchar_t c) {
    return (c >= L'A' && c <= L'Z') ? static_cast<wchar_t>(c - L'A' + L'a') : c;
  });
  return value;
}

bool Contains(const std::wstring& haystack, const wchar_t* needle) {
  return haystack.find(needle) != std::wstring::npos;
}

// 中文简繁：0 = 没说，1 = 简体，2 = 繁体。
int ChineseScriptOfTag(const std::wstring& lower_tag) {
  if (Contains(lower_tag, L"hans")) return 1;
  if (Contains(lower_tag, L"hant")) return 2;
  if (Contains(lower_tag, L"-cn") || Contains(lower_tag, L"-sg")) return 1;
  if (Contains(lower_tag, L"-tw") || Contains(lower_tag, L"-hk") ||
      Contains(lower_tag, L"-mo")) {
    return 2;
  }
  return 0;
}

int ChineseScriptOfSublang(WORD sublang) {
  switch (sublang) {
    case SUBLANG_CHINESE_SIMPLIFIED:
    case SUBLANG_CHINESE_SINGAPORE:
      return 1;
    case SUBLANG_CHINESE_TRADITIONAL:
    case SUBLANG_CHINESE_HONGKONG:
    case SUBLANG_CHINESE_MACAU:
      return 2;
    default:
      return 0;
  }
}

}  // namespace

bool LanguageTagMatchesLangId(const std::wstring& tag, LANGID langid) {
  if (tag.empty()) {
    return false;
  }
  const LCID lcid = LocaleNameToLCID(tag.c_str(), LOCALE_ALLOW_NEUTRAL_NAMES);
  if (lcid == 0) {
    return false;
  }
  const LANGID wanted = LANGIDFROMLCID(lcid);
  if (PRIMARYLANGID(wanted) != PRIMARYLANGID(langid)) {
    return false;
  }
  if (PRIMARYLANGID(wanted) != LANG_CHINESE) {
    return true;
  }
  // 中文：简繁是两套输入法，装了拼音打不出繁体。标签没说简繁（裸 `zh`）时不挑。
  const int wanted_script = ChineseScriptOfTag(ToLowerAscii(tag));
  if (wanted_script == 0) {
    return true;
  }
  return wanted_script == ChineseScriptOfSublang(SUBLANGID(langid));
}

std::vector<HKL> InstalledKeyboardLayouts() {
  const int count = GetKeyboardLayoutList(0, nullptr);
  if (count <= 0) {
    return {};
  }
  std::vector<HKL> layouts(static_cast<size_t>(count));
  const int written = GetKeyboardLayoutList(count, layouts.data());
  if (written <= 0) {
    return {};
  }
  layouts.resize(static_cast<size_t>(written));
  return layouts;
}

HKL FindLayoutForTag(const std::wstring& tag, const std::vector<HKL>& layouts) {
  for (const HKL layout : layouts) {
    // HKL 的低 16 位是这个布局的输入语言 LANGID。
    const LANGID langid =
        static_cast<LANGID>(reinterpret_cast<UINT_PTR>(layout) & 0xffff);
    if (LanguageTagMatchesLangId(tag, langid)) {
      return layout;
    }
  }
  return nullptr;
}

bool RequestInputLanguage(HWND hwnd, HKL hkl) {
  if (hwnd == nullptr || hkl == nullptr) {
    return false;
  }
  // PostMessage 而不是 ActivateKeyboardLayout：见头文件第 2 条。窗口线程收到后由
  // USER32 完成切换，调用线程是谁都不影响。
  return PostMessageW(hwnd, WM_INPUTLANGCHANGEREQUEST,
                      INPUTLANGCHANGE_FORWARD,
                      reinterpret_cast<LPARAM>(hkl)) != FALSE;
}

ImeLanguageUpdate ImeLanguageSwitcher::Activate(
    HWND hwnd,
    const std::wstring& tag,
    HKL current,
    const std::vector<HKL>& layouts) {
  if (request_ == nullptr) {
    return ImeLanguageUpdate::kFailed;
  }
  if (tag.empty()) {
    return Restore(hwnd);
  }
  const HKL target = FindLayoutForTag(tag, layouts);
  if (target == nullptr) {
    // 用户选了日语但系统里没装日语输入法。静默不动是对的：我们绝不替他装。
    return ImeLanguageUpdate::kUnavailable;
  }
  if (active_ && applied_ == target) {
    return ImeLanguageUpdate::kUnchanged;
  }
  if (!active_) {
    // 第一次切换才记原布局——查词页面之间来回跳时，原布局必须一直是「进入查词前」
    // 那个，而不是上一次我们自己切过去的那个。
    previous_ = current;
  }
  if (!request_(hwnd, target, context_)) {
    return ImeLanguageUpdate::kFailed;
  }
  applied_ = target;
  active_ = true;
  return ImeLanguageUpdate::kApplied;
}

ImeLanguageUpdate ImeLanguageSwitcher::Restore(HWND hwnd) {
  if (request_ == nullptr) {
    return ImeLanguageUpdate::kFailed;
  }
  if (!active_) {
    return ImeLanguageUpdate::kUnchanged;
  }
  // 记不住原布局（进入时就取不到）时不乱猜一个切过去，只把状态清掉。
  if (previous_ == nullptr) {
    active_ = false;
    applied_ = nullptr;
    return ImeLanguageUpdate::kUnchanged;
  }
  if (!request_(hwnd, previous_, context_)) {
    return ImeLanguageUpdate::kFailed;
  }
  active_ = false;
  applied_ = nullptr;
  return ImeLanguageUpdate::kApplied;
}
