// Fushi fork (PATCHES.md delta 19): JNI helpers for NativeTensorMemory.kt.
//
// Java has no public API for "a direct ByteBuffer over this native address" or
// "the address of this direct ByteBuffer"; JNI has both. Nothing here allocates
// or frees: the memory behind `wrap` is owned by Dart (package:ffi malloc, freed
// after releaseOrtValue), the memory behind `addressOf` by ONNX Runtime.
#include <jni.h>
#include <stdint.h>

JNIEXPORT jobject JNICALL
Java_com_masicai_flutteronnxruntime_NativeTensorMemory_wrap(JNIEnv *env, jclass clazz, jlong address,
                                                           jlong byteLength) {
  (void)clazz;
  return (*env)->NewDirectByteBuffer(env, (void *)(intptr_t)address, byteLength);
}

JNIEXPORT jlong JNICALL
Java_com_masicai_flutteronnxruntime_NativeTensorMemory_addressOf(JNIEnv *env, jclass clazz, jobject buffer) {
  (void)clazz;
  return (jlong)(intptr_t)(*env)->GetDirectBufferAddress(env, buffer);
}
