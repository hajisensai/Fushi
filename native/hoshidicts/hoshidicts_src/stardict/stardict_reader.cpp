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
  std::string prefix = key + "=";
  std::istringstream stream(content);
  std::string line;
  while (std::getline(stream, line)) {
    if (!line.empty() && line.back() == '\r') line.pop_back();
    if (line.starts_with(prefix)) {
      return line.substr(prefix.size());
    }
  }
  return "";
}

bool is_text_type(char c) {
  return c == 'm' || c == 'l' || c == 'g' || c == 't' ||
         c == 'x' || c == 'h' || c == 'k' || c == 'w' || c == 'y';
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

  std::string sametypesequence = parse_ifo_value(ifo_content, "sametypesequence");

  auto result = parse_from_data(bookname, idx_data.data(), idx_data.size(),
                                dict_data.data(), dict_data.size(), sametypesequence);

  // Read .syn (synonym) file if present
  auto syn_data = read_file(base + ".syn");
  if (!syn_data.empty()) {
    size_t pos = 0;
    while (pos < syn_data.size()) {
      const char* word_start = reinterpret_cast<const char*>(syn_data.data() + pos);
      size_t word_len = 0;
      while (pos + word_len < syn_data.size() && syn_data[pos + word_len] != 0) word_len++;
      if (pos + word_len >= syn_data.size()) break;
      std::string synonym(word_start, word_len);
      pos += word_len + 1;

      if (pos + 4 > syn_data.size()) break;
      uint32_t target_idx = (uint32_t(syn_data[pos]) << 24) | (uint32_t(syn_data[pos + 1]) << 16) |
                            (uint32_t(syn_data[pos + 2]) << 8) | syn_data[pos + 3];
      pos += 4;

      if (!synonym.empty() && target_idx < result.entries.size()) {
        result.entries.push_back({std::move(synonym), result.entries[target_idx].definition});
      }
    }
  }

  std::erase_if(result.entries, [](const StardictEntry& e) {
    return e.word.empty() || e.definition.empty();
  });

  return result;
}

StardictResult stardict_reader::parse_from_data(
    const std::string& bookname,
    const uint8_t* idx_data, size_t idx_size,
    const uint8_t* dict_data, size_t dict_size,
    const std::string& sametypesequence) {
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
    uint32_t entry_size = (uint32_t(idx_data[pos]) << 24) | (uint32_t(idx_data[pos + 1]) << 16) |
                          (uint32_t(idx_data[pos + 2]) << 8) | idx_data[pos + 3];
    pos += 4;

    if (entry_size > dict_size || offset > dict_size - entry_size) continue;

    std::string definition;
    if (!sametypesequence.empty()) {
      // sametypesequence: no per-entry type markers, types given by the string
      uint32_t dpos = 0;
      for (size_t ti = 0; ti < sametypesequence.size() && dpos < entry_size; ti++) {
        char type = sametypesequence[ti];
        bool last_field = (ti + 1 == sametypesequence.size());
        if (is_text_type(type)) {
          if (last_field) {
            // Last field consumes remaining bytes
            if (dpos > entry_size) break;
            if (!definition.empty()) definition += '\n';
            definition.append(reinterpret_cast<const char*>(dict_data + offset + dpos),
                              entry_size - dpos);
            dpos = entry_size;
          } else {
            // Non-last text: null-terminated
            const char* start = reinterpret_cast<const char*>(dict_data + offset + dpos);
            size_t len = 0;
            while (dpos + len < entry_size && dict_data[offset + dpos + len] != 0) len++;
            if (!definition.empty()) definition += '\n';
            definition.append(start, len);
            dpos += static_cast<uint32_t>((dpos + len < entry_size) ? len + 1 : len);
          }
        } else {
          if (last_field) {
            dpos = entry_size;
          } else {
            if (dpos + 4 > entry_size) break;
            uint32_t bsize = (uint32_t(dict_data[offset + dpos]) << 24) |
                             (uint32_t(dict_data[offset + dpos + 1]) << 16) |
                             (uint32_t(dict_data[offset + dpos + 2]) << 8) |
                             dict_data[offset + dpos + 3];
            if (bsize > entry_size - dpos - 4) break;
            dpos += 4 + bsize;
          }
        }
      }
    } else {
      // No sametypesequence: each field prefixed with a type byte
      uint32_t dpos = 0;
      while (dpos < entry_size) {
        char type = static_cast<char>(dict_data[offset + dpos]);
        dpos++;
        if (is_text_type(type)) {
          const char* start = reinterpret_cast<const char*>(dict_data + offset + dpos);
          size_t len = 0;
          while (dpos + len < entry_size && dict_data[offset + dpos + len] != 0) len++;
          if (!definition.empty()) definition += '\n';
          definition.append(start, len);
          dpos += (dpos + len < entry_size) ? len + 1 : len;
        } else {
          if (dpos + 4 > entry_size) break;
          uint32_t bsize = (uint32_t(dict_data[offset + dpos]) << 24) |
                           (uint32_t(dict_data[offset + dpos + 1]) << 16) |
                           (uint32_t(dict_data[offset + dpos + 2]) << 8) |
                           dict_data[offset + dpos + 3];
          if (bsize > entry_size - dpos - 4) break;
          dpos += 4 + bsize;
        }
      }
    }

    while (!definition.empty() && definition.back() == '\0') definition.pop_back();

    result.entries.push_back({std::move(word), std::move(definition)});
  }

  return result;
}
