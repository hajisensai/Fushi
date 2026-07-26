#pragma once

#include <cstddef>
#include <cstdint>
#include <string>
#include <vector>

namespace hibiki_voice_hook {

struct AsarVoiceEntry {
  uint64_t archive_offset = 0;
  uint64_t byte_len = 0;
  std::string path;
};

class AsarJsonCursor {
 public:
  AsarJsonCursor(const char* data, size_t size) : data_(data), size_(size) {}

  bool ParseVoiceEntries(uint64_t data_base,
                         std::vector<AsarVoiceEntry>* entries) {
    if (entries == nullptr || !Consume('{')) return false;
    bool found_files = false;
    while (true) {
      SkipWhitespace();
      if (Consume('}')) return found_files;
      std::string key;
      if (!ParseString(&key) || !Consume(':')) return false;
      if (key == "files") {
        if (!ParseFilesObject("", data_base, entries, 0)) return false;
        found_files = true;
      } else if (!SkipValue(0)) {
        return false;
      }
      SkipWhitespace();
      if (Consume('}')) return found_files;
      if (!Consume(',')) return false;
    }
  }

 private:
  static bool IsVoiceAudioPath(const std::string& path) {
    std::string lower;
    lower.reserve(path.size());
    for (char value : path) {
      lower.push_back(value >= 'A' && value <= 'Z'
                          ? static_cast<char>(value - 'A' + 'a')
                          : value);
    }
    const bool voice_dir =
        lower.find("data/sound/v_") != std::string::npos;
    if (!voice_dir || lower.size() < 4) return false;
    return lower.compare(lower.size() - 4, 4, ".ogg") == 0 ||
           lower.compare(lower.size() - 4, 4, ".m4a") == 0;
  }

  void SkipWhitespace() {
    while (position_ < size_) {
      const char value = data_[position_];
      if (value != ' ' && value != '\t' && value != '\r' && value != '\n') {
        break;
      }
      ++position_;
    }
  }

  bool Consume(char expected) {
    SkipWhitespace();
    if (position_ >= size_ || data_[position_] != expected) return false;
    ++position_;
    return true;
  }

  bool ParseString(std::string* value) {
    if (value == nullptr || !Consume('"')) return false;
    value->clear();
    while (position_ < size_) {
      char current = data_[position_++];
      if (current == '"') return true;
      if (current != '\\') {
        value->push_back(current);
        continue;
      }
      if (position_ >= size_) return false;
      const char escaped = data_[position_++];
      switch (escaped) {
        case '"':
        case '\\':
        case '/':
          value->push_back(escaped);
          break;
        case 'b': value->push_back('\b'); break;
        case 'f': value->push_back('\f'); break;
        case 'n': value->push_back('\n'); break;
        case 'r': value->push_back('\r'); break;
        case 't': value->push_back('\t'); break;
        case 'u':
          // ASAR resource paths relevant to the voice matcher are ASCII. Keep
          // escaped non-ASCII names parseable without expanding UTF-16 here.
          if (size_ - position_ < 4) return false;
          position_ += 4;
          value->push_back('?');
          break;
        default:
          return false;
      }
    }
    return false;
  }

  bool ParseUnsigned(uint64_t* value) {
    if (value == nullptr) return false;
    SkipWhitespace();
    if (position_ >= size_ || data_[position_] < '0' ||
        data_[position_] > '9') {
      return false;
    }
    uint64_t parsed = 0;
    while (position_ < size_ && data_[position_] >= '0' &&
           data_[position_] <= '9') {
      const uint64_t digit = static_cast<uint64_t>(data_[position_] - '0');
      if (parsed > (UINT64_MAX - digit) / 10u) return false;
      parsed = parsed * 10u + digit;
      ++position_;
    }
    *value = parsed;
    return true;
  }

  static bool DecimalStringToUnsigned(const std::string& text,
                                      uint64_t* value) {
    if (value == nullptr || text.empty()) return false;
    uint64_t parsed = 0;
    for (char current : text) {
      if (current < '0' || current > '9') return false;
      const uint64_t digit = static_cast<uint64_t>(current - '0');
      if (parsed > (UINT64_MAX - digit) / 10u) return false;
      parsed = parsed * 10u + digit;
    }
    *value = parsed;
    return true;
  }

  bool ParseFilesObject(const std::string& prefix, uint64_t data_base,
                        std::vector<AsarVoiceEntry>* entries, int depth) {
    if (depth > 32 || !Consume('{')) return false;
    while (true) {
      SkipWhitespace();
      if (Consume('}')) return true;
      std::string name;
      if (!ParseString(&name) || !Consume(':')) return false;
      const std::string path = prefix.empty() ? name : prefix + "/" + name;
      if (!ParseEntryObject(path, data_base, entries, depth + 1)) return false;
      SkipWhitespace();
      if (Consume('}')) return true;
      if (!Consume(',')) return false;
    }
  }

  bool ParseEntryObject(const std::string& path, uint64_t data_base,
                        std::vector<AsarVoiceEntry>* entries, int depth) {
    if (depth > 32 || !Consume('{')) return false;
    uint64_t size = 0;
    uint64_t relative_offset = 0;
    bool has_size = false;
    bool has_offset = false;
    while (true) {
      SkipWhitespace();
      if (Consume('}')) break;
      std::string key;
      if (!ParseString(&key) || !Consume(':')) return false;
      if (key == "files") {
        if (!ParseFilesObject(path, data_base, entries, depth + 1)) return false;
      } else if (key == "size") {
        has_size = ParseUnsigned(&size);
        if (!has_size) return false;
      } else if (key == "offset") {
        std::string offset_text;
        if (!ParseString(&offset_text) ||
            !DecimalStringToUnsigned(offset_text, &relative_offset)) {
          return false;
        }
        has_offset = true;
      } else if (!SkipValue(depth + 1)) {
        return false;
      }
      SkipWhitespace();
      if (Consume('}')) break;
      if (!Consume(',')) return false;
    }
    if (has_size && has_offset && size > 0 && size <= 32u * 1024u * 1024u &&
        relative_offset <= UINT64_MAX - data_base && IsVoiceAudioPath(path)) {
      entries->push_back({data_base + relative_offset, size, path});
    }
    return true;
  }

  bool SkipValue(int depth) {
    if (depth > 64) return false;
    SkipWhitespace();
    if (position_ >= size_) return false;
    if (data_[position_] == '"') {
      std::string ignored;
      return ParseString(&ignored);
    }
    if (data_[position_] == '{') {
      ++position_;
      SkipWhitespace();
      if (Consume('}')) return true;
      while (true) {
        std::string ignored;
        if (!ParseString(&ignored) || !Consume(':') || !SkipValue(depth + 1)) {
          return false;
        }
        SkipWhitespace();
        if (Consume('}')) return true;
        if (!Consume(',')) return false;
      }
    }
    if (data_[position_] == '[') {
      ++position_;
      SkipWhitespace();
      if (Consume(']')) return true;
      while (true) {
        if (!SkipValue(depth + 1)) return false;
        SkipWhitespace();
        if (Consume(']')) return true;
        if (!Consume(',')) return false;
      }
    }
    const size_t start = position_;
    while (position_ < size_) {
      const char current = data_[position_];
      if (current == ',' || current == '}' || current == ']' ||
          current == ' ' || current == '\t' || current == '\r' ||
          current == '\n') {
        break;
      }
      ++position_;
    }
    return position_ > start;
  }

  const char* data_ = nullptr;
  size_t size_ = 0;
  size_t position_ = 0;
};

inline bool ParseAsarVoiceEntries(const char* json, size_t size,
                                  uint64_t data_base,
                                  std::vector<AsarVoiceEntry>* entries) {
  if (json == nullptr || size == 0 || entries == nullptr) return false;
  entries->clear();
  AsarJsonCursor cursor(json, size);
  return cursor.ParseVoiceEntries(data_base, entries);
}

}  // namespace hibiki_voice_hook
