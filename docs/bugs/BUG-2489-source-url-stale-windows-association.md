## BUG-2489 · 来源链接仍启动旧安装版Fushi

- **报告**：2026-09-10（用户：点 Anki 卡片上的视频来源链接「好像跳不进去」，只开了另一个 Fushi 窗口）
- **真实性**：❌ 未复现（不是应用代码缺陷，是本机装了旧版）。沿真实链路实测：
  - Windows 的 `fushi://` 协议由**安装器**注册（`fushi/windows/installer/fushi.iss:153-155`），指向安装目录的 exe。本机 `HKCU\Software\Classes\fushi\shell\open\command` = `"D:\fushi\Fushi\fushi.exe" "%1"`，那份 exe 是 2026-09-10 01:41 的旧版，早于 `fushi://source` 落地，收到 URL 只会正常开窗口。开发版构建**从不**注册协议，所以关联永远指向已安装的那份。
  - 把用户原样的那条 Re:Zero 链接直接交给新版 exe：第二实例经 `FirstFileArgFromCommandLine`（`fushi/windows/runner/main.cpp:19-39`）+ `WM_COPYDATA` 转交首实例（`main.cpp:217-232`），首实例 `main.dart:1310` 分流到 `_queueCardSourceUrl` → 真实跳进回看页（顶栏「正在回看卡片片段」出现）。
  - 链接身份也全对：`video_books.book_uid` 精确命中；文件 SHA-256 = `886c1b79…e563d`，与卡片 `fingerprint` 完全一致，1.6GB 整文件校验实测 3.9s。
- **[x] ① 无需修复** — 应用侧无缺陷；用户装上新版（安装器会把关联指到新 exe）即恢复。风险点已记：同机并存两份 Fushi 时，协议归**最后一次安装**的那份，开发版构建不参与竞争。
- **[x] ② 无需新增测试** — 关联注册由安装器脚本负责，已有 `.iss` 覆盖；URL 转交与解析已由 `fushi/test/platform/source_url_native_contract_test.dart`、`packages/fushi_anki/test/card_source_link_test.dart` 覆盖。
- **备注**：首次点某张卡时 `_openCardSource` 会同步 await 整文件 SHA-256（`fushi/lib/src/anki/card_source_router.dart:68-82`），期间**无任何 UI 反馈**。本机 1.6GB 约 4s；更慢的盘/网络路径上会被当成「点了没反应」。缓存只在内存（`video_source_fingerprint.dart:14-15`），冷启动不复用。未在本轮处理。
