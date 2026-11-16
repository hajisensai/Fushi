package app.fushi.reader;

/**
 * 系统 OCR 送检位图的内存预算（BUG-4705）。
 *
 * <p>以前 {@code SystemOcrChannel} 对每张页图直接 {@code BitmapFactory.decodeByteArray}
 * 全分辨率解码，而且就在平台主线程上：一张 8000×11300 的页图解出来是 361 MB 的 ARGB
 * 位图，真机（Xiaomi Pad 5，无 GMS）上实测主线程卡 1.1 s、系统随即按低内存杀后台进程；
 * 内存更紧的设备上这一步直接把进程带走。识别器根本用不着这么多像素——这里给出一个
 * 像素上限，按 2 的幂降采样解码，识别出的框再按比例放回原图坐标系。
 *
 * <p>纯函数、不碰 Android API，JVM 单测直接覆盖（{@code SystemOcrImageBudgetTest}）。
 */
final class SystemOcrImageBudget {
    /**
     * 送进识别器的位图像素上限：16 MP（ARGB_8888 约 64 MB）。
     *
     * <p>常见漫画扫描页（≤ 4000×4000 级别）原样解码、识别精度不变；只有超过它的大图才
     * 降采样。条漫长图降一档后单行字仍有几十像素高，足够 ML Kit 认字。
     */
    static final long MAX_RECOGNIZE_PIXELS = 16L * 1024L * 1024L;

    private SystemOcrImageBudget() {}

    /**
     * 让 {@code width × height} 降到 {@code maxPixels} 以内的最小 2 的幂采样率
     * （{@code BitmapFactory.Options.inSampleSize} 只按 2 的幂生效）。尺寸非法返回 1。
     */
    static int sampleSizeFor(int width, int height, long maxPixels) {
        if (width <= 0 || height <= 0 || maxPixels <= 0) return 1;
        int sample = 1;
        while (pixelsAt(width, height, sample) > maxPixels && sample < (1 << 30)) {
            sample <<= 1;
        }
        return sample;
    }

    /** 采样率 {@code sample} 下解码出的像素数（与 BitmapFactory 一样向上取整）。 */
    static long pixelsAt(int width, int height, int sample) {
        final long w = (width + (long) sample - 1) / sample;
        final long h = (height + (long) sample - 1) / sample;
        return w * h;
    }

    /**
     * 把识别位图上的坐标放回原图坐标系：{@code value × original / decoded}，四舍五入并夹在
     * {@code [0, original]} 内。{@code decoded} 非法时原样返回。
     */
    static int toOriginal(int value, int original, int decoded) {
        if (decoded <= 0 || original <= 0 || original == decoded) return value;
        final long scaled = Math.round((double) value * original / decoded);
        if (scaled < 0) return 0;
        if (scaled > original) return original;
        return (int) scaled;
    }
}
