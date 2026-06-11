#include <jni.h>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>
#include "hoshidicts/platform.hpp"
#include "hoshidicts/deinflector.hpp"
#include "hoshidicts/lookup.hpp"
#include "hoshidicts/query.hpp"
#include "hoshidicts/popup_json.hpp"

struct HoshidictsHandle {
  DictionaryQuery query;
  Deinflector deinflector;
};

namespace {

// Minimal JSON string escaper for kanji fields (no external dep). Handles the
// control / quote / backslash bytes that would otherwise break the JSON sent to
// the Android popup WebView; multi-byte UTF-8 is passed through unchanged.
void append_json_escaped(std::string& out, const std::string& s) {
  out.push_back('"');
  for (char c : s) {
    switch (c) {
      case '"': out += "\\\""; break;
      case '\\': out += "\\\\"; break;
      case '\n': out += "\\n"; break;
      case '\r': out += "\\r"; break;
      case '\t': out += "\\t"; break;
      default:
        if (static_cast<unsigned char>(c) < 0x20) {
          char buf[8];
          std::snprintf(buf, sizeof(buf), "\\u%04x",
                        static_cast<unsigned>(static_cast<unsigned char>(c)));
          out += buf;
        } else {
          out.push_back(c);
        }
    }
  }
  out.push_back('"');
}

// Serialize a kanji query result vector to a JSON array. Each element mirrors
// the KanjiResult fields the Android popup needs:
//   {character, onyomi, kunyomi, radical, strokes, meanings:[...], dictName}
std::string build_kanji_json(const std::vector<KanjiResult>& kanji) {
  std::string out = "[";
  for (size_t i = 0; i < kanji.size(); i++) {
    if (i) out.push_back(',');
    const KanjiResult& k = kanji[i];
    out += "{\"character\":";
    append_json_escaped(out, k.character);
    out += ",\"onyomi\":";
    append_json_escaped(out, k.onyomi);
    out += ",\"kunyomi\":";
    append_json_escaped(out, k.kunyomi);
    out += ",\"radical\":";
    append_json_escaped(out, k.radical);
    out += ",\"strokes\":";
    out += std::to_string(k.strokes);
    out += ",\"meanings\":[";
    for (size_t j = 0; j < k.meanings.size(); j++) {
      if (j) out.push_back(',');
      append_json_escaped(out, k.meanings[j]);
    }
    out += "],\"dictName\":";
    append_json_escaped(out, k.dict_name);
    out.push_back('}');
  }
  out.push_back(']');
  return out;
}

}  // namespace

extern "C" {

JNIEXPORT jlong JNICALL
Java_app_hibiki_reader_HoshiBridge_nativeCreate(JNIEnv*, jclass) {
  return reinterpret_cast<jlong>(new HoshidictsHandle());
}

JNIEXPORT void JNICALL
Java_app_hibiki_reader_HoshiBridge_nativeDestroy(JNIEnv*, jclass, jlong handle) {
  delete reinterpret_cast<HoshidictsHandle*>(handle);
}

JNIEXPORT void JNICALL
Java_app_hibiki_reader_HoshiBridge_nativeAddTermDict(JNIEnv* env, jclass,
                                                     jlong handle,
                                                     jstring path) {
  const char* p = env->GetStringUTFChars(path, nullptr);
  reinterpret_cast<HoshidictsHandle*>(handle)->query.add_term_dict(p);
  env->ReleaseStringUTFChars(path, p);
}

JNIEXPORT void JNICALL
Java_app_hibiki_reader_HoshiBridge_nativeAddFreqDict(JNIEnv* env, jclass,
                                                     jlong handle,
                                                     jstring path) {
  const char* p = env->GetStringUTFChars(path, nullptr);
  reinterpret_cast<HoshidictsHandle*>(handle)->query.add_freq_dict(p);
  env->ReleaseStringUTFChars(path, p);
}

JNIEXPORT void JNICALL
Java_app_hibiki_reader_HoshiBridge_nativeAddPitchDict(JNIEnv* env, jclass,
                                                      jlong handle,
                                                      jstring path) {
  const char* p = env->GetStringUTFChars(path, nullptr);
  reinterpret_cast<HoshidictsHandle*>(handle)->query.add_pitch_dict(p);
  env->ReleaseStringUTFChars(path, p);
}

JNIEXPORT void JNICALL
Java_app_hibiki_reader_HoshiBridge_nativeAddKanjiDict(JNIEnv* env, jclass,
                                                      jlong handle,
                                                      jstring path) {
  const char* p = env->GetStringUTFChars(path, nullptr);
  reinterpret_cast<HoshidictsHandle*>(handle)->query.add_kanji_dict(p);
  env->ReleaseStringUTFChars(path, p);
}

JNIEXPORT void JNICALL
Java_app_hibiki_reader_HoshiBridge_nativeLoadTransforms(JNIEnv* env, jclass,
                                                        jlong handle,
                                                        jstring json) {
  const char* j = env->GetStringUTFChars(json, nullptr);
  reinterpret_cast<HoshidictsHandle*>(handle)->deinflector.load_transforms_json(
      j);
  env->ReleaseStringUTFChars(json, j);
}

JNIEXPORT jstring JNICALL
Java_app_hibiki_reader_HoshiBridge_nativeLookupJson(JNIEnv* env, jclass,
                                                    jlong handle,
                                                    jstring text,
                                                    jint max_results,
                                                    jint scan_length,
                                                    jint max_terms) {
  auto* h = reinterpret_cast<HoshidictsHandle*>(handle);
  const char* t = env->GetStringUTFChars(text, nullptr);
  Lookup lookup(h->query, h->deinflector);
  auto results =
      lookup.lookup(t, static_cast<int>(max_results),
                    static_cast<size_t>(scan_length));
  env->ReleaseStringUTFChars(text, t);
  std::string json =
      build_popup_json(results, static_cast<int>(max_terms));
  // NewStringUTF uses Modified UTF-8; supplementary codepoints (U+10000+) are
  // technically non-conformant but Android ART handles them correctly.
  return env->NewStringUTF(json.c_str());
}

JNIEXPORT jstring JNICALL
Java_app_hibiki_reader_HoshiBridge_nativeQueryKanjiJson(JNIEnv* env, jclass,
                                                        jlong handle,
                                                        jstring character) {
  auto* h = reinterpret_cast<HoshidictsHandle*>(handle);
  const char* c = env->GetStringUTFChars(character, nullptr);
  std::vector<KanjiResult> kanji = h->query.query_kanji(c);
  env->ReleaseStringUTFChars(character, c);
  std::string json = build_kanji_json(kanji);
  return env->NewStringUTF(json.c_str());
}

JNIEXPORT jstring JNICALL
Java_app_hibiki_reader_HoshiBridge_nativeGetStylesJson(JNIEnv* env, jclass,
                                                       jlong handle) {
  auto* h = reinterpret_cast<HoshidictsHandle*>(handle);
  std::string json = build_styles_json(h->query);
  return env->NewStringUTF(json.c_str());
}

JNIEXPORT jbyteArray JNICALL
Java_app_hibiki_reader_HoshiBridge_nativeGetMedia(JNIEnv* env, jclass,
                                                  jlong handle,
                                                  jstring dict_name,
                                                  jstring media_path) {
  auto* h = reinterpret_cast<HoshidictsHandle*>(handle);
  const char* dn = env->GetStringUTFChars(dict_name, nullptr);
  const char* mp = env->GetStringUTFChars(media_path, nullptr);
  auto data = h->query.get_media_file(dn, mp);
  env->ReleaseStringUTFChars(dict_name, dn);
  env->ReleaseStringUTFChars(media_path, mp);
  if (data.empty()) return nullptr;
  jbyteArray arr = env->NewByteArray(static_cast<jint>(data.size()));
  env->SetByteArrayRegion(arr, 0, static_cast<jint>(data.size()),
                          reinterpret_cast<const jbyte*>(data.data()));
  return arr;
}

}  // extern "C"
