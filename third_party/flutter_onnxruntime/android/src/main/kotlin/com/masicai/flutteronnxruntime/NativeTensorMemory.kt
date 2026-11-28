// Fushi fork (PATCHES.md delta 19, BUG-5508).

package com.masicai.flutteronnxruntime

import ai.onnxruntime.OnnxJavaType
import ai.onnxruntime.OnnxTensor
import ai.onnxruntime.OrtEnvironment
import java.lang.reflect.Method
import java.nio.ByteBuffer
import java.nio.ByteOrder

/**
 * Tensor bytes that never touch the Java heap.
 *
 * On Android `ByteBuffer.allocateDirect` is a Java-heap array (`VMRuntime.newNonMovableArray`),
 * so upstream's path -- `StandardMessageCodec` decodes the Dart list into a `FloatArray`, ORT
 * copies it into a direct buffer that lives as long as the tensor, and every read-back is
 * `getFloatBuffer()` + `FloatArray` + a doubling `ByteArrayOutputStream` + the reply buffer --
 * kept 2-5 full copies of every OCR / ASR tensor inside the app's 256 MB heap and crashed with
 * `OutOfMemoryError` (BUG-5508).
 *
 * Instead the channel only carries addresses:
 * - inputs: Dart mallocs the block and writes the data; [wrapInput] makes a direct ByteBuffer
 *   over it and ORT uses that buffer zero-copy (`OrtUtil.prepareBuffer` keeps direct buffers).
 *   Dart owns the block and frees it only after `releaseOrtValue` closed the tensor.
 * - outputs: [dataAddress] hands out the address of ORT's own tensor memory; Dart copies it into
 *   a Dart typed list while the tensor is still alive, then disposes it.
 */
internal object NativeTensorMemory {
    init {
        System.loadLibrary("flutter_onnxruntime_jni")
    }

    @JvmStatic
    private external fun wrap(address: Long, byteLength: Long): ByteBuffer

    @JvmStatic
    private external fun addressOf(buffer: ByteBuffer): Long

    /**
     * `OnnxTensor.getBuffer()` is the private accessor ORT's own `get*Buffer()` copies from: a
     * direct buffer over the tensor's native data. The app keeps `ai.onnxruntime.**` with all
     * members (fushi/android/app/proguard-rules.pro), so the name survives R8.
     */
    private val tensorBufferAccessor: Method by lazy {
        OnnxTensor::class.java.getDeclaredMethod("getBuffer").apply { isAccessible = true }
    }

    /** Element types whose dense bytes can cross as raw memory, with their element size. */
    private val elementSizes: Map<String, Int> =
        mapOf("float32" to 4, "int32" to 4, "int64" to 8, "uint8" to 1, "int8" to 1)

    private val javaTypes: Map<String, OnnxJavaType> =
        mapOf(
            "float32" to OnnxJavaType.FLOAT,
            "int32" to OnnxJavaType.INT32,
            "int64" to OnnxJavaType.INT64,
            "uint8" to OnnxJavaType.UINT8,
        )

    /** Creates a tensor that reads straight from the Dart-owned block at [address]. */
    fun wrapInput(
        environment: OrtEnvironment,
        sourceType: String,
        address: Long,
        byteLength: Long,
        shape: LongArray,
    ): OnnxTensor {
        val javaType =
            javaTypes[sourceType]
                ?: throw IllegalArgumentException("Unsupported native memory tensor type: $sourceType")
        require(address != 0L) { "Native tensor address is null" }
        val elements = shape.fold(1L) { acc, dim -> acc * dim }
        val expected = elements * elementSizes.getValue(sourceType)
        require(byteLength == expected) {
            "Shape ${shape.contentToString()} of $sourceType needs $expected bytes, got $byteLength"
        }
        val buffer = wrap(address, byteLength).order(ByteOrder.nativeOrder())
        return OnnxTensor.createTensor(environment, buffer, shape, javaType)
    }

    /**
     * Address + byte length of [tensor]'s native data, or null when its element type cannot be
     * read as raw bytes (float16 / bool / string keep the codec path).
     */
    fun dataAddress(
        tensor: OnnxTensor,
        dataType: String,
    ): Pair<Long, Long>? {
        val elementSize = elementSizes[dataType] ?: return null
        val buffer = tensorBufferAccessor.invoke(tensor) as ByteBuffer
        val elements = tensor.info.shape.fold(1L) { acc, dim -> acc * dim }
        val byteLength = buffer.capacity().toLong()
        check(byteLength == elements * elementSize) {
            "Tensor buffer has $byteLength bytes, shape ${tensor.info.shape.contentToString()} " +
                "of $dataType needs ${elements * elementSize}"
        }
        if (byteLength == 0L) return Pair(0L, 0L)
        val address = addressOf(buffer)
        check(address != 0L) { "Tensor buffer is not a direct buffer" }
        return Pair(address, byteLength)
    }
}
