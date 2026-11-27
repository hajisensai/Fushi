// MDict 1.2-era containers (`GeneratedByEngineVersion="1.2"`) store the inline
// first/last headword copies in key block info WITHOUT a NUL terminator (only
// v2 terminates them). The reader added the terminator for both versions, so
// every key block meta after the first edge key drifted: the key-block walk
// read garbage sizes, stopped short, and the record section header was taken
// from the middle of the key blocks -> "mdx: record block info overflow".
// Feedback qC77I6m6CK: five old .mdx dictionaries all failed with exactly that.
//
// Guard: a v1 .mdx with several entries parses (both parse() and
// parse_streaming()) to every headword with its definition, and a v2 .mdx with
// the same rows still parses identically.
//
// Red/green: add the terminator back for v1 in mdx_reader.cpp's key block info
// walk and parse() throws "record block info overflow" -> FAIL.
//
// Usage: mdx_v1_container_test  (no args) -> exit 0 PASS, non-zero FAIL.
#include <cstdio>
#include <exception>
#include <map>
#include <string>
#include <utility>
#include <vector>

#include "mdx_fixture.hpp"
#include "mdx_reader.hpp"

namespace {
int g_fail = 0;

void fail(const std::string& what) {
  std::fprintf(stderr, "FAIL %s\n", what.c_str());
  ++g_fail;
}

std::vector<std::pair<std::string, std::string>> rows() {
  return {
      {"apple", "<b>apple</b> a fruit"},
      {"banana", "<b>banana</b> a long yellow fruit"},
      {"cherry", "<b>cherry</b> small and red"},
      {"durian", "<b>durian</b> smells strong"},
      {"elderberry", "<b>elderberry</b> dark purple"},
  };
}

void check(const char* label, const std::vector<uint8_t>& file) {
  std::map<std::string, std::string> parsed;
  try {
    MdxResult r = mdx_reader::parse(file.data(), file.size());
    for (auto& e : r.entries) parsed.emplace(e.key, e.definition);
    if (r.title != "Legacy") fail(std::string(label) + ": title '" + r.title + "'");
  } catch (const std::exception& e) {
    fail(std::string(label) + ": parse threw: " + e.what());
    return;
  }
  for (const auto& [key, def] : rows()) {
    auto it = parsed.find(key);
    if (it == parsed.end()) {
      fail(std::string(label) + ": missing headword " + key);
    } else if (it->second != def) {
      fail(std::string(label) + ": " + key + " -> '" + it->second + "'");
    }
  }
  if (parsed.size() != rows().size()) {
    fail(std::string(label) + ": entry count " + std::to_string(parsed.size()));
  }

  std::map<std::string, std::string> streamed;
  try {
    mdx_reader::parse_streaming(file.data(), file.size(),
                                [&](std::string&& key, std::string&& definition) {
                                  streamed.emplace(std::move(key), std::move(definition));
                                });
  } catch (const std::exception& e) {
    fail(std::string(label) + ": parse_streaming threw: " + e.what());
    return;
  }
  if (streamed != parsed) fail(std::string(label) + ": parse_streaming disagrees with parse");
}
}  // namespace

int main() {
  check("v1.2 container", mdx_fixture::build_mdx_v1("Legacy", rows()));
  check("v2.0 container", mdx_fixture::build_mdx_plain("Legacy", rows()));
  if (g_fail == 0) std::printf("PASS mdx_v1_container_test\n");
  return g_fail == 0 ? 0 : 1;
}
