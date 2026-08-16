// 上游同步批4 v2 格式守卫（.fushidicts_2 版本阶梯首次引入）：
//   A) 新导入落 v2 marker（且不再写 v1 marker）；kanji 记录带 stats 追加段，
//      query_kanji 读回 radical/strokes 之外的完整 stats（JLPT/grade/freq），
//      且已提取进专用字段的 radical/strokes 键不重复出现在 stats 里。
//   B) marker 缺失 -> 词典不加载（版本 0 拒载，导入未完成语义不变）。
//   C) bloom.filter 截断 -> 置空降级（contains 恒真穿透），词典仍可查
//      （上游 d4183d4 的 size 校验 + fork 的不拒载哲学）。
//   D) term glossary 经 zstd（可能带训练字典 dict.zstd，样本不足时退普通压缩）
//      往返一致；重开 DictionaryQuery 再验一遍（DDict 加载路径）。
//
// Usage: format_v2_upstream_sync_test   (no args) -> exit 0 PASS, non-zero FAIL.
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "fushidicts/importer.hpp"
#include "fushidicts/query.hpp"

namespace {

int g_fail = 0;

void put16(std::vector<uint8_t>& b, uint16_t v) {
  b.push_back(static_cast<uint8_t>(v & 0xff));
  b.push_back(static_cast<uint8_t>((v >> 8) & 0xff));
}
void put32(std::vector<uint8_t>& b, uint32_t v) {
  for (int i = 0; i < 4; i++) b.push_back(static_cast<uint8_t>((v >> (8 * i)) & 0xff));
}

struct ZipFile {
  std::string name;
  std::string data;
};

// Minimal multi-entry STORED zip (method 0, no compression, no zip64) — same
// hand-rolled builder as kanji_import_query_test.cpp.
std::vector<uint8_t> build_zip(const std::vector<ZipFile>& files) {
  std::vector<uint8_t> z;
  std::vector<uint32_t> lfh_offsets;

  for (const auto& f : files) {
    lfh_offsets.push_back(static_cast<uint32_t>(z.size()));
    put32(z, 0x04034b50);
    put16(z, 20);
    put16(z, 0);
    put16(z, 0);
    put16(z, 0);
    put16(z, 0);
    put32(z, 0);
    put32(z, static_cast<uint32_t>(f.data.size()));
    put32(z, static_cast<uint32_t>(f.data.size()));
    put16(z, static_cast<uint16_t>(f.name.size()));
    put16(z, 0);
    for (char c : f.name) z.push_back(static_cast<uint8_t>(c));
    for (char c : f.data) z.push_back(static_cast<uint8_t>(c));
  }

  const size_t cd_off = z.size();
  for (size_t i = 0; i < files.size(); i++) {
    const auto& f = files[i];
    put32(z, 0x02014b50);
    put16(z, 20);
    put16(z, 20);
    put16(z, 0);
    put16(z, 0);
    put16(z, 0);
    put16(z, 0);
    put32(z, 0);
    put32(z, static_cast<uint32_t>(f.data.size()));
    put32(z, static_cast<uint32_t>(f.data.size()));
    put16(z, static_cast<uint16_t>(f.name.size()));
    put16(z, 0);
    put16(z, 0);
    put16(z, 0);
    put16(z, 0);
    put32(z, 0);
    put32(z, lfh_offsets[i]);
    for (char c : f.name) z.push_back(static_cast<uint8_t>(c));
  }
  const size_t cd_size = z.size() - cd_off;

  put32(z, 0x06054b50);
  put16(z, 0);
  put16(z, 0);
  put16(z, static_cast<uint16_t>(files.size()));
  put16(z, static_cast<uint16_t>(files.size()));
  put32(z, static_cast<uint32_t>(cd_size));
  put32(z, static_cast<uint32_t>(cd_off));
  put16(z, 0);
  return z;
}

std::string tmp_dir() {
  const char* tmp = std::getenv("TEMP");
  if (!tmp) tmp = std::getenv("TMPDIR");
  return std::string(tmp ? tmp : ".");
}

std::string write_zip(const char* label, const std::vector<ZipFile>& files) {
  std::string path = tmp_dir() + "/fushi_v2fmt_" + label + ".zip";
  std::vector<uint8_t> bytes = build_zip(files);
  FILE* fp = std::fopen(path.c_str(), "wb");
  if (!fp) return {};
  std::fwrite(bytes.data(), 1, bytes.size(), fp);
  std::fclose(fp);
  return path;
}

void fail(const char* msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg);
  ++g_fail;
}

void expect_eq_str(const char* what, const std::string& got, const std::string& want) {
  if (got != want) {
    std::fprintf(stderr, "FAIL %s: got '%s' want '%s'\n", what, got.c_str(), want.c_str());
    ++g_fail;
  }
}

void expect_true(const char* what, bool cond) {
  if (!cond) {
    std::fprintf(stderr, "FAIL %s\n", what);
    ++g_fail;
  }
}

const std::string kHi = "\xE6\x97\xA5";  // 日

std::string index_json(const char* title) {
  return std::string("{\"title\":\"") + title + "\",\"format\":3,\"revision\":\"test\"}";
}

// stats 混合字符串/数字值：radical+strokes 走专用字段，其余进 stats 追加段。
std::string kanji_bank_stats() {
  return "[[\"\xE6\x97\xA5\",\"nichi jitsu\",\"hi\",\"jouyou\","
         "[\"day\",\"sun\"],"
         "{\"radical\":\"\xE6\x97\xA5\",\"strokes\":\"4\",\"jlpt\":\"4\",\"grade\":8,\"freq\":\"1\"}]]";
}

// D 用：足量条目 + 共享短语，给 ZDICT 采样一个现实的训练面（训练是否成功
// 不作硬断言——样本不足退普通压缩同样是合法路径，往返一致才是契约）。
std::string big_term_bank(int n) {
  std::string bank = "[";
  for (int i = 0; i < n; i++) {
    if (i) bank.push_back(',');
    std::string word = "word" + std::to_string(i);
    bank += "[\"" + word + "\",\"" + word + "\",\"\",\"\",0,[\"the shared common phrase describing entry number " +
            std::to_string(i) + " with plenty of overlapping vocabulary for dictionary training\"],0,\"\"]";
  }
  bank.push_back(']');
  return bank;
}

std::string lookup_glossary(const DictionaryQuery& q, const std::string& word) {
  std::vector<TermResult> terms = q.query(word);
  if (terms.empty() || terms.front().glossaries.empty()) {
    return {};
  }
  return terms.front().glossaries.front().glossary;
}

}  // namespace

int main() {
  namespace fs = std::filesystem;
  const std::string out_dir = tmp_dir() + "/fushi_v2fmt_out";
  std::error_code ec;
  fs::remove_all(out_dir, ec);

  // ----- A: v2 marker + kanji stats 追加段 -----
  std::string kanji_dict_path;
  {
    std::vector<ZipFile> files = {
        {"index.json", index_json("V2KanjiStats")},
        {"kanji_bank_1.json", kanji_bank_stats()},
    };
    std::string zip_path = write_zip("kanji", files);
    ImportResult r = dictionary_importer::import(zip_path, out_dir);
    if (!r.success) {
      std::fprintf(stderr, "FAIL A: import failed: %s\n",
                   r.errors.empty() ? "(no error)" : r.errors.front().c_str());
      ++g_fail;
    } else {
      kanji_dict_path = out_dir + "/" + r.title;
      expect_true("A.marker v2 exists", fs::is_regular_file(kanji_dict_path + "/.fushidicts_2"));
      expect_true("A.marker v1 absent", !fs::exists(kanji_dict_path + "/.fushidicts_1"));

      DictionaryQuery q;
      q.add_kanji_dict(kanji_dict_path);
      std::vector<KanjiResult> res = q.query_kanji(kHi);
      if (res.empty()) {
        fail("A: query_kanji(日) returned nothing");
      } else {
        const KanjiResult& k = res.front();
        expect_eq_str("A.radical", k.radical, kHi);
        expect_true("A.strokes", k.strokes == 4);
        // stats：radical/strokes 之外全保留（std::map 键序：freq, grade, jlpt）。
        expect_true("A.stats count == 3", k.stats.size() == 3);
        bool has_jlpt = false, has_grade = false, has_freq = false, leaked = false;
        for (const auto& [key, value] : k.stats) {
          if (key == "jlpt") has_jlpt = (value == "4");
          if (key == "grade") has_grade = (value == "8");  // 数字 token 原样保留
          if (key == "freq") has_freq = (value == "1");
          if (key == "radical" || key == "strokes") leaked = true;
        }
        expect_true("A.stats jlpt=4", has_jlpt);
        expect_true("A.stats grade=8", has_grade);
        expect_true("A.stats freq=1", has_freq);
        expect_true("A.stats no radical/strokes leak", !leaked);
      }
    }
  }

  // ----- B: marker 缺失 -> 拒载 -----
  if (!kanji_dict_path.empty()) {
    const std::string marker = kanji_dict_path + "/.fushidicts_2";
    const std::string hidden = kanji_dict_path + "/.fushidicts_2.bak";
    fs::rename(marker, hidden, ec);
    if (ec) {
      fail("B: could not rename marker");
    } else {
      DictionaryQuery q;
      q.add_kanji_dict(kanji_dict_path);
      expect_true("B.no marker -> not loaded", q.query_kanji(kHi).empty());
      fs::rename(hidden, marker, ec);
    }
  }

  // ----- C: bloom.filter 截断 -> 置空降级仍可查 -----
  if (!kanji_dict_path.empty()) {
    const std::string bloom_path = kanji_dict_path + "/bloom.filter";
    std::vector<char> original;
    {
      std::ifstream in(bloom_path, std::ios::binary);
      original.assign(std::istreambuf_iterator<char>(in), {});
    }
    if (original.size() < 24) {
      fail("C: bloom.filter unexpectedly small");
    } else {
      {
        // 保留头部（num_bits 仍是合法 pow2）但砍掉一半位数组——旧校验放行、
        // 读位图越界；新 size 校验必须置空降级。
        std::ofstream out(bloom_path, std::ios::binary | std::ios::trunc);
        out.write(original.data(), static_cast<std::streamsize>(original.size() / 2));
      }
      DictionaryQuery q;
      q.add_kanji_dict(kanji_dict_path);
      expect_true("C.truncated bloom -> query still works", !q.query_kanji(kHi).empty());
      {
        std::ofstream out(bloom_path, std::ios::binary | std::ios::trunc);
        out.write(original.data(), static_cast<std::streamsize>(original.size()));
      }
    }
  }

  // ----- D: term glossary（可能训练 dict.zstd）往返一致 -----
  {
    std::vector<ZipFile> files = {
        {"index.json", index_json("V2ZstdTerms")},
        {"term_bank_1.json", big_term_bank(64)},
    };
    std::string zip_path = write_zip("terms", files);
    ImportResult r = dictionary_importer::import(zip_path, out_dir);
    if (!r.success) {
      std::fprintf(stderr, "FAIL D: import failed: %s\n",
                   r.errors.empty() ? "(no error)" : r.errors.front().c_str());
      ++g_fail;
    } else {
      const std::string dict_path = out_dir + "/" + r.title;
      expect_true("D.marker v2 exists", fs::is_regular_file(dict_path + "/.fushidicts_2"));
      const bool trained = fs::is_regular_file(dict_path + "/dict.zstd");
      std::fprintf(stderr, "INFO D: dict.zstd %s\n", trained ? "trained" : "not trained (fallback)");

      const std::string want0 =
          "[\"the shared common phrase describing entry number 0 with plenty of overlapping vocabulary for "
          "dictionary training\"]";
      {
        DictionaryQuery q;
        q.add_term_dict(dict_path);
        expect_eq_str("D.glossary word0", lookup_glossary(q, "word0"), want0);
        expect_true("D.glossary word63 non-empty", !lookup_glossary(q, "word63").empty());
      }
      // 重开一遍：DDict 从 dict.zstd 冷加载的路径（训练成功时）与普通路径等价。
      {
        DictionaryQuery q;
        q.add_term_dict(dict_path);
        expect_eq_str("D.reopen glossary word0", lookup_glossary(q, "word0"), want0);
      }
    }
  }

  // ----- E: pitch parser 先行（上游 79c55c2 部分）——pattern 字符串位不再让
  // 整条 meta 记录解析失败，同记录里的数字位照常读出 -----
  {
    const std::string kNeko = "\xE7\x8C\xAB";              // 猫
    const std::string kNekoReading = "\xE3\x81\xAD\xE3\x81\x93";  // ねこ
    std::string meta_bank = "[[\"" + kNeko + "\",\"pitch\",{\"reading\":\"" + kNekoReading +
                            "\",\"pitches\":[{\"position\":\"heiban\"},{\"position\":2}]}]]";
    // pitch enrich 要求 reading 匹配，term bank 必须带 ねこ 这个 reading。
    std::string term_bank =
        "[[\"" + kNeko + "\",\"" + kNekoReading + "\",\"\",\"\",0,[\"cat\"],0,\"\"]]";
    std::vector<ZipFile> files = {
        {"index.json", index_json("V2PitchPattern")},
        {"term_bank_1.json", term_bank},
        {"term_meta_bank_1.json", meta_bank},
    };
    std::string zip_path = write_zip("pitch", files);
    ImportResult r = dictionary_importer::import(zip_path, out_dir);
    if (!r.success) {
      fail("E: import failed");
    } else {
      const std::string dict_path = out_dir + "/" + r.title;
      DictionaryQuery q;
      q.add_term_dict(dict_path);
      q.add_pitch_dict(dict_path);
      std::vector<TermResult> terms = q.query(kNeko);
      if (terms.empty() || terms.front().pitches.empty()) {
        fail("E: pattern position killed the whole pitch record");
      } else {
        const PitchEntry& pe = terms.front().pitches.front();
        expect_true("E.numeric position survives", pe.pitch_positions.size() == 1 &&
                                                       pe.pitch_positions.front() == 2);
      }
    }
  }

  if (g_fail) {
    std::fprintf(stderr, "%d FAIL\n", g_fail);
    return 1;
  }
  std::printf("PASS\n");
  return 0;
}
