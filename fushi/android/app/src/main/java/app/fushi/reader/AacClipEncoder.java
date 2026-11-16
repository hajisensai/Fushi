package app.fushi.reader;

import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaFormat;
import android.media.MediaMuxer;
import android.util.Log;

import androidx.annotation.NonNull;

import java.io.File;
import java.io.IOException;
import java.nio.ByteBuffer;

/**
 * 把一段 16-bit 小端 PCM 编成 AAC-LC 的 m4a（MediaCodec + MediaMuxer）。跨应用语音制卡
 * 用：查词窗进程里没有 ffmpeg-kit，系统编码器每台 Android 10+ 设备都有。阻塞调用，放
 * 后台线程。
 */
final class AacClipEncoder {
    private static final String TAG = "AacClipEncoder";
    private static final String MIME = MediaFormat.MIMETYPE_AUDIO_AAC;
    private static final long TIMEOUT_US = 10_000;
    /** 整段编码的硬上限：编码器出错又不发 EOS 时不让调用线程（和制卡）永远挂住。 */
    private static final long MAX_ENCODE_NS = 30_000_000_000L;

    private AacClipEncoder() {}

    /** 编码成功返回 true；失败时删掉残留的输出文件。 */
    static boolean encode(@NonNull byte[] pcm, int sampleRate, int channels, int bitRate,
            @NonNull File output) {
        if (pcm.length == 0 || sampleRate <= 0 || channels <= 0) return false;
        MediaCodec codec = null;
        MediaMuxer muxer = null;
        boolean muxerStarted = false;
        boolean ok = false;
        try {
            MediaFormat format = MediaFormat.createAudioFormat(MIME, sampleRate, channels);
            format.setInteger(MediaFormat.KEY_AAC_PROFILE,
                    MediaCodecInfo.CodecProfileLevel.AACObjectLC);
            format.setInteger(MediaFormat.KEY_BIT_RATE, bitRate);
            format.setInteger(MediaFormat.KEY_MAX_INPUT_SIZE, 16 * 1024);
            codec = MediaCodec.createEncoderByType(MIME);
            codec.configure(format, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
            codec.start();
            muxer = new MediaMuxer(output.getAbsolutePath(),
                    MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
            int track = -1;
            int bytesPerFrame = channels * 2;
            int inputOffset = 0;
            boolean inputDone = false;
            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            long deadline = System.nanoTime() + MAX_ENCODE_NS;
            while (true) {
                if (System.nanoTime() > deadline) {
                    throw new IllegalStateException("AAC encoder produced no EOS in time");
                }
                if (!inputDone) {
                    int inIndex = codec.dequeueInputBuffer(TIMEOUT_US);
                    if (inIndex >= 0) {
                        ByteBuffer in = codec.getInputBuffer(inIndex);
                        long ptsUs = (long) (inputOffset / bytesPerFrame) * 1_000_000L / sampleRate;
                        int room = in == null ? 0 : in.capacity() / bytesPerFrame * bytesPerFrame;
                        int len = Math.min(room, pcm.length - inputOffset);
                        if (len <= 0) {
                            codec.queueInputBuffer(inIndex, 0, 0, ptsUs,
                                    MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                            inputDone = true;
                        } else {
                            in.clear();
                            in.put(pcm, inputOffset, len);
                            codec.queueInputBuffer(inIndex, 0, len, ptsUs, 0);
                            inputOffset += len;
                        }
                    }
                }
                int outIndex = codec.dequeueOutputBuffer(info, TIMEOUT_US);
                if (outIndex == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    track = muxer.addTrack(codec.getOutputFormat());
                    muxer.start();
                    muxerStarted = true;
                } else if (outIndex >= 0) {
                    ByteBuffer out = codec.getOutputBuffer(outIndex);
                    boolean config = (info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) != 0;
                    if (out != null && info.size > 0 && !config && muxerStarted) {
                        out.position(info.offset);
                        out.limit(info.offset + info.size);
                        muxer.writeSampleData(track, out, info);
                    }
                    codec.releaseOutputBuffer(outIndex, false);
                    if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) break;
                }
            }
            ok = muxerStarted;
        } catch (IOException | RuntimeException e) {
            Log.w(TAG, "AAC encode failed", e);
            ok = false;
        } finally {
            if (codec != null) {
                try {
                    codec.stop();
                } catch (RuntimeException ignored) {
                    // 已在异常路径上；release 才是要紧的。
                }
                codec.release();
            }
            if (muxer != null) {
                try {
                    if (muxerStarted) muxer.stop();
                } catch (RuntimeException e) {
                    Log.w(TAG, "muxer stop failed", e);
                    ok = false;
                }
                muxer.release();
            }
            if (!ok) {
                //noinspection ResultOfMethodCallIgnored
                output.delete();
            }
        }
        return ok;
    }
}
