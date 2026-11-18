// key.index / type 3 meta 记录 / 存量词典原地升级（hash/dict_index.hpp、json/meta_record.hpp、
// fushidicts/upgrade.hpp）的守卫：
//
//   1. 升级等价——同一批 fixture 词典（term：单记录键、多记录键、reading ≠ expression；
//      freq：各种 JSON 形态、数字串、解析不了的条目、未知 mode；pitch：数字 / pattern、
//      nasal / devoice、重复、reading 不符；ipa；kanji；simple dict）分别以
//        L  旧式导入（FUSHIDICTS_LEGACY_INDEX=1：hash.table + bloom.filter、type 1）
//        U  旧式导入后升级（允许 meta 重写）
//        Ui 旧式导入后升级（只换索引）
//        N  新式导入（key.index、type 3）
//      装进引擎，lookup() / query() / query_kanji() 逐字段相同，有 / 无联合过滤器都相同，
//      混装（各本词典状态不同）也相同；并核对各状态目录里的文件与记录类型。
//   2. 核对的必要性——人为造 key.index：键 A 的哈希指向键 B 的记录 → 查 A 查不到；主桶
//      全是 tag 相同的假候选、真键住在备桶 → 查得到（无假阴性）。旧式 hash.table 同样。
//   3. 升级的健壮性——幂等；遗留临时文件 / 孤儿 blobs3.bin 不影响下一次且被清掉；key.index
//      损坏而旧文件还在时回退到旧式仍可查、升级把它换掉；引擎正装着旧式词典时升级成功、
//      引擎结果不变、新引擎用上 key.index；旧文件在引擎释放后被清掉（Windows：下一次
//      调用；POSIX：立刻）；不是词典的目录返回失败。
//
// Usage: dict_upgrade_test <ja.json>  -> exit 0 PASS, non-zero FAIL.
#include <xxh3.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <functional>
#include <optional>
#include <sstream>
#include <string>
#include <thread>
#include <vector>

#include "fushidicts/deinflector.hpp"
#include "fushidicts/importer.hpp"
#include "fushidicts/lookup.hpp"
#include "fushidicts/query.hpp"
#include "fushidicts/upgrade.hpp"
#include "hash/dict_index.hpp"
#include "hash/hash.hpp"
#include "hash/key_index.hpp"
#include "legacy_index_env.hpp"
#include "memory/memory.hpp"
#include "import_fixture.hpp"
#include "zip_fixture.hpp"

namespace fs = std::filesystem;

// 真实导出符号（fushidicts_ffi.cpp 编进本测试）。
extern "C" int32_t fushidicts_upgrade_dictionary(const char* dict_dir, int32_t allow_meta_rewrite);
using fushidicts::UpgradeResult;

namespace {

int g_fail = 0;

void fail(const std::string& msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg.c_str());
  ++g_fail;
}

void expect(bool ok, const std::string& what) {
  if (!ok) fail(what);
}

std::string read_file(const std::string& path) {
  std::ifstream in(path, std::ios::binary);
  if (!in) return {};
  std::ostringstream buf;
  buf << in.rdbuf();
  return buf.str();
}

void write_text(const std::string& path, const std::string& text) {
  std::ofstream out(path, std::ios::binary | std::ios::trunc);
  out << text;
}

bool exists(const std::string& path) {
  std::error_code ec;
  return fs::exists(path, ec);
}

const char* result_name(UpgradeResult r) {
  switch (r) {
    case UpgradeResult::Failed:
      return "Failed";
    case UpgradeResult::UpToDate:
      return "UpToDate";
    case UpgradeResult::Upgraded:
      return "Upgraded";
    case UpgradeResult::NotApplicable:
      return "NotApplicable";
  }
  return "?";
}

void expect_result(UpgradeResult got, UpgradeResult want, const std::string& what) {
  if (got != want) {
    fail(what + ": upgrade returned " + result_name(got) + ", want " + result_name(want));
  }
}

// ── fixture ──────────────────────────────────────────────────────────────────

std::string term_row(const std::string& expr, const std::string& reading, const std::string& rules, int score,
                     const std::string& glossary) {
  return "[\"" + expr + "\",\"" + reading + "\",\"n\",\"" + rules + "\"," + std::to_string(score) + ",[\"" +
         glossary + "\"],0,\"common\"]";
}

std::string join_rows(const std::vector<std::string>& rows) {
  std::string out = "[";
  for (size_t i = 0; i < rows.size(); i++) {
    if (i) out += ",";
    out += rows[i];
  }
  return out + "]";
}

std::vector<fushi_test::ZipFile> with_index(const std::string& title, std::vector<fushi_test::ZipFile> files) {
  files.insert(files.begin(), {"index.json", "{\"title\":\"" + title + "\",\"format\":3,\"revision\":\"1\"}"});
  return files;
}

const std::vector<fushi_test::ZipFile>& term_files() {
  // 猫 / ねこ：多记录键（两条 猫ねこ + 一条只有假名的 ねこ），reading ≠ expression；
  // 上げる 单记录、あげる 多记录（上げる / 挙げる 共用读音）；犬 / 走る 单记录。
  static const std::vector<fushi_test::ZipFile> files = with_index(
      "UpTerm", {{"term_bank_1.json", join_rows({
                                          term_row("猫", "ねこ", "n", 10, "cat"),
                                          term_row("猫", "ねこ", "n", 3, "feline"),
                                          term_row("ねこ", "", "n", 1, "kana neko"),
                                          term_row("食べる", "たべる", "v1", 5, "to eat"),
                                          term_row("走る", "はしる", "v5", 2, "to run"),
                                          term_row("上げる", "あげる", "v1", 4, "to raise"),
                                          term_row("挙げる", "あげる", "v1", 1, "to cite"),
                                          term_row("犬", "いぬ", "n", 7, "dog"),
                                          term_row("日", "ひ", "n", 0, "sun"),
                                      })}});
  return files;
}

const std::vector<fushi_test::ZipFile>& freq_files() {
  static const std::vector<fushi_test::ZipFile> files = with_index(
      "UpFreq",
      {{"term_meta_bank_1.json",
        "[[\"猫\",\"freq\",120],"
        "[\"猫\",\"freq\",{\"reading\":\"ねこ\",\"value\":7}],"
        "[\"猫\",\"other\",{\"x\":1}],"
        "[\"食べる\",\"freq\",{\"reading\":\"たべる\",\"frequency\":45}],"
        "[\"食べる\",\"freq\",{\"reading\":\"くべる\",\"frequency\":9}],"
        "[\"犬\",\"freq\",{\"value\":300,\"displayValue\":\"300\\u3295\"}],"
        "[\"走る\",\"freq\",\"77\"],"
        "[\"上げる\",\"freq\",{\"frequency\":{\"value\":5,\"displayValue\":\"5/10\"}}],"
        "[\"挙げる\",\"freq\",\"oops\"],"
        "[\"ねこ\",\"freq\",{\"reading\":\"ねこ\",\"frequency\":{\"value\":11}}]]"}});
  return files;
}

const std::vector<fushi_test::ZipFile>& pitch_files() {
  static const std::vector<fushi_test::ZipFile> files = with_index(
      "UpPitch",
      {{"term_meta_bank_1.json",
        "[[\"猫\",\"pitch\",{\"reading\":\"ねこ\",\"pitches\":[{\"position\":1},"
        "{\"position\":\"heiban\",\"nasal\":2,\"devoice\":[1,3]}]}],"
        "[\"猫\",\"pitch\",{\"reading\":\"ねこ\",\"pitches\":[{\"position\":1}]}],"
        "[\"食べる\",\"pitch\",{\"reading\":\"たべる\",\"pitches\":[{\"position\":2,\"nasal\":[1]}]}],"
        "[\"犬\",\"pitch\",{\"reading\":\"けん\",\"pitches\":[{\"position\":0}]}],"
        "[\"走る\",\"pitch\",{\"broken\":true}],"
        "[\"上げる\",\"pitch\",{\"reading\":\"あげる\",\"pitches\":[{\"position\":0}]}]]"}});
  return files;
}

const std::vector<fushi_test::ZipFile>& ipa_files() {
  static const std::vector<fushi_test::ZipFile> files = with_index(
      "UpIpa", {{"term_meta_bank_1.json",
                 "[[\"猫\",\"ipa\",{\"reading\":\"ねこ\",\"transcriptions\":[{\"ipa\":\"neko\",\"tags\":[]},"
                 "{\"ipa\":\"ne\\u031eko\\u031e\"},{\"ipa\":\"neko\"}]}],"
                 "[\"犬\",\"ipa\",{\"reading\":\"いぬ\",\"transcriptions\":[{\"ipa\":\"inu\"}]}]]"}});
  return files;
}

const std::vector<fushi_test::ZipFile>& kanji_files() {
  static const std::vector<fushi_test::ZipFile> files = with_index(
      "UpKanji", {{"kanji_bank_1.json",
                   "[[\"日\",\"ニチ ジツ\",\"ひ か\",\"\",[\"day\",\"sun\"],{\"freq\":\"1\",\"grade\":\"1\"}],"
                   "[\"猫\",\"ビョウ\",\"ねこ\",\"\",[\"cat\"],{\"strokes\":\"11\"}]]"}});
  return files;
}

const std::vector<SimpleEntry>& simple_entries() {
  static const std::vector<SimpleEntry> entries = {
      {"猫", "<b>simple cat</b>"},
      {"犬", "simple dog"},
      {"猫", "simple cat, second entry"},
      {"走る", "simple run"},
  };
  return entries;
}

struct DictSet {
  std::string term, freq, pitch, ipa, kanji, simple;
  bool ok() const {
    return !term.empty() && !freq.empty() && !pitch.empty() && !ipa.empty() && !kanji.empty() && !simple.empty();
  }
  std::vector<std::string> all() const { return {term, freq, pitch, ipa, kanji, simple}; }
};

std::string import_one(const char* label, const std::vector<fushi_test::ZipFile>& files, const std::string& root) {
  std::string error;
  const std::string dir = fushi_test::import_fixture_dict(label, files, root, error);
  if (dir.empty()) fail(std::string("import ") + label + ": " + error);
  return dir;
}

DictSet import_set(const std::string& root, bool legacy) {
  std::optional<fushi_test::ScopedLegacyIndex> scope;
  if (legacy) scope.emplace();
  fs::remove_all(root);
  fs::create_directories(root);
  DictSet set;
  const std::string tag = legacy ? "legacy" : "new";
  set.term = import_one(("up_term_" + tag).c_str(), term_files(), root);
  set.freq = import_one(("up_freq_" + tag).c_str(), freq_files(), root);
  set.pitch = import_one(("up_pitch_" + tag).c_str(), pitch_files(), root);
  set.ipa = import_one(("up_ipa_" + tag).c_str(), ipa_files(), root);
  set.kanji = import_one(("up_kanji_" + tag).c_str(), kanji_files(), root);
  const ImportResult r = dictionary_importer::write_simple_dict("UpSimple", simple_entries(), root);
  if (!r.success) {
    fail("write_simple_dict failed");
  } else {
    set.simple = root + "/" + r.title;
  }
  return set;
}

void load(DictionaryQuery& q, const DictSet& s) {
  q.add_term_dict(s.term);
  q.add_term_dict(s.simple);
  q.add_freq_dict(s.freq);
  q.add_pitch_dict(s.pitch);
  q.add_pitch_dict(s.ipa);
  q.add_kanji_dict(s.kanji);
}

// ── 逐字段的结果文本 ──────────────────────────────────────────────────────────

std::string ints(const std::vector<int>& v) {
  std::string s;
  for (int x : v) s += std::to_string(x) + ",";
  return s;
}

std::string dump_term(const TermResult& t) {
  std::string s = "[" + t.expression + "|" + t.reading + "|" + t.rules + "|" + std::to_string(t.score);
  for (const GlossaryEntry& g : t.glossaries) {
    s += "{" + g.dict_name + ":" + g.glossary + ":" + g.definition_tags + ":" + g.term_tags + "}";
  }
  for (const FrequencyEntry& f : t.frequencies) {
    s += "<" + f.dict_name;
    for (const Frequency& v : f.frequencies) s += ":" + std::to_string(v.value) + "," + v.display_value;
    s += ">";
  }
  for (const PitchEntry& p : t.pitches) {
    s += "(" + p.dict_name;
    for (const Pitch& v : p.pitches) {
      s += ":" + std::to_string(v.position) + "," + v.pattern + ",n" + ints(v.nasal) + "d" + ints(v.devoice);
    }
    for (const std::string& tr : p.transcriptions) s += ":/" + tr + "/";
    s += ")";
  }
  return s + "]";
}

std::string dump_lookup(const std::vector<LookupResult>& results) {
  std::string s;
  for (const LookupResult& r : results) {
    s += r.matched + "|" + r.deinflected + "|" + std::to_string(r.preprocessor_steps);
    for (const TransformGroup& g : r.trace) s += "/" + g.name;
    s += dump_term(r.term) + "\n";
  }
  return s;
}

std::string dump_terms(const std::vector<TermResult>& terms) {
  std::string s;
  for (const TermResult& t : terms) s += dump_term(t) + "\n";
  return s;
}

std::string dump_kanji(const std::vector<KanjiResult>& kanji) {
  std::string s;
  for (const KanjiResult& k : kanji) {
    s += k.character + "|" + k.onyomi + "|" + k.kunyomi + "|" + k.radical + "|" + std::to_string(k.strokes) + "|" +
         k.dict_name;
    for (const std::string& m : k.meanings) s += ":" + m;
    for (const auto& [key, value] : k.stats) s += ";" + key + "=" + value;
    s += "\n";
  }
  return s;
}

const std::vector<std::string>& queries() {
  static const std::vector<std::string> q = {
      "猫", "ねこ", "猫が食べた", "食べられなかった", "走った犬", "上げる", "あげる", "挙げる", "犬", "いぬ",
      "日", "たべる", "存在しない", "zzz", "",
  };
  return q;
}

// 一个引擎状态下全部查询的完整结果。
std::string snapshot(DictionaryQuery& q, Deinflector& deinflector) {
  Lookup lookup(q, deinflector);
  std::string s;
  for (const std::string& text : queries()) {
    s += "#lookup " + text + "\n" + dump_lookup(lookup.lookup(text, 16, 16));
    LookupOptions no_mat;
    no_mat.materialize = false;
    s += "#lookup-nomat " + text + "\n" + dump_lookup(lookup.lookup(text, 1, 16, no_mat));
    s += "#query " + text + "\n" + dump_terms(q.query(text));
    s += "#kanji " + text + "\n" + dump_kanji(q.query_kanji(text));
  }
  return s;
}

std::string snapshot_of(const DictSet& set, Deinflector& deinflector, bool with_filter) {
  DictionaryQuery q;
  load(q, set);
  if (with_filter) {
    q.prepare_union_filter("", /*wait=*/true);
    expect(q.union_filter_state() == UnionFilterState::Ready, "union filter ready");
  }
  return snapshot(q, deinflector);
}

void expect_same(const std::string& want, const std::string& got, const std::string& what) {
  if (want == got) return;
  // 第一处不同的行，便于定位。
  std::istringstream a(want), b(got);
  std::string la, lb;
  int line = 0;
  while (true) {
    const bool ea = !std::getline(a, la);
    const bool eb = !std::getline(b, lb);
    line++;
    if (ea && eb) break;
    if (ea || eb || la != lb) {
      fail(what + ": differs at line " + std::to_string(line) + "\n  want: " + la + "\n  got : " + lb);
      return;
    }
  }
  fail(what + ": differs");
}

// 目录里各记录的类型字节计数（经索引枚举）。
std::vector<size_t> record_types(const std::string& dir) {
  std::vector<size_t> counts(256, 0);
  hash::dict_index index;
  if (!index.open(dir)) return counts;
  std::vector<uint64_t> seen;
  index.for_each_location([&](hash::location loc) -> bool {
    hash::for_each_record_offset(index.blobs(), loc, [&](uint64_t record) -> bool {
      if (std::find(seen.begin(), seen.end(), record) != seen.end()) return true;
      seen.push_back(record);
      const memory::blob_span b = index.blobs().view(record, 1);
      if (b) counts[b.data[0]]++;
      return true;
    });
    return true;
  });
  return counts;
}

bool uses_key_index(const std::string& dir) {
  hash::dict_index index;
  return index.open(dir) && index.uses_key_index();
}

// ── 1. 升级等价 ───────────────────────────────────────────────────────────────

void test_equivalence(const std::string& root, Deinflector& deinflector) {
  const DictSet legacy = import_set(root + "/L", true);
  const DictSet upgraded = import_set(root + "/U", true);
  const DictSet index_only = import_set(root + "/Ui", true);
  const DictSet fresh = import_set(root + "/N", false);
  if (!legacy.ok() || !upgraded.ok() || !index_only.ok() || !fresh.ok()) return;

  for (const std::string& dir : upgraded.all()) {
    expect_result(fushidicts::upgrade_dictionary(dir, true), UpgradeResult::Upgraded, "upgrade " + dir);
  }
  for (const std::string& dir : index_only.all()) {
    expect_result(fushidicts::upgrade_dictionary(dir, false), UpgradeResult::Upgraded, "index-only upgrade " + dir);
  }

  // 文件形态。
  for (const std::string& dir : legacy.all()) {
    expect(exists(dir + "/hash.table") && exists(dir + "/bloom.filter") && !exists(dir + "/key.index"),
           "legacy import has hash.table + bloom.filter and no key.index: " + dir);
    expect(!uses_key_index(dir), "legacy dict opens with the legacy index: " + dir);
  }
  for (const DictSet* set : {&upgraded, &index_only, &fresh}) {
    for (const std::string& dir : set->all()) {
      expect(exists(dir + "/key.index"), "key.index present: " + dir);
      expect(!exists(dir + "/hash.table") && !exists(dir + "/bloom.filter"),
             "no hash.table / bloom.filter left behind (nothing maps them): " + dir);
      expect(uses_key_index(dir), "opens with key.index: " + dir);
    }
  }
  // meta 重写只发生在纯 type 1 的 freq / pitch / ipa 词典上。
  for (const std::string& dir : {upgraded.freq, upgraded.pitch, upgraded.ipa}) {
    expect(exists(dir + "/blobs3.bin") && !exists(dir + "/blobs.bin"), "meta dict rewritten into blobs3.bin: " + dir);
  }
  for (const std::string& dir : {upgraded.term, upgraded.kanji, upgraded.simple}) {
    expect(exists(dir + "/blobs.bin") && !exists(dir + "/blobs3.bin"), "non-meta dict keeps blobs.bin: " + dir);
  }
  for (const std::string& dir : index_only.all()) {
    expect(exists(dir + "/blobs.bin") && !exists(dir + "/blobs3.bin"), "index-only upgrade keeps blobs.bin: " + dir);
  }

  // 记录类型：旧式只有 type 1；新式 / 重写后预解析成 type 3，解析不了的（"oops"、
  // 缺键的 pitch、未知 mode）留在 type 1。
  {
    const auto l = record_types(legacy.freq);
    const auto n = record_types(fresh.freq);
    const auto u = record_types(upgraded.freq);
    const auto ui = record_types(index_only.freq);
    expect(l[1] == 10 && l[3] == 0, "legacy freq: 10 type-1 records, got " + std::to_string(l[1]) + "/" +
                                        std::to_string(l[3]));
    // 不可预解析：猫 other、挙げる "oops"（数字串 "77" 经上游 fcea33f 可解析）。
    expect(n[3] == 8 && n[1] == 2, "new freq: 8 type-3 + 2 type-1, got " + std::to_string(n[3]) + "/" +
                                       std::to_string(n[1]));
    expect(u == n, "upgraded freq has the same record types as a fresh import");
    expect(ui == l, "index-only upgrade leaves the records alone");
    const auto np = record_types(fresh.pitch);
    expect(np[3] == 5 && np[1] == 1, "new pitch: 5 type-3 + 1 type-1 (broken entry)");
    expect(record_types(upgraded.pitch) == np, "upgraded pitch matches a fresh import");
    expect(record_types(fresh.ipa)[3] == 2, "new ipa: both records type 3");
    expect(record_types(fresh.term)[0] == 9, "term records untouched (type 0)");
  }

  // 结果逐字段相同。
  const std::string want = snapshot_of(legacy, deinflector, false);
  expect(want.find("{UpTerm:[\"feline\"]") != std::string::npos, "fixture sanity: multi-record key resolved");
  expect(want.find("<UpFreq:77,77>") != std::string::npos, "fixture sanity: numeric-string frequency (fcea33f)");
  expect(want.find("<UpFreq:120,120:7,7>") != std::string::npos, "fixture sanity: several freq records, one dict");
  expect(want.find(":0,heiban,n2,d1,3,") != std::string::npos, "fixture sanity: pitch pattern + nasal + devoice");
  expect(want.find(":/neko/:/ne") != std::string::npos, "fixture sanity: ipa transcriptions (deduped)");
  expect(want.find("{UpSimple:<b>simple cat</b>") != std::string::npos, "fixture sanity: simple dict");
  expect(want.find("日|ニチ ジツ|ひ か") != std::string::npos, "fixture sanity: kanji");
  for (const bool filter : {false, true}) {
    const std::string tag = filter ? " (union filter)" : "";
    if (filter) expect_same(want, snapshot_of(legacy, deinflector, true), "legacy" + tag);
    expect_same(want, snapshot_of(upgraded, deinflector, filter), "legacy+upgrade vs legacy" + tag);
    expect_same(want, snapshot_of(index_only, deinflector, filter), "legacy+index-only upgrade vs legacy" + tag);
    expect_same(want, snapshot_of(fresh, deinflector, filter), "new import vs legacy" + tag);
    // 混装：每本词典来自不同状态。
    const DictSet mixed{.term = fresh.term,
                        .freq = legacy.freq,
                        .pitch = upgraded.pitch,
                        .ipa = index_only.ipa,
                        .kanji = legacy.kanji,
                        .simple = upgraded.simple};
    expect_same(want, snapshot_of(mixed, deinflector, filter), "mixed states vs legacy" + tag);
  }

  // 整本扫描在两种索引上结论相同。
  for (const DictSet* set : {&upgraded, &fresh}) {
    expect(probe_dict_content(set->term) == probe_dict_content(legacy.term), "probe_dict_content(term) agrees");
    expect(probe_dict_content(set->kanji) == probe_dict_content(legacy.kanji), "probe_dict_content(kanji) agrees");
    expect(probe_dict_content(set->freq) == probe_dict_content(legacy.freq), "probe_dict_content(freq) agrees");
    expect(ensure_redirect_glossary_flag(set->term) == ensure_redirect_glossary_flag(legacy.term),
           "redirect flag agrees");
  }
}

// ── 2. 核对的必要性 ───────────────────────────────────────────────────────────

uint64_t key_hash(std::string_view key) { return XXH3_64bits(key.data(), key.size()); }

// 把 [dir] 拷到 [to]（只拷文件）。
void copy_dir(const std::string& dir, const std::string& to) {
  fs::remove_all(to);
  fs::create_directories(to);
  for (const auto& entry : fs::directory_iterator(dir)) {
    fs::copy_file(entry.path(), fs::path(to) / entry.path().filename());
  }
}

void test_verification(const std::string& root) {
  const DictSet fresh = import_set(root + "/verify_src", false);
  if (!fresh.ok()) return;
  const std::vector<std::string> keys = {"猫", "ねこ", "食べる", "たべる", "走る", "はしる",
                                         "上げる", "あげる", "挙げる", "犬", "いぬ", "日", "ひ"};
  std::vector<hash::key_index::entry> real;
  hash::location inu{};
  {
    hash::dict_index index;
    if (!index.open(fresh.term)) {
      fail("verify: cannot open fixture");
      return;
    }
    for (const std::string& k : keys) {
      const auto loc = index.locate(key_hash(k), k);
      if (!loc) {
        fail("verify: fixture key not found: " + k);
        return;
      }
      real.push_back({.hash = key_hash(k), .offset = loc->offset, .single = loc->single});
      if (k == "犬") inu = *loc;
    }
    // A = 狐（不在词典里）：直接核对。
    expect(!hash::location_has_key(index.blobs(), inu, "狐"), "verify: a foreign record does not carry the key");
  }

  // (a) 键 A 的哈希指向键 B 的记录。
  {
    const std::string dir = root + "/verify_alias";
    copy_dir(fresh.term, dir);
    std::vector<hash::key_index::entry> entries = real;
    entries.push_back({.hash = key_hash("狐"), .offset = inu.offset, .single = inu.single});
    fs::remove(dir + "/key.index");
    expect(hash::key_index::build_to_file(entries, hash::key_index::blobs_file::original, dir + "/key.index"),
           "verify: crafted key.index written");
    {
      hash::dict_index index;
      expect(index.open(dir) && index.uses_key_index(), "verify: crafted key.index loads");
      expect(!index.locate(key_hash("狐"), "狐").has_value(), "verify: key A pointing at B's record is rejected");
      expect(index.locate(key_hash("犬"), "犬").has_value(), "verify: B itself still resolves");
    }
    for (const bool filter : {false, true}) {
      DictionaryQuery q;
      q.add_term_dict(dir);
      if (filter) q.prepare_union_filter("", true);
      expect(q.query("狐").empty(), "verify: query(A) finds nothing");
      expect(!q.query("犬").empty(), "verify: query(B) still finds B");
    }
  }

  // (b) 主桶里有 tag 相同的假候选，真键住在备桶：必须查得到。构建器不会排出这种布局
  // （key_index_test 的 tag 歧义用例），所以这里按磁盘格式手写一份 key.index——读侧对
  // 「候选核对不上」的兜底不依赖构建器的保证。同时把磁盘格式钉住：
  //   头 64 字节 = "FDKEYIX1" | u32 version=1 | u32 slots=8 | u64 num_buckets | u64 num_keys |
  //               u32 blobs | 28 字节保留
  //   桶 64 字节 = u32 word x 8 | u32 offset x 8，word = tag(29) | bit29 溢出 | bit30 占用 |
  //               bit31 single
  {
    const uint64_t ha = key_hash("猫");
    hash::key_index::entry neko{};
    for (const auto& e : real) {
      if (e.hash == ha) neko = e;
    }
    uint64_t nb = 2;
    while (hash::key_index::bucket1(ha, nb) == hash::key_index::bucket2(ha, nb)) nb++;
    const uint64_t b1 = hash::key_index::bucket1(ha, nb);
    const uint64_t b2 = hash::key_index::bucket2(ha, nb);
    const uint32_t tag = hash::key_index::tag_of(ha);
    constexpr uint32_t kOverflow = 1U << 29;
    constexpr uint32_t kOccupied = 1U << 30;
    constexpr uint32_t kSingle = 1U << 31;

    std::vector<uint8_t> file(64 + nb * 64, 0);
    std::memcpy(file.data(), "FDKEYIX1", 8);
    const uint32_t version = 1;
    const uint32_t slots = 8;
    const uint64_t num_keys = 4;
    std::memcpy(file.data() + 8, &version, 4);
    std::memcpy(file.data() + 12, &slots, 4);
    std::memcpy(file.data() + 16, &nb, 8);
    std::memcpy(file.data() + 24, &num_keys, 8);
    const auto put = [&](uint64_t bucket, size_t slot, uint32_t word, uint64_t offset) {
      const auto offset32 = static_cast<uint32_t>(offset);
      std::memcpy(file.data() + 64 + bucket * 64 + slot * 4, &word, 4);
      std::memcpy(file.data() + 64 + bucket * 64 + 32 + slot * 4, &offset32, 4);
    };
    // 主桶：三个 tag 相同的假候选，都指向 犬 的位置；0 号 word 带溢出位。
    for (size_t s = 0; s < 3; s++) {
      put(b1, s, tag | kOccupied | (inu.single ? kSingle : 0) | (s == 0 ? kOverflow : 0), inu.offset);
    }
    // 备桶：猫 的真位置。
    put(b2, 5, tag | kOccupied | (neko.single ? kSingle : 0), neko.offset);

    const std::string dir = root + "/verify_alt";
    copy_dir(fresh.term, dir);
    fs::remove(dir + "/key.index");
    {
      std::ofstream out(fs::path(dir) / "key.index", std::ios::binary);
      out.write(reinterpret_cast<const char*>(file.data()), static_cast<std::streamsize>(file.size()));
    }

    hash::dict_index index;
    if (!index.open(dir) || !index.uses_key_index()) {
      fail("verify: hand-written key.index must load");
    } else {
      const hash::key_index& k = *index.keys();
      const auto first = k.primary(ha);
      expect(first.count == 3 && first.more, "verify: primary bucket holds the three fakes and the overflow bit");
      for (uint32_t i = 0; i < first.count; i++) {
        expect(!hash::location_has_key(index.blobs(), first.at[i], "猫"), "verify: fakes do not carry the key");
      }
      const auto loc = index.locate(ha, "猫");
      expect(loc.has_value() && loc->offset == neko.offset && loc->single == neko.single,
             "verify: key behind same-tag fakes in its primary bucket is found in the alternate");
      for (const bool filter : {false, true}) {
        DictionaryQuery crafted;
        crafted.add_term_dict(dir);
        DictionaryQuery original;
        original.add_term_dict(fresh.term);
        if (filter) {
          crafted.prepare_union_filter("", true);
          original.prepare_union_filter("", true);
        }
        expect_same(dump_terms(original.query("猫")), dump_terms(crafted.query("猫")),
                    "verify: query through fake candidates");
        expect(!crafted.query("猫").empty(), "verify: crafted index still finds 猫");
      }
    }
  }

  // (c) 旧式 hash.table 也核对：64 位哈希「相等」但记录不是这个键 → 查不到。
  {
    const DictSet legacy = import_set(root + "/verify_legacy_src", true);
    if (!legacy.ok()) return;
    const std::string dir = root + "/verify_legacy";
    copy_dir(legacy.term, dir);
    std::vector<std::pair<uint64_t, uint64_t>> slots;
    uint64_t inu_table = 0;
    {
      hash::dict_index index;
      if (!index.open(dir) || index.uses_key_index()) {
        fail("verify: legacy fixture");
        return;
      }
      for (const std::string& k : keys) {
        const auto loc = index.locate(key_hash(k), k);
        if (!loc) continue;
        slots.emplace_back(key_hash(k), loc->offset);
        if (k == "犬") inu_table = loc->offset;
      }
    }
    slots.emplace_back(key_hash("狐"), inu_table);
    fs::remove(dir + "/hash.table");
    fs::remove(dir + "/bloom.filter");
    hash::linear table;
    table.build_to_file(slots, dir + "/hash.table");
    hash::dict_index index;
    expect(index.open(dir) && !index.uses_key_index(), "verify: crafted legacy table loads");
    expect(!index.locate(key_hash("狐"), "狐").has_value(), "verify: legacy slot for A pointing at B is rejected");
    expect(index.locate(key_hash("犬"), "犬").has_value(), "verify: legacy B still resolves");
  }
}

// ── 3. 升级的健壮性 ───────────────────────────────────────────────────────────

fs::file_time_type mtime(const std::string& path) {
  std::error_code ec;
  return fs::last_write_time(path, ec);
}

void test_robustness(const std::string& root, Deinflector& deinflector) {
  const DictSet legacy = import_set(root + "/rob_ref", true);
  if (!legacy.ok()) return;
  const std::string want = snapshot_of(legacy, deinflector, false);

  // 幂等。
  {
    const DictSet set = import_set(root + "/rob_idem", true);
    if (!set.ok()) return;
    expect_result(fushidicts::upgrade_dictionary(set.freq, true), UpgradeResult::Upgraded, "idempotent: first");
    const auto t = mtime(set.freq + "/key.index");
    const auto size = fs::file_size(set.freq + "/key.index");
    expect_result(fushidicts::upgrade_dictionary(set.freq, true), UpgradeResult::UpToDate, "idempotent: second");
    expect_result(fushidicts::upgrade_dictionary(set.freq, false), UpgradeResult::UpToDate, "idempotent: third");
    expect(mtime(set.freq + "/key.index") == t && fs::file_size(set.freq + "/key.index") == size,
           "idempotent: key.index is not rewritten");
    // 新导入的词典本来就是最新的。
    const DictSet fresh = import_set(root + "/rob_fresh", false);
    if (!fresh.ok()) return;
    for (const std::string& dir : fresh.all()) {
      expect_result(fushidicts::upgrade_dictionary(dir, true), UpgradeResult::UpToDate, "fresh import: " + dir);
    }
    // 不是词典的目录。
    fs::create_directories(root + "/rob_not_a_dict");
    expect_result(fushidicts::upgrade_dictionary(root + "/rob_not_a_dict", true), UpgradeResult::Failed,
                  "not a dictionary directory");
    expect_result(fushidicts::upgrade_dictionary(root + "/rob_missing", true), UpgradeResult::Failed,
                  "missing directory");
    // 一个键都没有的旧式索引（槽位全空——导入端不产出空词典，只会是坏表）：没有可搬的
    // 东西，留在旧式，不写也不删任何文件。
    {
      const std::string dir = root + "/rob_empty";
      fs::create_directories(dir);
      std::ofstream(fs::path(dir) / ".fushidicts_2") << "2";
      std::ofstream(fs::path(dir) / "blobs.bin", std::ios::binary) << "x";
      std::vector<char> table(4 + 4 * 16, 0);
      const uint32_t capacity = 4;
      std::memcpy(table.data(), &capacity, sizeof(capacity));
      std::ofstream(fs::path(dir) / "hash.table", std::ios::binary)
          .write(table.data(), static_cast<std::streamsize>(table.size()));
      expect_result(fushidicts::upgrade_dictionary(dir, true), UpgradeResult::NotApplicable, "empty legacy index");
      expect(!fs::exists(dir + "/key.index") && fs::exists(dir + "/hash.table") && fs::exists(dir + "/blobs.bin"),
             "empty legacy index: nothing written, nothing removed");
    }
  }

  // 遗留临时文件 + 孤儿 blobs3.bin（上一次升级中途被杀）：不影响这一次，且被清掉。
  {
    const DictSet set = import_set(root + "/rob_leftover", true);
    if (!set.ok()) return;
    for (const std::string& dir : set.all()) {
      write_text(dir + "/key.index.1a2b-3c4d.tmp", "half-written index");
      write_text(dir + "/blobs3.bin.1a2b-3c4d.tmp", "half-written blobs");
      write_text(dir + "/blobs3.bin", "orphan blobs3 from an interrupted rewrite");
      write_text(dir + "/key.index.tmp", "an older naming of the temporary file");
      // 放过了清理窗口的遗留物（十分钟以上）。
      const auto old = fs::file_time_type::clock::now() - std::chrono::hours(1);
      fs::last_write_time(dir + "/key.index.1a2b-3c4d.tmp", old);
      fs::last_write_time(dir + "/blobs3.bin.1a2b-3c4d.tmp", old);
      fs::last_write_time(dir + "/key.index.tmp", old);
      expect_result(fushidicts::upgrade_dictionary(dir, true), UpgradeResult::Upgraded, "leftovers: " + dir);
      expect(!exists(dir + "/key.index.1a2b-3c4d.tmp") && !exists(dir + "/blobs3.bin.1a2b-3c4d.tmp") &&
                 !exists(dir + "/key.index.tmp"),
             "leftovers: stale temporary files are removed: " + dir);
    }
    // 重写过的 meta 词典：孤儿被新的 blobs3.bin 取代；其余词典：孤儿被删掉。
    for (const std::string& dir : {set.term, set.kanji, set.simple}) {
      expect(!exists(dir + "/blobs3.bin"), "leftovers: orphan blobs3.bin removed: " + dir);
    }
    expect_same(want, snapshot_of(set, deinflector, false), "leftovers: results after upgrade");
    // 刚写的临时文件（可能是另一个进程正在写的那份）不碰。
    write_text(set.term + "/key.index.fresh.tmp", "someone else's in-flight write");
    expect_result(fushidicts::upgrade_dictionary(set.term, true), UpgradeResult::UpToDate, "leftovers: rerun");
    expect(exists(set.term + "/key.index.fresh.tmp"), "leftovers: a fresh temporary file is left alone");
  }

  // 已有合法 key.index（original）旁边的孤儿 blobs3.bin：「已是最新」分支把它清掉。
  {
    const DictSet fresh = import_set(root + "/rob_orphan", false);
    if (!fresh.ok()) return;
    write_text(fresh.freq + "/blobs3.bin", "orphan");
    expect_result(fushidicts::upgrade_dictionary(fresh.freq, true), UpgradeResult::UpToDate, "orphan beside key.index");
    expect(!exists(fresh.freq + "/blobs3.bin"), "orphan beside a valid key.index is removed");
  }

  // key.index 损坏、旧文件还在：引擎回退旧式仍可查；升级换掉坏文件。
  {
    const DictSet set = import_set(root + "/rob_corrupt", true);
    if (!set.ok()) return;
    for (const std::string& dir : set.all()) {
      write_text(dir + "/key.index", "FDKEYIX1 but truncated");
      expect(!uses_key_index(dir), "corrupt key.index is not used: " + dir);
    }
    expect_same(want, snapshot_of(set, deinflector, false), "corrupt key.index: falls back to the legacy index");
    for (const std::string& dir : set.all()) {
      expect_result(fushidicts::upgrade_dictionary(dir, true), UpgradeResult::Upgraded, "corrupt key.index: " + dir);
      expect(uses_key_index(dir), "corrupt key.index replaced: " + dir);
    }
    expect_same(want, snapshot_of(set, deinflector, true), "corrupt key.index: results after upgrade");
    // key.index 指向的记录文件不在（blobs3.bin 被删了）：同样不可用、回退。
    const DictSet set2 = import_set(root + "/rob_missing_blobs3", true);
    if (!set2.ok()) return;
    expect_result(fushidicts::upgrade_dictionary(set2.freq, true), UpgradeResult::Upgraded, "rewrite for removal");
    fs::remove(set2.freq + "/blobs3.bin");
    expect(!uses_key_index(set2.freq), "key.index without its record file is not used");
  }

  // C ABI：与 C++ 入口同语义，空指针不崩。
  {
    const DictSet set = import_set(root + "/rob_ffi", true);
    if (!set.ok()) return;
    expect(fushidicts_upgrade_dictionary(nullptr, 1) == -1, "ffi: null dir -> -1");
    expect(fushidicts_upgrade_dictionary(set.term.c_str(), 0) == 1, "ffi: index-only upgrade -> 1");
    expect(fushidicts_upgrade_dictionary(set.term.c_str(), 1) == 0, "ffi: second call -> 0");
    expect(fushidicts_upgrade_dictionary(set.freq.c_str(), 1) == 1, "ffi: meta rewrite -> 1");
    expect(exists(set.freq + "/blobs3.bin"), "ffi: allow_meta_rewrite honoured");
    expect(fushidicts_upgrade_dictionary((root + "/rob_missing").c_str(), 1) == -1, "ffi: missing dir -> -1");
    expect_same(want, snapshot_of(set, deinflector, false), "ffi: results after upgrade");
  }

  // 引擎正装着旧式词典时升级。
  {
    const DictSet set = import_set(root + "/rob_live", true);
    if (!set.ok()) return;
    auto engine = std::make_unique<DictionaryQuery>();
    load(*engine, set);
    engine->prepare_union_filter("", true);
    expect_same(want, snapshot(*engine, deinflector), "live: before upgrade");
    for (const std::string& dir : set.all()) {
      expect_result(fushidicts::upgrade_dictionary(dir, true), UpgradeResult::Upgraded, "live upgrade: " + dir);
      expect(uses_key_index(dir), "live: a new engine would use key.index: " + dir);
    }
    expect_same(want, snapshot(*engine, deinflector), "live: the loaded engine is unaffected by the upgrade");
    expect_same(want, snapshot_of(set, deinflector, true), "live: a new engine on the upgraded dicts");
    // 引擎还映射着旧文件，名字照样立刻摘掉（POSIX unlink；Windows 上是 POSIX 语义删除，
    // MSVC 与 llvm-mingw 一致），映射着的引擎照常读（上面 "unaffected"）。
    expect(!exists(set.term + "/hash.table") && !exists(set.term + "/bloom.filter"),
           "live: superseded index files are unlinked at once");
    expect(!exists(set.freq + "/blobs.bin"), "live: superseded blobs.bin is unlinked at once");
    // app 的次序：影子引擎先装上升级后的词典，旧引擎再放手，然后补跑一遍清理。清理时
    // 新引擎正开着 key.index / blobs3.bin（Windows 上是只读共享的句柄 / 映射）——旧文件
    // 照样要清得掉。
    auto reloaded = std::make_unique<DictionaryQuery>();
    load(*reloaded, set);
    reloaded->prepare_union_filter("", true);
    engine.reset();
    for (const std::string& dir : set.all()) {
      expect_result(fushidicts::upgrade_dictionary(dir, true), UpgradeResult::UpToDate, "live: after release " + dir);
      expect(!exists(dir + "/hash.table") && !exists(dir + "/bloom.filter"),
             "live: superseded index files are gone once released: " + dir);
    }
    for (const std::string& dir : {set.freq, set.pitch, set.ipa}) {
      expect(!exists(dir + "/blobs.bin"), "live: superseded blobs.bin is gone once released: " + dir);
    }
    expect_same(want, snapshot(*reloaded, deinflector), "live: the reloaded engine is unaffected by the cleanup");
    reloaded.reset();
    expect_same(want, snapshot_of(set, deinflector, false), "live: results after cleanup");
  }
}

}  // namespace

// ── 4. 手写索引：读侧对坏 / 罕见布局的行为 ─────────────────────────────────────

// 按磁盘格式手写一份 key.index（布局见 test_verification (b) 的注释）。
struct RawSlot {
  uint64_t bucket;
  size_t slot;
  uint32_t word;
  uint64_t offset;
};

void write_raw_key_index(const std::string& dir, uint64_t num_buckets, uint64_t num_keys,
                         const std::vector<RawSlot>& slots) {
  std::vector<uint8_t> file(64 + num_buckets * 64, 0);
  std::memcpy(file.data(), "FDKEYIX1", 8);
  const uint32_t version = 1;
  const uint32_t slots_per_bucket = 8;
  std::memcpy(file.data() + 8, &version, 4);
  std::memcpy(file.data() + 12, &slots_per_bucket, 4);
  std::memcpy(file.data() + 16, &num_buckets, 8);
  std::memcpy(file.data() + 24, &num_keys, 8);
  for (const RawSlot& s : slots) {
    const auto offset32 = static_cast<uint32_t>(s.offset);
    std::memcpy(file.data() + 64 + s.bucket * 64 + s.slot * 4, &s.word, 4);
    std::memcpy(file.data() + 64 + s.bucket * 64 + 32 + s.slot * 4, &offset32, 4);
  }
  fs::remove(dir + "/key.index");
  std::ofstream out(fs::path(dir) / "key.index", std::ios::binary);
  out.write(reinterpret_cast<const char*>(file.data()), static_cast<std::streamsize>(file.size()));
}

void test_raw_index(const std::string& root) {
  constexpr uint32_t kOverflow = 1U << 29;
  constexpr uint32_t kOccupied = 1U << 30;
  constexpr uint32_t kSingle = 1U << 31;

  const DictSet fresh = import_set(root + "/raw_src", false);
  if (!fresh.ok()) return;
  const uint64_t ha = key_hash("猫");
  hash::location neko{};
  {
    hash::dict_index index;
    const auto loc = index.open(fresh.term) ? index.locate(ha, "猫") : std::nullopt;
    if (!loc) {
      fail("raw: fixture key not found");
      return;
    }
    neko = *loc;
  }
  uint64_t nb = 2;
  while (hash::key_index::bucket1(ha, nb) == hash::key_index::bucket2(ha, nb)) nb++;
  const uint64_t b1 = hash::key_index::bucket1(ha, nb);
  const uint64_t b2 = hash::key_index::bucket2(ha, nb);
  const uint32_t tag = hash::key_index::tag_of(ha);
  const uint32_t neko_word = tag | kOccupied | (neko.single ? kSingle : 0);

  const auto query_both = [&](const std::string& dir, bool want_found, const std::string& what) {
    {
      hash::dict_index index;
      if (!index.open(dir) || !index.uses_key_index()) {
        fail(what + ": hand-written key.index must load");
        return;
      }
      expect(index.locate(ha, "猫").has_value() == want_found, what + ": locate");
    }
    for (const bool filter : {false, true}) {
      DictionaryQuery q;
      q.add_term_dict(dir);
      if (filter) q.prepare_union_filter("", true);
      expect(!q.query("猫").empty() == want_found, what + (filter ? ": query (filter)" : ": query"));
    }
  };

  // (a) 主桶里没有 tag 相同的 slot、只有溢出位（住着别的键），真键在备桶：分遍预取的
  //     「读备桶」那一遍（locate_all 的 2b）必须走到。
  {
    const std::string dir = root + "/raw_overflow";
    copy_dir(fresh.term, dir);
    write_raw_key_index(dir, nb, 2,
                        {
                            {b1, 0, ((tag ^ 1U) & hash::key_index::kTagMask) | kOccupied | kOverflow, neko.offset},
                            {b2, 3, neko_word, neko.offset},
                        });
    query_both(dir, true, "raw overflow-only primary");
  }

  // (b) 同样的主桶、但没有溢出位：一条缓存行就判「不在」，备桶里即使有也不看——这是
  //     构建端「键住备桶则主桶必带溢出位」那条保证的另一面。
  {
    const std::string dir = root + "/raw_no_overflow";
    copy_dir(fresh.term, dir);
    write_raw_key_index(dir, nb, 2,
                        {
                            {b1, 0, ((tag ^ 1U) & hash::key_index::kTagMask) | kOccupied, neko.offset},
                            {b2, 3, neko_word, neko.offset},
                        });
    query_both(dir, false, "raw primary without overflow bit");
  }

  // (c) tag 对得上、offset 指到文件外（single 与 offset 表两种）：核对读不到记录，判
  //     「不在」，不越界、不崩。
  for (const bool single : {true, false}) {
    const std::string dir = root + (single ? "/raw_oob_single" : "/raw_oob_list");
    copy_dir(fresh.term, dir);
    write_raw_key_index(dir, nb, 1, {{b1, 2, tag | kOccupied | (single ? kSingle : 0), 0xFFFFFFF0ULL}});
    query_both(dir, false, single ? "raw out-of-range record offset" : "raw out-of-range list offset");
  }

  // (d) 头里的 num_keys 多过 slot 数（坏头）：不装载，退回——这里没有旧式文件，打不开。
  {
    const std::string dir = root + "/raw_bad_num_keys";
    copy_dir(fresh.term, dir);
    write_raw_key_index(dir, nb, nb * 8 + 1, {{b1, 0, neko_word, neko.offset}});
    hash::dict_index index;
    expect(!index.open(dir), "raw: num_keys beyond the slot count must not load");
  }
}

// ── 5. 并发升级 ───────────────────────────────────────────────────────────────

std::string marker_of(const std::string& dir) {
  for (const char* name : {"/.fushidicts_2", "/.fushidicts_1", "/.hoshidicts_1"}) {
    if (fs::exists(dir + name)) return dir + name;
  }
  return {};
}

void test_concurrency(const std::string& root, Deinflector& deinflector) {
  // (a) 串行化：别人持有这本词典的升级锁时，升级调用等着，放锁之后才进行。
  {
    const DictSet set = import_set(root + "/conc_lock", true);
    if (!set.ok()) return;
    const std::string marker = marker_of(set.freq);
    expect(!marker.empty(), "concurrency: fixture has an import marker");
    std::atomic<bool> finished{false};
    UpgradeResult result = UpgradeResult::Failed;
    std::thread waiter;
    {
      const memory::file_lock held(marker);
      expect(held.held(), "concurrency: test takes the lock");
      waiter = std::thread([&] {
        result = fushidicts::upgrade_dictionary(set.freq, true);
        finished.store(true);
      });
      std::this_thread::sleep_for(std::chrono::milliseconds(300));
      expect(!finished.load(), "concurrency: upgrade must wait while the dictionary lock is held");
      expect(!exists(set.freq + "/key.index"), "concurrency: nothing is committed while waiting");
    }
    waiter.join();
    expect_result(result, UpgradeResult::Upgraded, "concurrency: proceeds once the lock is released");
  }

  // (b) 多线程同时升级同一批词典，参数混用（有的允许重写记录、有的只换索引）。审查复现
  //     过的坏法：后到的调用按开头看到的旧状态行事，把先到者刚提交的 key.index 删掉 /
  //     改回指向已被删除的 blobs.bin，词典从此打不开。每一轮结束后：每本词典都打得开、
  //     用的是 key.index、结果与旧式逐字段相同，且恰好一个调用报「已升级」。
  const DictSet baseline_set = import_set(root + "/conc_baseline", true);
  if (!baseline_set.ok()) return;
  const std::string baseline = snapshot_of(baseline_set, deinflector, false);
  for (int round = 0; round < 6; round++) {
    const DictSet set = import_set(root + "/conc_round", true);
    if (!set.ok()) return;
    const std::vector<std::string> dirs = set.all();
    constexpr int kThreads = 4;
    std::vector<std::vector<UpgradeResult>> results(kThreads, std::vector<UpgradeResult>(dirs.size()));
    std::atomic<bool> go{false};
    std::vector<std::thread> threads;
    for (int t = 0; t < kThreads; t++) {
      threads.emplace_back([&, t] {
        while (!go.load()) std::this_thread::yield();
        for (size_t d = 0; d < dirs.size(); d++) {
          // 线程各自从不同的词典起步，参数按线程与轮次错开。
          const size_t at = (d + static_cast<size_t>(t)) % dirs.size();
          results[static_cast<size_t>(t)][at] = fushidicts::upgrade_dictionary(dirs[at], ((t + round) & 1) == 0);
        }
      });
    }
    go.store(true);
    for (std::thread& th : threads) th.join();

    const std::string label = "concurrency round " + std::to_string(round);
    for (size_t d = 0; d < dirs.size(); d++) {
      int upgraded = 0;
      int other = 0;
      for (int t = 0; t < kThreads; t++) {
        const UpgradeResult r = results[static_cast<size_t>(t)][d];
        if (r == UpgradeResult::Upgraded) {
          upgraded++;
        } else if (r != UpgradeResult::UpToDate) {
          other++;
        }
      }
      expect(upgraded == 1 && other == 0, label + ": exactly one caller upgrades " + dirs[d] + " (upgraded=" +
                                              std::to_string(upgraded) + ", failed=" + std::to_string(other) + ")");
      expect(uses_key_index(dirs[d]), label + ": " + dirs[d] + " opens with key.index");
    }
    expect_same(baseline, snapshot_of(set, deinflector, false), label + ": results after concurrent upgrade");
  }
}

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
  Deinflector deinflector;
  deinflector.load_transforms_json(ja_json);

  const std::string root = fushi_test::temp_dir() + "/fushi_dict_upgrade_test";
  fs::remove_all(root);
  fs::create_directories(root);

  test_equivalence(root, deinflector);
  test_verification(root);
  test_robustness(root, deinflector);
  test_raw_index(root);
  test_concurrency(root, deinflector);

  if (g_fail == 0) std::printf("PASS dict_upgrade_test\n");
  return g_fail == 0 ? 0 : 1;
}
