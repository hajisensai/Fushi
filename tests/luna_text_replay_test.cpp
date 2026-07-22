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
