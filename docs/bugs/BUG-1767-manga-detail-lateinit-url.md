## BUG-1767 · 点开漫画作品报 RUNTIME_FAILURE：详情解析结果被当完整条目读 lateinit url
- **报告**：2026-08-22（用户：Android debug 通道 APK，Manga Mura 源，作品「ONE PIECE学園」）
- **现象**：漫画源能装、源浏览页的作品网格能正常加载出封面和标题；点进任意作品，详情页只显示一行
  `MihonRuntimeException(RUNTIME_FAILURE): Mihon extension operation failed`，无重试、无更多信息。
- **真实性**：✅ 真 bug。根因 `fushi/android/app/src/main/kotlin/app/fushi/reader/mihon/MihonChannelHandler.kt:273-285`
  （旧代码 `.manga.also { result -> loaded.mangaCache[cacheKey(source, result.url)] = result }.toBridgeMap()`）。

### 根因

Mihon 的 `mangaDetailsParse()` 返回的是**增量**，不是完整条目：扩展 `SManga.create()` 一个新对象，
只填元数据（title / thumbnail_url / genre / description / author / artist / status），**从不回填 `url`**——
`url` 是条目身份，上游官方 app 只把元数据 merge 回已存条目，永远不读返回值的 `url`。
`HttpSource.fetchMangaDetails` 也原样返回该对象，只额外置 `initialized = true`
（mihon `fdb223d6` `source-api/.../online/HttpSource.kt:245-251`）。

而 `SMangaImpl.url` / `title` 是 `lateinit var`（同 commit `source-api/.../model/SMangaImpl.kt:9-11`）。
Fushi 的桥接层把这个增量对象当完整条目用，缓存 key 和 `toBridgeMap()` 都第一行就读 `url`：

- `MihonChannelHandler.kt` `getDetailsManga` 分支：`cacheKey(source, result.url)`
- `MihonModelBridge.kt:9` `SManga.toBridgeMap()`：`"url" to url`

⇒ `kotlin.UninitializedPropertyAccessException: lateinit property url has not been initialized`。
它是 `RuntimeException`、不是 `IllegalArgumentException`，正好落进 `MihonChannelHandler` 的
`catch (_: Throwable)` 兜底桶 → `RUNTIME_FAILURE` + 固定文案。

**为什么列表不炸**：列表/搜索解析走 `setUrlWithoutDomain(...)`，`url` 有值；`chapterListParse` 也
调 `setUrlWithoutDomain` + `setName`。**只有详情**返回未初始化 `url` 的对象。所以这不是 Manga Mura
专属——凡是 `mangaDetailsParse` 不回填 `url`（Mihon 扩展的普遍写法）都会中招。

同族缺陷（桌面）：`third_party/m_extension_server` 的 `ResponseModels.kt:88-99` 用
`runCatching { this.url }.getOrDefault("")` 读同一个字段，**不崩但把 url 静默变成空串**，
接下来拿空 url 去拉章节。所以身份收敛必须做在 Dart 侧才能同时覆盖两个后端。

### 放大伤害的第二个缺陷：桥接层把异常抹干净

`MihonChannelHandler.kt` 的 `catch (_: Throwable)` 把原始 `Throwable` 整个丢弃——不打日志、
不进 message、`details` 传 `null`。而扩展是第三方 dex，失败原因（缺类 / 网络 / 站点改版）**只存在于
cause 链**。Dart 侧 `MihonRuntimeException.toString()` 又不输出 cause，全仓无一处读
`PlatformException.details`；详情页 `_load()` 的 catch 也不记日志。三层叠加的结果是：
这个 bug 从用户截图到 ErrorLogService 都读不出任何可行动信息。

- **[x] ① 已修复** — 三处：
  1. `MihonModelBridge.kt` 新增 `SManga.mergedWithDetails()`：身份取入参，只有元数据走「新值覆盖旧值」；
     `MihonChannelHandler.kt` 的 `getDetailsManga` 改用它，不再读详情结果的 `url`。
  2. `MihonManga.mergedWithDetails()`（`mihon_models.dart`）+ `MihonBridgeRuntime.getDetails` 在 Dart 侧
     再收敛一次身份，覆盖桌面 sidecar 回传空 url 的同族缺陷。
  3. 诊断链路：`MihonDiagnostics.kt`（`describeCauseChain` / `diagnosticDetails`）+ 兜底改为
     `catch (error: Throwable)`，回传 `Mihon <method>/<inner> failed: <cause 链>` 与堆栈（`details`），
     并 `Log.e("MihonChannel", …)`；`MihonRuntimeException` 增加 `details`/`diagnostics`；
     详情页记录失败阶段（details / chapters / library）、写 ErrorLogService、渲染带「重试 + 查看详情」的失败态。
- **[x] ② 已加自动化测试** —
  - `fushi/test/media/manga/mihon_detail_identity_test.dart`：Dart 合并语义 + 空 url 回传时身份不丢 +
    Kotlin 源码守卫（`getDetailsManga` 不得读详情结果的 `url`、兜底不得再吞 `Throwable`）。
    守卫扫描前先剥注释——本文件自己注释里就写过 `update.url`，直扫原文会被自己的注释骗。
  - `fushi/test/media/manga/android_mihon_runtime_error_test.dart`：`PlatformException` 的
    code/message/details 三者透传。
  - `fushi/test/media/manga/mihon_source_browse_page_test.dart`：详情页失败态渲染 + 诊断对话框 + 重试复原。
  - 四条变异实测全部让守卫变红、且文件逐字节还原。
- **备注**：真机复测缺口——本机当前无连接设备/可用模拟器 NAT 到 Manga Mura 的验证环境，
  修复是沿真实代码路径静态确证（上游 `SMangaImpl` lateinit + `MangaReader.mangaDetailsParse` 不设 url，
  两处均从源仓核对过原文）+ 单测/守卫覆盖，未做真机端到端。装上新 debug 通道包后，
  若仍失败，`adb logcat -s MihonChannel:E` 或详情页的「查看详情」会直接给出真实 cause。
