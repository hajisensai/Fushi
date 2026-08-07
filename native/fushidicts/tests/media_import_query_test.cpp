// HBK-AUDIT-100 / media e2e guard: importing a Yomitan dictionary that bundles
// media files (gaiji images, term audio) must copy those blobs into the
// dictionary's media store, and get_media_file(dict_name, path) must read them
// back byte-for-byte. A miss (unknown media path) must return an empty buffer
// (size==0) rather than crash or return garbage.
//
// Why this matters: query.cpp serves media from a memory-mapped media.bin via a
// binary search over media.idx; an off-by-one / OOM there is an out-of-bounds
// read (HBK-AUDIT-100). The only自包含 way to exercise the real import->mmap->
// memcpy path is to hand-roll a zip with media, import it, and assert bytes.
//
// importer.cpp treats every zip entry that is NOT index.json / styles.css and
// not a *_bank_* file as media (reverse whitelist), normalizing backslashes to
// '/'. get_media_file only serves media for dictionaries registered via
// add_term_dict, keyed by the index.json title (dict_name).
//
// Usage: media_import_query_test   (no args) -> exit 0 PASS, non-zero FAIL.
#include <cstdio>
#include <string>
#include <vector>

#include "hoshidicts/importer.hpp"
#include "hoshidicts/query.hpp"
#include "zip_fixture.hpp"

namespace {

int g_fail = 0;

void fail(const char* msg) {
  std::fprintf(stderr, "FAIL: %s\n", msg);
  ++g_fail;
}

// A term entry whose structured-content glossary references an image at
// "img/sun.png" — the engine stores the glossary opaquely; the path link is the
// string we pass to get_media_file below.
std::string term_bank_with_img() {
  // [[expr, reading, defTags, rules, score, [glossary], seq, termTags]]
  // glossary[0] is a structured-content object referencing img/sun.png.
  return "[[\"\xE6\x97\xA5\",\"\xE3\x81\xB2\",\"\",\"\",0,"
         "[{\"type\":\"structured-content\","
         "\"content\":{\"tag\":\"img\",\"path\":\"img/sun.png\"}}],"
         "0,\"\"]]";
}

std::string index_json(const char* title) {
  return std::string("{\"title\":\"") + title +
         "\",\"format\":3,\"revision\":\"test\"}";
}

}  // namespace

int main() {
  const std::string out_dir = hoshi_test::temp_dir() + "/hoshi_media_out";
  const char* kTitle = "MediaDict";

  // Two media blobs with distinct, non-trivial byte content (incl. a NUL and
  // high bytes) so a wrong-length / wrong-offset read is caught.
  const std::string sun_png =
      std::string("\x89PNG\r\n\x1a\n", 8) + std::string("SUN-PIXELS", 10) +
      std::string("\x00\xff\x7f", 3);
  const std::string audio_ogg =
      std::string("OggS", 4) + std::string("\x00AUDIO-FRAME", 12) +
      std::string("\xfe\x01", 2);

  std::vector<hoshi_test::ZipFile> files = {
      {"index.json", index_json(kTitle)},
      {"term_bank_1.json", term_bank_with_img()},
      {"img/sun.png", sun_png},
      {"audio/hi.ogg", audio_ogg},
  };

  std::string zip_path = hoshi_test::write_zip("media", files);
  if (zip_path.empty()) {
    fail("could not write fixture zip");
  } else {
    ImportResult r = dictionary_importer::import(zip_path, out_dir);
    if (!r.success) {
      std::fprintf(stderr, "FAIL import: %s\n",
                   r.errors.empty() ? "(no error)" : r.errors.front().c_str());
      ++g_fail;
    } else {
      // Both media files must be counted.
      if (r.media_count != 2) {
        std::fprintf(stderr, "FAIL media_count: got %zu want 2\n",
                     r.media_count);
        ++g_fail;
      }

      DictionaryQuery q;
      q.add_term_dict(out_dir + "/" + r.title);

      // Hit 1: the image referenced by the glossary.
      std::vector<char> png = q.get_media_file(r.title, "img/sun.png");
      if (std::string(png.begin(), png.end()) != sun_png) {
        std::fprintf(stderr,
                     "FAIL img/sun.png: got %zu bytes want %zu (content "
                     "mismatch)\n",
                     png.size(), sun_png.size());
        ++g_fail;
      }

      // Hit 2: the audio blob, fetched via the view API to exercise both paths.
      MediaFileView view = q.get_media_file_view(r.title, "audio/hi.ogg");
      if (view.data == nullptr || view.size != audio_ogg.size() ||
          std::string(view.data, view.data + view.size) != audio_ogg) {
        std::fprintf(stderr,
                     "FAIL audio/hi.ogg view: data=%p size=%zu want %zu\n",
                     static_cast<const void*>(view.data), view.size,
                     audio_ogg.size());
        ++g_fail;
      }

      // Path normalization: a backslash path must resolve to the same blob.
      std::vector<char> png_back = q.get_media_file(r.title, "img\\sun.png");
      if (std::string(png_back.begin(), png_back.end()) != sun_png) {
        fail("backslash media path did not normalize to the same blob");
      }

      // Miss: an unknown path must return an empty buffer, not crash.
      std::vector<char> miss = q.get_media_file(r.title, "img/missing.png");
      if (!miss.empty()) {
        std::fprintf(stderr, "FAIL miss: got %zu bytes want 0\n", miss.size());
        ++g_fail;
      }
      MediaFileView miss_view =
          q.get_media_file_view(r.title, "img/missing.png");
      if (miss_view.data != nullptr || miss_view.size != 0) {
        fail("miss view should be {nullptr, 0}");
      }

      // Miss: an unknown dict_name must also return empty, not crash.
      std::vector<char> wrong_dict =
          q.get_media_file("NoSuchDict", "img/sun.png");
      if (!wrong_dict.empty()) {
        fail("unknown dict_name should return empty media buffer");
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
