## BUG-2784 · 查过一次词后再开 app 外查词窗只剩旧 WebView 残影、卡片画不出
- **报告**：2026-09-29（排查 BUG-2783 时真机发现；与用户报的「截屏识字只有一层灰」同一类症状）
- **真实性**：✅ 真 bug，根因未定位。三星 Tab S9（Android 16）上 **release 包 `2.8.0-debug.16172` 与本地 debug 包都复现**，与 BUG-2783 的锚点布局无关：
  1. 用 `PROCESS_TEXT`（或截屏识字点字）打开 app 外查词窗查一次词——词典结果 WebView（flutter_inappwebview 平台视图）在 `:popup` 热引擎里建出来；
  2. 关窗（`PopupDictFlutterActivity` finish，引擎留在 `FlutterEngineCache`）；
  3. 再用任何入口打开查词窗（悬浮球「应用外查词」/ 系统「处理文本」/ 截屏识字）。
  新 Activity 挂回热引擎后 `:popup` 进程每帧报 `E/flutter: [ERROR:flutter/impeller/toolkit/egl/egl.cc(56)] EGL Error: Bad Access (12290)` + `gpu_surface_gl_impeller.cc(76) Could not make the context current to acquire the frame`：Flutter 整帧画不出来（没有搜索栏 / 卡片），屏上只剩上一次那个 WebView 平台视图停在旧位置；透明关闭层仍收触摸，点外面能关。
  没建过 WebView（只开空查词窗）时反复开关不复现（release 包实测两次零 EGL 错误）。
- **[ ] ① 未修复** — 疑为热引擎 + Hybrid Composition 平台视图在宿主 Activity 重建后 Impeller GLES 上下文无法 make current（EGL_BAD_ACCESS = 上下文仍被别的线程/表面占着）。候选方向（未验证）：关窗前让 Dart 先拆掉热槽 WebView；或 popup 进程的 Impeller 后端配置；或不 finish 宿主 Activity。热槽常驻是 TODO-951 的有意设计（防每次查词闪白），改之前要权衡。
- **[ ] ② 未加自动化测试** —
- **备注**：取证命令：`adb logcat -d | grep -c "EGL Error"`，在上述第 3 步后 > 0 即复现。
