// HBK-AUDIT-009：词典句柄的引用计数 + 读写锁（fushidicts_retain / fushidicts_release /
// 退役式 fushidicts_destroy，查询共享锁、add_*_dict / load_transforms 独占锁）。
//
// 背景：浏览器扩展的整页分词要搬进后台 isolate，后台拿的是主 isolate 那个句柄的地址。
// 旧的 destroy 直接 delete，词典重载（Dart 侧 _applyTyped / loadPendingAsync /
// releaseAllMappings）会在后台分词还在跑时把句柄连同文件映射一起释放——释放后使用；
// add_*_dict 与在飞查询并发时也没有任何保护。
//
// 本测试把 fushidicts_ffi.cpp 直接编进可执行文件，经真实导出符号、用真线程验证：
//   1. 借用期间 destroy 只是退役：句柄不销毁、借用方照常拿到正确分词；最后一次
//      release 才销毁，且只销毁一次（fushidicts_live_handle_count 恰好归零、不为负）；
//      退役后的 retain 被拒；重复 destroy 不会多还引用。
//   2. 多个线程在借来的旧句柄上持续分词，同时主线程做「重载」：新建句柄装词典、退役
//      旧句柄。所有在飞结果都正确，旧句柄在最后一个借用归还时才销毁。
//   3. 读写并发：多个线程分词的同时主线程往同一句柄连续 add 词典（迫使内部容器扩容），
//      每个结果都必须是「加之前」或「加之后」两种合法切分之一。
//
// Usage: handle_lifecycle_concurrency_test <ja.json>  -> exit 0 PASS, non-zero FAIL.
#include <atomic>
#include <chrono>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <mutex>
#include <sstream>
#include <string>
#include <thread>
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
int32_t fushidicts_retain(void* handle);
void fushidicts_release(void* handle);
int32_t fushidicts_live_handle_count();
void fushidicts_add_term_dict(void* handle, const char* path);
void fushidicts_load_transforms(void* handle, const char* json);
FfiTokenizeResult fushidicts_tokenize(void* handle, const char* text, int32_t text_bytes, int32_t scan_length,
                                      int32_t with_readings);
void fushidicts_free_tokenize_result(FfiTokenizeResult* r);
}

namespace {

std::mutex g_fail_mutex;
int g_fail = 0;

void fail(const std::string& msg) {
  std::lock_guard<std::mutex> lock(g_fail_mutex);
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

// 导入一本只含 [rows] 的词典，返回其目录。
std::string import_dict(const std::string& root, const std::string& title, const std::string& rows) {
  const std::vector<fushi_test::ZipFile> files = {
      {"index.json", "{\"title\":\"" + title + "\",\"format\":3,\"revision\":\"1\"}"},
      {"term_bank_1.json", "[" + rows + "]"},
  };
  const ImportResult imported = dictionary_importer::import(fushi_test::write_zip(title.c_str(), files), root);
  if (!imported.success) {
    fail("fixture import failed: " + title);
    return {};
  }
  return root + "/" + imported.title;
}

std::vector<int32_t> tokenize_lengths(void* handle, const std::string& text) {
  FfiTokenizeResult r =
      fushidicts_tokenize(handle, text.data(), static_cast<int32_t>(text.size()), 16, /*with_readings=*/1);
  std::vector<int32_t> out(r.lengths, r.lengths + r.count);
  fushidicts_free_tokenize_result(&r);
  return out;
}

std::string describe(const std::vector<int32_t>& v) {
  std::string s = "[";
  for (size_t i = 0; i < v.size(); i++) s += (i ? "," : "") + std::to_string(v[i]);
  return s + "]";
}

void expect_live(int32_t want, const std::string& where) {
  const int32_t got = fushidicts_live_handle_count();
  if (got != want) fail(where + ": live handles want " + std::to_string(want) + " got " + std::to_string(got));
}

void* new_loaded_handle(const std::string& ja_json, const std::vector<std::string>& dicts) {
  void* h = fushidicts_create();
  if (!h) {
    fail("fushidicts_create returned null");
    return nullptr;
  }
  fushidicts_load_transforms(h, ja_json.c_str());
  for (const std::string& d : dicts) fushidicts_add_term_dict(h, d.c_str());
  return h;
}

// 文本：日本 + 語 + です 反复；只有「日本」词典时切成 [2,1,2]×n，加上「日本語」后 [3,2]×n。
const std::string kSentence = "日本語です";
std::string repeated_text(int n) {
  std::string s;
  for (int i = 0; i < n; i++) s += kSentence;
  return s;
}
std::vector<int32_t> repeated(const std::vector<int32_t>& unit, int n) {
  std::vector<int32_t> out;
  for (int i = 0; i < n; i++) out.insert(out.end(), unit.begin(), unit.end());
  return out;
}

void scenario_retire_while_borrowed(const std::string& ja_json, const std::string& base_dict) {
  expect_live(0, "start");
  void* h = new_loaded_handle(ja_json, {base_dict});
  expect_live(1, "after create");
  const std::string text = repeated_text(4);
  const std::vector<int32_t> want = repeated({2, 1, 2}, 4);

  if (fushidicts_retain(h) != 1) fail("retain on a live handle must succeed");
  fushidicts_destroy(h);  // 宿主退役，借用仍在。
  expect_live(1, "destroy while borrowed must not delete");
  if (fushidicts_retain(h) != 0) fail("retain on a retired handle must be refused");
  fushidicts_destroy(h);  // 重复 destroy：不得把借用方的引用还掉。
  expect_live(1, "second destroy must not release the borrow");
  const std::vector<int32_t> got = tokenize_lengths(h, text);
  if (got != want) fail("tokenize on retired-but-borrowed handle: want " + describe(want) + " got " + describe(got));
  fushidicts_release(h);  // 最后一个引用：此刻才销毁。
  expect_live(0, "last release destroys exactly once");

  // 无借用时 destroy 立即销毁（宿主独占的老语义不变）。
  void* plain = new_loaded_handle(ja_json, {base_dict});
  expect_live(1, "plain create");
  fushidicts_destroy(plain);
  expect_live(0, "destroy without borrows deletes immediately");

  // 空句柄：全部安全返回。
  if (fushidicts_retain(nullptr) != 0) fail("retain(nullptr) must return 0");
  fushidicts_release(nullptr);
  fushidicts_destroy(nullptr);
  expect_live(0, "null handle ops");
}

void scenario_reload_during_background_tokenize(const std::string& ja_json, const std::string& base_dict) {
  constexpr int kWorkers = 4;
  constexpr int kIterations = 300;
  const std::string text = repeated_text(64);
  const std::vector<int32_t> want = repeated({2, 1, 2}, 64);

  void* old_handle = new_loaded_handle(ja_json, {base_dict});
  // 与 Dart 侧同一顺序：主线程（宿主仍持有引用）先 retain，再把地址交给后台。
  for (int i = 0; i < kWorkers; i++) {
    if (fushidicts_retain(old_handle) != 1) fail("retain for worker failed");
  }
  std::atomic<int> started{0};
  std::atomic<int> done{0};
  std::vector<std::thread> workers;
  for (int w = 0; w < kWorkers; w++) {
    workers.emplace_back([&, w]() {
      started.fetch_add(1);
      for (int i = 0; i < kIterations; i++) {
        const std::vector<int32_t> got = tokenize_lengths(old_handle, text);
        if (got != want) {
          fail("worker " + std::to_string(w) + " iteration " + std::to_string(i) + ": got " + describe(got));
          break;
        }
      }
      done.fetch_add(1);
      fushidicts_release(old_handle);
    });
  }
  while (started.load() < kWorkers) std::this_thread::yield();
  // 「重载」：新句柄装好后退役旧句柄——旧实现在这里 delete，worker 随即释放后使用。
  void* new_handle = new_loaded_handle(ja_json, {base_dict});
  fushidicts_destroy(old_handle);
  if (done.load() < kWorkers) expect_live(2, "old handle must survive while borrowed");
  for (std::thread& t : workers) t.join();
  expect_live(1, "old handle destroyed after the last borrow, new one alive");
  fushidicts_destroy(new_handle);
  expect_live(0, "reload scenario end");
}

void scenario_add_dict_during_tokenize(const std::string& ja_json, const std::string& base_dict,
                                       const std::vector<std::string>& extra_dicts) {
  constexpr int kWorkers = 4;
  const std::string text = repeated_text(32);
  const std::vector<int32_t> before = repeated({2, 1, 2}, 32);
  const std::vector<int32_t> after = repeated({3, 2}, 32);

  void* h = new_loaded_handle(ja_json, {base_dict});
  for (int i = 0; i < kWorkers; i++) fushidicts_retain(h);
  std::atomic<bool> stop{false};
  std::atomic<int> started{0};
  std::atomic<long> reads{0};
  std::vector<std::thread> workers;
  for (int w = 0; w < kWorkers; w++) {
    workers.emplace_back([&, w]() {
      started.fetch_add(1);
      while (!stop.load()) {
        const std::vector<int32_t> got = tokenize_lengths(h, text);
        reads.fetch_add(1);
        if (got != before && got != after) {
          fail("worker " + std::to_string(w) + " saw a torn segmentation: " + describe(got));
          break;
        }
      }
      fushidicts_release(h);
    });
  }
  while (started.load() < kWorkers) std::this_thread::yield();
  for (const std::string& d : extra_dicts) {
    fushidicts_add_term_dict(h, d.c_str());
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  // 加完之后再让 worker 至少各跑一轮，确认看到的是新集合。
  const long reads_after_add = reads.load();
  while (reads.load() < reads_after_add + kWorkers) std::this_thread::yield();
  stop.store(true);
  for (std::thread& t : workers) t.join();
  const std::vector<int32_t> final_got = tokenize_lengths(h, text);
  if (final_got != after) fail("after adds: want " + describe(after) + " got " + describe(final_got));
  if (reads.load() < kWorkers) fail("workers never ran");
  fushidicts_destroy(h);
  expect_live(0, "add-dict scenario end");
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
  const std::string root = fushi_test::temp_dir() + "/fushi_handle_lifecycle_out";
  std::filesystem::remove_all(root);

  const std::string base_dict =
      import_dict(root, "LifecycleBase", row("日本", "にほん", "Japan") + "," + row("です", "です", "copula"));
  // 多本附加词典：连续 add 迫使 DictionaryQuery 内部的 vector<Dictionary> 扩容，旧实现下
  // 并发遍历会读到已释放的元素。
  std::vector<std::string> extra;
  for (int i = 0; i < 12; i++) {
    extra.push_back(import_dict(root, "LifecycleExtra" + std::to_string(i), row("日本語", "にほんご", "Japanese")));
  }
  if (g_fail) return 1;

  scenario_retire_while_borrowed(ja_json, base_dict);
  scenario_reload_during_background_tokenize(ja_json, base_dict);
  scenario_add_dict_during_tokenize(ja_json, base_dict, extra);

  std::filesystem::remove_all(root);
  if (g_fail) {
    std::fprintf(stderr, "%d failure(s)\n", g_fail);
    return 1;
  }
  std::printf("handle_lifecycle_concurrency_test: PASS\n");
  return 0;
}
