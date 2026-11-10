package app.fushi.reader;

import android.app.Application;

/**
 * 应用级入口：所有进程（主进程与 {@code :popup}、{@code :second_screen}、
 * {@code :network_challenge}）启动都先经过这里。
 *
 * <p>minSdk 24 原生支持 multidex，不需要 {@code FlutterMultiDexApplication} 的
 * {@code MultiDex.install}。
 */
public class FushiApplication extends Application {
    @Override
    public void onCreate() {
        // 最先装：之后任何初始化里的 Java 未捕获异常都要留下栈。
        JavaCrashCapture.install(this);
        super.onCreate();
    }
}
