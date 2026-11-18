// 测试里造「存量词典」：作用域内设 FUSHIDICTS_LEGACY_INDEX=1，导入端按改动前的格式写
// （旧式 hash.table + bloom.filter、meta 记录一律 type 1，见 importer.cpp
// legacy_index_forced），离开作用域恢复原值。
#pragma once

#include <cstdlib>
#include <optional>
#include <string>

namespace fushi_test {

inline void set_env_var(const char* name, const char* value) {
#ifdef _WIN32
  _putenv_s(name, value ? value : "");
#else
  if (value) {
    setenv(name, value, 1);
  } else {
    unsetenv(name);
  }
#endif
}

class ScopedLegacyIndex {
 public:
  ScopedLegacyIndex() {
    if (const char* v = std::getenv(kName)) {
      previous_ = v;
    }
    set_env_var(kName, "1");
  }
  ~ScopedLegacyIndex() { set_env_var(kName, previous_ ? previous_->c_str() : nullptr); }
  ScopedLegacyIndex(const ScopedLegacyIndex&) = delete;
  ScopedLegacyIndex& operator=(const ScopedLegacyIndex&) = delete;

 private:
  static constexpr const char* kName = "FUSHIDICTS_LEGACY_INDEX";
  std::optional<std::string> previous_;
};

}  // namespace fushi_test
