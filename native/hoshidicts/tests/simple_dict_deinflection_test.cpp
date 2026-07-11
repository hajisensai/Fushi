// Simple dictionaries (MDX / StarDict / DSL) carry no per-term part of speech.
// They are stored via write_simple_dict, which used to write rules_len = 0.
// Lookup::filter_by_pos erases any term whose POS conditions do not overlap the
// deinflection's required conditions -- so an empty-rules term was dropped for
// EVERY inflected-form lookup (e.g. querying 食べた never surfaced the 食べる
// entry of an MDX/StarDict dict). Only the bare dictionary form survived.
//
// The fix stores the wildcard rule "*" on simple-dict terms, and makes
// Deinflector::pos_to_conditions("*") return all condition bits, so
// filter_by_pos keeps them for any deinflection. This test pins both halves:
//   1) pos_to_conditions({"*"}) == ~0, while real/unknown tags behave normally.
//   2) a dict written by write_simple_dict stores rules == "*" (query surfaces
//      it), proving the wildcard actually reaches the term record.
//
// Red/green: revert either the deinflector "*" branch or the importer
// rules="*" write and an assertion fails.
//
// Usage: simple_dict_deinflection_test  (no args) -> exit 0 PASS, non-zero FAIL.
#include <cstdio>
#include <string>
#include <vector>

#include "hoshidicts/deinflector.hpp"
#include "hoshidicts/importer.hpp"
#include "hoshidicts/query.hpp"
#include "zip_fixture.hpp"

namespace {

int g_fail = 0;

void fail(const char* msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg);
  ++g_fail;
}

// 食べる (ichidan verb, dictionary form)
const std::string kTaberu = "\xE9\xA3\x9F\xE3\x81\xB9\xE3\x82\x8B";

// Minimal one-condition descriptor: bare tag "v1" -> bit 0. No transforms.
const std::string kTransforms =
    "{\"language\":\"ja\",\"conditions\":{"
    "\"v1\":{\"name\":\"ichidan verb\",\"isDictionaryForm\":true,\"subConditions\":[]}"
    "},\"transforms\":{}}";

}  // namespace

int main() {
  // --- Part 1: pos_to_conditions wildcard ---------------------------------
  Deinflector d;
  d.load_transforms_json(kTransforms);

  if (d.pos_to_conditions({"*"}) != ~uint64_t{0}) {
    fail("pos_to_conditions({\"*\"}) must be all-ones (wildcard)");
  }
  if (d.pos_to_conditions({}) != 0) {
    fail("pos_to_conditions({}) must be 0");
  }
  if (d.pos_to_conditions({"totally-unknown-tag"}) != 0) {
    fail("pos_to_conditions(unknown) must be 0");
  }
  const uint64_t v1_bits = d.pos_to_conditions({"v1"});
  if (v1_bits == 0) {
    fail("pos_to_conditions({\"v1\"}) must be non-zero");
  }
  if (v1_bits == ~uint64_t{0}) {
    fail("a real tag must NOT resolve to the wildcard all-ones");
  }
  // The wildcard overlaps every real condition (this is what lets filter_by_pos
  // keep a "*" term for a v1-requiring deinflection).
  if ((d.pos_to_conditions({"*"}) & v1_bits) == 0) {
    fail("wildcard must overlap real condition bits");
  }

  // --- Part 2: write_simple_dict stores rules == "*" ----------------------
  const std::string out_dir = hoshi_test::temp_dir() + "/hoshi_simple_deinf_out";
  std::vector<SimpleEntry> entries = {{kTaberu, "to eat"}};
  ImportResult r = dictionary_importer::write_simple_dict("SimpleDeinfDict", entries, out_dir);
  if (!r.success) {
    fail(r.errors.empty() ? "write_simple_dict failed" : r.errors.front().c_str());
  } else {
    DictionaryQuery q;
    q.add_term_dict(out_dir + "/" + r.title);
    std::vector<TermResult> terms = q.query(kTaberu);
    if (terms.empty()) {
      fail("query(食べる) returned no terms");
    } else if (terms.front().rules != "*") {
      std::fprintf(stderr, "FAIL rules: got '%s' want '*'\n", terms.front().rules.c_str());
      ++g_fail;
    }
  }

  if (g_fail) {
    std::fprintf(stderr, "%d FAIL\n", g_fail);
    return 1;
  }
  std::printf("PASS\n");
  return 0;
}
