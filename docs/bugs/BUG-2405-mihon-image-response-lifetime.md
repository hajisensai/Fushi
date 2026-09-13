## BUG-2405 · Mihon 图片响应在读取正文前因 Rx 退订关闭 Socket
- **报告**：2026-09-10（用户：日语漫画《週に一度クラスメイトを買う話》章节图片加载不出来。）
- **真实性**：✅ 真 bug。安装版 Chapter 15.1 阅读器停在 1/12 黑屏破图；Mihon 日志显示原站返回 200 和图片 Content-Length，随后 `Socket closed`，栈为 `ResponseBody.bytes → MihonImageProxy.fetch:92`。`upstream_src/server/src/main/kotlin/mextensionserver/impl/MihonImageProxy.kt:89` 在 `fetchImage(...).toBlocking().single()` 结束后才读取正文；`upstream_src/server/src/main/kotlin/eu/kanade/tachiyomi/network/OkHttpExtensions.kt:111` 的退订会 `call.cancel()`，因此网络 Response 已失效。旧测试都用内存 ResponseBody，无法暴露该错误。
- **[x] ① 已修复** — overlay `MihonImageProxy.fetch` 在 Rx map 内读取并关闭 Response，然后才返回已脱离网络生命周期的 ImageData。修复哈希见本文件同批提交。
- **[x] ② 已加自动化测试** — overlay `MihonImageProxyTest` 增加真实回环 HTTP 256 KiB 图片逐字节校验。旧代码执行 4 项/1 项失败（Socket closed），修复后图片与代理测试通过；全 JVM 29 项/0 失败/0 跳过。
- **修复边界**：通过 overlay 修正响应消费生命周期，不改 pristine upstream、不绕过扩展 fetchImage/client/interceptor、不重试或延长超时。公网图片已开始返回正文，不能把这个错误归因于原站没资源。
- **等价路径**：扫描桌面 bridge 的 blocking/await 消费点，唯一把 live Response 移出订阅再读取正文的位置是 MihonImageProxy.fetch；封面独立请求路径不受此生命周期问题影响。
- **验收**：`:server:test :server:shadowJar` exit 0，`verify_desktop_runtime.ps1` exit 0；本地 `.codex-test/jvm-policy-validation/image-{red,green,full}.log` 和 XML 保存证据。备份本机旧 JAR/checksums 后应用修复，重启精确识别的 Mihon Java 子进程。用户安装版重开同一 Chapter 15.1：1/12 封面正常，向左翻页后人物介绍及黑白日语对白均真实渲染；2026-09-10 07:35 图片请求返回 200，未重现 Socket closed。整书离线下载未验证。
