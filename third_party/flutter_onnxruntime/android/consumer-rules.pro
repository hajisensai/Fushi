# Fushi fork (PATCHES.md delta 19, BUG-5508): native tensor memory path.
# libflutter_onnxruntime_jni.so binds NativeTensorMemory's natives by JNI name.
-keep class com.masicai.flutteronnxruntime.NativeTensorMemory { native <methods>; }
# NativeTensorMemory reads tensor memory through this private accessor by reflection.
-keepclassmembers class ai.onnxruntime.OnnxTensor { private java.nio.ByteBuffer getBuffer(); }
