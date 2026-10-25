// 「我库里的例句」的倒排键来源：C ABI 入口 `fushidicts_corpus_terms`（tokenize.hpp 的
// tokenize_corpus）。经真实导出符号调用（本测试与 fushidicts_ffi.cpp 同编进一个可执行文件），
// 钉死四件事：
//   1. 键是**词典形**（首条结果的 term.expression）而不是原文：日语「食べた」→「食べる」
//      （真 ja.json），英语「went」→「go」（真 en.json + en_irregular.json）——两种语言走的是
//      同一条代码，没有任何按语言分支（不假设日语）；
//   2. 位置 / 长度按 UTF-16 码元，增补平面字（𠮷）占 2；
//   3. 未命中的拉丁词整串跳过，不从词中间切出伪词元（"zephyr" 里有 "e" 也不出 "e"）；
//   4. 批量线格式：多句一批、空句 / 非法 UTF-8 句各回 0 个词元，截断输入回 -1。
//
// Usage: corpus_terms_ffi_test <ja.json> <en.json> <en_irregular.json> -> exit 0 PASS.
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

extern "C" {
void* fushidicts_create();
void fushidicts_destroy(void* handle);
void fushidicts_add_term_dict(void* handle, const char* path);
void fushidicts_load_transforms(void* handle, const char* json);
int32_t fushidicts_corpus_terms(void* handle, const uint8_t* input, int32_t input_len, int32_t scan_length,
                                uint8_t** out, int32_t* out_len);
void fushidicts_free_bytes(uint8_t* p);
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

std::string row(const std::string& expr, const std::string& reading, const std::string& rules,
                const std::string& text) {
  return "[\"" + expr + "\",\"" + reading + "\",\"\",\"" + rules + "\",0,[\"" + text + "\"],0,\"\"]";
}

std::string import_dict(const char* label, const std::string& title, const std::vector<std::string>& rows,
                        const std::string& out_dir) {
  std::string bank = "[";
  for (size_t i = 0; i < rows.size(); i++) {
    if (i) bank += ",";
    bank += rows[i];
  }
  bank += "]";
  const std::vector<fushi_test::ZipFile> files = {
      {"index.json", "{\"title\":\"" + title + "\",\"format\":3,\"revision\":\"1\"}"},
      {"term_bank_1.json", bank},
  };
  const ImportResult r = dictionary_importer::import(fushi_test::write_zip(label, files), out_dir);
  if (!r.success) {
    fail(std::string("import ") + label + " failed");
    return {};
  }
  return out_dir + "/" + r.title;
}

void put_u32(std::string& out, uint32_t v) {
  for (int k = 0; k < 4; k++) out.push_back(static_cast<char>((v >> (8 * k)) & 0xFF));
}

uint32_t get_u32(const uint8_t* p, size_t& at) {
  const uint32_t v = static_cast<uint32_t>(p[at]) | (static_cast<uint32_t>(p[at + 1]) << 8) |
                     (static_cast<uint32_t>(p[at + 2]) << 16) | (static_cast<uint32_t>(p[at + 3]) << 24);
  at += 4;
  return v;
}

struct Token {
  uint32_t start;
  uint32_t length;
  std::string lemma;
};

std::string encode(const std::vector<std::string>& sentences) {
  std::string in;
  put_u32(in, static_cast<uint32_t>(sentences.size()));
  for (const std::string& s : sentences) {
    put_u32(in, static_cast<uint32_t>(s.size()));
    in += s;
  }
  return in;
}

std::vector<std::vector<Token>> corpus_terms(void* handle, const std::vector<std::string>& sentences) {
  const std::string in = encode(sentences);
  uint8_t* out = nullptr;
  int32_t out_len = 0;
  const int32_t status = fushidicts_corpus_terms(handle, reinterpret_cast<const uint8_t*>(in.data()),
                                                 static_cast<int32_t>(in.size()), 16, &out, &out_len);
  std::vector<std::vector<Token>> result;
  if (status != 0) {
    fail("corpus_terms status " + std::to_string(status));
    return result;
  }
  size_t at = 0;
  for (size_t s = 0; s < sentences.size(); s++) {
    const uint32_t count = get_u32(out, at);
    std::vector<Token> tokens;
    for (uint32_t t = 0; t < count; t++) {
      Token token;
      token.start = get_u32(out, at);
      token.length = get_u32(out, at);
      const uint32_t bytes = get_u32(out, at);
      token.lemma.assign(reinterpret_cast<const char*>(out + at), bytes);
      at += bytes;
      tokens.push_back(token);
    }
    result.push_back(tokens);
  }
  if (at != static_cast<size_t>(out_len)) fail("trailing bytes in corpus_terms output");
  fushidicts_free_bytes(out);
  return result;
}

std::string describe(const std::vector<Token>& tokens) {
  std::string s;
  for (const Token& t : tokens) s += "[" + std::to_string(t.start) + "+" + std::to_string(t.length) + " " + t.lemma + "] ";
  return s;
}

void expect(const std::string& label, const std::vector<Token>& got, const std::vector<Token>& want) {
  bool same = got.size() == want.size();
  for (size_t i = 0; same && i < got.size(); i++) {
    same = got[i].start == want[i].start && got[i].length == want[i].length && got[i].lemma == want[i].lemma;
  }
  if (!same) fail(label + "\n  want " + describe(want) + "\n  got  " + describe(got));
}

}  // namespace

int main(int argc, char** argv) {
  if (argc < 4) {
    std::fprintf(stderr, "usage: %s <ja.json> <en.json> <en_irregular.json>\n", argv[0]);
    return 2;
  }
  const std::string ja_json = read_file(argv[1]);
  const std::string en_json = read_file(argv[2]);
  const std::string en_irregular_json = read_file(argv[3]);
  if (ja_json.empty() || en_json.empty() || en_irregular_json.empty()) {
    fail("cannot read transforms");
    return 1;
  }
  const std::string out_dir = fushi_test::temp_dir() + "/fushi_corpus_terms_out";
  std::filesystem::remove_all(out_dir);

  const std::string ja_dict = import_dict("corpus_ja", "CorpusJa",
                                          {
                                              row("食べる", "たべる", "v1", "eat"),
                                              row("日本語", "にほんご", "", "Japanese"),
                                              row("は", "", "", "topic"),
                                              row("を", "", "", "object"),
                                              row("𠮷野家", "よしのや", "", "Yoshinoya"),
                                          },
                                          out_dir);
  const std::string en_dict = import_dict("corpus_en", "CorpusEn",
                                          {
                                              row("go", "", "v", "move"),
                                              row("dog", "", "n", "animal"),
                                              row("the", "", "", "article"),
                                          },
                                          out_dir);
  if (g_fail) return 1;

  void* handle = fushidicts_create();
  fushidicts_add_term_dict(handle, ja_dict.c_str());
  fushidicts_add_term_dict(handle, en_dict.c_str());
  fushidicts_load_transforms(handle, ja_json.c_str());
  fushidicts_load_transforms(handle, en_irregular_json.c_str());
  fushidicts_load_transforms(handle, en_json.c_str());

  const std::vector<std::vector<Token>> got = corpus_terms(
      handle, {
                  "日本語を食べた",           // 0：词形还原 食べた → 食べる
                  "The dog went, zephyr dog.",  // 1：went → go；zephyr 未收录整词跳过
                  "",                          // 2：空句
                  "𠮷野家は",                  // 3：增补平面字占 2 个 UTF-16 码元
                  std::string("\xFF\xFE", 2),  // 4：非法 UTF-8
              });
  if (got.size() == 5) {
    expect("ja deinflection", got[0], {{0, 3, "日本語"}, {3, 1, "を"}, {4, 3, "食べる"}});
    expect("en irregular + latin word skip", got[1],
           {{0, 3, "the"}, {4, 3, "dog"}, {8, 4, "go"}, {21, 3, "dog"}});
    expect("empty sentence", got[2], {});
    expect("supplementary plane offsets", got[3], {{0, 4, "𠮷野家"}, {4, 1, "は"}});
    expect("invalid utf-8 sentence", got[4], {});
  } else {
    fail("expected 5 sentence results, got " + std::to_string(got.size()));
  }

  // 截断输入：声明 2 句只给 1 句。
  std::string truncated = encode({"日本語"});
  truncated[0] = 2;
  uint8_t* out = nullptr;
  int32_t out_len = 0;
  const int32_t status = fushidicts_corpus_terms(handle, reinterpret_cast<const uint8_t*>(truncated.data()),
                                                 static_cast<int32_t>(truncated.size()), 16, &out, &out_len);
  if (status != -1 || out != nullptr) fail("truncated input must return -1, got " + std::to_string(status));

  fushidicts_destroy(handle);
  std::filesystem::remove_all(out_dir);
  if (g_fail) {
    std::fprintf(stderr, "corpus_terms_ffi_test: %d failure(s)\n", g_fail);
    return 1;
  }
  std::printf("corpus_terms_ffi_test: PASS\n");
  return 0;
}
