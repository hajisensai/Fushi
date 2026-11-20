package app.fushi.reader.mihon

import android.os.Parcel
import android.os.ResultReceiver

/**
 * 把一个（通常是匿名子类的）[ResultReceiver] 换成可以安全跨进程传的框架基类实例。
 *
 * `Bundle.putParcelable` / `Intent.putExtra` 序列化 Parcelable 时写的是**运行时类名**：
 * `object : ResultReceiver(...)` 写进去的是 `…$onCreate$1` 这类 app 私有类名。对端
 * 进程从 `ResultReceiver.send` 收到的 Bundle 没有设 classLoader，反序列化退回 boot
 * classloader，找不到这个类就抛 `BadParcelableException`——在主线程 Handler 里抛出，
 * 主进程直接崩（BUG-4952：Android 上一点「网站验证」，验证进程的 Activity 一回发
 * control receiver，主进程就闪退）。
 *
 * 这里经一次 Parcel 往返得到 `android.os.ResultReceiver` 本身：它持有的 binder 仍指向
 * 原对象（binder 引用也让原对象保持存活），回调照常进原对象的 `onReceiveResult`，
 * 但线上只出现框架类名，任何进程、任何 classloader 都能解出来。所有跨进程传的
 * ResultReceiver 都必须先过这里（`android_cloudflare_proxy_boundary_test.dart` 守卫）。
 */
internal fun ResultReceiver.forIpc(): ResultReceiver {
    val parcel = Parcel.obtain()
    try {
        writeToParcel(parcel, 0)
        parcel.setDataPosition(0)
        return ResultReceiver.CREATOR.createFromParcel(parcel)
    } finally {
        parcel.recycle()
    }
}
