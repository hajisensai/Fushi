## BUG-1581 · 互联设备名与下载文件名仍播报 Hibiki 品牌词
- **报告**：2026-08-12（用户：「互联，下载等设备标志名称没换成 fushi」）
- **真实性**：✅ 真 bug，根因 `fushi/lib/src/sync/interconnect_device_name.dart:5`
  （`kGenericInterconnectDeviceName = 'Hibiki'`）
- **[x] ① 已修复** — 品牌词常量改 `'Fushi'`；同批清掉两处「下载」侧遗留名
  （`update_checker_download.dart` 的兜底落盘名 `hibiki-update.bin`、
  `download_save_root.dart` 的写权限探针 `.hibiki_write_probe`）与 3 个
  i18n 过时品牌串。提交见本文件末尾。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_device_name_test.dart`
  新增值守卫 `expect(kGenericInterconnectDeviceName, 'Fushi')`，并把两条格式断言
  从 `Hibiki · <model>` 改到 `Fushi · <model>`。已做变异实测：常量改回 `'Hibiki'`
  → FAILED（3 error events），反向替换还原 → PASSED（10 tests）。
- **备注**：改名终局清算的残留，非新引入。

### 真实证据（生产库，非推理）

用户本机 `D:\APP\HIBIKI_date\support\fushi.db` 的 `fushi_paired_peers`：

| peer | device_name |
|---|---|
| dBK6G5UY… | `Hibiki · CPH2747` |
| CSocc83s… | `Hibiki · shfaifsjdeMacBook-Air.local` |

### 根因

`resolveInterconnectDeviceName()` 用 `'$kGenericInterconnectDeviceName · $model'`
拼本机对外播报名。该常量在改名清算里没被扫到（它是**值**不是符号名，全仓
`Hibiki*` 类名族替换 `ddad0a377` 只动词首标识符，动不到字符串字面量）。

播报名进两条链路：`/api/pair` + `/api/pair/v2` 的 `deviceName` 字段、以及
`/api/ping` 与 LAN 广播（`lan_discovery_service.dart`）。

### 存量记录不会自动变（有意，不是漏修）

`fushi_paired_peers.device_name` 只在配对成功那一刻由
`FushiServerController._persistPairedPeer` 写入**对方当时自报的**字符串，之后
没有任何刷新路径（`upsertPairedPeer` 仅由 `onPeerPaired` 触发）。所以：

- 对端仍跑 Hibiki 时，`Hibiki · CPH2747` 是**准确**的，本地改写反而是撒谎；
- 对端升到 Fushi 后，需**重新配对**才会刷新成 `Fushi · CPH2747`。

若要免重配对就刷新，须让已鉴权请求也带 deviceName 并在 host 侧 upsert ——
那是协议面变更，不在本次改名范围内，另开条目。

### 未改动（有意保留）

- `sync_hibiki_client_token` / `sync_hibiki_client_urls`：**冻结的持久化键**，
  代码读写一致（`sync_repository.dart:918-919`），改了会丢用户配对凭据。
- `Basic base64(hibiki:token)`：互联鉴权的 wire 常量，两侧同值，改一侧即断连。
- `_hibiki-sync._tcp` 已是 `_fushi-sync._tcp`（`lan_discovery_service.dart:71`）。
- i18n `migration_*` 7 个键里的 “Hibiki” 指的就是**老 app**，必须保留。
