// BUG-3277: entry names carried in the Info-ZIP Unicode Path Extra Field.
//
// A Yomitan dictionary zipped by an archiver that does not set general-purpose
// bit 11 stores each raw name in the local code page (the reported
// "JA-JA 大辞林　第四版.zip": Shift-JIS, e.g. "daijirin2/\x88\xea-default.svg")
// and the real UTF-8 name in extra field 0x7075:
//   <id 0x7075:u16><size:u16><version=1:u8><crc32(raw name):u32><UTF-8 name>
// Zip took the raw bytes, so media.bin was keyed by Shift-JIS paths while the
// term bank's {"tag":"img","path":"daijirin2/一-default.svg"} looks up UTF-8:
// all 24 tag icons / gaiji images of that dictionary rendered as nothing.
//
// Pins (APPNOTE 4.6.9):
//   * bit 11 clear + 0x7075 v1 + CRC match  -> UTF-8 name (import e2e: the
//     media is reachable by the UTF-8 path and NOT by the raw bytes);
//   * CRC mismatch (stale field)            -> raw name;
//   * bit 11 set                            -> raw name (already UTF-8);
//   * unknown version / overrunning record  -> raw name, archive still opens;
//   * 0x7075 after an unrelated record in the same block still applies.
//
// Red/green: make resolve_entry_name() in zip.cpp return the raw name
// unconditionally and the e2e + Zip-level positive cases go red (measured).
//
// Usage: zip_unicode_path_extra_test  (no args) -> exit 0 PASS, non-zero FAIL.
#include <cstdint>
#include <cstdio>
#include <string>
#include <vector>

#include "fushidicts/importer.hpp"
#include "fushidicts/query.hpp"
#include "zip/zip.hpp"
#include "zip_fixture.hpp"

namespace {

int g_fail = 0;

void fail(const std::string& msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg.c_str());
  ++g_fail;
}

// Independent bitwise CRC-32 (IEEE, reflected) so the fixture does not share
// the implementation under test.
uint32_t crc32_ieee(const std::string& s) {
  uint32_t crc = 0xFFFFFFFFu;
  for (unsigned char c : s) {
    crc ^= c;
    for (int k = 0; k < 8; ++k) {
      crc = (crc >> 1) ^ (0xEDB88320u & (0u - (crc & 1u)));
    }
  }
  return ~crc;
}

void put16(std::string& b, uint16_t v) {
  b.push_back(static_cast<char>(v & 0xff));
  b.push_back(static_cast<char>((v >> 8) & 0xff));
}

void put32(std::string& b, uint32_t v) {
  for (int i = 0; i < 4; ++i) b.push_back(static_cast<char>((v >> (8 * i)) & 0xff));
}

// One 0x7075 record. [crc] defaults to the correct CRC of [raw_name].
std::string unicode_path_extra(const std::string& raw_name, const std::string& utf8_name,
                               uint8_t version = 1, const uint32_t* crc = nullptr) {
  std::string rec;
  put16(rec, 0x7075);
  put16(rec, static_cast<uint16_t>(5 + utf8_name.size()));
  rec.push_back(static_cast<char>(version));
  put32(rec, crc ? *crc : crc32_ieee(raw_name));
  rec += utf8_name;
  return rec;
}

std::string index_json(const char* title) {
  return std::string("{\"title\":\"") + title + "\",\"format\":3,\"revision\":\"test\"}";
}

// [[expr, reading, defTags, rules, score, [glossary], seq, termTags]]
std::string term_bank() {
  return "[[\"\xE6\x97\xA5\",\"\xE3\x81\xB2\",\"\",\"\",0,[\"sun\"],0,\"\"]]";
}

// The two shapes seen in the reported dictionary.
const std::string kRawIcon = "daijirin2/\x88\xea-default.svg";                   // Shift-JIS 一
const std::string kUtf8Icon = "daijirin2/\xE4\xB8\x80-default.svg";              // UTF-8 一
const std::string kRawGaiji = "daijirin2/gaiji/U\x8c|E0102.svg";                 // Shift-JIS 芸
const std::string kUtf8Gaiji = "daijirin2/gaiji/U\xE8\x8A\xB8" "E0102.svg";      // UTF-8 芸

std::vector<std::string> zip_names(const std::string& path) {
  std::vector<std::string> out;
  Zip z;
  if (!z.open(path)) {
    fail("Zip::open failed for " + path);
    return out;
  }
  // Full entry names: these single-directory fixtures would otherwise have
  // their shared "daijirin2/" peeled by root_prefix.
  for (const auto& e : z.entries) out.push_back(e.name);
  return out;
}

void expect_name(const std::vector<std::string>& names, size_t i, const std::string& want,
                 const char* label) {
  if (i >= names.size() || names[i] != want) {
    fail(std::string(label) + ": entry " + std::to_string(i) + " = '" +
         (i < names.size() ? names[i] : std::string("<missing>")) + "' want '" + want + "'");
  }
}

}  // namespace

int main() {
  const std::string tmp = fushi_test::temp_dir();
  const std::string icon_svg = "<svg id=\"icon\"/>";
  const std::string gaiji_svg = "<svg id=\"gaiji\"/>";

  // --- e2e: import, then the media is found by its UTF-8 path.
  {
    const char* kTitle = "UnicodePathExtra";
    const std::string out_dir = tmp + "/fushi_unicode_path_extra_out";
    std::vector<fushi_test::ZipFile> files = {
        {"index.json", index_json(kTitle)},
        {"term_bank_1.json", term_bank()},
        {kRawIcon, icon_svg, unicode_path_extra(kRawIcon, kUtf8Icon)},
        {kRawGaiji, gaiji_svg, unicode_path_extra(kRawGaiji, kUtf8Gaiji)},
    };
    const std::string zip_path = fushi_test::write_zip("unicode_path_extra", files);
    if (zip_path.empty()) {
      fail("could not write fixture zip");
    } else {
      ImportResult r = dictionary_importer::import(zip_path, out_dir);
      if (!r.success) {
        fail(std::string("import: ") + (r.errors.empty() ? "(no error)" : r.errors.front()));
      } else {
        if (r.media_count != 2) fail("media_count " + std::to_string(r.media_count) + " want 2");
        DictionaryQuery q;
        q.add_term_dict(out_dir + "/" + r.title);
        auto icon = q.get_media_file(r.title, kUtf8Icon);
        if (std::string(icon.begin(), icon.end()) != icon_svg) {
          fail("icon not reachable by UTF-8 path (" + std::to_string(icon.size()) + " bytes)");
        }
        auto gaiji = q.get_media_file(r.title, kUtf8Gaiji);
        if (std::string(gaiji.begin(), gaiji.end()) != gaiji_svg) {
          fail("gaiji not reachable by UTF-8 path (" + std::to_string(gaiji.size()) + " bytes)");
        }
        if (!q.get_media_file(r.title, kRawIcon).empty()) {
          fail("media still keyed by the raw Shift-JIS path");
        }
      }
    }
  }

  // --- Zip level: each rule of APPNOTE 4.6.9.
  {
    const uint32_t bad_crc = crc32_ieee(kRawIcon) ^ 0x1u;
    std::string overrun;  // a 0x7075 header claiming more bytes than the block has
    put16(overrun, 0x7075);
    put16(overrun, 200);
    overrun += std::string("\x01\x00\x00\x00\x00", 5);
    std::vector<fushi_test::ZipFile> files = {
        {kRawIcon, "a", unicode_path_extra(kRawIcon, kUtf8Icon)},                    // 0 match
        {kRawIcon + "2", "b", unicode_path_extra(kRawIcon + "2", kUtf8Icon, 1, &bad_crc)},  // 1
        {kRawIcon + "3", "c", unicode_path_extra(kRawIcon + "3", kUtf8Icon), 1u << 11},     // 2
        {kRawIcon + "4", "d", unicode_path_extra(kRawIcon + "4", kUtf8Icon, 2)},            // 3
        {kRawIcon + "5", "e", overrun},                                                     // 4
        {kRawIcon + "6", "f", unicode_path_extra(kRawIcon + "6", "")},                      // 5
    };
    const std::string zip_path = fushi_test::write_zip("unicode_path_rules", files);
    if (zip_path.empty()) {
      fail("could not write rules fixture zip");
    } else {
      const auto names = zip_names(zip_path);
      expect_name(names, 0, kUtf8Icon, "CRC match -> UTF-8 name");
      expect_name(names, 1, kRawIcon + "2", "CRC mismatch -> raw name");
      expect_name(names, 2, kRawIcon + "3", "bit 11 set -> raw name");
      expect_name(names, 3, kRawIcon + "4", "unknown version -> raw name");
      expect_name(names, 4, kRawIcon + "5", "overrunning record -> raw name");
      expect_name(names, 5, kRawIcon + "6", "empty UTF-8 name -> raw name");
    }
  }

  // --- 0x7075 placed after an unrelated record in the same block still applies.
  {
    std::string extra;
    put16(extra, 0x5455);  // extended timestamp, 5 bytes
    put16(extra, 5);
    extra += std::string("\x01\x00\x00\x00\x00", 5);
    extra += unicode_path_extra(kRawGaiji, kUtf8Gaiji);
    const std::string zip_path =
        fushi_test::write_zip("unicode_path_second", {{kRawGaiji, "g", extra}});
    if (zip_path.empty()) {
      fail("could not write second-record fixture zip");
    } else {
      expect_name(zip_names(zip_path), 0, kUtf8Gaiji, "0x7075 after another record");
    }
  }

  if (g_fail) {
    std::fprintf(stderr, "zip_unicode_path_extra_test: %d failure(s)\n", g_fail);
    return 1;
  }
  std::printf("zip_unicode_path_extra_test: PASS\n");
  return 0;
}
