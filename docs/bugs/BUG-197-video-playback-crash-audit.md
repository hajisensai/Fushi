## BUG-197 · 视频播放高频闪退全平台根因排查 (TODO-116)
- **报告**：2026-06-11（用户：「看完一集动画中途闪退 10+ 次，基本都是查词或跳转字幕导致；调字幕大小/位置/模糊、设倍速也可能闪退；本地音频掉了一次致查词没声，退出重启后正常」）。
- **真实性**：✅ **部分真 bug（已被 TODO-061 覆盖）+ 部分误归因**。沿真实代码路径逐触发点定性，未在 host 复现 native 崩溃（UAF 退出/销毁崩溃 host 不可复现），结论靠静态代码路径 + 依赖源码证据。

### 定性矩阵（触发点 × 平台 → 覆盖结论 · file:line）

| 触发点 | Windows | Android | mac/Linux | 证据 |
|---|---|---|---|---|
| **查词（开/关弹窗）** | 顶层查词复用常驻热槽 WebView（不 create/destroy）；**嵌套查词 / 退页销毁热槽**才销毁 `CustomPlatformView` → **TODO-061 已覆盖** | 原生 WebView 生命周期，无 WGC/texture-bridge UAF（fork 注释明示双 dispose 在 Android 只是 no-op） | 同 Windows 走 inappwebview？否——桌面仅 Windows 用 WGC fork；mac/Linux 无此 WebView 渲染路径 | `dictionary_page_mixin.dart:288,383` 热槽 `reuseWarmSlot`；`dictionary_popup_webview.dart:312-321` 双 dispose 注释；`custom_platform_view.cc:199-218` 061 析构 sever |
| **跳转字幕（句子 seek）** | seek 本身只 `_player.seek()`，纯 mpv，**不 teardown 任何 texture/WebView → 无独立崩溃**；若跳完立即查词则走查词路径（同上） | 同左 | 同左 | `video_player_controller.dart:803` `seekMs`；`video_subtitle_jump_panel.dart` 纯 Flutter 只 `skipToCue` |
| **调字幕大小/位置/模糊** | 纯 Flutter `setState` 重建字幕 overlay（Text/ImageFiltered），**不动 media_kit 纹理、不动 WebView、不发 native 调用 → 无独立崩溃**；崩溃多为同期有查词弹窗（WGC，061 覆盖） | 同左 | 同左 | `video_subtitle_overlay.dart` 全 Flutter；`video_hibiki_page.dart:3781-3801` 仅重建 overlay，`Video`/`VideoController` 不重建 |
| **设置倍速** | **已安全**：视频走裸 `Player()`，media_kit `PlayerConfiguration.pitch` 默认 `false` → `setRate` 只设 `speed` double，**不重写 mpv `af` 滤镜链**（这才是 TODO-070 有声书调速崩的根因）。视频从不经 just_audio/JustAudioMediaKit，`pitch=false` 那条修复管不到它，但它本就默认安全 | 同左（同一 media_kit 路径） | 同左 | `video_player_controller.dart:395` 裸 `Player()`；`video_player_controller.dart:827` `setSpeed`→`setRate`；media_kit-1.2.6 `real.dart:817` `if (configuration.pitch)` 分支；`platform_player.dart:521` `pitch = false` 默认 |
| **本地音频掉了致查词没声** | 非崩溃，是状态副作用（疑为某次闪退后 TtsChannel/本地音频 DB 句柄残留坏态，重启清除）。**需真机复现 + 日志，host 不可定性** | 同左（关联 TODO-078 安卓更新关本地音频，但本条是退出重启即恢复，语义不同） | 同左 | `dictionary_page_mixin.dart:138-179` autoRead 走 TtsChannel；无独立崩溃路径 |

### 关键结论
1. **该转告用户先测新包 c586ae1ea（含 061）**：查词 / 嵌套查词 / 退页 这三类「销毁 WebView `CustomPlatformView`」的 Windows 闪退，应在 061 修复后消失（用户旧 exe 无 061）。061 是**析构级**修复（`~CustomPlatformView` 先 `SetOnFrameAvailable(nullptr)` 再 `Stop()`），覆盖退出 + 中途弹窗销毁 + 优雅 WM_DESTROY 全部路径，非仅退出。
2. **倍速 / 字幕设置 / 字幕跳转 本身不是独立 native 崩溃**：倍速默认走 media_kit 安全分支（无 af 重写）；字幕设置/跳转是纯 Flutter 重建 / 纯 mpv seek。用户把这些归因于闪退，大概率是操作时**恰好有查词弹窗在栈中**（WGC 路径，061 覆盖），或与 media_kit 自身的 Windows 偶发崩相撞（非本仓库可控）。
3. **未在 host 复现任何独立崩溃**：UAF/退出崩溃 host 不可复现，本条全部基于静态代码路径 + media_kit/inappwebview 源码证据。

- **[x] ① 根因修复（无独立崩溃可修；落「不变量加固」防回归）** — 倍速路径**当前已安全**，无 bug 可修；但其安全性是隐式依赖 media_kit `PlayerConfiguration.pitch` 默认 `false` 的脆弱不变量。在 `video_player_controller.dart:395` `Player()` 构造点补根因注释，钉死「视频 Player 必须裸构造 / pitch 保持 false，否则每次调速重写 af 滤镜图、Win 回归 TODO-070 调速闪退」。其余触发点经 061 覆盖或为纯 Flutter，无独立崩溃需修。提交见分支 `codex/todo-116-crash-audit`。
- **[x] ② 已加自动化测试** — `hibiki/test/media/video/video_speed_pitch_guard_test.dart`：源码守卫断言①视频用裸 `Player()`②不出现 `Player(PlayerConfiguration(...))` / `pitch: true`③保留根因注释 + `audio-pitch-correction`④`pubspec.lock` 仍钉 media_kit 1.2.6（升级须重核 setRate 分支语义）。4 用例绿。061 的 WGC teardown 不变量已由既有 `texture_bridge_stop_guard_test.dart` 守卫，本条不重复。
- **备注**：
  - **需用户真机 dump 才能定位的残留风险**：若用户在 c586ae1ea（含 061）上仍闪退，需 `C:\Users\<用户>\AppData\Local\CrashDumps\hibiki.exe.*.dmp` + Windows 事件查看器「应用程序」日志（崩溃模块 + 异常码 0xc0000005/其它）。若崩溃模块是 `GraphicsCapture.dll` / `flutter_windows.dll!MarkExternalTextureFrameAvailable` → 061 应已修，请确认确在新包；若是 `media_kit` / ANGLE / `libEGL`/`libGLESv2`/`d3d11` → media_kit 视频纹理自身崩（非本仓库 fork，需上报 media_kit 或换纹理后端）；若是 `libmpv` → libmpv 解码/滤镜崩（与片源/解码器相关）。
  - **本地音频掉声**：非崩溃，需真机复现「查词无声」时的 `flutter run` 日志（`[hibiki-autoread]` / TtsChannel 错误）+ 是否伴随一次闪退；高度疑为闪退副作用而非独立 bug，与 TODO-078（安卓更新后本地音频被关）语义不同（本条退出重启即恢复）。
