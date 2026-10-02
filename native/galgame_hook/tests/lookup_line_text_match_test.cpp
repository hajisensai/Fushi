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

bool Segment(const wchar_t* page, const wchar_t* sentence, size_t char_index,
             size_t* begin, size_t* end) {
  return fushi_voice_hook::LookupPageSentenceCovering(
      page, std::wcslen(page), sentence, std::wcslen(sentence), char_index,
      begin, end);
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

  // Fate/stay night[Realta Nua]（KAG3 NVL）真机：消息层整页累积，渲染面的「行」是
  // 两句拼在一起，文本道里一句一条。点第二句里的字要落到第二句。
  const wchar_t* page = L"それは、稲妻のような切っ先だった。心臓を串刺しにせんと繰り出される槍の穂先。";
  const wchar_t* first = L"それは、稲妻のような切っ先だった。";
  const wchar_t* second = L"心臓を串刺しにせんと繰り出される槍の穂先。";
  const size_t second_at = std::wcslen(first);
  size_t b = 0;
  size_t e = 0;
  assert(Segment(page, second, second_at + 1, &b, &e));
  assert(b == second_at && e == std::wcslen(page));
  assert(Segment(page, first, 3, &b, &e));
  assert(b == 0 && e == second_at);
  // 句段必须覆盖被点的字：点第一句时第二句不算。
  assert(!Segment(page, second, 3, &b, &e));
  // 反过来点第二句时第一句也不算（句段在被点字之前就结束了）。
  assert(!Segment(page, first, second_at + 1, &b, &e));
  // KAG 在读点处 [r] 换行：一句拆成两条事件，渲染行把两行字形无空白拼起来。
  const wchar_t* comma_page =
      L"この身を貫こうとする稲妻は、この身を救おうとする月光に弾かれた。";
  const wchar_t* head = L"この身を貫こうとする稲妻は、";
  const size_t head_len = std::wcslen(head);
  assert(Segment(comma_page, head, 2, &b, &e));
  assert(b == 0 && e == head_len);
  assert(Segment(comma_page, L"この身を救おうとする月光に弾かれた。",
                 head_len + 3, &b, &e));
  assert(b == head_len && e == std::wcslen(comma_page));
  // 句间有换行 / 全角空格时照样定位，段不含边界空白。
  const wchar_t* spaced = L"「はい」\n　「いいえ」";
  assert(Segment(spaced, L"「いいえ」", 8, &b, &e));
  assert(b == 6 && e == 11);
  // 页里只是碰巧出现的短句不在句界上，不绑：「はい」嵌在「はいはい」后半。
  assert(!Segment(L"「そうだね、はいはい」", L"はい", 8, &b, &e));
  // 起点也必须在句界：句尾对得上、但前面紧贴着上一句的词，不是这一句。
  assert(!Segment(L"まあはい。", L"はい。", 2, &b, &e));
  assert(Segment(L"まあ。はい。", L"はい。", 3, &b, &e));
  assert(b == 3 && e == 6);
  // 也不能停在半个词上：短句后面紧跟的不是句界。
  assert(!Segment(L"はいからさん。", L"はい", 0, &b, &e));
  // 渐进渲染的半页不包含完整句子。
  assert(!Segment(L"体調に問題", L"体調に問題ないなら", 2, &b, &e));
  // 越界 / 全空白句不是身份。
  assert(!Segment(page, second, std::wcslen(page), &b, &e));
  assert(!Segment(page, L"　", 0, &b, &e));
  return 0;
}
