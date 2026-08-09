#pragma once

#include <string>
#include <vector>

struct TextVariant {
  std::string text;
  int steps;
};

namespace text_processor {
std::vector<TextVariant> process(const std::string& src);
}
