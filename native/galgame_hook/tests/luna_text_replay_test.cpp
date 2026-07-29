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

  // BUG-1175：带 ruby 的台词被 KiriKiriZ 分别以 base（汉字）和 ruby（假名）两种形式
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

  // BUG-1175 负向：合法叠句开头 + 后面跟正文，**绝不允许折叠**。
  // 旧的「开头二倍就截掉后面全部」判据会把这两句静默腰斩成「わかった」/「ありがとう」，
  // 而残句短到过不了伪影门，会被当干净行写进环。
  {
    // 「わかったわかった、もう行くよ」
    const std::wstring doubled_prefix_line =
        L"\u308f\u304b\u3063\u305f\u308f\u304b\u3063\u305f"
        L"\u3001\u3082\u3046\u884c\u304f\u3088";
    if (hibiki_voice_hook::LunaNormalizedTextLengthForHook(
            "EmbedKrkrZ", doubled_prefix_line.c_str(),
            static_cast<int>(doubled_prefix_line.size())) !=
        static_cast<int>(doubled_prefix_line.size())) {
      return 29;
    }
    // 「ありがとうありがとう、本当に助かった」
    const std::wstring thanks_line =
        L"\u3042\u308a\u304c\u3068\u3046\u3042\u308a\u304c\u3068\u3046"
        L"\u3001\u672c\u5f53\u306b\u52a9\u304b\u3063\u305f";
    if (hibiki_voice_hook::LunaNormalizedTextLengthForHook(
            "EmbedKrkrZ", thanks_line.c_str(),
            static_cast<int>(thanks_line.size())) !=
        static_cast<int>(thanks_line.size())) {
      return 30;
    }
    // 正向：真正的整串双写仍必须能折（否则 EmbedKrkrZ 原症状回来）。
    const std::wstring folded_prefix = doubled_prefix_line + doubled_prefix_line;
    if (hibiki_voice_hook::LunaNormalizedTextLengthForHook(
            "EmbedKrkrZ", folded_prefix.c_str(),
            static_cast<int>(folded_prefix.size())) !=
        static_cast<int>(doubled_prefix_line.size())) {
      return 31;
    }
  }

  // BUG-1159：手动/记忆选定线程后，同一 hook 面（同 addr+ctx2+hookcode，ctx 不同）的
  // 其余调用路径必须继续放行，否则剧情一换调用路径整段台词就被丢弃。
  //
  // 这里用**真实引擎参数**驱动生产实现 LunaTextFaceIdFrom / LunaTextThreadIdFrom，
  // 不手捏 face 常量——手捏常量只能证明比较运算符能用，证不了分面规则对。
  {
    const uint32_t pid = 4242;
    // 引擎 A：KiriKiriZ。同一 hook 面、同 split 分类，两个不同调用点（ctx）。
    const wchar_t* krkr_code = L"HB0@4A1C30:krkr.exe";
    const char* krkr_name = "EmbedKrkrZ";
    const uint64_t krkr_addr = 0x4a1c30ull;
    const uint64_t selected_thread = hibiki_voice_hook::LunaTextThreadIdFrom(
        pid, krkr_addr, 0x18ff20ull, 0, krkr_code, krkr_name);
    const uint64_t sibling_thread = hibiki_voice_hook::LunaTextThreadIdFrom(
        pid, krkr_addr, 0x18fe40ull, 0, krkr_code, krkr_name);
    const uint64_t krkr_face = hibiki_voice_hook::LunaTextFaceIdFrom(
        pid, krkr_addr, 0, krkr_code, krkr_name);
    if (selected_thread == sibling_thread) return 32;

    // 引擎 B：SiglusEngine——另一个 hook 面（不同 addr + hookcode + hookname）。
    const wchar_t* siglus_code = L"HSN4@77A0:SiglusEngine.exe";
    const char* siglus_name = "SiglusEngine";
    const uint64_t siglus_addr = 0x77a0ull;
    const uint64_t siglus_thread = hibiki_voice_hook::LunaTextThreadIdFrom(
        pid, siglus_addr, 0x18ff20ull, 0, siglus_code, siglus_name);
    const uint64_t siglus_face = hibiki_voice_hook::LunaTextFaceIdFrom(
        pid, siglus_addr, 0, siglus_code, siglus_name);
    if (krkr_face == siglus_face) return 33;

    // 同一 addr 上的 split H 码：ctx2 是引擎声明的语义分类（角色名 vs 正文），
    // 必须继续分面，否则角色名会混进正文流。
    const wchar_t* split_code = L"HBN8*0@4A1C30:krkr.exe";
    const uint64_t split_body_face = hibiki_voice_hook::LunaTextFaceIdFrom(
        pid, krkr_addr, 0x1ull, split_code, krkr_name);
    const uint64_t split_name_face = hibiki_voice_hook::LunaTextFaceIdFrom(
        pid, krkr_addr, 0x2ull, split_code, krkr_name);
    if (split_body_face == split_name_face) return 34;
    const uint64_t split_body_thread = hibiki_voice_hook::LunaTextThreadIdFrom(
        pid, krkr_addr, 0x18ff20ull, 0x1ull, split_code, krkr_name);
    const uint64_t split_name_thread = hibiki_voice_hook::LunaTextThreadIdFrom(
        pid, krkr_addr, 0x18fe40ull, 0x2ull, split_code, krkr_name);

    hibiki_voice_hook::LunaTextSelector face_selector;
    if (!face_selector.AcceptsLine(selected_thread, false, selected_thread,
                                   krkr_face)) {
      return 35;  // 选定线程自己当然要放行
    }
    if (!face_selector.AcceptsLine(sibling_thread, false, selected_thread,
                                   krkr_face)) {
      return 36;  // 同 hook 面、不同 ctx → 必须放行（本 bug 的核心回归点）
    }
    // 跨引擎负向：另一个引擎的行绝不能被并进选定线程。
    if (face_selector.AcceptsLine(siglus_thread, false, selected_thread,
                                  siglus_face)) {
      return 37;
    }
    // split H 码负向：同 addr、同 hookcode，仅 ctx2 不同（角色名）→ 必须挡掉。
    hibiki_voice_hook::LunaTextSelector split_selector;
    if (!split_selector.AcceptsLine(split_body_thread, false, split_body_thread,
                                    split_body_face)) {
      return 38;
    }
    if (split_selector.AcceptsLine(split_name_thread, false, split_body_thread,
                                   split_name_face)) {
      return 39;
    }
    if (face_selector.AcceptsLine(sibling_thread, true, selected_thread,
                                  krkr_face)) {
      return 40;  // 伪影门在选择之前，放宽粒度不得让伪影漏进来
    }
  }
  {
    // face 未知（调用方给 0）时退回精确 thread_id 匹配，与旧实现语义一致。
    hibiki_voice_hook::LunaTextSelector legacy_selector;
    if (legacy_selector.AcceptsLine(1002, false, 1001, 0)) {
      return 41;
    }
  }
  {
    // BUG-1159 跨会话恢复路径：未选择阶段的行不进文本环，只靠 NoteFace 单独登记。
    // 只要选定线程本会话出过预览行，即使它一行都没通过准入判定，兄弟线程也必须能被认回。
    hibiki_voice_hook::LunaTextSelector restore_selector;
    const uint64_t remembered = 5001, sibling = 5002, face = 909;
    restore_selector.NoteFace(remembered, face);
    if (restore_selector.FaceOf(remembered) != face) return 42;
    if (!restore_selector.AcceptsLine(sibling, false, remembered, face)) {
      return 43;
    }
    // Reset 必须一并清掉 face 表，否则换游戏后旧 face 会幽灵放行。
    restore_selector.Reset();
    if (restore_selector.FaceOf(remembered) != 0) return 44;
  }
  {
    // BUG-1193 / v12 核心：**没有显式选择就一行都不发布**，无论这行多干净、也无论
    // 之前那条 hook 表现多好。旧实现在这里会自动锁定赢家并放行，正是它把用户锁死在
    // 猜错的线程上。这条是防"自动选线程"以任何形式悄悄回归的守卫。
    hibiki_voice_hook::LunaTextSelector no_auto;
    for (int i = 0; i < 16; ++i) {
      // 反复喂同一条线程的干净行——旧实现累计到阈值就会 primed 并放行。
      if (no_auto.AcceptsLine(7001, false, 0, 4242)) return 45;
    }
    // 另一条线程同样不得被自动选中。
    if (no_auto.AcceptsLine(7002, false, 0, 4243)) return 46;
    // 用户显式选定之后才开始发布。
    if (!no_auto.AcceptsLine(7001, false, 7001, 4242)) return 47;
    // face 登记必须在"未选择"阶段就已发生，否则用户选定后第一批兄弟线程会被漏掉。
    if (no_auto.FaceOf(7002) != 4243) return 48;
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
    // v12 起 hook_code 不参与准入判定（自动赢家已退役），fixture 随之去掉该列——
    // 留一个没人读的列只会让下一个读者以为它还有意义。
    if (fields.size() != 4) return 10 + row;
    const std::wstring text(fields[2].begin(), fields[2].end());
    const bool actual = selector.AcceptsLine(
        std::stoull(fields[0]),
        hibiki_voice_hook::LunaTextIsArtifact(text.c_str(),
                                               static_cast<int>(text.size())),
        std::stoull(fields[1]));
    if (actual != (fields[3] == "1")) return 100 + row;
  }
  return row == 8 ? 0 : 3;
}
