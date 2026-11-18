#include "meta_record.hpp"

#include <cstring>
#include <limits>
#include <string>

namespace meta_record {
namespace {

constexpr size_t kU16Max = std::numeric_limits<uint16_t>::max();

template <typename T>
void put(std::vector<char>& out, T value) {
  const size_t at = out.size();
  out.resize(at + sizeof(T));
  std::memcpy(out.data() + at, &value, sizeof(T));
}

void put_bytes(std::vector<char>& out, std::string_view s) {
  out.insert(out.end(), s.begin(), s.end());
}

void put_str16(std::vector<char>& out, std::string_view s) {
  put<uint16_t>(out, static_cast<uint16_t>(s.size()));
  put_bytes(out, s);
}

void put_ints(std::vector<char>& out, const std::vector<int>& values) {
  put<uint16_t>(out, static_cast<uint16_t>(values.size()));
  for (int v : values) {
    put<int32_t>(out, static_cast<int32_t>(v));
  }
}

void put_prefix(std::vector<char>& out, uint8_t type, std::string_view expr, std::string_view mode) {
  put<uint8_t>(out, type);
  put<uint16_t>(out, static_cast<uint16_t>(expr.size()));
  put_bytes(out, expr);
  put<uint8_t>(out, static_cast<uint8_t>(mode.size()));
  put_bytes(out, mode);
}

// 预解析的载荷（mode 之后的部分）；false = 解析失败或放不进 u16 字段，调用方写 type 1。
bool parsed_payload(std::string_view mode, std::string_view data, std::vector<char>& payload) {
  if (mode == "freq") {
    ParsedFrequency f;
    if (!yomitan_parser::parse_frequency(data, f) || f.reading.size() > kU16Max || f.display_value.size() > kU16Max) {
      return false;
    }
    put_str16(payload, f.reading);
    put<int32_t>(payload, static_cast<int32_t>(f.value));
    put_str16(payload, f.display_value);
    return true;
  }
  if (mode == "pitch") {
    ParsedPitch p;
    if (!yomitan_parser::parse_pitch(data, p) || p.reading.size() > kU16Max || p.pitches.size() > kU16Max) {
      return false;
    }
    put_str16(payload, p.reading);
    put<uint16_t>(payload, static_cast<uint16_t>(p.pitches.size()));
    for (const ParsedAccent& a : p.pitches) {
      if (a.pattern.size() > kU16Max || a.nasal.size() > kU16Max || a.devoice.size() > kU16Max) {
        return false;
      }
      put<int32_t>(payload, static_cast<int32_t>(a.position));
      put_str16(payload, a.pattern);
      put_ints(payload, a.nasal);
      put_ints(payload, a.devoice);
    }
    return true;
  }
  if (mode == "ipa") {
    ParsedPitch p;
    if (!yomitan_parser::parse_ipa(data, p) || p.reading.size() > kU16Max || p.transcriptions.size() > kU16Max) {
      return false;
    }
    put_str16(payload, p.reading);
    put<uint16_t>(payload, static_cast<uint16_t>(p.transcriptions.size()));
    for (std::string_view t : p.transcriptions) {
      if (t.size() > kU16Max) {
        return false;
      }
      put_str16(payload, t);
    }
    return true;
  }
  return false;
}

struct Reader {
  const uint8_t* p;
  const uint8_t* end;
  bool ok = true;

  template <typename T>
  T read() {
    if (!ok || static_cast<size_t>(end - p) < sizeof(T)) {
      ok = false;
      return T{};
    }
    T v;
    std::memcpy(&v, p, sizeof(T));
    p += sizeof(T);
    return v;
  }

  std::string_view str(size_t n) {
    if (!ok || static_cast<size_t>(end - p) < n) {
      ok = false;
      return {};
    }
    std::string_view s(reinterpret_cast<const char*>(p), n);
    p += n;
    return s;
  }

  std::string_view str16() { return str(read<uint16_t>()); }

  std::vector<int> ints() {
    const uint16_t n = read<uint16_t>();
    std::vector<int> out;
    if (!ok || static_cast<size_t>(end - p) < size_t{n} * sizeof(int32_t)) {
      ok = false;
      return out;
    }
    out.reserve(n);
    for (uint16_t i = 0; i < n; i++) {
      out.push_back(static_cast<int>(read<int32_t>()));
    }
    return out;
  }
};

// type 1：[u32 data_len][data]。
std::string_view raw_data(const uint8_t* p, const uint8_t* end, bool& ok) {
  Reader r{p, end};
  const uint32_t n = r.read<uint32_t>();
  std::string_view s = r.str(n);
  ok = r.ok;
  return s;
}

}  // namespace

uint8_t append(std::vector<char>& out, std::string_view expr, std::string_view mode, std::string_view data,
               bool allow_parsed) {
  // expr / mode 超长时的写法与改动前逐字节相同（长度字段截断），只在 type 1 上出现。
  if (allow_parsed && expr.size() <= kU16Max && mode.size() <= std::numeric_limits<uint8_t>::max()) {
    std::vector<char> payload;
    if (parsed_payload(mode, data, payload)) {
      put_prefix(out, kParsedType, expr, mode);
      out.insert(out.end(), payload.begin(), payload.end());
      return kParsedType;
    }
  }
  put_prefix(out, kRawType, expr, mode);
  put<uint32_t>(out, static_cast<uint32_t>(data.size()));
  put_bytes(out, data);
  return kRawType;
}

bool read_frequency(uint8_t type, const uint8_t* p, const uint8_t* end, ParsedFrequency& out) {
  if (type == kRawType) {
    bool ok = false;
    const std::string_view data = raw_data(p, end, ok);
    return yomitan_parser::parse_frequency(data, out);
  }
  if (type != kParsedType) {
    return false;
  }
  Reader r{p, end};
  out.reading = r.str16();
  out.value = static_cast<int>(r.read<int32_t>());
  out.display_value = std::string(r.str16());
  return r.ok;
}

bool read_pitch(uint8_t type, const uint8_t* p, const uint8_t* end, ParsedPitch& out) {
  if (type == kRawType) {
    bool ok = false;
    const std::string_view data = raw_data(p, end, ok);
    return yomitan_parser::parse_pitch(data, out);
  }
  if (type != kParsedType) {
    return false;
  }
  Reader r{p, end};
  out.reading = r.str16();
  const uint16_t n = r.read<uint16_t>();
  for (uint16_t i = 0; i < n && r.ok; i++) {
    ParsedAccent a;
    a.position = static_cast<int>(r.read<int32_t>());
    a.pattern = std::string(r.str16());
    a.nasal = r.ints();
    a.devoice = r.ints();
    if (r.ok) {
      out.pitches.push_back(std::move(a));
    }
  }
  return r.ok;
}

bool read_ipa(uint8_t type, const uint8_t* p, const uint8_t* end, ParsedPitch& out) {
  if (type == kRawType) {
    bool ok = false;
    const std::string_view data = raw_data(p, end, ok);
    return yomitan_parser::parse_ipa(data, out);
  }
  if (type != kParsedType) {
    return false;
  }
  Reader r{p, end};
  out.reading = r.str16();
  const uint16_t n = r.read<uint16_t>();
  for (uint16_t i = 0; i < n && r.ok; i++) {
    const std::string_view t = r.str16();
    if (r.ok) {
      out.transcriptions.push_back(t);
    }
  }
  return r.ok;
}

}  // namespace meta_record
