## BUG-3934 · Windows 偏好文件断电损坏后每次启动都 FormatException 失败
- **报告**：2026-11-01（用户：QQ 群反馈 p8vt5jHJgC，Windows，GitHub 下载版）
- **真实性**：✅ 真 bug（据截图 + 代码路径确认，用户日志未到）。现象：配置完重启后启动先出看门狗，Retry 后「Initialisation failed: FormatException: Unexpected character (at character 1)」+ 一长串方框（NUL）。根因在官方 `shared_preferences_windows` 2.3.2（Linux 版同构）：
  - 写盘原地 `localDataFile.writeAsStringSync(stringMap)`（`shared_preferences_windows.dart:94`，不 flush、不走临时文件），写完不久断电 / 强制关机，NTFS 留下长度不变、内容全 NUL 的 `%APPDATA%\Fushi\Fushi\shared_preferences.json`；
  - 读盘 `json.decode(stringMap)`（同文件 `:67`）不接异常；`SharedPreferences.getInstance()` 失败不缓存，**每次**调用都重读重抛，启动链上任何没包 try 的读取都把整个初始化打成错误屏，Retry 也一样。
- **[x] ① 已修复** — 新增 `fushi/lib/src/startup/durable_shared_preferences.dart`（`DurableFileSharedPreferencesStore`），`main()` 在第一次读偏好前 `installDurableDesktopSharedPreferences()` 替换 Windows / Linux 插件（同一文件、同一 JSON 格式，存量零迁移）：写盘改临时文件 + flush + rename 原子替换；读到坏文件（空 / 非法 UTF-8 / 非 JSON / 非对象）不抛，改名隔离成 `shared_preferences.json.corrupt-<时间>` 原样留证，再用每次读通过时刷新的 `.bak` 恢复，没有备份才以空偏好继续；恢复记录在错误日志就绪后写进 `SharedPreferences.recovered`。测试根隔离存储（`TestRootSharedPreferencesStore`）改为同一实现的子类。
- **[x] ② 已加自动化测试** — `fushi/test/startup/durable_shared_preferences_test.dart`（存量文件类型保真；NUL 文件不抛、隔离、从备份恢复；无备份时空偏好继续且坏文件原样隔离；写盘不留 .tmp；只在 Windows / Linux 安装）。
- **备注**：用户日志未到，无法 100% 排除是别的启动期 JSON 文件；修复后若仍复现，请用户贴「Copy error」全文。macOS（NSUserDefaults）与移动端不经这个文件。
