// CI 走 `--config Release`，MSVC 在该配置下定义 NDEBUG，裸 assert 会被整条编译掉，
// 于是这个测试无论断言对不对都恒绿——与 BUG-1157「零测试执行伪装成通过」同一族。
// 必须在任何 include 之前撤销它。守卫：tests/assert_liveness_guard_test.py
#undef NDEBUG

#include <cassert>
#include <cwchar>

#include "lookup_line_text_match.h"

namespace {

bool Match(const wchar_t* a, const wchar_t* b) {
  return fushi_voice_hook::LookupLineTextMatches(a, std::wcslen(a), b,
                                                 std::wcslen(b));
}

}  // namespace

int main() {
  // tenshi_sz 真机：TJS 渲染面整句 vs Luna EmbedKrkrZ 行，逐字相等。
  assert(Match(L"「体調に問題ないなら朝ご飯食べちゃったら？」",
               L"「体調に問題ないなら朝ご飯食べちゃったら？」"));
  // 只允许空白差异（全角空格 / 换行 / 尾随空白）。
  assert(Match(L"「あー……多分、４月頃かな？　一月以上は見てると思う」",
               L"「あー……多分、４月頃かな？一月以上は見てると思う」\r\n"));
  assert(Match(L"  はい ", L"はい"));
  // 多语言 KiriKiri Z 把译文紧跟日文行发出：译文绝不能命中。
  assert(!Match(L"「体調に問題ないなら朝ご飯食べちゃったら？」",
                L"「你身体要是没问题的话，要不吃个早饭？」"));
  // 前缀 / 包含都不算同句（渐进重绘的半句、带 ruby 读音替换的变体）。
  assert(!Match(L"一月以上は見てると思う", L"ひとつき以上は見てると思う"));
  assert(!Match(L"体調に問題", L"体調に問題ないなら"));
  // 空 / 全空白不是身份。
  assert(!Match(L"", L""));
  assert(!Match(L"　", L" "));
  assert(!fushi_voice_hook::LookupLineTextMatches(nullptr, 0, L"a", 1));
  return 0;
}
