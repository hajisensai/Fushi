# 从 app 外用 Hibiki 打开视频（Windows 文件关联 / argv）

目标：在 Windows 资源管理器里右键视频「打开方式 → Hibiki」、把视频拖到
`hibiki.exe`、或命令行 `hibiki.exe "<视频>"` → Hibiki 接收路径 → 直接播放
（`VideoHibikiPage`）+ 把它加入书架视频分区（建 `VideoBook`，外部路径不复制），
之后能在书架再次打开。

## 数据流（argv → Dart → 播放 + 入库）

1. **Windows runner**：`windows/runner/utils.cpp::GetCommandLineArguments()` 用
   `CommandLineToArgvW` 取 argv（去掉 binary 名）转 UTF-8；`main.cpp` 经
   `project.set_dart_entrypoint_arguments(...)` 把它喂给 Dart entrypoint。
   **C++ 侧无需改动**——Flutter Windows 标准模板已具备该传递。
2. **Dart `main(List<String> args)`**（`hibiki/lib/main.dart`）：仅桌面平台，用
   `firstExternalVideoArg(args)`（`lib/src/media/video/external_video.dart`）挑出
   第一个受支持的视频路径，存在性校验（`File.existsSync`）后暂存到顶层
   `_pendingExternalVideoPath`。
3. **app 初始化完成后**：`_HoshiReaderAppState.build` 在 `isInitialised==true`
   分支调度一次性 post-frame callback → `_openExternalVideo(path)`：
   - bookUid 用 `externalVideoBookUid(path)`（规范化路径的 sha1 前 12 位，前缀
     `video/ext/`）——**幂等**：同一文件重复打开复用同条记录、保留进度。
   - 不存在则 `saveVideoBook`（title=文件名，videoPath=外部绝对路径，**不复制**）。
   - 用全局 `navigatorKey` push `VideoHibikiPage(bookUid, repo)` 播放。
   - 字幕**无需预解析**：`VideoHibikiPage._init` 在 `subtitleSource` 为空时自动
     探测同名 sidecar 字幕（`findSidecarSubtitle`：`.ja.srt > .ja.ass > .srt >
     .ass`）。内嵌字幕轨由 libmpv 渲染。
4. VideoBook 已入库 → 书架视频分区自动出现该条目，后续可再打开。

### 命名约定区分

- **外部打开**：`video/ext/<sha1前12>`（全路径派生，跨同名文件唯一）。
- **手动导入单视频**（`VideoImportDialog._doImport`）：`video/<basename>`。
- **m3u8 播放列表**：`video/playlist/<basename_短哈希>`。

三者前缀不同，互不覆盖。

## 支持的扩展名

`isSupportedVideoFile`（`external_video.dart`）白名单：
`mkv mp4 m4v avi webm mov ts m2ts mts flv wmv mpg mpeg ogv 3gp`。
不在表内的扩展名一律拒绝，避免把词典 zip / EPUB 误当视频打开。

## Windows 文件关联

安装包 `windows/installer/hibiki.iss` 含可选 `[Tasks] videoassoc`（默认勾选），
注册到 **HKCU**（`PrivilegesRequired=lowest`，无需管理员）：

- ProgId `Hibiki.Video` → `shell\open\command = "hibiki.exe" "%1"`。
- `Applications\hibiki.exe`（让 Hibiki 出现在「打开方式」列表 + 声明 SupportedTypes）。
- 各扩展名的 `OpenWithProgids` **追加** `Hibiki.Video`（不改系统默认播放器，只在
  右键「打开方式」里多一个 Hibiki 候选）。

卸载时 `uninsdeletekey` / `uninsdeletevalue` 清理。

### 手动注册（不装安装包 / 调试构建）

资源管理器里右键视频 → 打开方式 → 选择其他应用 → 浏览到 `hibiki.exe` → 勾选
「始终」即可（argv 路径已能处理）。或命令行直接：

```
hibiki.exe "D:\video\Dragon Maid\S01E01.mkv"
```

## single-instance 转发（TODO-904：已实现）

runner 用 `CreateMutexW(L"HibikiSingleInstanceMutex")` 做**真单实例**（检测
`ERROR_ALREADY_EXISTS`）：app 已开着时再从外部打开一个视频，第二实例**不会**起新
窗口（避免双实例共享同一 WebView2 userDataFolder 的锁冲突），而是把视频路径**转交**
给首实例后退出。链路：

1. 第二实例 `main.cpp`：`FirstFileArgFromCommandLine()` 从 argv 取第一个文件参数 →
   `::hibiki::SendExternalVideoPath(existing, file_arg)`（`external_video_handoff.*`）
   用 `WM_COPYDATA`（dwData magic `kExternalVideoCopyDataMagic`，lpData 为 UTF-8
   路径字节）发给首实例窗口 → 前置窗口 → `return EXIT_SUCCESS`。**无文件参数**（纯
   第二次启动）则只前置 + 退出，不发消息。
2. 首实例 `flutter_window.cpp::MessageHandler` 收到 `WM_COPYDATA` →
   `DecodeExternalVideoPath`（magic 不匹配则忽略）→ 经 `app.hibiki/external_video`
   MethodChannel `InvokeMethod("openExternalVideo", path)` 推给 Dart。
3. Dart `_HoshiReaderAppState._handleExternalVideoChannel`（`main.dart`，仅 Windows
   注册）：做与首启 argv 等价的校验（`isSupportedVideoFile` + `File.existsSync`），
   通过后复用 `_openExternalVideo`（同一打开链路，不另造第二套）。若首实例尚未初始化
   完成，则暂存到 `_pendingExternalVideoPath` 交由 `build` 的首启分支接手。

守卫：`test/native/windows_single_instance_guard_static_test.dart`（转交链路源码扫描）。
WM_COPYDATA 真实跨进程行为 headless 测不到，须真机验证（app 已开 → 双击/右键用
Hibiki 打开另一个视频 → 复用已开窗口打开播放页，不起第二进程）。

## 验证

- 纯函数测试：`test/media/video/external_video_test.dart`
  （`isSupportedVideoFile` / `externalVideoBookUid` / `firstExternalVideoArg`）。
- 真机：`hibiki.exe "<某视频绝对路径>"` 启动应自动打开播放页 + 书架出现条目。
