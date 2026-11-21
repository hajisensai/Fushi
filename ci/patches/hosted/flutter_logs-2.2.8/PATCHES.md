# flutter_logs 2.2.8

## BUG-5067：iOS 磁盘写满时日志追加直接 SIGABRT

上游 `ios/Classes/Logger.swift` 的 `FileOutput.process`（:50-51）与 `URLOutput.process`（:87-88）
用旧 API `FileHandle.seekToEndOfFile()` / `write(_:)` 追加日志。这两个方法出 I/O 错误
（设备存储满 ENOSPC、EIO 等）时抛的是 Objective-C 的 `NSFileHandleOperationException`，
Swift 接不住，异常一路冒到 `libc++abi` → `abort()`。实测崩溃栈（应用内反馈 AwX7bUtymI，
iPad / iOS 26.6.2）：`flutter_logs` → `Foundation` → `libobjc` 抛异常 → `libc++abi` → `abort`，
signal 6，跑在 flutter_logs 自己的 `File output` 串行队列上；同一份日志里满是 `errno = 28`。
存储一满，任何一次 `FlutterLogs.logError` / `initLogs` 写盘都会把整个 app 带走。

改法（整份 `Logger.swift` 覆盖进 pub cache，基于 2.2.8 原件，原件 SHA-256
`06f54baa5437a811bbca37cda6a48dd1b3d79c3840d54328f9a3431929eb5d50`）：

- 追加改走可抛错 API：`do { try seekToEnd(); try write(contentsOf:); try close() } catch { 丢弃本条 }`
  （iOS 13.4+；`fushi/ios/Podfile` 的 post_install 把所有 pod 的部署目标钉在 15.1）。
  写不进去的一条日志就丢掉：日志器是唯一能报告自身失败的通道，而它要报告的恰恰是
  让它写不进去的那个条件。
- 打开失败返回 nil：`createFile` 失败或 `FileHandle(forWritingAtPath:)` 返回 nil 时直接不写。
- 删掉从未赋值的 `fileHandle` 字段与 `deinit` 里的 `closeFile()`（同属会抛 ObjC 异常的旧 API）。
- `URLOutput` 仍按上游用 `url.absoluteString` 当路径（本仓不使用 `URLOutput`），只换写入 API。

文件里不得再出现 `seekToEndOfFile` / `write(data)` 旧重载 / `closeFile` / `truncateFile` /
`synchronizeFile` / `readDataToEndOfFile` 等旧 API。由 `ci/apply-patches.sh` / `tool/bootstrap.ps1` 应用。

守卫：`fushi/test/build/flutter_logs_enospc_patch_guard_test.dart`（目录版本必须等于根
`pubspec.lock` 解析到的版本，否则补丁被 apply-patches 静默跳过；并钉住上面的源码结构）。

**删除条件**：上游 flutter_logs 改用可抛错的 FileHandle API；本仓升级 flutter_logs 时必须把补丁
移植到新版本目录（守卫会因版本不符变红）。
