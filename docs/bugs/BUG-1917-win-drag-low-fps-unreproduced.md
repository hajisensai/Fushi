## BUG-1917 · 窗口拖动帧率低（未复现）
- **报告**：2026-08-28（用户：「窗口拖动帧率很低」，与 BUG-1916 同批）
- **真实性**：❌ 未复现。沿真实路径排查：主窗 WndProc（`win32_window.cpp` / `flutter_window.cpp`）对 `WM_MOVE`/`WM_MOVING` 无额外动作；所有 `RegisterTopLevelWindowProcDelegate` 委托（window_manager 0.5.2 / screen_retriever / clipboard_watcher / hotkey_manager / record_windows / inappwebview fork）在移动路径上只发一条轻量事件；`WH_MOUSE_LL` 钩子对移动事件纯比较放行；Dart 侧 `onWindowMoved` 只在拖动结束记一次位置。实测（2026-08-28 develop `4125386daa` Release 隔离实例，空闲仪表盘，2068×1316 物理像素）：合成拖动标题栏 1.9s，窗口位置更新 63~65 次/s、更新间隔 p50 15.4ms / max 31ms、滞后光标 p50 4px——与经典 Win32 窗口（charmap）和 hello-world Flutter 完全一致；主线程空闲时 `SendMessageTimeout(WM_NULL)` 往返 p99 2.4ms / max 6.2ms，无周期性卡顿。
- **[ ] ① 未修复** — 无可修对象。
- **[ ] ② 未加自动化测试** — 无。
- **备注**：需要用户补充复现场景（当时在哪个页面：视频播放中 / 阅读器 WebView / 漫画？窗口多大？）。可疑但本轮未测的方向：视频页 media_kit 纹理或阅读器 WebView2 在拖动中的表现，以及 GPU 客户端饱和的环境因素（见记忆 GPU 饱和建不出硬件 D3D）。取证工具与 BUG-1916 相同（`mouse_event` 合成拖动 + 1kHz `GetWindowRect` 采样）。
