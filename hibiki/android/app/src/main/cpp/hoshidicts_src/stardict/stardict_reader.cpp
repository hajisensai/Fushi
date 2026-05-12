#include "stardict_reader.hpp"

#include <libdeflate.h>

#include <cstring>
#include <filesystem>
#include <fstream>
#include <stdexcept>
#include <sstream>

namespace {

std::vector<uint8_t> read_file(const std::string& path) {
  std::ifstream f(path, std::ios::binary | std::ios::ate);
  if (!f.is_open()) return {};
  auto size = f.tellg();
  f.seekg(0);
  std::vector<uint8_t> data(size);
  f.read(reinterpret_cast<char*>(data.data()), size);
  return data;
}

std::vector<uint8_t> decompress_gz(const uint8_t* data, size_t size) {
  if (size < 18) return {};

  uint32_t uncompressed_size;
  std::memcpy(&uncompressed_size, data + size - 4, 4);
  if (uncompressed_size == 0 || uncompressed_size > 256 * 1024 * 1024) {
    return {};
  }

  size_t header_end = 10;
  uint8_t flags = data[3];
  if (flags & 0x04) {
    if (header_end + 2 > size) return {};
    uint16_t xlen = data[header_end] | (uint16_t(data[header_end + 1]) << 8);
    header_end += 2 + xlen;
  }
  if (flags & 0x08) {
    while (header_end < size && data[header_end] != 0) header_end++;
    if (header_end >= size) return {};
    header_end++;
  }
  if (flags & 0x10) {
    while (header_end < size && data[header_end] != 0) header_end++;
    if (header_end >= size) return {};
    header_end++;
  }
  if (flags & 0x02) header_end += 2;

  if (header_end + 8 >= size) return {};
  size_t comp_size = size - header_end - 8;
  std::vector<uint8_t> result(uncompressed_size);

  auto* d = libdeflate_alloc_decompressor();
  if (!d) return {};
  auto ret = libdeflate_deflate_decompress(d, data + header_end, comp_size,
                                            result.data(), uncompressed_size, nullptr);
  libdeflate_free_decompressor(d);
  if (ret != LIBDEFLATE_SUCCESS) return {};

  return result;
}

std::string parse_ifo_value(const std::string& content, const std::string& key) {
  std::istringstream stream(content);
  std::string line;
  while (std::getline(stream, line)) {
    if (line.starts_with(key + "=")) {
      return line.substr(key.size() + 1);
    }
  }
  return "";
}

}  // namespace

StardictResult stardict_reader::parse(const std::string& ifo_path) {
  auto ifo_data = read_file(ifo_path);
  if (ifo_data.empty()) throw std::runtime_error("stardict: failed to read .ifo");

  std::string ifo_content(reinterpret_cast<char*>(ifo_data.data()), ifo_data.size());
  std::string bookname = parse_ifo_value(ifo_content, "bookname");
  if (bookname.empty()) {
    bookname = std::filesystem::path(ifo_path).stem().string();
  }

  std::string base = ifo_path.substr(0, ifo_path.size() - 4);
  auto idx_data = read_file(base + ".idx");
  if (idx_data.empty()) throw std::runtime_error("stardict: failed to read .idx");

  std::vector<uint8_t> dict_data;
  auto dict_dz = read_file(base + ".dict.dz");
  if (!dict_dz.empty()) {
    dict_data = decompress_gz(dict_dz.data(), dict_dz.size());
    if (dict_data.empty()) throw std::runtime_error("stardict: failed to decompress .dict.dz");
  } else {
    dict_data = read_file(base + ".dict");
    if (dict_data.empty()) throw std::runtime_error("stardict: failed to read .dict");
  }

  return parse_from_data(bookname, idx_data.data(), idx_data.size(),
                         dict_data.data(), dict_data.size());
}

StardictResult stardict_reader::parse_from_data(
    const std::string& bookname,
    const uint8_t* idx_data, size_t idx_size,
    const uint8_t* dict_data, size_t dict_size) {
  StardictResult result;
  result.bookname = bookname;

  size_t pos = 0;
  while (pos < idx_size) {
    const char* word_start = reinterpret_cast<const char*>(idx_data + pos);
    size_t word_len = 0;
    while (pos + word_len < idx_size && idx_data[pos + word_len] != 0) word_len++;
    if (pos + word_len >= idx_size) break;

    std::string word(word_start, word_len);
    pos += word_len + 1;

    if (pos + 8 > idx_size) break;

    uint32_t offset = (uint32_t(idx_data[pos]) << 24) | (uint32_t(idx_data[pos + 1]) << 16) |
                      (uint32_t(idx_data[pos + 2]) << 8) | idx_data[pos + 3];
    pos += 4;
    uint32_t size = (uint32_t(idx_data[pos]) << 24) | (uint32_t(idx_data[pos + 1]) << 16) |
                    (uint32_t(idx_data[pos + 2]) << 8) | idx_data[pos + 3];
    pos += 4;

    if (offset + size > dict_size) continue;

    std::string definition(reinterpret_cast<const char*>(dict_data + offset), size);
    while (!definition.empty() && definition.back() == '\0') definition.pop_back();

    if (!word.empty() && !definition.empty()) {
      result.entries.push_back({std::move(word), std::move(definition)});
    }
  }

  return result;
}
