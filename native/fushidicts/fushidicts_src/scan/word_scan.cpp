#include "word_scan.hpp"

#include <utf8.h>

#include <algorithm>

namespace {

// 空格分词类字母：用空格分词的脚本的字母（拉丁/西里尔/希腊/阿拉伯/希伯来/亚美尼亚/格鲁吉亚）。
// 刻意不含 CJK 汉字/假名/谚文，也不含数字/标点/组合记号/无空格脚本(泰/老挝/高棉/缅甸)。
// 范围外一律 false → 在那些位置退回逐码点旧行为（不引入回归，可按需扩展脚本）。
bool is_space_delimited_letter(char32_t c) {
  // Latin
  if ((c >= 0x0041 && c <= 0x005A) || (c >= 0x0061 && c <= 0x007A)) return true;  // ASCII A-Z a-z
  if (c == 0x00AA || c == 0x00B5 || c == 0x00BA) return true;                      // ª µ º
  if ((c >= 0x00C0 && c <= 0x00D6) || (c >= 0x00D8 && c <= 0x00F6) ||
      (c >= 0x00F8 && c <= 0x02AF)) {
    return true;  // Latin-1 supplement letters + Latin Ext-A/B + IPA extensions
  }
  if (c >= 0x1E00 && c <= 0x1EFF) return true;  // Latin Extended Additional
  // Greek and Coptic + Greek Extended（区段内零星非字母点位由后续精确查询自然过滤，宽松无害）
  if (c >= 0x0370 && c <= 0x03FF) return true;
  if (c >= 0x1F00 && c <= 0x1FFF) return true;
  // Cyrillic + Cyrillic Supplement
  if (c >= 0x0400 && c <= 0x052F) return true;
  // Armenian（0x0531-0x0556 大写, 0x0561-0x0587 小写）
  if ((c >= 0x0531 && c <= 0x0556) || (c >= 0x0561 && c <= 0x0587)) return true;
  // Hebrew letters（0x05D0-0x05EA, 0x05EF-0x05F2）——不含点/cantillation（text_processor 已剥离）
  if ((c >= 0x05D0 && c <= 0x05EA) || (c >= 0x05EF && c <= 0x05F2)) return true;
  // Arabic letters：跳过 tatweel(0x0640)、harakat(0x064B-0x065F)、上标 alef(0x0670)、数字(0x0660-0x0669)
  if (c >= 0x0620 && c <= 0x063F) return true;  // hamza/alef 等
  if (c >= 0x0641 && c <= 0x064A) return true;  // fa … ya
  if (c == 0x066E || c == 0x066F) return true;  // dotless ba/qaf
  if (c >= 0x0671 && c <= 0x06D3) return true;  // 扩展阿拉伯字母
  if (c == 0x06D5) return true;
  if ((c >= 0x06EE && c <= 0x06EF) || (c >= 0x06FA && c <= 0x06FC) || c == 0x06FF) return true;
  if (c >= 0x0750 && c <= 0x077F) return true;  // Arabic Supplement
  if (c >= 0x08A0 && c <= 0x08BD) return true;  // Arabic Extended-A 字母段
  // Georgian（0x10A0-0x10C5 Asomtavruli, 0x10D0-0x10FA Mkhedruli）
  if ((c >= 0x10A0 && c <= 0x10C5) || (c >= 0x10D0 && c <= 0x10FA)) return true;
  return false;
}

bool is_scan_whitespace(char32_t c) {
  return c == 0x20 || (c >= 0x09 && c <= 0x0D) || c == 0xA0 || c == 0x1680 ||
         (c >= 0x2000 && c <= 0x200A) || c == 0x2028 || c == 0x2029 || c == 0x202F ||
         c == 0x205F || c == 0x3000;
}

}  // namespace

std::vector<std::string> scan_candidates(const std::string& text, std::size_t scan_length) {
  std::vector<std::string> candidates;
  std::size_t text_len = utf8::distance(text.begin(), text.end());
  std::size_t start = std::min(scan_length, text_len);
  if (start == 0) {
    return candidates;
  }

  auto cut = text.begin();
  utf8::advance(cut, start, text.end());  // cut 指向最长窗口末尾（第 start 个码点之后）

  for (std::size_t i = start; i > 0; i--) {
    // 当前前缀 = [text.begin(), cut)。prev = 前缀最后一个码点；cur = 余下第一个码点。
    auto prev_it = cut;
    char32_t prev = utf8::prior(prev_it, text.begin());
    // 切点合法：在串尾，或 prev/cur 不是「两个空格分词类字母」（不在单词中间切断）。
    bool boundary_ok = (cut == text.end()) ||
                       !(is_space_delimited_letter(prev) &&
                         is_space_delimited_letter(utf8::peek_next(cut, text.end())));
    // 以空白结尾的前缀冗余（更短的去空白前缀已覆盖），丢弃。
    if (boundary_ok && !is_scan_whitespace(prev)) {
      candidates.emplace_back(text.begin(), cut);
    }
    if (i > 1) {
      utf8::prior(cut, text.begin());
    }
  }
  return candidates;
}
