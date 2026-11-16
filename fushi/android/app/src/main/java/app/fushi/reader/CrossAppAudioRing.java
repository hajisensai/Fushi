package app.fushi.reader;

/**
 * 跨应用语音挖掘（拍板 oqk37s3QFL）的 PCM 环形缓冲：采集线程不停往里写，查词那一刻
 * 取「最近 N 字节」。容量固定（采集开始时按格式算好），内存有界；超出容量后覆盖最旧的
 * 数据。与 Windows 的 WASAPI loopback 环（{@code fushi/windows/runner/audio_loopback_capture.cpp}）
 * 同一语义：只保留最近一段，取的时候按帧对齐。
 *
 * <p>线程：所有公开方法 {@code synchronized}，采集线程写、查词 RPC 线程读。
 */
final class CrossAppAudioRing {
    private final byte[] buffer;
    private final int blockAlign;
    /** 下一次写入的位置。 */
    private int writePos = 0;
    /** 当前有效字节数（≤ capacity）。 */
    private int size = 0;

    /**
     * @param capacityBytes 环容量（会向下对齐到 [blockAlign]，至少一帧）。
     * @param blockAlign 每帧字节数（声道数 × 每采样字节数）。
     */
    CrossAppAudioRing(int capacityBytes, int blockAlign) {
        if (blockAlign <= 0) throw new IllegalArgumentException("blockAlign must be > 0");
        int aligned = Math.max(blockAlign, capacityBytes / blockAlign * blockAlign);
        this.buffer = new byte[aligned];
        this.blockAlign = blockAlign;
    }

    int capacity() {
        return buffer.length;
    }

    synchronized int size() {
        return size;
    }

    /** 追加 [len] 字节；超过容量时只保留最后 capacity 字节。 */
    synchronized void write(byte[] src, int offset, int len) {
        if (len <= 0) return;
        if (len >= buffer.length) {
            // 一次写入就超过整个环：只留它的末尾一整环。
            System.arraycopy(src, offset + len - buffer.length, buffer, 0, buffer.length);
            writePos = 0;
            size = buffer.length;
            return;
        }
        int first = Math.min(len, buffer.length - writePos);
        System.arraycopy(src, offset, buffer, writePos, first);
        int rest = len - first;
        if (rest > 0) System.arraycopy(src, offset + first, buffer, 0, rest);
        writePos = (writePos + len) % buffer.length;
        size = Math.min(buffer.length, size + len);
    }

    /**
     * 取「最近 [maxBytes] 字节」（按时间先后、向下对齐到整帧）。缓冲不足时返回现有全部；
     * 空缓冲返回长度 0 的数组。
     */
    synchronized byte[] tail(int maxBytes) {
        int want = Math.min(Math.max(0, maxBytes), size) / blockAlign * blockAlign;
        byte[] out = new byte[want];
        if (want == 0) return out;
        int start = Math.floorMod(writePos - want, buffer.length);
        int first = Math.min(want, buffer.length - start);
        System.arraycopy(buffer, start, out, 0, first);
        if (want > first) System.arraycopy(buffer, 0, out, first, want - first);
        return out;
    }

    synchronized void clear() {
        writePos = 0;
        size = 0;
    }
}
