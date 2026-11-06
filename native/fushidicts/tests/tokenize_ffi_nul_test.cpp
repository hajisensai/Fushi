// HBK-AUDIT-007：批量分词的 C ABI 入口 `fushidicts_tokenize` 必须按显式字节长度处理整段，
// 不能在正文里的 U+0000 处截断。
//
// 旧入口只收 `const char*`、隐式构造 std::string：`日本語\0日本語` 只切到第一个 NUL，
// 各段总长（3）≠ 原文 UTF-16 长度（7），Dart 侧闸门于是把**整段**降级成逐码元、读音全空。
// tokenize_batch_test 覆盖的是 tokenize.hpp 内核（它本来就收带长 std::string），抓不到
// 这一层；本测试把 fushidicts_ffi.cpp 直接编进可执行文件，经真实导出符号调用，
// 断言 NUL 前后的整词与读音都正确、各段总长覆盖全输入。
//
// Usage: tokenize_ffi_nul_test <ja.json>  -> exit 0 PASS, non-zero FAIL.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

#include "fushidicts/importer.hpp"
#include "zip_fixture.hpp"

// 与 fushidicts_ffi.cpp 的导出逐字一致（本测试与它同编译进一个可执行文件）。
extern "C" {
struct FfiTokenizeResult {
  int32_t* lengths;
  char** readings;
  int32_t count;
};
void* fushidicts_create();
void fushidicts_destroy(void* handle);
void fushidicts_add_term_dict(void* handle, const char* path);
void fushidicts_load_transforms(void* handle, const char* json);
FfiTokenizeResult fushidicts_tokenize(void* handle, const char* text, int32_t text_bytes, int32_t scan_length,
                                      int32_t with_readings);
void fushidicts_free_tokenize_result(FfiTokenizeResult* r);
}

namespace {

int g_fail = 0;

void fail(const std::string& msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg.c_str());
  ++g_fail;
}

std::string read_file(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) return {};
  std::ostringstream buf;
  buf << in.rdbuf();
  return buf.str();
}

std::string row(const std::string& expr, const std::string& reading, const std::string& text) {
  return "[\"" + expr + "\",\"" + reading + "\",\"\",\"\",0,[\"" + text + "\"],0,\"\"]";
}

std::string printable(const std::string& s) {
  std::string out;
  for (char c : s) {
    if (c == '\0') {
      out += "\\0";
    } else {
      out += c;
    }
  }
  return out;
}

struct Segment {
  int32_t length;
  std::string reading;
};

// 经 C ABI 分词；返回 (长度, 读音) 序列。with_readings=false 时读音恒空。
std::vector<Segment> ffi_tokenize(void* handle, const std::string& text, bool with_readings) {
  FfiTokenizeResult r = fushidicts_tokenize(handle, text.data(), static_cast<int32_t>(text.size()), 16,
                                            with_readings ? 1 : 0);
  std::vector<Segment> out;
  for (int32_t i = 0; i < r.count; i++) {
    std::string reading;
    if (with_readings && r.readings && r.readings[i]) reading = r.readings[i];
    out.push_back({r.lengths[i], reading});
  }
  fushidicts_free_tokenize_result(&r);
  return out;
}

std::string describe(const std::vector<Segment>& segs) {
  std::string s;
  for (const Segment& seg : segs) s += std::to_string(seg.length) + "(" + seg.reading + ") ";
  return s;
}

void expect_tokens(void* handle, const std::string& text, const std::vector<Segment>& want) {
  for (bool with_readings : {true, false}) {
    const std::vector<Segment> got = ffi_tokenize(handle, text, with_readings);
    bool same = got.size() == want.size();
    for (size_t i = 0; same && i < got.size(); i++) {
      same = got[i].length == want[i].length && (!with_readings || got[i].reading == want[i].reading) &&
             (with_readings || got[i].reading.empty());
    }
    if (!same) {
      fail("tokenize(\"" + printable(text) + "\", readings=" + (with_readings ? "1" : "0") + ")\n  want " +
           describe(want) + "\n  got  " + describe(got));
    }
  }
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 2) {
    std::fprintf(stderr, "usage: %s <ja.json>\n", argv[0]);
    return 2;
  }
  const std::string ja_json = read_file(argv[1]);
  if (ja_json.empty()) {
    fail("cannot read ja.json");
    return 1;
  }
  const std::string out_dir = fushi_test::temp_dir() + "/fushi_tokenize_ffi_nul_out";
  std::filesystem::remove_all(out_dir);

  const std::string bank = "[" + row("日本語", "にほんご", "Japanese") + "," + row("難しい", "むずかしい", "difficult") +
                           "," + row("です", "です", "copula") + "]";
  const std::vector<fushi_test::ZipFile> files = {
      {"index.json", "{\"title\":\"TokenizeFfiNul\",\"format\":3,\"revision\":\"1\"}"},
      {"term_bank_1.json", bank},
  };
  const ImportResult imported =
      dictionary_importer::import(fushi_test::write_zip("tokenize_ffi_nul", files), out_dir);
  if (!imported.success) {
    fail("fixture import failed");
    return 1;
  }

  void* handle = fushidicts_create();
  if (!handle) {
    fail("fushidicts_create returned null");
    return 1;
  }
  fushidicts_load_transforms(handle, ja_json.c_str());
  fushidicts_add_term_dict(handle, (out_dir + "/" + imported.title).c_str());

  // 对照：不含 NUL 的同一段，确认词典与入口本身正常。
  expect_tokens(handle, "日本語日本語", {{3, "にほんご"}, {3, "にほんご"}});

  // 内嵌 NUL：NUL 自成一段（未命中切一个码元、无读音），前后两个整词各自带读音，
  // 总长 3 + 1 + 3 = 7 = 原文 UTF-16 长度。
  const std::string nul_mid("日本語\0日本語", sizeof("日本語\0日本語") - 1);
  expect_tokens(handle, nul_mid, {{3, "にほんご"}, {1, ""}, {3, "にほんご"}});

  // NUL 打头 / 结尾 / 连续，以及 NUL 后接多词：每一段都不能丢。
  const std::string nul_edges("\0日本語\0\0難しいです\0", sizeof("\0日本語\0\0難しいです\0") - 1);
  expect_tokens(handle, nul_edges,
                {{1, ""}, {3, "にほんご"}, {1, ""}, {1, ""}, {3, "むずかしい"}, {2, "です"}, {1, ""}});

  // 非法长度：回空结果，不越界读。
  {
    FfiTokenizeResult r = fushidicts_tokenize(handle, "日本語", -1, 16, 1);
    if (r.count != 0 || r.lengths != nullptr) fail("negative text_bytes must yield an empty result");
    fushidicts_free_tokenize_result(&r);
  }

  fushidicts_destroy(handle);
  std::filesystem::remove_all(out_dir);

  if (g_fail) {
    std::fprintf(stderr, "%d failure(s)\n", g_fail);
    return 1;
  }
  std::printf("tokenize_ffi_nul_test: PASS\n");
  return 0;
}
