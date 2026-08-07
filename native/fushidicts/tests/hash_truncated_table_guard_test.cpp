// BUG-1303 guard: a truncated / corrupt hash.table must not hang or read out
// of bounds on the query path.
//
// hash::linear::load() used to take the capacity straight out of the mapped
// file and trust it:
//
//     ptr_->capacity = *reinterpret_cast<uint32_t*>(ptr);
//     ptr_->table    = reinterpret_cast<slot*>(ptr + sizeof(uint32_t));
//
// with no check that the mapping actually holds `capacity` slots, and
// operator() probed with an unbounded `while (true)`. Two real failure modes
// followed from that:
//
//   * capacity larger than the file (truncated write, interrupted import,
//     partially synced dictionary folder) -> the probe walks past the end of
//     the mapping: EXCEPTION_IN_PAGE_ERROR on Windows, SIGSEGV elsewhere.
//   * a table with no free slot (or capacity read as garbage) -> the probe
//     never terminates. Dart calls lookup() as a *synchronous* FFI call on the
//     UI isolate, so that is a permanently frozen app, not a slow lookup.
//   * capacity == 0 -> `h % capacity` is an integer division by zero.
//
// probe_dict_content() in query.cpp already clamped against the real file size;
// the query path -- the one that runs on every single user lookup -- did not.
//
// This test drives the *public* query path against deliberately damaged
// hash.table files. Passing means: returns normally, no crash, no hang (ctest
// kills a hung case via its timeout, which is a failure).
//
// Usage: hash_truncated_table_guard_test  (no args) -> exit 0 PASS.
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "hoshidicts/importer.hpp"
#include "hoshidicts/query.hpp"
#include "zip_fixture.hpp"

namespace {

int g_fail = 0;

void fail(const char* msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg);
  ++g_fail;
}

// 猫 / ねこ
const std::string kNeko = "\xE7\x8C\xAB";
const std::string kNekoReading = "\xE3\x81\xAD\xE3\x81\x93";

std::string index_json(const char* title) {
  return std::string("{\"title\":\"") + title + "\",\"format\":3,\"revision\":\"test\"}";
}

std::string term_bank_neko() {
  return "[[\"" + kNeko + "\",\"" + kNekoReading + "\",\"\",\"\",0,[\"cat\"],0,\"\"]]";
}

// Import the fixture into its own directory and return the dictionary path.
std::string import_fixture(const std::string& tag) {
  const std::string out_dir = hoshi_test::temp_dir() + "/hoshi_hashguard_" + tag;
  std::error_code ec;
  std::filesystem::remove_all(out_dir, ec);

  std::vector<hoshi_test::ZipFile> files = {
      {"index.json", index_json("HashGuardDict")},
      {"term_bank_1.json", term_bank_neko()},
  };
  const std::string zip_name = "hashguard_" + tag;
  const std::string zip_path = hoshi_test::write_zip(zip_name.c_str(), files);
  if (zip_path.empty()) {
    fail("could not write fixture zip");
    return {};
  }
  ImportResult r = dictionary_importer::import(zip_path, out_dir);
  if (!r.success) {
    fail("fixture import failed");
    return {};
  }
  return out_dir + "/" + r.title;
}

// Query through the public path. The point is that this RETURNS at all.
void query_must_not_hang_or_crash(const char* label, const std::string& dict_path) {
  DictionaryQuery q;
  q.add_term_dict(dict_path);
  std::vector<TermResult> terms = q.query(kNeko);
  // Any result count is acceptable -- the table is damaged, so both "no match"
  // and "the surviving slots still matched" are legitimate. Only hanging,
  // crashing, or dividing by zero are not.
  std::printf("  %s: returned %zu term(s)\n", label, terms.size());
}

}  // namespace

int main() {
  // 1. hash.table truncated mid-slot-array: the stored capacity claims far more
  //    slots than the file holds.
  {
    const std::string dict_path = import_fixture("truncated");
    if (!dict_path.empty()) {
      const std::string table = dict_path + "/hash.table";
      std::error_code ec;
      const auto original = std::filesystem::file_size(table, ec);
      if (ec) {
        fail("could not stat hash.table");
      } else {
        // Keep the 4-byte capacity header plus a single 16-byte slot; the
        // header still claims the original (much larger) capacity.
        const std::uintmax_t keep = sizeof(std::uint32_t) + 16;
        if (original <= keep) {
          fail("fixture hash.table unexpectedly small");
        } else {
          std::filesystem::resize_file(table, keep, ec);
          if (ec) {
            fail("could not truncate hash.table");
          } else {
            query_must_not_hang_or_crash("truncated hash.table", dict_path);
          }
        }
      }
    }
  }

  // 2. capacity field stomped to 0 -> the old code did `h % 0`.
  {
    const std::string dict_path = import_fixture("zerocap");
    if (!dict_path.empty()) {
      const std::string table = dict_path + "/hash.table";
      std::fstream f(table, std::ios::binary | std::ios::in | std::ios::out);
      if (!f) {
        fail("could not open hash.table for patching");
      } else {
        const std::uint32_t zero = 0;
        f.seekp(0);
        f.write(reinterpret_cast<const char*>(&zero), sizeof(zero));
        f.close();
        query_must_not_hang_or_crash("capacity=0 hash.table", dict_path);
      }
    }
  }

  // 3. capacity field stomped to a huge value -> unbounded probe + OOB read.
  {
    const std::string dict_path = import_fixture("hugecap");
    if (!dict_path.empty()) {
      const std::string table = dict_path + "/hash.table";
      std::fstream f(table, std::ios::binary | std::ios::in | std::ios::out);
      if (!f) {
        fail("could not open hash.table for patching");
      } else {
        const std::uint32_t huge = 0xFFFFFFFFu;
        f.seekp(0);
        f.write(reinterpret_cast<const char*>(&huge), sizeof(huge));
        f.close();
        query_must_not_hang_or_crash("capacity=0xFFFFFFFF hash.table", dict_path);
      }
    }
  }

  // 4. Sanity: an undamaged copy still resolves the term, so the clamping did
  //    not simply break every lookup.
  {
    const std::string dict_path = import_fixture("intact");
    if (!dict_path.empty()) {
      DictionaryQuery q;
      q.add_term_dict(dict_path);
      std::vector<TermResult> terms = q.query(kNeko);
      if (terms.empty()) {
        fail("intact dictionary no longer resolves 猫 -- the bounds check is too strict");
      } else if (terms.front().expression != kNeko) {
        fail("intact dictionary returned the wrong term");
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
