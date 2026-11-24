## BUG-5376 · Android 多进程下 SharedPreferences 会被别的进程的旧副本整份覆盖
- **报告**：2026-11-24（BUG-5375 根因排查中发现，反馈 RCv76PPoiJ）
- **真实性**：✅ 真隐患（沿代码路径确认，未单独复现）。`AndroidManifest.xml` 里 `:popup`、`:second_screen`、`:network_challenge` 是独立进程，其中 `:popup` / `:second_screen` 起 Flutter 引擎、经 `SharedPreferences.getInstance()` 读写偏好（`fushi/lib/src` 下 36 处 `getInstance`）。Android 的 `SharedPreferencesImpl` 每个进程各持一份内存副本、不感知别的进程的写入，提交时把整份副本落盘，所以一个进程写任意键都可能把另一个进程刚写的键冲回旧值。
- **影响面**：`documents_layout` / `documents_container` 等启动期锚点、`android_documents_move_prompted`，以及所有在弹窗 / 副屏进程里会写的功能偏好。Android 书库位置锚点已在 BUG-5375 搬到原子写的文件并加磁盘对账；其余键仍在 SharedPreferences。
- **[ ] ① 未修复** — 方向：启动期锚点一律搬离 SharedPreferences（同 BUG-5375 的锚点文件或 DB 偏好表）；副进程对 SharedPreferences 只读，或副进程写入经主进程转发。要先盘点副进程实际会写哪些键。
- **[ ] ② 未加自动化测试** —
- **备注**：桌面上弹窗是同进程多引擎，每个引擎的 Dart 侧也各有一份 `SharedPreferences` 缓存，同类问题是否存在要一起核。
