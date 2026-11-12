package app.fushi.reader;

import android.app.Application;

import io.flutter.FlutterInjector;

/**
 * 应用级入口：所有进程（主进程与 {@code :popup}、{@code :second_screen}、
 * {@code :network_challenge}）启动都先经过这里。
 *
 * <p>minSdk 24 原生支持 multidex，不需要 {@code FlutterMultiDexApplication} 的
 * {@code MultiDex.install}。
 */
public class FushiApplication extends Application {
    /** 与 AndroidManifest 里 CloudflareChallengeActivity 的 {@code android:process} 一致。 */
    private static final String NETWORK_CHALLENGE_PROCESS = ":network_challenge";

    @Override
    public void onCreate() {
        // 最先装：之后任何初始化里的 Java 未捕获异常都要留下栈。
        JavaCrashCapture.install(this);
        super.onCreate();
        // 引擎原生库的加载（System.loadLibrary("flutter") 等）跑在后台线程，但要有人
        // 先起它。不在这里起的话，要等 Activity 建引擎时才开始，主线程随即在
        // FlutterLoader.ensureInitializationComplete 里干等它跑完（小米平板 5 冷启动
        // 采样：主线程在这一处停 143-148 ms）。这里先起，它就和 Activity 的创建并行。
        // 过 Cloudflare 质询的进程只有一个系统 WebView，不建引擎，不替它加载。
        if (!JavaCrashCapture.currentProcessName(this).endsWith(NETWORK_CHALLENGE_PROCESS)) {
            FlutterInjector.instance().flutterLoader().startInitialization(this);
        }
        StartupTrace.mark("application-create");
    }
}
