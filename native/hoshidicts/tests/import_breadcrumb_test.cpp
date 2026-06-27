// TODO-892 guard: the native import step breadcrumb (util/import_breadcrumb.hpp)
// writes a fixed-name file into a caller-supplied directory, synchronously
// (fflush+fclose), and clears it on a clean return. The Dart side reads this
// file back on the next launch to report "crashed while at: <step>".
//
// Usage: import_breadcrumb_test  (no args) -> exit 0 on PASS.
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>

#include "util/import_breadcrumb.hpp"

namespace fs = std::filesystem;

namespace {
std::string slurp(const std::string& path) {
  std::ifstream f(path, std::ios::binary);
  std::stringstream ss;
  ss << f.rdbuf();
  return ss.str();
}
}  // namespace

int main() {
  const std::string dir =
      (fs::temp_directory_path() / "hoshi_breadcrumb_test").string();
  fs::create_directories(dir);
  const std::string path =
      hoshi::import_breadcrumb::step_path(dir);

  bool ok = true;

  // 1) set() writes the step synchronously and it is readable immediately.
  hoshi::import_breadcrumb::set(dir, "yomitan: term_bank #3 / term_bank_3.json");
  if (!fs::exists(path)) {
    std::fprintf(stderr, "FAIL: breadcrumb file not created\n");
    ok = false;
  } else if (slurp(path) != "yomitan: term_bank #3 / term_bank_3.json") {
    std::fprintf(stderr, "FAIL: content mismatch: '%s'\n", slurp(path).c_str());
    ok = false;
  } else {
    std::printf("ok[set] (synchronous write)\n");
  }

  // 2) set() overwrites (not appends).
  hoshi::import_breadcrumb::set(dir, "yomitan: media #1 / a.png");
  if (slurp(path) != "yomitan: media #1 / a.png") {
    std::fprintf(stderr, "FAIL: overwrite did not replace: '%s'\n",
                 slurp(path).c_str());
    ok = false;
  } else {
    std::printf("ok[overwrite]\n");
  }

  // 3) clear() removes the file.
  hoshi::import_breadcrumb::clear(dir);
  if (fs::exists(path)) {
    std::fprintf(stderr, "FAIL: clear() left the breadcrumb file\n");
    ok = false;
  } else {
    std::printf("ok[clear]\n");
  }

  // 4) empty dir disables the breadcrumb (no throw, no file).
  hoshi::import_breadcrumb::set("", "ignored");
  hoshi::import_breadcrumb::clear("");
  std::printf("ok[disabled] (empty dir is a no-op)\n");

  if (!ok) return 1;
  std::printf("PASS\n");
  return 0;
}
