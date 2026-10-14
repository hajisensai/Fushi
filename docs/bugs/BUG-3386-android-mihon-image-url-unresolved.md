## BUG-3386 · Android在线漫画不解析逐页图片地址
- **报告**：2026-10-15（排查在线漫画不稳定时发现）
- **真实性**：✅ 真 bug。Android 原生 `fetchPageImage`（`fushi/android/app/src/main/kotlin/app/fushi/reader/mihon/MihonChannelHandler.kt:481`）直接 `getImage(page)`，从不调 `getImageUrl`；钉住的 Mihon source-api（`fdb223d6`）`imageRequest` 是 `GET(page.imageUrl!!)`。凡 `getPageList` 只给阅读页地址、需逐页解析图片地址的源，Android 上直读与下载每页都失败。桌面 sidecar 的 `MihonImageProxy.fetch` 有这一步。
- **[x] ① 根因修复** — `MihonChannelHandler.kt:498` `imageUrl` 为空时先 `getImageUrl(page)`，与 sidecar 同一步。
- **[ ] ② 自动化测试** — 未加：该处是 Android 原生 + 第三方扩展 dex 边界，仓库现有 JVM 测试不覆盖 `MihonChannelHandler`；需要一个只给阅读页地址的假 HttpSource 才能钉住，留待补。
- **备注**：未在 Android 真机上验证具体受影响源。
