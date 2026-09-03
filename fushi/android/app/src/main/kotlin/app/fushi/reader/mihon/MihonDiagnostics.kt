package app.fushi.reader.mihon

/**
 * 扩展宿主的错误描述工具。
 *
 * Mihon 扩展是第三方 dex，失败原因几乎全在异常的 **cause 链最深一层**
 * （`NoClassDefFoundError` 指出宿主缺哪个类、`IOException` 指出网络/Cloudflare、
 * `NullPointerException` 指出站点改版后选择器落空）。反射调用还会再包一层
 * `InvocationTargetException`，只看最外层等于什么都没看到。
 *
 * 所以桥接层往 Flutter 回传错误时，必须把整条链渲染出来，而不是替换成一句
 * 「操作失败」——那句话对用户和维护者都是零信息。
 */
internal fun describeCauseChain(error: Throwable): String {
    val parts = mutableListOf<String>()
    var current: Throwable? = error
    val seen = HashSet<Throwable>()
    while (current != null && seen.add(current) && parts.size < MAX_CAUSE_LINKS) {
        val label = current.javaClass.simpleName.ifBlank { current.javaClass.name }
        val message = current.message?.trim().orEmpty()
        parts += if (message.isEmpty()) label else "$label: $message"
        current = current.cause
    }
    return parts.joinToString(" ← ")
}

/**
 * MethodChannel `details` 字段承载的完整堆栈。
 *
 * 消息体要短到能进 toast/标题，堆栈则留给「复制详情」对话框和日志上传，因此分开
 * 两路而不是把堆栈塞进 message。做长度上限是因为 platform channel 的每次回包都要
 * 整段序列化过去，跑飞的链路能产出几百 KB。
 */
internal fun diagnosticDetails(error: Throwable): String =
    error.stackTraceToString().let { trace ->
        if (trace.length <= MAX_DETAILS_CHARS) {
            trace
        } else {
            trace.take(MAX_DETAILS_CHARS) + "\n… (truncated)"
        }
    }

private const val MAX_CAUSE_LINKS = 6
private const val MAX_DETAILS_CHARS = 8000
