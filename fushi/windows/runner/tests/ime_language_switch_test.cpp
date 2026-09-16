// release 也要真断言：NDEBUG 会把 assert 编成空语句，本文件的断言就会整批消失、
// 测试空跑照样"通过"。与 ime_association_guard_test.cpp 同一写法。
#undef NDEBUG

#include "../ime_language_switch.h"

#include <iostream>
#include <string>
#include <vector>

namespace {

struct Recorder {
  std::vector<HKL> requests;
  bool fail_next = false;
};

bool Record(HWND hwnd, HKL hkl, void* context) {
  (void)hwnd;
  auto* rec = static_cast<Recorder*>(context);
  if (rec->fail_next) {
    rec->fail_next = false;
    return false;
  }
  rec->requests.push_back(hkl);
  return true;
}

bool Expect(bool condition, const std::string& message) {
  if (condition) {
    return true;
  }
  std::cerr << "FAIL: " << message << '\n';
  return false;
}

HWND FakeHwnd() {
  return reinterpret_cast<HWND>(static_cast<UINT_PTR>(0x1234));
}

// 造一个 HKL：低 16 位是输入语言 LANGID，高位是设备句柄部分（这里随便填）。
HKL LayoutFor(LANGID langid) {
  return reinterpret_cast<HKL>(static_cast<UINT_PTR>(0x04000000u) |
                               static_cast<UINT_PTR>(langid));
}

const LANGID kJapanese = MAKELANGID(LANG_JAPANESE, SUBLANG_JAPANESE_JAPAN);
const LANGID kEnglishUs = MAKELANGID(LANG_ENGLISH, SUBLANG_ENGLISH_US);
const LANGID kEnglishUk = MAKELANGID(LANG_ENGLISH, SUBLANG_ENGLISH_UK);
const LANGID kKorean = MAKELANGID(LANG_KOREAN, SUBLANG_KOREAN);
const LANGID kChineseSimplified =
    MAKELANGID(LANG_CHINESE, SUBLANG_CHINESE_SIMPLIFIED);
const LANGID kChineseTraditional =
    MAKELANGID(LANG_CHINESE, SUBLANG_CHINESE_TRADITIONAL);

}  // namespace

int main() {
  bool passed = true;

  // 标签匹配：主语言对上就算数。
  {
    passed &= Expect(LanguageTagMatchesLangId(L"ja", kJapanese),
                     "ja matches a Japanese layout");
    passed &= Expect(!LanguageTagMatchesLangId(L"ja", kEnglishUs),
                     "ja must not match an English layout");
    passed &= Expect(LanguageTagMatchesLangId(L"ko", kKorean),
                     "ko matches a Korean layout");
  }

  // 地区变体不该挑剔：装的是 en-GB 也照样能打英文。
  {
    passed &= Expect(LanguageTagMatchesLangId(L"en", kEnglishUk),
                     "en matches en-GB layout (sublang is only a region)");
  }

  // 中文简繁是两套输入法：装了拼音打不出繁体，必须分开。
  {
    passed &= Expect(LanguageTagMatchesLangId(L"zh-Hans", kChineseSimplified),
                     "zh-Hans matches a simplified layout");
    passed &= Expect(!LanguageTagMatchesLangId(L"zh-Hans", kChineseTraditional),
                     "zh-Hans must not match a traditional layout");
    passed &= Expect(LanguageTagMatchesLangId(L"zh-Hant", kChineseTraditional),
                     "zh-Hant matches a traditional layout");
    passed &= Expect(LanguageTagMatchesLangId(L"zh", kChineseSimplified) &&
                         LanguageTagMatchesLangId(L"zh", kChineseTraditional),
                     "bare zh does not discriminate script");
  }

  // 认不出的标签一律不匹配（宁可不切，也不要切错语言）。
  {
    passed &= Expect(!LanguageTagMatchesLangId(L"", kJapanese),
                     "empty tag matches nothing");
    passed &= Expect(!LanguageTagMatchesLangId(L"nonsense", kJapanese),
                     "garbage tag matches nothing");
  }

  // 只在已安装清单里找。
  {
    const std::vector<HKL> layouts = {LayoutFor(kEnglishUs),
                                      LayoutFor(kJapanese)};
    passed &= Expect(FindLayoutForTag(L"ja", layouts) == LayoutFor(kJapanese),
                     "finds the installed Japanese layout");
    passed &= Expect(FindLayoutForTag(L"ko", layouts) == nullptr,
                     "returns null when the language is not installed");
  }

  // 没装目标语言时什么都不做——绝不替用户安装布局。
  {
    Recorder rec;
    ImeLanguageSwitcher switcher(Record, &rec);
    const std::vector<HKL> layouts = {LayoutFor(kEnglishUs)};
    passed &= Expect(switcher.Activate(FakeHwnd(), L"ja", LayoutFor(kEnglishUs),
                                       layouts) ==
                         ImeLanguageUpdate::kUnavailable,
                     "missing layout reports unavailable");
    passed &= Expect(rec.requests.empty(),
                     "missing layout makes no platform call");
    passed &= Expect(!switcher.active(), "switcher stays inactive");
  }

  // 正常切换 + 还原：还原必须回到**进入查词前**那个布局。
  {
    Recorder rec;
    ImeLanguageSwitcher switcher(Record, &rec);
    const std::vector<HKL> layouts = {LayoutFor(kEnglishUs),
                                      LayoutFor(kJapanese)};
    passed &= Expect(switcher.Activate(FakeHwnd(), L"ja", LayoutFor(kEnglishUs),
                                       layouts) == ImeLanguageUpdate::kApplied,
                     "activate switches to Japanese");
    passed &= Expect(rec.requests.size() == 1 &&
                         rec.requests[0] == LayoutFor(kJapanese),
                     "activate posts the Japanese layout");
    passed &= Expect(switcher.Restore(FakeHwnd()) == ImeLanguageUpdate::kApplied,
                     "restore switches back");
    passed &= Expect(rec.requests.size() == 2 &&
                         rec.requests[1] == LayoutFor(kEnglishUs),
                     "restore posts the layout the user had before");
    passed &= Expect(!switcher.active(), "switcher is inactive after restore");
  }

  // 查词页面之间来回跳：原布局必须一直是「进入查词前」那个，不能变成我们自己切过去
  // 的那个——否则还原会把用户永久留在日语上。
  {
    Recorder rec;
    ImeLanguageSwitcher switcher(Record, &rec);
    const std::vector<HKL> layouts = {LayoutFor(kEnglishUs),
                                      LayoutFor(kJapanese),
                                      LayoutFor(kKorean)};
    switcher.Activate(FakeHwnd(), L"ja", LayoutFor(kEnglishUs), layouts);
    // 第二次 Activate 时系统当前布局已经是日语了（我们刚切的）。
    switcher.Activate(FakeHwnd(), L"ko", LayoutFor(kJapanese), layouts);
    passed &= Expect(switcher.previous_layout() == LayoutFor(kEnglishUs),
                     "previous layout stays the pre-lookup one");
    switcher.Restore(FakeHwnd());
    passed &= Expect(rec.requests.back() == LayoutFor(kEnglishUs),
                     "restore still returns to English");
  }

  // 重复请求同一语言不该反复打扰系统。
  {
    Recorder rec;
    ImeLanguageSwitcher switcher(Record, &rec);
    const std::vector<HKL> layouts = {LayoutFor(kEnglishUs),
                                      LayoutFor(kJapanese)};
    switcher.Activate(FakeHwnd(), L"ja", LayoutFor(kEnglishUs), layouts);
    passed &= Expect(switcher.Activate(FakeHwnd(), L"ja", LayoutFor(kJapanese),
                                       layouts) ==
                         ImeLanguageUpdate::kUnchanged,
                     "repeated activate is coalesced");
    passed &= Expect(rec.requests.size() == 1,
                     "repeated activate makes no second platform call");
  }

  // 没切过就还原 = 什么都不做（别把用户当前布局改成我们记的空值）。
  {
    Recorder rec;
    ImeLanguageSwitcher switcher(Record, &rec);
    passed &= Expect(switcher.Restore(FakeHwnd()) ==
                         ImeLanguageUpdate::kUnchanged,
                     "restore without activate is a no-op");
    passed &= Expect(rec.requests.empty(), "no-op restore makes no call");
  }

  // 空标签 = 未设置 = 还原。
  {
    Recorder rec;
    ImeLanguageSwitcher switcher(Record, &rec);
    const std::vector<HKL> layouts = {LayoutFor(kEnglishUs),
                                      LayoutFor(kJapanese)};
    switcher.Activate(FakeHwnd(), L"ja", LayoutFor(kEnglishUs), layouts);
    passed &= Expect(switcher.Activate(FakeHwnd(), L"", LayoutFor(kJapanese),
                                       layouts) == ImeLanguageUpdate::kApplied,
                     "empty tag restores");
    passed &= Expect(rec.requests.back() == LayoutFor(kEnglishUs),
                     "empty tag returns to the pre-lookup layout");
  }

  // 平台调用失败时状态不能乱走，否则下一次还原会把用户切到错的布局。
  {
    Recorder rec;
    ImeLanguageSwitcher switcher(Record, &rec);
    const std::vector<HKL> layouts = {LayoutFor(kEnglishUs),
                                      LayoutFor(kJapanese)};
    rec.fail_next = true;
    passed &= Expect(switcher.Activate(FakeHwnd(), L"ja", LayoutFor(kEnglishUs),
                                       layouts) == ImeLanguageUpdate::kFailed,
                     "platform failure is reported");
    passed &= Expect(!switcher.active(), "failed activate leaves it inactive");
  }

  if (!passed) {
    std::cerr << "ime_language_switch_test FAILED\n";
    return 1;
  }
  std::cout << "ime_language_switch_test passed\n";
  return 0;
}
