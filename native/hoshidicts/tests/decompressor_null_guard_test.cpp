// TODO-892 source-scan guard: every libdeflate_alloc_decompressor() call in the
// hoshidicts *production* sources must be followed, within a small window, by a
// null check on the returned pointer. The historical yomitan import hard-crash
// (0xC0000005) was a null decompressor being deref'd by
// libdeflate_deflate_decompress() because zip.cpp skipped the check; this guard
// stops any future decompression site from reintroducing the same UB.
//
// The scan is intentionally NOT pinned to specific files: it walks the whole
// hoshidicts_src/ tree (skipping the vendored libdeflate's own sources/tests),
// so it covers zip.cpp's new checks, mdx/stardict's existing checks, and any
// decompression site added later.
//
// Usage: decompressor_null_guard_test <hoshidicts_src_dir>
//   (the test build passes HOSHI_SRC via argv; falls back to a relative guess.)
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>

namespace fs = std::filesystem;

namespace {

bool is_cpp_source(const fs::path& p) {
  const std::string ext = p.extension().string();
  return ext == ".cpp" || ext == ".cc" || ext == ".hpp" || ext == ".h";
}

std::string read_file(const fs::path& p) {
  std::ifstream f(p, std::ios::binary);
  std::stringstream ss;
  ss << f.rdbuf();
  return ss.str();
}

// Within [from, from+window) of `s`, does a null check on the decompressor
// appear? Accept the common spellings.
bool has_null_check(const std::string& s, size_t from, size_t window) {
  const size_t end = std::min(s.size(), from + window);
  const std::string slice = s.substr(from, end - from);
  static const char* patterns[] = {"if (!d)", "if(!d)",   "d == nullptr",
                                    "d==nullptr", "if (d)",  "if(d)",
                                    "d != nullptr", "d!=nullptr"};
  for (const char* pat : patterns) {
    if (slice.find(pat) != std::string::npos) return true;
  }
  return false;
}

}  // namespace

int main(int argc, char** argv) {
  fs::path src_root;
  if (argc > 1) {
    src_root = argv[1];
  } else {
    src_root = fs::path(__FILE__).parent_path().parent_path() / "hoshidicts_src";
  }
  if (!fs::exists(src_root)) {
    std::fprintf(stderr, "FAIL: source root not found: %s\n",
                 src_root.string().c_str());
    return 2;
  }

  const std::string kAlloc = "libdeflate_alloc_decompressor()";
  // Window after the alloc call within which a null check must appear. A couple
  // hundred bytes comfortably covers the assignment line + the next statement.
  const size_t kWindow = 240;

  int sites = 0;
  std::vector<std::string> violations;

  for (const auto& entry : fs::recursive_directory_iterator(src_root)) {
    if (!entry.is_regular_file()) continue;
    const fs::path& p = entry.path();
    if (!is_cpp_source(p)) continue;

    const std::string contents = read_file(p);
    size_t pos = 0;
    while ((pos = contents.find(kAlloc, pos)) != std::string::npos) {
      ++sites;
      if (!has_null_check(contents, pos, kWindow)) {
        violations.push_back(p.string() + " @offset " + std::to_string(pos));
      }
      pos += kAlloc.size();
    }
  }

  if (sites == 0) {
    std::fprintf(stderr,
                 "FAIL: scanned but found 0 decompressor alloc sites under %s "
                 "(scan path wrong?)\n",
                 src_root.string().c_str());
    return 1;
  }
  if (!violations.empty()) {
    std::fprintf(stderr, "FAIL: %zu decompressor alloc site(s) missing a null "
                         "check within %zu bytes:\n",
                 violations.size(), kWindow);
    for (const auto& v : violations) std::fprintf(stderr, "  - %s\n", v.c_str());
    return 1;
  }

  std::printf("PASS (%d decompressor alloc site(s), all null-checked)\n", sites);
  return 0;
}
