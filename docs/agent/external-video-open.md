# 从 app 外用 Fushi 打开视频（Windows 文件关联 / argv）

目标：在 Windows 资源管理器里右键视频「打开方式 → Fushi」、把视频拖到
`fushi.exe`、或命令行 `fushi.exe "<视频>"` → Fushi 接收路径 → 直接播放
（`VideoFushiPage`）+ 把它加入书架视频分区（建 `VideoBook`，外部路径不复制），
之后能在书架再次打开。

## 数据流（argv → Dart → 播放 + 入库）

1. **Windows runner**：`windows/runner/utils.cpp::GetCommandLineArguments()` 用
   `CommandLineToArgvW` 取 argv（去掉 binary 名）转 UTF-8；`main.cpp` 经
   `project.set_dart_entrypoint_arguments(...)` 把它喂给 Dart entrypoint。
   **C++ 侧无需改动**——Flutter Windows 标准模板已具备该传递。
2. **Dart `main(List<String> args)`**（`fushi/lib/main.dart`）：仅桌面平台，用
   `firstExternalVideoArg(args)`（`lib/src/media/video/external_video.dart`）挑出
   第一个受支持的视频路径，存在性校验（`File.existsSync`）后暂存到顶层
   `_pendingExternalVideoPath`。
3. **app 初始化完成后**：`_FushiReaderAppState.build` 在 `isInitialised==true`
   分支调度一次性 post-frame callback → `_openExternalVideo(path)`：
   - bookUid 用 `externalVideoBookUid(path)`（规范化路径的 sha1 前 12 位，前缀
     `video/ext/`）——**幂等**：同一文件重复打开复用同条记录、保留进度。
   - 不存在则 `saveVideoBook`（title=文件名，videoPath=外部绝对路径，**不复制**）。
   - 用全局 `navigatorKey` push `VideoFushiPage(bookUid, repo)` 播放。
   - 字幕**无需预解析**：`VideoFushiPage._init` 在 `subtitleSource` 为空时自动
     探测同名 sidecar 字幕（`findSidecarSubtitle`：`.ja.srt > .ja.ass > .srt >
     .ass`）。内嵌字幕轨由 libmpv 渲染。
4. VideoBook 已入库 → 书架视频分区自动出现该条目，后续可再打开。

### 命名约定区分

- **外部打开**：`video/ext/<sha1前12>`（全路径派生，跨同名文件唯一）。
- **手动导入单视频**（`VideoImportDialog._doImport`）：`video/<basename>`。
- **m3u8 播放列表**：`video/playlist/<basename_短哈希>`。

三者前缀不同，互不覆盖。

## 支持的扩展名

`isSupportedVideoFile`（`external_video.dart`）白名单派生自共享真相源
`kVideoExtensions`（`media_extensions.dart`，导入 / 目录扫描 / 刮削同表）
∪ 显式增项 `3gp`（历史上只在外开白名单，导入表暂不收录）。此前这里手写第三份
整表并已漂移（`.rmvb` 能导入却不能外开）；防漂移守卫见
`test/media/video/external_video_test.dart`。不在表内的扩展名一律拒绝，
避免把词典 zip / EPUB 误当视频打开。

## Windows 文件关联

安装包 `windows/installer/fushi.iss` 含可选 `[Tasks] videoassoc`（默认勾选），
注册到 **HKCU**（`PrivilegesRequired=lowest`，无需管理员）：

- ProgId `Fushi.Video` → `shell\open\command = "fushi.exe" "%1"`。
- `Applications\fushi.exe`（让 Fushi 出现在「打开方式」列表 + 声明 SupportedTypes）。
- 各扩展名的 `OpenWithProgids` **追加** `Fushi.Video`（不改系统默认播放器，只在
  右键「打开方式」里多一个 Fushi 候选）。

卸载时 `uninsdeletekey` / `uninsdeletevalue` 清理。

### 手动注册（不装安装包 / 调试构建）

资源管理器里右键视频 → 打开方式 → 选择其他应用 → 浏览到 `fushi.exe` → 勾选
「始终」即可（argv 路径已能处理）。或命令行直接：

```
fushi.exe "D:\video\Dragon Maid\S01E01.mkv"
```

## single-instance 转发（TODO-904：已实现）

runner 用 `CreateMutexW(L"FushiSingleInstanceMutex")` 做**真单实例**（检测
`ERROR_ALREADY_EXISTS`）：app 已开着时再从外部打开一个视频，第二实例**不会**起新
窗口（避免双实例共享同一 WebView2 userDataFolder 的锁冲突），而是把视频路径**转交**
给首实例后退出。链路：

1. 第二实例 `main.cpp`：`FirstFileArgFromCommandLine()` 从 argv 取第一个文件参数 →
   `::fushi::SendExternalVideoPath(existing, file_arg)`（`external_video_handoff.*`）
   用 `WM_COPYDATA`（dwData magic `kExternalVideoCopyDataMagic`，lpData 为 UTF-8
   路径字节）发给首实例窗口 → 前置窗口 → `return EXIT_SUCCESS`。**无文件参数**（纯
   第二次启动）则只前置 + 退出，不发消息。
2. 首实例 `flutter_window.cpp::MessageHandler` 收到 `WM_COPYDATA` →
   `DecodeExternalVideoPath`（magic 不匹配则忽略）→ 经 `app.fushi/external_video`
   MethodChannel `InvokeMethod("openExternalVideo", path)` 推给 Dart。
3. Dart `_FushiReaderAppState._handleExternalVideoChannel`（`main.dart`，仅 Windows
   注册）：做与首启 argv 等价的校验（`isSupportedVideoFile` + `File.existsSync`），
   通过后复用 `_openExternalVideo`（同一打开链路，不另造第二套）。若首实例尚未初始化
   完成，则暂存到 `_pendingExternalVideoPath` 交由 `build` 的首启分支接手。

守卫：`test/native/windows_single_instance_guard_static_test.dart`（转交链路源码扫描）。
WM_COPYDATA 真实跨进程行为 headless 测不到，须真机验证（app 已开 → 双击/右键用
Fushi 打开另一个视频 → 复用已开窗口打开播放页，不起第二进程）。

## 验证

- 纯函数测试：`test/media/video/external_video_test.dart`
  （`isSupportedVideoFile` / `externalVideoBookUid` / `firstExternalVideoArg`）。
- 真机：`fushi.exe "<某视频绝对路径>"` 启动应自动打开播放页 + 书架出现条目。

## 外部打开书 / 漫画（2026-10-14）

同一条链路也接书：资源管理器右键 `.epub` / `.pdf` / `.txt` / `.cbz` / `.cbr` /
`.cb7` / `.mokuro` →「打开方式 → Fushi」，或 `fushi.exe "<书>"`。

- **原生层不变**：Windows `FirstFileArgFromCommandLine` / `WM_COPYDATA` 与 Linux
  D-Bus 转交的本来就是任意候选路径，不看扩展名；通道名 `app.fushi/external_video`
  与方法名 `openExternalVideo` 保持原名（守卫逐字钉着），语义是「外部候选参数」。
- **Dart 白名单**：`lib/src/media/import/external_book.dart` 的
  `kExternalBookOpenExtensions`（刻意比导入白名单窄：不收 `.zip` / `.json` 等）。
  冷启动 `main()` 先认视频、再认书（`_pendingExternalBookPath`）；单实例转交在
  `_handleExternalVideoChannel` 里视频优先、其次书。
- **落地 `_openExternalBook`**：入库复用 `fushi_cli library import` 的
  `LibraryCtlImporter`（载体判定、图片型 EPUB 归漫画、模块门全同一份）。同名书已在库
  时传 `askOnDuplicate` 弹框问用户（同名 ≠ 同一本，如两部作品的 `01.cbz`）：选
  「打开已有」→ 导入器抛 `DuplicateImportCancelledException`，结果带回已在库那本的 key
  （`existingBookKeyForTitle`，与 `resolveDuplicateTitle` 同口径），打开它、保留进度；
  选「作为新书导入」→ 加序号后缀落新的一本。同一路径导入进行中再次打开直接忽略。
  随后查 `EpubBooks.format` →
  `buildCollectionReaderMediaItem` → `appModel.openMedia` 打开对应阅读器。
  与外部视频的区别：书会被**复制**进书库（阅读器读解压目录），不引用原路径。
- **安装包**：`fushi.iss` 的 `[Tasks] bookassoc`（默认勾选）登记 ProgId `Fushi.Book`、
  `SupportedTypes` 与各扩展名 `OpenWithProgids`（只追加候选，不改默认关联）。
  `Applications\fushi.exe` 键两任务共用（`Tasks: videoassoc or bookassoc`）。
  扩展名与 Dart 白名单的双向一致由 `test/media/import/external_book_test.dart` 守卫。
- **尚未覆盖**：Android（无 VIEW + mime intent-filter，`content://` 需复制到临时文件）、
  macOS（无 `CFBundleDocumentTypes` / `application(_:openFile:)`，视频也一样没有）、
  iOS（无 `CFBundleDocumentTypes`）、Linux 无 `.desktop` 的 `MimeType=` 声明；
  `fushi_cli open` 仍只认视频（书用 `library import`）。
