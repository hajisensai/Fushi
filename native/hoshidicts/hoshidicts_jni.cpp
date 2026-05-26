#include <jni.h>
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
