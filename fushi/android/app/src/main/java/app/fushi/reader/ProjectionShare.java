package app.fushi.reader;

import androidx.annotation.NonNull;
import androidx.annotation.Nullable;

/**
 * 本 app 唯一在用的屏幕投屏授权（MediaProjection）与挂在它上面的那块虚拟屏（BUG-4922）。
 *
 * <p>系统同一时刻只留一个活的 MediaProjection：再 {@code getMediaProjection} 一次，旧的就被
 * 系统停掉（回调 {@code onStop}）。App 外内录（{@link CrossAppAudioService}）与截屏识字
 * （{@link ScreenOcrService}）原先各自申请，开着内录点一次截屏识字，内录就被停了。现在
 * 内录拿到授权后在这里登记，截屏识字发现有登记的授权就直接在它上面取帧，不再申请第二个。
 *
 * <p>同一个 projection 只建一次虚拟屏：Android 14 起对同一实例第二次
 * {@code createVirtualDisplay} 抛 SecurityException。所以虚拟屏归这里持有，截屏识字每次
 * 只挂 / 摘自己的 surface；授权撤下（内录停止）时先放掉虚拟屏，再由持有方停投屏。
 *
 * <p>纯 Java、泛型化（P = projection，D = 虚拟屏），好在 JVM 单测里验证；Android 绑定见
 * {@link #MEDIA}。只在主线程读写。
 */
final class ProjectionShare<P, D> {
    /** 放掉一块虚拟屏。 */
    interface Releaser<D> {
        void release(@NonNull D display);
    }

    /** 在登记的 projection 上建虚拟屏（失败抛 RuntimeException）。 */
    interface Factory<D> {
        @NonNull
        D create();
    }

    /** 应用进程里的那一份（主进程：内录与截屏识字两个服务都在这里）。 */
    static final ProjectionShare<android.media.projection.MediaProjection,
            android.hardware.display.VirtualDisplay> MEDIA =
            new ProjectionShare<>(android.hardware.display.VirtualDisplay::release);

    private final Releaser<D> releaser;
    @Nullable private P projection;
    @Nullable private D display;

    ProjectionShare(@NonNull Releaser<D> releaser) {
        this.releaser = releaser;
    }

    /** 持有方（内录）拿到授权并开始使用后登记；换了新授权时旧授权上的虚拟屏一并放掉。 */
    void publish(@NonNull P p) {
        if (projection == p) return;
        releaseDisplay();
        projection = p;
    }

    /** 持有方停投屏前撤下：先放掉虚拟屏。撤的不是当前登记的那个（已被替换）时什么都不做。 */
    void withdraw(@NonNull P p) {
        if (projection != p) return;
        releaseDisplay();
        projection = null;
    }

    /** 此刻可以借用的授权；没有返回 null。 */
    @Nullable
    P current() {
        return projection;
    }

    /**
     * 登记授权上的虚拟屏：第一次借用时用 [factory] 建，之后一直复用同一块。[p] 已不是
     * 当前登记的授权时抛 IllegalStateException（调用方按截屏失败收尾）。
     */
    @NonNull
    D displayFor(@NonNull P p, @NonNull Factory<D> factory) {
        if (projection != p) throw new IllegalStateException("projection is no longer shared");
        D d = display;
        if (d == null) {
            d = factory.create();
            display = d;
        }
        return d;
    }

    /** [d] 是否仍是 [p] 上由这里持有的虚拟屏（撤下后它已被放掉，借用方不能再碰它）。 */
    boolean holds(@NonNull P p, @NonNull D d) {
        return projection == p && display == d;
    }

    private void releaseDisplay() {
        D d = display;
        display = null;
        if (d != null) releaser.release(d);
    }
}
