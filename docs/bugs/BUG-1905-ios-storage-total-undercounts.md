## BUG-1905 · 存储统计漏算缓存根与白名单外顶层项：app 内 6.9GB vs 系统 13.68GB
- **报告**：2026-08-28（用户：「ios 存储数据统计有问题」，两张截图——app 内「存储」页总计 6.9 GB，iOS 系统设置里 Fushi 的「文稿与数据」13.68 GB）
- **真实性**：✅ 真 bug。

### 根因（两层，互相掩护）

**① 第三个根从来没被扫过**

`AppPaths` 定义了三个根，`storage_usage_service.dart` 的 `scanCategories` 只消费了两个：

```dart
final Directory docs = await _documentsRoot();
final Directory support = await _supportRoot();
```

`tempRoot` 一次都没出现。而在 iOS 上它恰恰是大头 —— **`path_provider` 的
`getTemporaryDirectory()` 在 Apple 平台返回的是 `Library/Caches`**
（`PathProviderPlugin.swift` 的 `case .temp: return .cachesDirectory`），
而 Dart 的 `Directory.systemTemp` 读 `TMPDIR` 指向 `<沙盒>/tmp`——**两个不同目录，
两个都没扫**。已知落在那里的东西：远端封面缓存（注释自陈「跨重启存活」）、互联导入
发音库的 staging 副本（与 support 里那份**重复**，发音库是 GB 级）、整包
`.fushiaudio` / EPUB、备份 zip、`file_picker` 对每个导入文件的整份复制、
`flutter_cache_manager` 的图片缓存。

iOS 系统设置的「文稿与数据」= `Documents` + 整个 `Library/*` + `tmp`，三块全算；
只扫两块必然少报。

**② 总计 = 各类目之和，所以漏算永远发现不了**

`storage_usage_view.dart` 的总计就是十一个类目相加，没有任何独立口径参与校对。
而类目 = 一份手写白名单（`kStorageCategoryDocumentsChildren`），漏了什么就静默少算
多少。守卫测试也只断言「类目清单 == `AppPaths.fushiOwnedDocumentsEntries`」——而那份
迁移白名单**本身就故意排除**了 temp、剪辑导出 `video_clips`、错误日志。
统计复用迁移口径，等于把迁移的豁免项原样继承成了记账黑洞。

### 修复与测试

- **[x] ① 已修复** — 新增两个类目：
  - **`cache`（缓存与临时文件）**：扫此前完全没扫的缓存根。
    **根的选取按平台门控**，这是本类目的正确性红线：iOS/Android 两个目录都在沙盒内
    且互不相同（去重后都算）；macOS 只算 app 私有的 `Library/Caches`，
    `systemTemp`（`/var/folders/…/T`）跨 app 共享不算；**Windows/Linux 一律为 0**
    ——那里的 `%TEMP%` / `/tmp` 是全系统共享的，装着别的程序的文件，算进来会严重
    **高报**。要在桌面统计 Fushi 自己的临时文件，只能再引入一份「哪些子目录是我们的」
    白名单，而白名单漂移正是本 bug 的成因，不再重蹈。
  - **`other`（其他未归类）**：documents 根下**不在**白名单里的顶层项。它的意义是让
    「漏算」变得**结构上无法隐藏**——白名单外的东西会自己冒出来，而不是静默消失。
    已知的两个既有漏点（`video_clips`、错误日志 `.txt`）自动落进这里。
    只在 documents 根是 Fushi 专属容器时启用（新增
    `AppPaths.documentsRootIsFushiOwned()`）：桌面老扁平安装的 documents 根就是用户
    自己的文档文件夹，把用户的文件算成 app 占用既不准也吓人，那种情况恒为 0。
  - i18n `storage_category_cache` / `storage_category_other`（17 语言）+ UI 图标/文案。
- **[x] ② 已加自动化测试** — `fushi/test/storage/storage_usage_service_test.dart` 新增
  三个用例：cache 类目统计注入的缓存根、other 只收白名单外顶层项（白名单内的目录出现
  在 other 就是重复计数，显式断言其**不**出现）、非专属容器时 other 恒为 0。
  **变异实测**（2026-08-28）：去掉 other 的白名单过滤 → 重复计数用例转红；
  把 cache 的根列表钉成空 → cache 用例转红。还原后 storage + i18n 共 218 项全绿。

### 备注

- **本轮开发中被测试当场抓到的一个真实设计缺陷**：第一版实现无条件把
  `Directory.systemTemp` 也算进去，结果单测直接去扫了真实的 Windows 临时目录
  （跑了 5 分钟且失败）。那不只是测试问题——桌面上那样做会把别的程序的临时文件算成
  Fushi 的占用。平台门控就是为此加的。
- **仍未覆盖、会继续少报的部分**（如实记录，未修）：
  - iOS 的 `Library/WebKit`、`Library/Preferences`、`Library/Cookies` —— 全仓没有任何
    一处配置自定义 WebView 数据目录，7 个 `InAppWebView` 实例全用默认
    `WKWebsiteDataStore.default()`，其占用落在 app 无法枚举的系统托管目录里；
  - 桌面的共享临时目录（见上）。
  因此「app 内总计」与 iOS 系统数字仍可能有差额，但差额来源现在是**已知且可解释的**，
  不再是一个静默黑洞。
- **相邻问题（未修，另计）**：`real_path_directory_picker.dart:155` 的注释把 iOS 归成
  「`pickFiles()` 已返回真实路径、不复制」，与 `file_picker` 的 iOS 实现
  （`UIDocumentPickerModeImport`，整份复制进 `NSTemporaryDirectory()`）**矛盾**；
  这条错误前提让 iOS 侧所有导入都不清临时副本 —— 导一个 3 GB 的 m4b 就在 tmp 里多一份
  3 GB。全仓只有词典对话框调 `clearTemporaryFiles()`。这是「占用为什么会那么大」的
  真正成因之一，属于清理逻辑而非统计逻辑，需要单独一条修复。
- 未做真机复测（需要 iOS 设备对账系统数字）。
