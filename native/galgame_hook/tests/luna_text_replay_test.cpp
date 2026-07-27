#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "luna_text_selector.h"

std::vector<std::string> Split(const std::string& value) {
  std::vector<std::string> fields;
  std::stringstream stream(value);
  std::string field;
  while (std::getline(stream, field, '\t')) fields.push_back(field);
  return fields;
}

int main(int argc, char** argv) {
  if (argc != 2) return 1;
  const std::wstring single_line =
      L"\u300c\u6c17\u3092\u4ed8\u3051\u307e\u3059\u3063\u3002"
      L"\u3042\u308a\u304c\u3068\u3046\u3054\u3056\u3044\u307e\u3059\u3063\u300d";
  const std::wstring duplicated_line = single_line + single_line;
  const int normalized_length =
      hibiki_voice_hook::LunaNormalizedTextLengthForHook(
          "EmbedKrkrZ", duplicated_line.c_str(),
          static_cast<int>(duplicated_line.size()));
  if (normalized_length != static_cast<int>(single_line.size()) ||
      std::wstring(duplicated_line.c_str(),
                   duplicated_line.c_str() + normalized_length) != single_line) {
    return 4;
  }
  if (hibiki_voice_hook::LunaTextIsArtifact(duplicated_line.c_str(),
                                             normalized_length)) {
    return 5;
  }

  const int other_engine_length =
      hibiki_voice_hook::LunaNormalizedTextLengthForHook(
          "OtherEngine", duplicated_line.c_str(),
          static_cast<int>(duplicated_line.size()));
  if (other_engine_length != static_cast<int>(duplicated_line.size()) ||
      !hibiki_voice_hook::LunaTextIsArtifact(duplicated_line.c_str(),
                                             other_engine_length)) {
    return 6;
  }

  const std::wstring per_character_artifact = L"AABBCC";
  const int artifact_length =
      hibiki_voice_hook::LunaNormalizedTextLengthForHook(
          "EmbedKrkrZ", per_character_artifact.c_str(),
          static_cast<int>(per_character_artifact.size()));
  if (artifact_length != static_cast<int>(per_character_artifact.size())) {
    return 7;
  }
  if (!hibiki_voice_hook::LunaTextIsArtifact(
          per_character_artifact.c_str(), artifact_length)) {
    return 8;
  }

  // BUG-1144：带 ruby 的台词被 KiriKiriZ 分别以 base（汉字）和 ruby（假名）两种形式
  // 送进同一 hook 面，叠上完整行双写后收到的是 `A A B B A A`。整串既不是二倍重复
  // （前半 AAB != 后半 BAA），也不是等长游程伪影，旧实现整串放行 → 一句话出现六遍。
  std::wstring ruby_variant = single_line;
  ruby_variant[1] = L'り';  // 同长度的注音变体（模拟「李空」→「りく」）
  if (ruby_variant == single_line) return 20;
  const std::wstring ruby_double_write = single_line + single_line +
                                         ruby_variant + ruby_variant +
                                         single_line + single_line;
  const int ruby_normalized =
      hibiki_voice_hook::LunaNormalizedTextLengthForHook(
          "EmbedKrkrZ", ruby_double_write.c_str(),
          static_cast<int>(ruby_double_write.size()));
  if (ruby_normalized != static_cast<int>(single_line.size()) ||
      std::wstring(ruby_double_write.c_str(),
                   ruby_double_write.c_str() + ruby_normalized) != single_line) {
    return 21;
  }
  // 折叠只对 EmbedKrkrZ 生效，其它引擎的同形串必须原样保留。
  if (hibiki_voice_hook::LunaNormalizedTextLengthForHook(
          "OtherEngine", ruby_double_write.c_str(),
          static_cast<int>(ruby_double_write.size())) !=
      static_cast<int>(ruby_double_write.size())) {
    return 22;
  }
  // 正常台词（无重复开头）绝不能被折叠。
  if (hibiki_voice_hook::LunaNormalizedTextLengthForHook(
          "EmbedKrkrZ", single_line.c_str(),
          static_cast<int>(single_line.size())) !=
      static_cast<int>(single_line.size())) {
    return 23;
  }

  // BUG-1143：手动/记忆选定线程后，同一 hook 面（同 addr+hookcode，ctx/ctx2 不同）的
  // 其余调用路径必须继续放行，否则剧情一换调用路径整段台词就被丢弃。
  {
    hibiki_voice_hook::LunaTextSelector face_selector;
    const uint64_t selected_thread = 1001, sibling_thread = 1002;
    const uint64_t other_thread = 2001;
    const uint64_t face = 77, other_face = 88;
    const std::wstring hook = L"HB0@0:test.exe";
    if (!face_selector.ShouldWrite(hook, selected_thread, false,
                                   selected_thread, face)) {
      return 24;  // 选定线程自己当然要放行
    }
    if (!face_selector.ShouldWrite(hook, sibling_thread, false, selected_thread,
                                   face)) {
      return 25;  // 同 hook 面、不同 ctx → 必须放行（本 bug 的核心回归点）
    }
    if (face_selector.ShouldWrite(hook, other_thread, false, selected_thread,
                                  other_face)) {
      return 26;  // 不同 hook 面 → 仍须挡掉，选择才有意义
    }
    if (face_selector.ShouldWrite(hook, sibling_thread, true, selected_thread,
                                  face)) {
      return 27;  // 伪影门在选择之前，放宽粒度不得让伪影漏进来
    }
  }
  {
    // face 未知（调用方给 0）时退回精确 thread_id 匹配，与旧实现语义一致。
    hibiki_voice_hook::LunaTextSelector legacy_selector;
    if (legacy_selector.ShouldWrite(L"HB0@0:test.exe", 1002, false, 1001, 0)) {
      return 28;
    }
  }

  std::ifstream input(argv[1]);
  if (!input) return 2;
  hibiki_voice_hook::LunaTextSelector selector;
  std::string line;
  int row = 0;
  while (std::getline(input, line)) {
    if (line.empty() || line[0] == '#') continue;
    ++row;
    const auto fields = Split(line);
    if (fields.size() != 5) return 10 + row;
    const std::wstring hook(fields[0].begin(), fields[0].end());
    const std::wstring text(fields[3].begin(), fields[3].end());
    const bool actual = selector.ShouldWrite(
        hook, std::stoull(fields[1]),
        hibiki_voice_hook::LunaTextIsArtifact(text.c_str(),
                                               static_cast<int>(text.size())),
        std::stoull(fields[2]));
    if (actual != (fields[4] == "1")) return 100 + row;
  }
  return row == 8 ? 0 : 3;
}
