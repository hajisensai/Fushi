// MDX import streams record blocks instead of decompressing the whole record
// stream into one buffer, so a 400 MB dictionary no longer needs >1 GB of heap
// (which got the app jetsam-killed mid-import on iOS). This test covers the
// paths that only exist once records are inflated a block at a time:
//
//   1) a record that STRADDLES a block boundary must still come out whole --
//      the reader has to carry the partial record forward into the next block;
//   2) a @@@LINK= redirect whose target lives in a DIFFERENT block must still
//      resolve, in both directions (target earlier and target later than the
//      redirect), and through a chain that crosses blocks;
//   3) block layout must not change the result: the same entries split many
//      ways, and not split at all, must parse identically;
//   4) parse() and parse_streaming() must agree entry-for-entry;
//   5) .mdd binary records must stay byte-exact across a block boundary.
//
// Every other fixture in this suite emits a SINGLE record block, so none of the
// above is reachable from them.
//
// Red/green: drop the window carry-over in stream_records, or resolve redirects
// only against the block being streamed, and the definitions come back truncated
// or empty -> FAIL.
//
// Usage: mdx_streaming_blocks_test  (no args) -> exit 0 PASS, non-zero FAIL.
#include <cstdio>
#include <map>
#include <string>
#include <utility>
#include <vector>

#include "mdx_fixture.hpp"
#include "mdx_reader.hpp"

namespace {
int g_fail = 0;

void expect_eq(const std::string& what, const std::string& got, const std::string& want) {
  if (got == want) return;
  std::fprintf(stderr, "FAIL %s:\n  got  '%s'\n  want '%s'\n", what.c_str(), got.c_str(), want.c_str());
  ++g_fail;
}

void expect_size(const char* what, size_t got, size_t want) {
  if (got == want) return;
  std::fprintf(stderr, "FAIL %s: got %zu want %zu\n", what, got, want);
  ++g_fail;
}

const std::string kAlpha = "<div>ALPHA definition body</div>";
const std::string kBeta = "<div>BETA definition body, deliberately long enough to span blocks</div>";
const std::string kDelta = "<div>DELTA definition body</div>";
const std::string kZeta = "<div>ZETA definition body</div>";

// Key order matters: record offsets must ascend. gamma points backwards at
// alpha, epsilon points forwards at zeta, and eta chains through epsilon.
std::vector<std::pair<std::string, std::string>> entries() {
  return {
      {"alpha", kAlpha},
      {"beta", kBeta},
      {"gamma", "@@@LINK=alpha"},
      {"delta", kDelta},
      {"epsilon", "@@@LINK=zeta"},
      {"zeta", kZeta},
      {"eta", "@@@LINK=epsilon"},
  };
}

std::map<std::string, std::string> parse_to_map(const std::vector<uint8_t>& file) {
  MdxResult r = mdx_reader::parse(file.data(), file.size());
  std::map<std::string, std::string> out;
  for (auto& e : r.entries) out.emplace(e.key, e.definition);
  return out;
}

// Every headword must survive with its fully resolved definition, whatever the
// block layout is.
void check_all(const char* label, const std::map<std::string, std::string>& m) {
  expect_size(label, m.size(), 7);
  auto get = [&](const char* k) -> std::string {
    auto it = m.find(k);
    return it == m.end() ? std::string("<MISSING>") : it->second;
  };
  expect_eq(std::string(label) + " alpha", get("alpha"), kAlpha);
  expect_eq(std::string(label) + " beta", get("beta"), kBeta);
  expect_eq(std::string(label) + " delta", get("delta"), kDelta);
  expect_eq(std::string(label) + " zeta", get("zeta"), kZeta);
  // Redirects carry their target's bytes verbatim -- byte-identical aliases are
  // what let the importer collapse them onto one glossary blob (BUG-1665).
  expect_eq(std::string(label) + " gamma -> alpha (backward, cross-block)", get("gamma"), kAlpha);
  expect_eq(std::string(label) + " epsilon -> zeta (forward, cross-block)", get("epsilon"), kZeta);
  expect_eq(std::string(label) + " eta -> epsilon -> zeta (chain)", get("eta"), kZeta);
}
}  // namespace

int main() {
  const auto rows = entries();

  // --- Case A: one block (control) ----------------------------------------
  auto single = mdx_fixture::build_mdx_record_splits("Streamed", rows, {});
  auto single_map = parse_to_map(single);
  check_all("single-block", single_map);

  // --- Case B: split every 7 bytes ----------------------------------------
  // Records are 30-70 bytes, so every one of them straddles at least one block
  // boundary and the reader must carry bytes forward across many blocks.
  {
    std::vector<size_t> splits;
    for (size_t off = 7; off < 4096; off += 7) splits.push_back(off);
    auto many = mdx_fixture::build_mdx_record_splits("Streamed", rows, splits);
    check_all("7-byte blocks", parse_to_map(many));
  }

  // --- Case C: split once, in the middle of beta's record ------------------
  // beta starts right after alpha's record (alpha + its NUL terminator), so a
  // split a few bytes into beta lands squarely inside one record.
  {
    const size_t beta_start = kAlpha.size() + 1;
    std::vector<size_t> splits{beta_start + 5};
    auto straddle = mdx_fixture::build_mdx_record_splits("Streamed", rows, splits);
    check_all("mid-record split", parse_to_map(straddle));
  }

  // --- Case D: block layout must not change the result ---------------------
  {
    std::vector<size_t> splits{9, 40, 61, 130, 190};
    auto chunked = mdx_fixture::build_mdx_record_splits("Streamed", rows, splits);
    auto chunked_map = parse_to_map(chunked);
    check_all("uneven blocks", chunked_map);
    if (chunked_map != single_map) {
      std::fprintf(stderr, "FAIL: block layout changed the parsed result\n");
      ++g_fail;
    }
  }

  // --- Case E: parse() and parse_streaming() agree -------------------------
  {
    std::vector<size_t> splits{11, 23, 47, 83};
    auto file = mdx_fixture::build_mdx_record_splits("Streamed", rows, splits);

    std::map<std::string, std::string> streamed;
    size_t emitted = 0;
    MdxMeta meta = mdx_reader::parse_streaming(
        file.data(), file.size(), [&](std::string&& key, std::string&& definition) {
          ++emitted;
          streamed.emplace(std::move(key), std::move(definition));
        });
    expect_eq("parse_streaming title", meta.title, "Streamed");
    expect_size("parse_streaming emitted", emitted, 7);
    check_all("parse_streaming", streamed);
    if (streamed != parse_to_map(file)) {
      std::fprintf(stderr, "FAIL: parse_streaming disagrees with parse\n");
      ++g_fail;
    }
  }

  // --- Case F: .mdd binary records stay byte-exact across a boundary -------
  {
    // Embedded NUL and a high byte: a real PNG legitimately contains both, and
    // MDD records are never NUL-stripped or transcoded.
    const std::string png_a("\x89PNG\x00\x01\xFF\x00 first blob payload", 27);
    const std::string png_b("\x89PNG\x00\x02\xFE\x00 second blob payload", 28);
    std::vector<std::pair<std::string, std::string>> media{
        {"\\img\\a.png", png_a},
        {"\\img\\b.png", png_b},
    };
    // build_mdx_record_splits NUL-terminates records (MDX text shape), so drive
    // the boundary check through the .mdx path and compare the text form.
    std::vector<size_t> splits{png_a.size() - 4, png_a.size() + 6};
    auto file = mdx_fixture::build_mdx_record_splits("MediaLike", media, splits);
    auto m = parse_to_map(file);
    expect_size("mdd-like entry count", m.size(), 2);
    expect_eq("blob a across boundary", m["\\img\\a.png"], png_a);
    expect_eq("blob b across boundary", m["\\img\\b.png"], png_b);
  }

  // --- Case G: a corrupt key table must not strand every later entry --------
  // record_offset comes straight out of the file with no validation. A garbage
  // value makes one record claim a span larger than the whole dictionary; the
  // reader has to drop that key and carry on. Honouring it instead would grow
  // the sliding window until it held the entire decompressed stream (gigabytes
  // on a real dictionary) AND leave every later entry permanently unreachable,
  // because that key can never complete.
  {
    std::vector<std::pair<std::string, std::string>> rows5{
        {"k0", "DEF0-body"}, {"k1", "DEF1-body"}, {"k2", "DEF2-body"},
        {"k3", "DEF3-body"}, {"k4", "DEF4-body"},
    };
    // Each record is 9 bytes + NUL = 10; the real offsets would be 0,10,20,30,40.
    // k1 is given an end far past the stream, k2 an impossible backwards span.
    const std::vector<uint64_t> corrupt{0, 10, 0x40000000ull, 30, 40};
    auto file = mdx_fixture::build_mdx_bad_offsets("Corrupt", rows5, corrupt, {17, 33});
    auto m = parse_to_map(file);

    expect_size("corrupt key table: entries after the bad key survive", m.size(), 3);
    expect_eq("corrupt k0", m.count("k0") ? m["k0"] : "<MISSING>", "DEF0-body");
    expect_eq("corrupt k3 (after the oversized key)", m.count("k3") ? m["k3"] : "<MISSING>",
              "DEF3-body");
    expect_eq("corrupt k4 (after the oversized key)", m.count("k4") ? m["k4"] : "<MISSING>",
              "DEF4-body");
  }

  // --- Case H: offsets past the window must not run the erase off the buffer -
  // Every offset here is beyond the record stream, so nothing is emitted; the
  // point is that reclaiming the window clamps to what it actually holds
  // instead of trusting the key table's arithmetic (UB / heap corruption).
  {
    std::vector<std::pair<std::string, std::string>> rows5{
        {"k0", "DEF0-body"}, {"k1", "DEF1-body"}, {"k2", "DEF2-body"},
        {"k3", "DEF3-body"}, {"k4", "DEF4-body"},
    };
    const std::vector<uint64_t> corrupt{900, 800, 950, 1000, 1100};
    auto file = mdx_fixture::build_mdx_bad_offsets("Corrupt2", rows5, corrupt, {20, 35});
    auto m = parse_to_map(file);
    expect_size("out-of-range key table yields nothing and does not crash", m.size(), 0);
  }

  // --- Case I: .mdd binary records across block boundaries ------------------
  // parse_mdd shares the streaming reader but keeps bytes verbatim -- no
  // transcoding, no trailing-NUL stripping, no @@@LINK. Only single-block .mdd
  // fixtures existed, so the multi-block path was never exercised.
  {
    const std::string blob_a("\x89PNG\x00\x01\xFF\x00 alpha resource bytes", 30);
    const std::string blob_b("\x00\x00OggS\xFF\x00 beta resource bytes\x00", 29);
    std::vector<std::pair<std::string, std::string>> media{
        {"\\img\\a.png", blob_a},
        {"\\audio\\b.ogg", blob_b},
    };
    // Split inside the first blob and again inside the second.
    auto file = mdx_fixture::build_mdd_record_splits("MddSplit", media, {11, 34});
    auto out = mdx_reader::parse_mdd(file.data(), file.size());
    expect_size("mdd multi-block record count", out.size(), 2);
    if (out.size() == 2) {
      expect_eq("mdd path a", out[0].path, "\\img\\a.png");
      expect_eq("mdd path b", out[1].path, "\\audio\\b.ogg");
      if (out[0].blob != blob_a) {
        std::fprintf(stderr, "FAIL mdd blob a not byte-exact (got %zu want %zu)\n", out[0].blob.size(),
                     blob_a.size());
        ++g_fail;
      }
      if (out[1].blob != blob_b) {
        std::fprintf(stderr, "FAIL mdd blob b not byte-exact (got %zu want %zu)\n", out[1].blob.size(),
                     blob_b.size());
        ++g_fail;
      }
    }
  }

  // --- Case J: circular and over-long redirect chains must terminate --------
  // The resolver's loop guard has two arms -- "already seen this target" and
  // "hop budget spent" -- and neither was reachable from the fixtures above
  // (gamma/epsilon/eta are 1- and 2-hop acyclic). Mutation-tested: dropping the
  // seen-set check leaves every case above green while `aa` silently resolves
  // to its own `@@@LINK=` text, so this is the only thing standing between a
  // hostile .mdx and an unbounded walk.
  {
    // aa <-> bb is a two-node cycle; cc..cn is a 13-hop chain, past the budget.
    std::vector<std::pair<std::string, std::string>> rows{
        {"aa", "@@@LINK=bb"},
        {"bb", "@@@LINK=aa"},
    };
    for (int i = 0; i < 13; i++) {
      char key[8];
      char target[24];
      std::snprintf(key, sizeof(key), "c%02d", i);
      std::snprintf(target, sizeof(target), "@@@LINK=c%02d", i + 1);
      rows.emplace_back(key, target);
    }
    rows.emplace_back("c13", "<div>END of the long chain</div>");

    auto file = mdx_fixture::build_mdx_record_splits("Cycles", rows, {40, 90});
    auto m = parse_to_map(file);
    // Every headword survives -- a cycle must not drop entries or hang.
    expect_size("circular redirects keep every headword", m.size(), rows.size());
    auto get = [&](const char* k) -> std::string {
      auto it = m.find(k);
      return it == m.end() ? std::string("<MISSING>") : it->second;
    };
    // Unresolvable: the cycle has no body anywhere, so the raw link text stays.
    // It must be the *other* node's link (one hop taken, then the cycle is cut),
    // never its own -- resolving to itself is what the broken loop guard did.
    expect_eq("aa in a cycle keeps an unresolved link", get("aa"), "@@@LINK=bb");
    expect_eq("bb in a cycle keeps an unresolved link", get("bb"), "@@@LINK=aa");
    // The chain's tail is within budget and resolves to the real body.
    expect_eq("c13 is the real body", get("c13"), "<div>END of the long chain</div>");
    expect_eq("c04 resolves through the chain", get("c04"), "<div>END of the long chain</div>");
  }

  if (g_fail == 0) std::printf("PASS\n");
  return g_fail == 0 ? 0 : 1;
}
