// Yomitan index.json 的 sourceLanguage / targetLanguage 必须原样写回导入输出目录的
// index.json。app 与 fushi_server 导入后从输出目录读来源 metadata
// （packages/fushi_dictionary parseSourceMetadataFromIndexJson），以前 Index 结构只带
// title/format/revision/isUpdatable/indexUrl/downloadUrl，语言被丢，每本本地导入的
// 词典都没有语言、词典管理没法按语言分组。
//
// 本测试钉：
//   1) 源 index.json 带两个语言 -> 输出 index.json 带同值的两个键，revision /
//      isUpdatable / indexUrl / downloadUrl 照旧保留；
//   2) 源不带语言 -> 输出里没有这两个键，且输出与改动前的固定字节串逐字节一致；
//   3) 空串 / 非字符串（数字、null）语言当缺席：导入不失败，输出不写该键。
//
// Usage: index_language_roundtrip_test (no args) -> exit 0 PASS, non-zero FAIL.
#include <filesystem>
#include <format>
#include <fstream>
#include <iostream>
#include <sstream>
#include <string>
#include <string_view>

#include "import_fixture.hpp"

namespace {

struct Failures {
  int count = 0;
  void expect(bool ok, std::string_view msg) {
    if (!ok) {
      std::cerr << std::format("FAIL: {}\n", msg);
      ++count;
    }
  }
};

constexpr const char* kTermBank = R"([["IdxLangTerm","","","",0,["gloss"],0,""]])";

// 导入只含 [index] 的词典，返回输出 index.json 的全文；失败返回 "" 并记失败。
std::string import_and_read_index(Failures& f, const std::string& label, const std::string& index) {
  const std::string out_dir = fushi_test::temp_dir() + "/fushi_idxlang_" + label;
  std::error_code ec;
  std::filesystem::remove_all(std::filesystem::path(out_dir), ec);
  std::string error;
  const std::string dir = fushi_test::import_fixture_dict(
      "idxlang_" + label, {{"index.json", index}, {"term_bank_1.json", kTermBank}}, out_dir, error);
  if (dir.empty()) {
    f.expect(false, label + ": " + error);
    return {};
  }
  std::ifstream in(std::filesystem::path(dir + "/index.json"), std::ios::binary);
  if (!in) {
    f.expect(false, label + ": output index.json missing");
    return {};
  }
  std::stringstream ss;
  ss << in.rdbuf();
  return ss.str();
}

bool contains(std::string_view s, std::string_view needle) { return s.contains(needle); }

}  // namespace

int main() {
  Failures f;

  // 1) 带语言：两键写回，其它来源字段不丢。
  {
    const std::string out = import_and_read_index(
        f, "with",
        R"({"title":"IdxLangWith","format":3,"revision":"r1","isUpdatable":true,)"
        R"("indexUrl":"https://e.x/i.json","downloadUrl":"https://e.x/d.zip",)"
        R"("sourceLanguage":"ja","targetLanguage":"zh","author":"someone"})");
    f.expect(contains(out, R"("sourceLanguage":"ja")"), "with: sourceLanguage written back (got " + out + ")");
    f.expect(contains(out, R"("targetLanguage":"zh")"), "with: targetLanguage written back (got " + out + ")");
    f.expect(contains(out, R"("revision":"r1")"), "with: revision kept");
    f.expect(contains(out, R"("isUpdatable":true)"), "with: isUpdatable kept");
    f.expect(contains(out, R"("indexUrl":"https://e.x/i.json")"), "with: indexUrl kept");
    f.expect(contains(out, R"("downloadUrl":"https://e.x/d.zip")"), "with: downloadUrl kept");
  }

  // 2) 不带语言：无语言键，输出与改动前逐字节一致。
  {
    const std::string out =
        import_and_read_index(f, "without", R"({"title":"IdxLangWithout","format":3,"revision":"r2"})");
    f.expect(!contains(out, "sourceLanguage"), "without: no sourceLanguage key (got " + out + ")");
    f.expect(!contains(out, "targetLanguage"), "without: no targetLanguage key (got " + out + ")");
    const std::string expected =
        R"({"title":"IdxLangWithout","format":3,"revision":"r2","isUpdatable":false,)"
        R"("indexUrl":"","downloadUrl":""})";
    f.expect(out == expected, "without: byte-identical to pre-change output (got " + out + ")");
  }

  // 3) 空串 / 非字符串：当缺席，导入照常成功。
  {
    const std::string out = import_and_read_index(
        f, "odd", R"({"title":"IdxLangOdd","format":3,"revision":"r3","sourceLanguage":"",)"
                  R"("targetLanguage":42})");
    f.expect(!out.empty(), "odd: import succeeded");
    f.expect(!contains(out, "sourceLanguage"), "odd: empty sourceLanguage omitted (got " + out + ")");
    f.expect(!contains(out, "targetLanguage"), "odd: numeric targetLanguage omitted (got " + out + ")");
  }
  {
    const std::string out = import_and_read_index(
        f, "nulls", R"({"title":"IdxLangNulls","format":3,"revision":"r4","sourceLanguage":null,)"
                    R"("targetLanguage":"en"})");
    f.expect(!contains(out, "sourceLanguage"), "nulls: null sourceLanguage omitted (got " + out + ")");
    f.expect(contains(out, R"("targetLanguage":"en")"), "nulls: targetLanguage written (got " + out + ")");
  }

  if (f.count != 0) {
    std::cerr << std::format("index_language_roundtrip_test: {} failure(s)\n", f.count);
    return 1;
  }
  std::cout << "index_language_roundtrip_test: PASS\n";
  return 0;
}
