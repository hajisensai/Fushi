## BUG-2045 · 桌面 Mihon sidecar 用漫画源搜在线漫画报错（500）
- **报告**：2026-09-02（用户：截图 `MihonRuntimeException(BRIDGE_HTTP_500): class java.util.ArrayList cannot be cast to class e0 (... e0 is in unnamed module of loader java.net.URLClassLoader @1e594ca0)`，「用漫画源搜在线漫画的时候好像会报错」）
- **真实性**：✅ 真 bug，桌面端特有，**两个独立根因**，症状都表现为「浏览热门正常、一搜就 500」

  之所以只在搜索上暴露：搜索页要先拉源的筛选器，两条路径都会调用扩展的 `getFilterList()`
  （`MihonInvoker.kt:178` 的 `filtersManga`、`:223` 的 `getSearchManga`），而
  `getPopularManga` / `getLatestUpdates` 完全不碰它。

  本机 6 个已装扩展实测（脱离 app 直连 sidecar 取完整 Java 栈）：rawkuma ❌、koharu ❌，
  rawlh / mangadex / ahottie / raw18 ✅（这四个的失败都是本机代理 fake-ip 导致的网络超时，与本 bug 无关）。

  ### 根因 A —— 桌面宿主 ABI 版本落后 Android 宿主
  扩展 APK 把宿主提供的一切（Kotlin 运行时、coroutines、okhttp、jsoup、source-api…）都当
  compileOnly，dex 里**只留引用、不带定义**（`mihon_host_abi_keep_guard_test.dart:55-72` 的清单
  就是这么解析出来的），运行期全部由宿主解析。宿主版本落后于扩展编译时链接的版本，就会在调用点
  直接 `NoSuchMethodError`：

  ```
  java.lang.NoSuchMethodError: 'java.lang.Object kotlinx.coroutines.BuildersKt.runBlockingK(
      kotlin.coroutines.CoroutineContext, kotlin.jvm.functions.Function2)'
      at eu.kanade.tachiyomi.extension.ja.rawkuma.ExtensionGenerated.getFilterList(Unknown Source)
      at mextensionserver.impl.MihonInvoker.invokeFiltersManga(MihonInvoker.kt:178)
  ```

  本机对拍两个 jar 的 `kotlinx/coroutines/BuildersKt.class`，差异是硬的：

  | kotlinx-coroutines | `BuildersKt` 里的方法 |
  |---|---|
  | **1.10.2**（桌面 sidecar，`upstream_src/gradle/libs.versions.toml:3`） | `runBlocking`, `runBlocking$default` |
  | **1.11.0**（Android 宿主，`fushi/android/app/build.gradle:295`） | 多出 `runBlockingImpl`, **`runBlockingK`**, `runBlockingK$default` |

  rawkuma 的 dex 引用 `BuildersKt.runBlockingK` 且 `defined_in_dex=False`（要求宿主提供），
  桌面宿主给 1.10.2 → 找不到方法。**Android 端同一扩展完全正常**，这类漂移天然只在一端暴露。
  同时发现 jsoup 也漂了（sidecar `1.21.2` vs Android `1.22.2`）。

  ### 根因 B —— dex2jar 把分配点泛化成抽象基类
  ```
  java.lang.InstantiationError: eu.kanade.tachiyomi.source.model.Filter$Group
      at p.getFilterList(Unknown Source)
      at mextensionserver.impl.MihonInvoker.invokeFiltersManga(MihonInvoker.kt:178)
  ```
  用 dex2jar 自己的 reader 解析 koharu 原始 dex，`Lp;.getFilterList` 里是
  `new-instance Lp0;`（`Lp0;` = public final，`extends Filter$Group`，dex 里有定义）；
  而 dex2jar 输出的 jar 里这条变成了 `NEW Filter$Group` + `INVOKESPECIAL Filter$Group.<init>`
  ——**两处 owner 一起被泛化**。同方法里另外 8 个 `Lb1;`（同样 extends `Filter$Group`、构造器
  签名同为 `(String, List)`）却完好无损，所以不是「宿主少了类」，是单个分配点在控制流合并处
  被推断成了公共父类。JVM 规范禁止实例化抽象类，运行到即 `InstantiationError`。

  隔离实验已排除 `BytecodeEditor.fixAndroidClasses`：对同一 APK 分别产出「纯 dex2jar 输出」与
  「再过 fixAndroidClasses」两个 jar，`p.getFilterList` 的 NEW/CHECKCAST 序列**逐条相同**，
  错误在纯 dex2jar 阶段就已存在。（首轮我用手写指令宽度表扫 dex 得到过「dex 里没有
  `new-instance Filter$Group`」的假阴性——payload 处会错位，别再用手写宽度表判定 dex。）

  上游 Mihon `source-api` 与 keiyoushi `extensions-lib` 的 `Filter.Group` **都是 abstract**，
  已逐一取回原文核对，排除「扩展针对 open class 编译」这条假设。

- **[x] ① 已修复** —
  - **根因 A**：`third_party/m_extension_server/server-build.gradle.patch` 的 `libs.versions.toml`
    hunk 把 `coroutines` `1.10.2 → 1.11.0`、`jsoup` `1.21.2 → 1.22.2`，与 Android 宿主对齐
    （`serialization` 原本已是 1.11.0）。
  - **根因 B（部分修复，koharu 仍不可用——见备注）**：新增
    `third_party/m_extension_server/overlay/.../util/DexAllocationRepair.kt`，
    在 `PackageTools.dex2jar` 的 `fixAndroidClasses` 之后用**原始 dex 的真值**对账修回被泛化的
    `NEW`。判据是可判定的、不猜：只碰 `NEW T` 且 T 抽象/接口（这类指令一定是转换 bug）；候选只从
    同一方法的原始 dex 分配集合里取；必须唯一对账（dex 有、jar 缺的具体子类恰好一个，且缺口数
    正好等于 `NEW T` 条数）；有歧义就原样放过，宁可保留一个明确的 `InstantiationError` 也不写进
    语义错误的 filter 类型。`NEW` 与配对 `<init>` 按栈序配对后一起改写，配不上对就整体不动
    （避免产出过不了校验器的字节码）。
  - **附带**（不修就无法在本机验证）：`tool/mihon/build_desktop_runtime.ps1` 与两个
    `verify_desktop_*.ps1` 用了 `[IO.Path]::GetRelativePath` / `-Encoding utf8NoBOM` /
    `RandomNumberGenerator::Fill` 三个 .NET Core-only API，**在 Windows 自带的 PowerShell 5.1 下
    直接崩**（CI 用 pwsh 7 所以从没暴露）。已换成 5.1/7 通吃的写法。
  - **诊断链路**（这类问题此前无法自证根因）：`DalvikHandler.errorResponse` 的 500 响应体补
    `errorType` + `stackTrace`；`desktop_mihon_runtime.dart` 把它填进
    `MihonRuntimeException.details`（桌面路径此前恒为 null，「查看详情」永远是空的）；sidecar 的
    stdout/stderr 不再被丢弃，落盘到 `<数据根>/support/mihon/logs/sidecar.log`（带轮转）。
    此前完整 Java 栈只存在于 sidecar stdout，而宿主在 ready 行之后就 `return` 丢弃、stderr 直接
    扔空，栈随进程退出永久消失，本机一个 sidecar 日志文件都没有。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/mihon_desktop_host_abi_parity_test.dart`
  - 「共享 ABI 依赖两边同版本」：解析 sidecar 的**有效**版本（vendored `libs.versions.toml` 再让
    补丁里对该文件的 `+` 行覆盖）与 Android `build.gradle` 的 `implementation 'g:a:v'`，对
    coroutines / serialization / okhttp / jsoup / rxjava 五项逐一比对。
  - 这条守卫是必需的：两边依赖声明分处两个文件、互不知情，漂移只在一个平台上暴露，定向测试和
    目录枚举型守卫都挑不到。
- **备注**：
  - **koharu 在桌面端仍不可用，本轮没修好，别当已解决**。`DexAllocationRepair` 确实把它的
    分配点修回来了（实测日志 `Restored dex allocation in p.getFilterList:
    NEW Filter$Group → NEW p0 (×1)`，`InstantiationError` 归零），但随即暴露下一层：
    `NoSuchMethodError: p0: method 'void <init>(java.lang.String, java.util.List)' not found`。
    原因是 `Lp0;` 在 dex 里是 `<init>(Lp;)V` 的 Kotlin 内部类（捕获外部类实例），dex2jar
    把整个构造**内联**成了父类的 `Filter$Group.<init>(String, List)`——owner、描述符、栈上
    实参三者一起被改写，字节码层面已无损恢复的信息。要真修得做 IR 级还原，等于重写
    dex2jar 的这条路径，不在本轮范围。
    因此给 pass 加了构造器签名保护：候选类没有匹配签名的构造器就原样放过，让 koharu 保持
    那个语义明确的 `InstantiationError`，而不是换成更难查的 `NoSuchMethodError`。
    **Android 端不经 dex2jar，同一扩展不受这条影响。**
  - 用户截图那条 `ClassCastException: ArrayList → e0` **未能在本机复现**。本机 6 个扩展跑遍了
    「带 filterList」与「不带 filterList」两条搜索路径都没触发，`convertFilterList` 全部通过。
    它与本条的两个根因同属「宿主 ABI / dex→jar 转换链」这一类，但没有直接证据，不并入本条结论。
    诊断链路修好后再遇到会直接带出扩展名与栈，届时按栈定位。
  - `PackageTools.kt:36-37` 把扩展 lib 版本上限钉在 `1.5`，而线上已有 lib `1.6` 扩展在流通
    （`ahottie-v1.6.4`）；桌面口径比 Android 窄一档。本轮未动，单独评估。
