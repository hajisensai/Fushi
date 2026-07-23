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
