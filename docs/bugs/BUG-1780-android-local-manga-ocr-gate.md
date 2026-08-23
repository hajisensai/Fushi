## BUG-1780 · 安卓本地漫画 OCR 不可用：整卷平台白名单漏掉 Android，模型下载入口被同一闸门连坐关闭
- **报告**：2026-08-23（用户：群反馈截图，安卓调试版）
- **真实性**：✅ 真 bug（一个闸门承担两个语义）

### 症状
安卓上「设置 → 漫画 → OCR 引擎」里「本地 ONNX」恒灰点不动；存储页却显示
`ocr_models/manga` 占 266 MB。用户以为是模型没下全导致选不了。

### 根因
`isSupportedPlatform` 这**一个**闸门同时承担了两个互不相同的语义：

1. 「整卷 OCR 这种重活允不允许」——`fushi/lib/src/ocr/manga_ocr_service_impl.dart`
   `defaultPlatformSupport()` 的平台白名单 `Windows || Linux || macOS || iOS`，
   **从未包含 Android**（`git log -S"Platform.isAndroid"` 对该文件零命中）。
2. 「本机能不能跑本地 ONNX 推理」——真相源是 `fushi/lib/src/ocr/ocr_inference_ort.dart`
   的 `isLocalOnnxRuntimeAvailable`，它**包含 Android**（安卓 ORT native 一直正常注册）。

两个语义共用一个位，于是安卓被 (1) 连坐拿走了本该由 (2) 决定的东西：

- `fushi/lib/src/media/manga/manga_ocr_settings_section.dart` 的模型区（下载 / 删除 /
  占用）整块吊在 `if (widget.service.isSupportedPlatform)` 上 → 安卓**不渲染下载和
  删除按钮**，只显示一行「内置漫画 OCR 暂不支持当前平台」。
- 同文件 `initState` 也按同一个位决定要不要 `_loadStatus()` → 安卓上 `_status` 恒 null。
- 而框选识别（单框重扫）的闸门是 `fushi/lib/src/media/manga/ocr/manga_box_rescan.dart`
  的 `isLocalRescanSupported => isLocalOnnxRuntimeAvailable`，**在安卓为真、本该可用**，
  它需要同一套识别模型。

结果是死循环：安卓用户在阅读器点「框选识别」→ 提示 `manga_rescan_model_missing`
（"请先在设置里下载漫画 OCR 模型"）→ 设置里安卓根本没有那个下载按钮。已经下了一半
的 266 MB 也因为删除按钮同样被连坐关闭而**既下不完也删不掉**。

附带确认（非本 bug 主因，但同一路径上的真实缺口）：
- 用户那 266 MB 确实没下全。清单 `manga_ocr_model_manifest.dart` 四件套合计
  472,085,492 B（app 按 1024 进制显示 450.2 MB），缺的约 184 MB 基本是
  `encoder_model.onnx`（343 MB）没下完，残留在 `.part` 里；存储页统计用
  `listSync(recursive: true)` 不过滤 `.part`，所以「显示占 266 MB」与「模型未下载」
  同时成立（这部分是 BUG-1732 有意为之，不是缺陷）。
- `resolveMangaOcrEngine()` 返回 null 时，`manga_ocr_wizard_dialog.dart` 兜底成
  `preference.explicitEngine ?? MangaOcrEngineId.localOnnx`。auto 的 `explicitEngine`
  是 null，于是在没有可用配对主机的安卓上，auto **兜底到当时并不可用的 localOnnx**，
  表现为「自动 = 卡住」。

### 第二道墙：引擎闸门（同一根因链，一并修）
即便平台闸门放开，**全新安装的用户仍然看不到下载入口**：
`_buildLocalModelArea` 在「当前引擎用不到本地模型 且 磁盘干净」时整块
`SizedBox.shrink()`，而出厂默认引擎恰恰是用不到本地模型的 `google_lens`。
本意是「别劝只用 Lens 的用户下 450 MB」，落地成了「不给你下的机会」。

**这条为什么没被守卫抓到**：`_readEnginePreference()` 在未注入 getter 时回退
`auto`，而生产默认是 `google_lens`——**测试默认值与生产默认值分叉**，UI 守卫因此
长期在跑一条用户碰不到的分支，恒绿。

### 修复
1. `manga_ocr_service_impl.dart` `defaultPlatformSupport()` 不再维护第二份平台
   白名单，直接 `=> isLocalOnnxRuntimeAvailable`（唯一真相源，含 Android）。
2. `manga_ocr_engine.dart` 新增 `kDefaultMangaOcrEnginePreference`，偏好仓库与
   设置区回退值共用它，消除默认值分叉。
3. `manga_ocr_settings_section.dart` 的 `SizedBox.shrink()` 换成次级下载入口
   `_buildDormantModelEntry`（普通 TextButton，不喊「未下载」——不劝，也不藏）。
4. **`android/app/proguard-rules.pro` 补 `-keep class ai.onnxruntime.** { *; }`**。
   这条是 release 阻塞项，见下。
5. `_volumeJobIsolateMain` 里 `RootIsolateToken == null` 不再静默跳过，补 log。

### ⚠️ 订正：不是「慢而不是崩」，release 上是真会崩
本文件初稿写的「解开闸门后是『慢』而不是『崩』」**只在 debug 上成立**。
release APK `minifyEnabled true`，而 `libonnxruntime4j_jni.so` 按**类名字符串**
`FindClass`；已核实 `onnxruntime-android:1.23.0` 的 AAR **只有 classes.jar、不带
consumer `proguard.txt`**，app 三处 proguard 也没有 keep。从 `.so` 提取到 12 个
硬编码描述符，其中 `TensorInfo` / `OrtException` / `MapInfo` / `SequenceInfo` /
`ValueInfo` 落在 AGP 默认 `-keepclasseswithmembernames,includedescriptorclasses`
覆盖范围之外（`throws` 子句不属于方法描述符，救不到 `OrtException`）。
不补 keep 就是交付一个 release 必崩、debug 永远复现不了的功能——与 BUG-1702
`kotlin.Lazy` 被改名同形。

### 测试
- `fushi/test/ocr/onnxruntime_r8_keep_guard_test.dart`（新增）：12 个 JNI 反查类
  必须被不可改名的 keep 覆盖。**变异实测**：改成 `-keep,allowobfuscation` → 红；
  整行删除 → 红；两次还原后 sha256 与基线一致。
- `fushi/test/ocr/manga_ocr_service_impl_test.dart`：平台闸门测试改为钉「闸门 ==
  ORT 可用性」，并**新增源码守卫**——扫 `defaultPlatformSupport()` 实现体，出现
  `Platform.` 即红。旧写法按宿主算 expected，在 Windows/macOS 上改前改后都绿、
  只有 Android 宿主才红，而单测从不在 Android 跑，等于没有守卫。**变异实测**：
  塞回 `Platform.isWindows &&` → 红；还原后 sha256 与基线一致。
- `fushi/test/media/manga/manga_ocr_settings_section_ui_test.dart`：新增「出厂默认
  引擎下，模型下载入口仍然可达」；两条原本依赖回退值的用例改为**显式**注入
  `enginePreferenceGetter`，不再隐式吃默认值。

### 未做（已知缺口，不要当成已解决）
- **安卓真机从未跑过 ORT**。本次是 Android 上第一次真正执行本地推理：此前闸门
  虽为真的框选识别也因为下载入口被连坐关闭而「门开着、门后没路」，从未真跑。
  与 BUG-1613 的 Apple CoreML「分支存在但从未被执行」同形，**别把闸门为真当成
  已验证**。补证据的现成入口：`integration_test/manga_ocr_apple_native_itest.dart`
  （毫秒级、不下模型）+ `manga_ocr_volume_e2e_itest.dart`，且**必须跑 minify 变体**
  才能验证第 4 条。
- **长任务后台存活 = 零**。退出漫画阅读页即 `dispose()` 无条件 cancel，无前台
  服务。逐页缓存（`manga_ocr_out/_pages/`）保证「不丢进度、可续跑」，但保证不了
  「用户以为在跑其实早停了」。**本次刻意没加 wakelock**：漫画阅读页存活期间
  app 已按 `keepScreenAwake` 偏好开着 wakelock，而全 app 的 wakelock 是裸
  enable/disable **无引用计数**，再加一个调用方只会误关别人的。正解是 `dataSync`
  前台服务，属独立改动。
- **互联 host 的行为变化**：`fushi_manga_ocr_host.dart` 的 `/api/capabilities`
  直读 `isSupportedPlatform`，闸门一开，安卓手机会向局域网对端宣告「我能代跑整卷
  OCR」，桌面可以把活推到手机上。协议上没问题（能力协商本就是动态的），是否要按
  设备类型再收一道是产品决定。
- **i18n `manga_ocr_unsupported`** 文案仍是「暂不支持当前平台」（平台白名单口径），
  而该分支在出包五端已不可达，只剩「将来某端 native 被摘掉」的理论兜底。key 保留
  （删了等于删掉降级出口），文案措辞未改，避免为一句不可达文案改动 17 个语言文件。

- **[x] ① 已修复** — `40ad94fe04`，见上「修复」段
- **[x] ② 已加自动化测试** — `40ad94fe04`：
  `fushi/test/ocr/onnxruntime_r8_keep_guard_test.dart`（新增）、
  `fushi/test/ocr/manga_ocr_service_impl_test.dart`（闸门源码守卫）、
  `fushi/test/media/manga/manga_ocr_settings_section_ui_test.dart`（出厂默认引擎下
  下载入口可达）。两条新守卫均已变异实测。
- **备注**：Android 走纯 CPU 执行提供者（`selectOcrExecutionProviders` 对 `android`
  早有显式分支，见 `fushi/test/ocr/manga_ocr_service_impl_test.dart` 的「Linux /
  Android：纯 CPU」），不会踩 BUG-1149 那条「传了插件不认的 EP」。整卷在低端安卓
  上是「挂着跑几十分钟到几小时」的量级，与 A13 同档；不接受的用户仍有「已配对
  主机代跑」和 Google Lens。
