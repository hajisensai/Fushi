// 三个 MDX/MDD media store 测试共用的落盘 + 断言 helper（BUG-2147）。
//
// mdd_empty_encoding_test / mdx_sibling_script_media_test / mdx_loose_asset_media_test
// 此前各抄一份同样的 g_fail / fail / write_bytes / write_text / media_str，改一处
// 要改三处。收成一份共享头，和 mdx_fixture.hpp / zip_fixture.hpp 同一形状。
#pragma once

#include <cstdio>
#include <filesystem>
#include <fstream>
#include <string>
#include <vector>

#include "fushidicts/query.hpp"

namespace fushi_test {

// 失败计数：每个测试是独立可执行文件，main 末尾据此定退出码。
inline int g_fail = 0;

inline void fail(const char* msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg);
  ++g_fail;
}

inline void write_bytes(const std::string& path, const std::vector<uint8_t>& bytes) {
  std::ofstream f(std::filesystem::u8path(path), std::ios::binary);
  f.write(reinterpret_cast<const char*>(bytes.data()), static_cast<std::streamsize>(bytes.size()));
}

inline void write_text(const std::string& path, const std::string& text) {
  std::ofstream f(std::filesystem::u8path(path), std::ios::binary);
  f.write(text.data(), static_cast<std::streamsize>(text.size()));
}

inline std::string media_str(DictionaryQuery& q, const std::string& dict, const char* path) {
  std::vector<char> b = q.get_media_file(dict, path);
  return std::string(b.begin(), b.end());
}

}  // namespace fushi_test
