## BUG-1899 · 自定义数据安装位置启动即 Database damaged：派生根目录从没被创建
- **报告**：2026-08-28（用户：「要选数据安装位置 然后我没选默认的 就疯狂报错」，附截图）
- **真实性**：✅ 真 bug。

用户看到的原文：

```
Database damaged
FushiDatabaseUnrecoverableException: the database file at "D:\support\fushi.db"
could not be opened even after WAL/sidecar recovery. It is likely corrupt and
must be restored from a backup or cleared.
Cause: SqliteException(14): while opening the database, unable to open database
file, unable to open database file (code 14)
```

**SQLITE_CANTOPEN(14) 是「路径打不开」，不是「文件损坏」** —— 磁盘上一个字节都没坏。

### 根因（两层，各自独立）

**① 两条分支的契约不一致（真正的成因）**

`AppPaths.resolve()` 承诺返回可用的 documents / support 根，但两条分支做的事不一样：

- 默认分支：`getApplicationSupportDirectory()`（`path_provider_windows` 内部
  `create(recursive: true)`）→ 返回的目录**一定存在**；
- dataRoot 分支：`app_paths.dart` 的 `_resolveSupportRoot` / `_resolveDocumentsRoot`
  只做 `Directory(p.join(dataRoot.path, 'support'))` **纯路径拼接，不建目录**。

而安装向导的首启引导 `fushi/lib/src/storage/installer_data_root_bootstrap.dart:202`
也只 `create` 了 dataRoot **本身**：

```dart
await Directory(dataRoot).create(recursive: true).timeout(_pickedRootIoTimeout);
```

于是 `<dataRoot>/support` 这个空目录从头到尾没有任何人建。sqlite 在父目录不存在时连
db 文件都创建不出来 → CANTOPEN(14)。

「默认位置能用、自定义位置炸」的对称性由此而来。**设置页换位置那条路不受影响**——
`DataRootMigrator` 搬文件时顺手 `create(recursive: true)` 了；只有「安装向导选自定义
位置 → 首启」这一条路会踩。

**② 错误被归错类（让症状变成误导）**

`packages/fushi_core/lib/src/database/database.dart`：
- `_isSidecarOpenError` 认领 IOERR(10) / **CANTOPEN(14)** / NOTADB(26)；
- `_mainDbHeaderIsValid` 对「文件不存在」和「文件头不是 SQLite magic」返回**同一个
  `false`**（`:126` `if (!file.existsSync()) return false;`）；
- 于是两种成因塌成一句「likely corrupt … restore from a backup or cleared」，
  把用户往**清空数据**上引。

### 修复与测试

- **[x] ① 已修复** —
  - `app_paths.dart`：`resolve()` 末尾新增 `_ensureResolvedRootsExist(documents, support)`，
    让 dataRoot 分支与默认分支**契约一致**（返回的根必须真实存在）。建不出来时抛
    `DataRootUnavailableException`，走已有的可操作逃生屏（重试 / 本次用默认位置），
    而不是继续走到 DB 层被误报成损坏。
    只在 `resolve()` 里做、**不下沉进 `_resolve*Root()`** —— 那三个函数会被运行时静态
    便捷层高频调用，widget 测试跑在 FakeAsync 上，真实文件 IO 的 future 永不完成
    （与 `_ensureDocumentsLayoutDecided` 同一条理由，那里已有注释记录过）。
  - `database.dart`：新增 `FushiDatabaseFailureKind { corrupt, cannotOpen }`。
    sqlite 在父目录存在时会**自己创建**缺失的 db 文件，所以走到终态判定还「文件不存在」
    只可能是连创建都失败（目录不存在 / 无权限 / 只读介质 / 盘断链）→ `cannotOpen`；
    文件在但头不是 SQLite magic → `corrupt`。两种 `toString()` 分开，不再声称损坏。
  - `main.dart`：错误屏按 kind 分流标题、正文与图标；新增 i18n
    `db_cannot_open_title` / `db_cannot_open_message`（17 语言经 `i18n_sync.dart --add`）。
- **[x] ② 已加自动化测试** —
  - `fushi/test/storage/app_paths_creates_data_root_children_test.dart`：复刻安装向导首启后的
    磁盘状态（dataRoot 在、两个子目录都不在），断言 `resolve()` 把它们建出来；另断言幂等
    （已有 `fushi.db` 一字节不动）与默认分支同样满足契约。
  - `fushi/test/database/db_failure_kind_cannot_open_test.dart`：目录不存在 → `cannotOpen`
    且诊断串不含 `likely corrupt`；文件是垃圾 → 仍判 `corrupt`（既有行为不回归）。
  - **变异实测**（2026-08-28）：注释掉 `_ensureResolvedRootsExist` 调用 + 把 kind 钉死成
    `corrupt`，两个 suite 共 3 项转红；还原后 63 项（含全部既有 storage / WAL 恢复测试）全绿。

### 备注

- **存量受害用户**：本修复在下次启动时自动补建目录，无需手动干预。若之前已按错误提示
  「清空数据」，那部分数据无法找回——这正是错误分类必须修的原因。
- **未修的相邻问题（另计）**：`fushi/windows/installer/fushi.iss:694` 的绝对路径判据
  （`Length >= 3 且 Copy(DataRoot,2,2) = ':\'`）会**放行盘符根**，用户这次选的正是 `D:\`，
  于是 app 直接在 `D:\` 下建 `documents\` 和 `support\` 两个目录。功能上现在可用，但污染
  盘根不是好体验。没有一并改：「用一整块盘做数据盘」是合法用法，收紧校验需要单独设计
  （例如自动追加一层 `Fushi\`），会影响已安装用户的路径解析。
- 未做真机复测（Windows 安装器全流程需要真机重装）。行为由上述两组单测覆盖。
