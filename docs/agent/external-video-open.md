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

## 已知限制：无 single-instance 转发

runner 仅 `CreateMutexW(L"HibikiSingleInstanceMutex")`（供 Inno Setup 静默更新
检测），**未做**「app 已开时把新视频路径转发给已运行实例」。所以当前：app 已开着
时再从外部打开一个视频，会**起一个新进程**播放该视频（仍能播放 + 入库），不会复用
已开窗口。

后续要做 single-instance 转发的方案（未实现，避免为它引入大改）：runner 启动时
`OpenMutex` 检测到已有实例 → 通过 `FindWindow` + `WM_COPYDATA` 把视频路径发给已有
窗口的消息循环 → Dart 侧经一个 MethodChannel 收到后调用 `_openExternalVideo`，本进程
随即退出。

## 验证

- 纯函数测试：`test/media/video/external_video_test.dart`
  （`isSupportedVideoFile` / `externalVideoBookUid` / `firstExternalVideoArg`）。
- 真机：`hibiki.exe "<某视频绝对路径>"` 启动应自动打开播放页 + 书架出现条目。
