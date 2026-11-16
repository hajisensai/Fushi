package app.fushi.reader

import android.app.Activity
import android.content.ClipData
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import app.fushi.reader.constants.ChannelNames
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Android 文件分享：`app.fushi.reader/share` 的原生侧（Dart 门面 `FushiShare.shareFiles`）。
 *
 * **为什么不用 share_plus（BUG-4740，反馈 P1pyoS0dQb）**：share_plus 7.2.2 的
 * `Share.getUrisForPaths` 在 MethodChannel 回调里——也就是 Android 主线程上——对每个
 * 待分享文件无条件 `File.copyTo(cache/share_plus/…)`，整份同步拷贝。分享片段视频 /
 * m4b / 备份 zip 这种几百 MB 的产物时，主线程阻塞在 `FileOutputStream.write` 上，
 * 系统判 ANR。
 *
 * **契约**：传进来的 `paths` 必须已经是 Dart 侧 `FushiShare` 落好的**分享快照**（异步
 * I/O 拷进 `getTemporaryDirectory()/fushi_share/…`，即 cacheDir，被
 * `provider_paths.xml` 的 `cache-path` 覆盖）。这里**不碰文件内容**：只把路径换成
 * [FushiFileProvider] 的 `content://` URI、拼 `ACTION_SEND(_MULTIPLE)` + chooser 并
 * 拉起。不在任何 provider 根下的路径由 `getUriForFile` 抛 `IllegalArgumentException`，
 * 原样回报给 Dart，不在这里补拷贝。
 */
object FushiShareChannel {
    private const val METHOD_SHARE_FILES = "shareFiles"

    @JvmStatic
    fun registerWith(engine: FlutterEngine, activity: Activity) {
        MethodChannel(engine.dartExecutor.binaryMessenger, ChannelNames.SHARE)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    METHOD_SHARE_FILES -> shareFiles(activity, call, result)
                    else -> result.notImplemented()
                }
            }
    }

    private fun shareFiles(activity: Activity, call: MethodCall, result: MethodChannel.Result) {
        val paths: List<String>? = call.argument("paths")
        val mimeType: String? = call.argument("mimeType")
        if (paths.isNullOrEmpty() || mimeType.isNullOrEmpty()) {
            result.error("bad_args", "shareFiles needs non-empty paths and mimeType", null)
            return
        }
        val text: String? = call.argument("text")
        val subject: String? = call.argument("subject")

        val authority = activity.packageName + ".provider"
        val uris = ArrayList<Uri>(paths.size)
        try {
            for (path in paths) {
                uris.add(FileProvider.getUriForFile(activity, authority, File(path)))
            }
        } catch (e: IllegalArgumentException) {
            result.error("not_shareable", e.message, null)
            return
        }

        val send = Intent().apply {
            type = mimeType
            if (uris.size == 1) {
                action = Intent.ACTION_SEND
                putExtra(Intent.EXTRA_STREAM, uris.first())
            } else {
                action = Intent.ACTION_SEND_MULTIPLE
                putParcelableArrayListExtra(Intent.EXTRA_STREAM, uris)
            }
            if (text != null) putExtra(Intent.EXTRA_TEXT, text)
            if (subject != null) putExtra(Intent.EXTRA_SUBJECT, subject)
            // URI 授权随 ClipData 经 chooser 传给最终选中的目标（ShareCompat 同款做法），
            // 不必逐个 queryIntentActivities 去 grantUriPermission。
            val clip = ClipData.newRawUri(null, uris.first())
            for (i in 1 until uris.size) clip.addItem(ClipData.Item(uris[i]))
            clipData = clip
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
        }
        activity.startActivity(Intent.createChooser(send, null))
        result.success(null)
    }
}
