// A dictionary re-zipped with a wrapper directory must import exactly like one
// zipped at the root.
//
// Extracting a Yomitan dictionary and zipping the folder back up puts every
// entry under "MyDict/". The importer matched raw entry names, so
// zip.find("index.json") missed and get_files() classified every
// term_bank_/term_meta_bank_ file as media -> no offsets -> "empty dictionary",
// or "unsupported dictionary format" before that. The Dart side meanwhile
// accepted such an archive (it matches "*/index.json"), so the user saw a bare
// "import failed" toast on a perfectly valid package.
//
// Guard: Zip exposes dictionary-relative logical names (root_prefix stripped),
// so both layouts behave identically — including media, whose stored key must
// stay "img/sun.png" and not "MyDict/img/sun.png".
//
// Red/green: match zip.entries[i].name instead of zip.logical_name(i) in
// get_files/find and the wrapped cases fail.
//
// Usage: zip_wrapper_directory_test  (no args) -> exit 0 PASS, non-zero FAIL.
#include <cstdio>
#include <string>
#include <vector>

#include "fushidicts/importer.hpp"
#include "fushidicts/query.hpp"
#include "zip_fixture.hpp"

namespace {

int g_fail = 0;

void fail(const char* msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg);
  ++g_fail;
}

std::string index_json(const char* title) {
  return std::string("{\"title\":\"") + title + "\",\"format\":3,\"revision\":\"test\"}";
}

// [[expr, reading, defTags, rules, score, [glossary], seq, termTags]]
std::string term_bank() {
  return "[[\"\xE6\x97\xA5\",\"\xE3\x81\xB2\",\"\",\"\",0,[\"sun\"],0,\"\"]]";
}

// [[expr, "freq", value]] — the shape a JPDB-style frequency package ships.
std::string freq_meta_bank() {
  return "[[\"\xE6\x97\xA5\",\"freq\",100]]";
}

}  // namespace

int main() {
  const std::string tmp = fushi_test::temp_dir();
  const std::string sun_png = std::string("\x89PNG\r\n\x1a\n", 8) + std::string("SUN", 3);

  // --- A term dictionary wrapped in a directory: imports, and its media keeps
  // the dictionary-relative key.
  {
    const char* kTitle = "WrappedTerms";
    const std::string out_dir = tmp + "/fushi_wrapped_term_out";
    std::vector<fushi_test::ZipFile> files = {
        {"WrappedTerms/index.json", index_json(kTitle)},
        {"WrappedTerms/term_bank_1.json", term_bank()},
        {"WrappedTerms/styles.css", "th{color:red}"},
        {"WrappedTerms/img/sun.png", sun_png},
    };
    const std::string zip_path = fushi_test::write_zip("wrapped_term", files);
    if (zip_path.empty()) {
      fail("could not write wrapped term fixture zip");
    } else {
      ImportResult r = dictionary_importer::import(zip_path, out_dir);
      if (!r.success) {
        std::fprintf(stderr, "FAIL wrapped term import: %s\n",
                     r.errors.empty() ? "(no error)" : r.errors.front().c_str());
        ++g_fail;
      } else {
        if (r.title != kTitle) {
          std::fprintf(stderr, "FAIL wrapped title: got '%s' want '%s'\n", r.title.c_str(), kTitle);
          ++g_fail;
        }
        if (r.detected_type != "term") {
          std::fprintf(stderr, "FAIL wrapped type: got '%s' want 'term'\n", r.detected_type.c_str());
          ++g_fail;
        }
        // styles.css must be recognised as the stylesheet, not stored as media.
        if (r.media_count != 1) {
          std::fprintf(stderr, "FAIL wrapped media_count: got %zu want 1\n", r.media_count);
          ++g_fail;
        }

        DictionaryQuery q;
        q.add_term_dict(out_dir + "/" + r.title);
        std::vector<char> png = q.get_media_file(r.title, "img/sun.png");
        if (std::string(png.begin(), png.end()) != sun_png) {
          std::fprintf(stderr, "FAIL wrapped media key: got %zu bytes for 'img/sun.png' want %zu\n",
                       png.size(), sun_png.size());
          ++g_fail;
        }
        if (!q.get_media_file(r.title, "WrappedTerms/img/sun.png").empty()) {
          fail("wrapper directory leaked into the stored media key");
        }
      }
    }
  }

  // --- A frequency-only package wrapped the same way (the reported shape):
  // every bank used to land in media_files, leaving no offsets at all.
  {
    const char* kTitle = "WrappedFreq";
    const std::string out_dir = tmp + "/fushi_wrapped_freq_out";
    std::vector<fushi_test::ZipFile> files = {
        {"[JA Freq] JPDB/index.json", index_json(kTitle)},
        {"[JA Freq] JPDB/term_meta_bank_1.json", freq_meta_bank()},
    };
    const std::string zip_path = fushi_test::write_zip("wrapped_freq", files);
    if (zip_path.empty()) {
      fail("could not write wrapped freq fixture zip");
    } else {
      ImportResult r = dictionary_importer::import(zip_path, out_dir);
      if (!r.success) {
        std::fprintf(stderr, "FAIL wrapped freq import: %s\n",
                     r.errors.empty() ? "(no error)" : r.errors.front().c_str());
        ++g_fail;
      } else if (r.detected_type != "frequency") {
        std::fprintf(stderr, "FAIL wrapped freq type: got '%s' want 'frequency'\n",
                     r.detected_type.c_str());
        ++g_fail;
      }
    }
  }

  // --- Root-level layout must keep working, and a dictionary that legitimately
  // uses subdirectories (index.json at the root + img/) must NOT be stripped.
  {
    const char* kTitle = "RootTerms";
    const std::string out_dir = tmp + "/fushi_root_term_out";
    std::vector<fushi_test::ZipFile> files = {
        {"index.json", index_json(kTitle)},
        {"term_bank_1.json", term_bank()},
        {"img/sun.png", sun_png},
    };
    const std::string zip_path = fushi_test::write_zip("root_term", files);
    if (zip_path.empty()) {
      fail("could not write root term fixture zip");
    } else {
      ImportResult r = dictionary_importer::import(zip_path, out_dir);
      if (!r.success) {
        std::fprintf(stderr, "FAIL root term import: %s\n",
                     r.errors.empty() ? "(no error)" : r.errors.front().c_str());
        ++g_fail;
      } else {
        DictionaryQuery q;
        q.add_term_dict(out_dir + "/" + r.title);
        std::vector<char> png = q.get_media_file(r.title, "img/sun.png");
        if (std::string(png.begin(), png.end()) != sun_png) {
          fail("root-level media key changed");
        }
      }
    }
  }

  // --- Two top-level directories: nothing wraps the whole archive, so no
  // prefix may be stripped and the package stays unrecognised rather than
  // silently importing half of itself.
  {
    const std::string out_dir = tmp + "/fushi_two_roots_out";
    std::vector<fushi_test::ZipFile> files = {
        {"a/index.json", index_json("TwoRoots")},
        {"b/term_bank_1.json", term_bank()},
    };
    const std::string zip_path = fushi_test::write_zip("two_roots", files);
    if (zip_path.empty()) {
      fail("could not write two-root fixture zip");
    } else {
      ImportResult r = dictionary_importer::import(zip_path, out_dir);
      if (r.success) {
        fail("an archive with two top-level directories must not be stripped into a dictionary");
      }
    }
  }

  if (g_fail) {
    std::fprintf(stderr, "%d FAIL\n", g_fail);
    return 1;
  }
  std::printf("PASS\n");
  return 0;
}
