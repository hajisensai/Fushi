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
// Also covers the shapes real archives arrive in: a macOS Finder "Compress"
// package (__MACOSX/ resource forks + .DS_Store), two nested wrapper layers,
// explicit directory-marker entries, and a stray empty directory next to the
// dictionary -- plus the negative case, an archive whose entries genuinely fan
// out into two top-level directories.
//
// Red/green: match zip.entries[i].name instead of zip.logical_name(i) in
// get_files/find and the wrapped cases fail; disable any single skip/fan-out
// condition in compute_root_prefix() and exactly one case below goes red
// (measured, see BUG-2053).
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
  //
  // The layout matters. An earlier version of this case put index.json under
  // "a/" and the bank under "b/", which passed even with the fan-out check
  // disabled: peeling "a/" still left the bank outside the prefix, so the import
  // failed for an UNRELATED reason ("empty dictionary") and this assertion never
  // saw the difference. Here the dictionary is complete under "a/", so a broken
  // fan-out check peels "a/", imports a real dictionary and swallows
  // "b/readme.txt" as media -- r.success flips and the guard bites.
  {
    const std::string out_dir = tmp + "/fushi_two_roots_out";
    std::vector<fushi_test::ZipFile> files = {
        {"a/index.json", index_json("TwoRoots")},
        {"a/term_bank_1.json", term_bank()},
        {"b/readme.txt", "not part of the dictionary"},
    };
    const std::string zip_path = fushi_test::write_zip("two_roots", files);
    if (zip_path.empty()) {
      fail("could not write two-root fixture zip");
    } else {
      ImportResult r = dictionary_importer::import(zip_path, out_dir);
      if (r.success) {
        fail(
            "entries fanning out into two top-level directories were wrongly peeled: "
            "\"a/\" was stripped into a dictionary and \"b/\" swallowed as media");
      }
    }
  }

  // --- BUG-2053: macOS Finder "Compress" emits an __MACOSX/ AppleDouble tree
  // alongside the folder. That is a second top-level directory, so the archive
  // used to fan out, keep its wrapper and fail with "unsupported dictionary
  // format" -- on the single most likely way a Mac user re-zips a dictionary.
  // __MACOSX/ is skipped when computing the prefix AND excluded from the media,
  // since a resource fork is not dictionary media.
  {
    const char* kTitle = "MacZipped";
    const std::string out_dir = tmp + "/fushi_macosx_out";
    const std::string apple_double = std::string("\x00\x05\x16\x07", 4) + "rsrc";
    std::vector<fushi_test::ZipFile> files = {
        {"MacZipped/index.json", index_json(kTitle)},
        {"MacZipped/term_bank_1.json", term_bank()},
        {"MacZipped/img/sun.png", sun_png},
        {"__MACOSX/._MacZipped", apple_double},
        {"__MACOSX/MacZipped/._index.json", apple_double},
        {"__MACOSX/MacZipped/._term_bank_1.json", apple_double},
    };
    const std::string zip_path = fushi_test::write_zip("macosx_zip", files);
    if (zip_path.empty()) {
      fail("could not write __MACOSX fixture zip");
    } else {
      ImportResult r = dictionary_importer::import(zip_path, out_dir);
      if (!r.success) {
        std::fprintf(stderr, "FAIL __MACOSX import: %s\n",
                     r.errors.empty() ? "(no error)" : r.errors.front().c_str());
        ++g_fail;
      } else {
        if (r.detected_type != "term") {
          std::fprintf(stderr, "FAIL __MACOSX type: got '%s' want 'term'\n",
                       r.detected_type.c_str());
          ++g_fail;
        }
        if (r.media_count != 1) {
          std::fprintf(stderr,
                       "FAIL __MACOSX media_count: got %zu want 1 (resource forks must not "
                       "be stored as media)\n",
                       r.media_count);
          ++g_fail;
        }
        DictionaryQuery q;
        q.add_term_dict(out_dir + "/" + r.title);
        std::vector<char> png = q.get_media_file(r.title, "img/sun.png");
        if (std::string(png.begin(), png.end()) != sun_png) {
          fail("__MACOSX archive lost the dictionary-relative media key");
        }
      }
    }
  }

  // --- BUG-2053: Finder also drops a ".DS_Store" next to the compressed folder.
  // A root-level *file* ends the peel outright, so "MyDict/ + .DS_Store" kept its
  // wrapper and failed the same way. Skipped by exact basename (both at the root
  // and inside the dictionary), and never stored as media.
  {
    const char* kTitle = "DsStoreZipped";
    const std::string out_dir = tmp + "/fushi_dsstore_out";
    const std::string ds = std::string("\x00\x00\x00\x01", 4) + "Bud1";
    std::vector<fushi_test::ZipFile> files = {
        {".DS_Store", ds},
        {"DsStoreZipped/index.json", index_json(kTitle)},
        {"DsStoreZipped/term_bank_1.json", term_bank()},
        {"DsStoreZipped/.DS_Store", ds},
    };
    const std::string zip_path = fushi_test::write_zip("dsstore_zip", files);
    if (zip_path.empty()) {
      fail("could not write .DS_Store fixture zip");
    } else {
      ImportResult r = dictionary_importer::import(zip_path, out_dir);
      if (!r.success) {
        std::fprintf(stderr, "FAIL .DS_Store import: %s\n",
                     r.errors.empty() ? "(no error)" : r.errors.front().c_str());
        ++g_fail;
      } else if (r.media_count != 0) {
        std::fprintf(stderr, "FAIL .DS_Store media_count: got %zu want 0\n", r.media_count);
        ++g_fail;
      }
    }
  }

  // --- Nesting: extracting an already-wrapped dictionary and zipping the outer
  // folder again gives "MyDict/MyDict-v2/index.json". The peel repeats, so this
  // must behave exactly like a single layer.
  {
    const char* kTitle = "NestedTwice";
    const std::string out_dir = tmp + "/fushi_nested_out";
    std::vector<fushi_test::ZipFile> files = {
        {"NestedTwice/NestedTwice-v2/index.json", index_json(kTitle)},
        {"NestedTwice/NestedTwice-v2/term_bank_1.json", term_bank()},
        {"NestedTwice/NestedTwice-v2/img/sun.png", sun_png},
    };
    const std::string zip_path = fushi_test::write_zip("nested_wrap", files);
    if (zip_path.empty()) {
      fail("could not write nested fixture zip");
    } else {
      ImportResult r = dictionary_importer::import(zip_path, out_dir);
      if (!r.success) {
        std::fprintf(stderr, "FAIL nested import: %s\n",
                     r.errors.empty() ? "(no error)" : r.errors.front().c_str());
        ++g_fail;
      } else {
        DictionaryQuery q;
        q.add_term_dict(out_dir + "/" + r.title);
        std::vector<char> png = q.get_media_file(r.title, "img/sun.png");
        if (std::string(png.begin(), png.end()) != sun_png) {
          fail("two nested wrapper directories were not both peeled off the media key");
        }
      }
    }
  }

  // --- Explicit directory-marker entries ("MyDict/", "MyDict/img/"), which most
  // real zip writers emit. They carry no payload, so they must not decide the
  // prefix nor be counted as media.
  //
  // "scratch/" is the part that bites: a stray empty directory zipped next to
  // the dictionary is a second top-level *name* but no payload at all. Counting
  // directory markers makes the archive look like it fans out, so the wrapper
  // stays on and the import fails -- even though every actual file sits under
  // "DirMarkers/".
  {
    const char* kTitle = "DirMarkers";
    const std::string out_dir = tmp + "/fushi_dir_markers_out";
    std::vector<fushi_test::ZipFile> files = {
        {"scratch/", ""},
        {"DirMarkers/", ""},
        {"DirMarkers/img/", ""},
        {"DirMarkers/index.json", index_json(kTitle)},
        {"DirMarkers/term_bank_1.json", term_bank()},
        {"DirMarkers/img/sun.png", sun_png},
    };
    const std::string zip_path = fushi_test::write_zip("dir_markers", files);
    if (zip_path.empty()) {
      fail("could not write directory-marker fixture zip");
    } else {
      ImportResult r = dictionary_importer::import(zip_path, out_dir);
      if (!r.success) {
        std::fprintf(stderr, "FAIL dir-marker import: %s\n",
                     r.errors.empty() ? "(no error)" : r.errors.front().c_str());
        ++g_fail;
      } else {
        if (r.media_count != 1) {
          std::fprintf(stderr, "FAIL dir-marker media_count: got %zu want 1\n", r.media_count);
          ++g_fail;
        }
        DictionaryQuery q;
        q.add_term_dict(out_dir + "/" + r.title);
        std::vector<char> png = q.get_media_file(r.title, "img/sun.png");
        if (std::string(png.begin(), png.end()) != sun_png) {
          fail("directory-marker entries broke the media key");
        }
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
