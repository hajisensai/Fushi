# Fushi fork (PATCHES.md delta 19): the JNI half of the Android native tensor
# memory path. Two calls only -- wrap a Dart-owned malloc block as a direct
# ByteBuffer, and read a direct buffer's address -- so tensor bytes never get a
# Java-heap copy (on Android `ByteBuffer.allocateDirect` is a Java-heap array).
cmake_minimum_required(VERSION 3.22.1)
project(flutter_onnxruntime_jni C)

add_library(flutter_onnxruntime_jni SHARED native_tensor_memory.c)
target_compile_options(flutter_onnxruntime_jni PRIVATE -Wall -Wextra -Werror)
# 16 KB page devices (Android 15+): NDK r28 already aligns, pin it anyway.
target_link_options(flutter_onnxruntime_jni PRIVATE "-Wl,-z,max-page-size=16384")
