## BUG-1702 · release APK 的 R8 混淆掉宿主 Kotlin 运行时，所有 Mihon 漫画扩展 LOAD_FAILED
- **报告**：2026-08-17（用户：手机上装 Keiyoushi 漫画扩展报 `MihonRuntimeException (LOAD_FAILED): Unabl…`，截图里 toast 被截断）
- **真实性**：✅ 真 bug。根因 `fushi/android/app/proguard-rules.pro`（缺 `kotlin.**` / `eu.kanade.tachiyomi.util.**` 的 keep）→ 表现在 `fushi/android/app/src/main/kotlin/app/fushi/reader/mihon/MihonExtensionLoader.kt:144`（`Class.forName(...).newInstance()` 抛异常被包成 `LOAD_FAILED`）。

  实证（拆用户实际运行的 release 包 `fushi-2.1.1-arm64-v8a.apk` 与真实扩展 APK 对拆 dex）：
  - Mihon 扩展 APK 是**独立编译**的第三方 dex，把 Kotlin 运行时当 compileOnly（由宿主提供），字节码里写死**未混淆的原名**。`tachiyomi-all.ahottie-v1.6.4.apk` 引用 22 个 `kotlin.*` 类（`kotlin.Lazy` / `kotlin.LazyKt` / `kotlin.jvm.internal.Intrinsics` / `kotlin.jvm.functions.Function0` …）。
  - 宿主 release APK 里 `kotlin.*` 只剩 34 个类，全是被 R8 改名成单字母的 `kotlin.jvm.internal.A/B/C…` 加一个 `kotlin.Metadata`。扩展需要的那 22 个里，除 `kotlin.Metadata` 外**一个都不存在**。
  - 佐证同一处混淆：宿主 `HttpSource` 的字段签名已变成 `headers$delegate : LW4/f;` —— `kotlin.Lazy` 被改名为 `W4.f`（字段名本身靠 `-keep class eu.kanade.tachiyomi.source.** { *; }` 保住了，类型没保住）。
  - 扩展的 source 类构造函数第一条就是 `invoke-static kotlin.LazyKt.lazy(...)`（`ExtensionGenerated` → 父类 `n.<init>`），于是 `newInstance()` 必抛 `NoClassDefFoundError` → `LOAD_FAILED`。

  影响面：**所有 Kotlin 编写的 Mihon 扩展 100% 装不上**（等于全部），与 lib 1.4 / 1.6 无关。**debug 构建不 minify，类名全在，所以本地永远复现不了**，只有 release APK 必现 —— 这正是过去被误判成「个别扩展缺类」的原因。

  同批发现的第二个缺口（同一根因、同一修复）：`eu.kanade.tachiyomi.util.**` 从未被 keep，而宿主自身一次都不调用它，R8 把整个包删掉了；扩展解析 HTML 必用的 `JsoupExtensionsKt.asJsoup()` 因此在 release 上也不存在。

- **[x] ① 已修复** — `fushi/android/app/proguard-rules.pro` 新增「Mihon 扩展宿主 ABI」区块，按上游 Mihon `app/proguard-rules.pro` 的 "Keep common dependencies used in extensions" 区块逐条对齐：补 `kotlin.**` / `kotlin.time.**` / `eu.kanade.tachiyomi.util.**` / `com.squareup.zstd.**` / `app.cash.quickjs.**`。（Mihon 自己走 `-dontobfuscate` 全保，Fushi 有混淆，只能逐包 keep。）提交 `edfed870ca`。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/mihon_host_abi_keep_guard_test.dart`：以两个真实 Keiyoushi 扩展 dex 解析出的「引用但未定义」类清单为基准，断言 proguard-rules.pro 里每个类都被至少一条**不带 `allowobfuscation`** 的 keep 覆盖。变异实测两轮均由绿转红：① 删掉 `kotlin.**` keep → 精确报出 16 个 `kotlin.*` 缺口；② 把该 keep 改成 `-keep,allowobfuscation` → 同样报红（验证「允许改名等于没保」这条语义生效）；两轮还原后 proguard-rules.pro 的 sha256 与变异前逐字节一致。
- **备注**：
  - 未纳入本次修复的相邻事实，另见 BUG-1703：错误消息投递通道在 Android 上是 `Fluttertoast`（系统原生 Toast，硬上限 2 行、不可复制），所以 `MihonExtensionLoader` 在 develop 上已经带的链式根因（`03c98a0828`）**依然送不到用户眼前**，截图里就断在 `Unabl…`。用户报的 v2.1.1 更早于该提交，消息里连根因都还没有。
  - 已知但**未**处理：宿主的 QuickJS 来自 `com.github.zhanghai.quickjs-java`，类名落在 `app.cash.quickjs.*`（与扩展预期一致），本次已补 keep；但成员级兼容未验证，用 QuickJs 的扩展仍可能 `NoSuchMethodError`，需真机复验后另开条目。
  - 验证限制：本机模拟器 NAT 走不通宿主 fake-ip 代理，装源 E2E 只能真机验；本条的根因与修复均由 dex 级静态实证确立，尚未在真机 release 包上跑过「装扩展 → 成功」的端到端。
