package app.fushi.reader

import android.app.Notification
import android.content.Context
import android.os.Build
import android.os.Bundle

/**
 * 下载进度通知 → Android 16 Live Update（实时通知 / 推广常驻通知）。
 *
 * <p>Android 16（API 36）起，带 `requestPromotedOngoing` 的常驻进度通知会被系统
 * 提升为实时通知：Pixel 上是状态栏胶囊，ColorOS 16 上是「流体云」。社区的
 * FluidCapsule（github.com/Venompool888/FluidCapsule）就是把别家 app 的通知
 * 转发成这种形态；它没有第三方接入协议，用的正是这组公开 API，所以 Fushi
 * 自己直接发成 Live Update，不装 FluidCapsule 也能上胶囊 / 流体云，装了也不用
 * 再把 Fushi 加进它的白名单去镜像（镜像版只有文字、没有进度）。
 *
 * <p>系统判定「可推广」的条件（[Notification.hasPromotableCharacteristics]）：
 * ongoing、有标题、未 colorized、无自定义 RemoteViews、非组摘要、样式为空或
 * BigText / Call / ProgressStyle、渠道重要性不是 MIN——下载通知全都满足，这里
 * 只补请求位、胶囊短文本和 ProgressStyle。是否真的显示成胶囊由系统 / 用户
 * （设置里每个 app 的「实时通知」开关）决定，失败时就是一条普通进度通知。
 */
internal object DownloadLiveUpdate {
    /**
     * 胶囊上的短文本：确定进度时显示百分比，不确定进度时不给（系统只显示图标）。
     * 与 [DownloadKeepAliveService] 的约定一致：0..100 为确定进度，其它值为不确定。
     */
    @JvmStatic
    fun shortCriticalText(progress: Int): String? =
        if (progress in 0..100) "$progress%" else null

    /**
     * API 36+ 把已构建的进度通知改造成 Live Update；更低版本原样返回。
     * 用 [Notification.Builder.recoverBuilder] 在原通知上追加，不重复一份字段。
     */
    @JvmStatic
    fun promote(context: Context, notification: Notification, progress: Int): Notification {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.BAKLAVA) return notification
        val determinate = progress in 0..100
        val style = Notification.ProgressStyle()
            .setStyledByProgress(false)
            .setProgressIndeterminate(!determinate)
        if (determinate) style.setProgress(progress)
        val builder = Notification.Builder.recoverBuilder(context, notification)
            .setStyle(style)
            // Builder.setRequestPromotedOngoing 是 API 36.1 才进 SDK 的便捷方法，本仓
            // compileSdk 36 里没有；它做的就是写这个 extra，API 36 系统据此判定推广。
            // AndroidX NotificationCompat.Builder.setRequestPromotedOngoing 同样写它。
            .addExtras(Bundle().apply { putBoolean(EXTRA_REQUEST_PROMOTED_ONGOING, true) })
        shortCriticalText(progress)?.let { text -> builder.setShortCriticalText(text) }
        return builder.build()
    }

    /** `Notification.EXTRA_REQUEST_PROMOTED_ONGOING` 的值（API 36.1 才有该常量）。 */
    private const val EXTRA_REQUEST_PROMOTED_ONGOING = "android.requestPromotedOngoing"
}
