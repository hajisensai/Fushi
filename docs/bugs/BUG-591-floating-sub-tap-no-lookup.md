## BUG-591 · 悬浮字幕点击文字不出查词窗(Android)
- **报告**：2026-07-07（用户：TODO-1268 复诉「没反应」）
- **真实性**：✅ 真 bug（根因 `hibiki/android/app/src/main/java/app/hibiki/reader/FloatingLyricService.java:396` 原 `startActivity(intent)`——从后台前台服务裸启动 `PopupDictFlutterActivity` 是一次 background activity launch，现代 Android/OEM ROM 会拦掉）
- **[x] ① 已修复** — `FloatingLyricService.java` 把点词启动抽成弹性 helper `startLookupActivity`：API 34+ 走自发 `PendingIntent` + `ActivityOptions.setPendingIntentBackgroundActivityStartMode(MODE_BACKGROUND_ACTIVITY_START_ALLOWED)` 官方后台启动 opt-in；失败回退直接 `startActivity`，再失败回退 `bringAppToFront()`，每条 log。分支 `todo1268-floating-sub-tap-lookup`
- **[x] ② 已加自动化测试** — `hibiki/test/media/audiobook/floating_lyric_android_tap_lookup_guard_test.dart`（源码扫描守卫：handleTap 不再裸 startActivity、经 helper 启动且保留 PopupDictFlutterActivity+文本+charIndex 契约；helper 在 API 34+ 显式 opt-in 后台启动；失败绝不静默吞——回退 startActivity+前台化+log）
- **备注**：Android 悬浮窗+后台点词时序无法离屏复现，需真机验收（见「待验」）。

### 现象
Android 听有声书、显示悬浮字幕条时，点字幕里的日文词**没有任何反应**，不弹查词窗。用户附图确认是播放控制条（⏮▶⏭🔒✕ 圆角按钮 chip）+ 日文字幕行，即 Android `FloatingLyricService` 原生悬浮窗（非桌面——Windows `floating_lyric_window.cpp` 画的是 `Segoe UI Symbol` 裸字形，无圆角 chip 背景）。

### 前修为何没根治
前一条 TODO-1268 修复 `96582d328` 标题即 **desktop** floating-lyric，改的是 `hibiki/lib/src/lookup/global_lookup_controller.dart` 的 `lookupText`（Windows app 外全局查词覆盖窗）。看板 solution 也误判成「桌面悬浮歌词」。但用户在 Android，那条改动**从未触及** Android 点词入口，所以用户复诉「没反应」。

### 根因（`FloatingLyricService.handleTap` → 原 `startActivity`）
Android 点词路径：`BaseFloatingService` 的触摸监听在非拖拽 UP 时调 `onOverlayTapped` → `FloatingLyricService.handleTap`（命中测试 + charIndex + anchor 都正确）→ 末尾 `startActivity(new Intent(this, PopupDictFlutterActivity.class), FLAG_ACTIVITY_NEW_TASK)`。

悬浮字幕的使用场景恰恰是 **Hibiki 不在前台**（悬浮窗画在别的 app / 桌面上），所以这次 `startActivity` 是一次 **background activity launch**：
- 自 Android 10 (API 29) 起后台启动 Activity 默认被拦；
- Android 14 (API 34) 起 app 不再默默继承后台启动特权；
- Android 15 (API 35，本项目 targetSdk 35) 把 `SYSTEM_ALERT_WINDOW` 豁免收窄到「有权限**且**当前有可见 overlay」，OEM ROM 更激进。

对照系统 `PROCESS_TEXT` 走同一个 `PopupDictFlutterActivity` 却正常——差异只在**启动上下文**：系统选词菜单是前台/系统发起的合法启动；`FloatingLyricService` 是后台服务发起。故裸 startActivity 被 OS 静默丢弃 → 点词「没反应」。`bringAppToFront()` 在此前是 dead code，印证早期设计曾先把 app 拉到前台。

### 修复
把启动抽成 `startLookupActivity(Intent)` 弹性 helper：
1. **API 34+**：自发 `PendingIntent.getActivity(...)` + `ActivityOptions.makeBasic().setPendingIntentBackgroundActivityStartMode(MODE_BACKGROUND_ACTIVITY_START_ALLOWED)`，用 `send(..., optionsBundle)` 发出——这是 Android 官方文档化的「后台启动 activity」opt-in，显式把我们自己（持 SYSTEM_ALERT_WINDOW + 有可见 overlay）的后台启动特权授予这次启动。
2. **回退**：PendingIntent 抛异常 / <34 → 直接 `startActivity`（老版本 SYSTEM_ALERT_WINDOW 豁免宽，直启即可）。
3. **兜底**：直启也被拒 → `bringAppToFront()`，保证一次点词绝不被静默吞掉。
每条回退 `Log.w(TAG, ...)`，真机复现可看到命中哪条分支。

平台边界兼容层（针对不可控的 OS background-activity-launch 策略），非症状补丁：点词契约（文本 + charIndex + anchor extras）零变化，前台场景行为不变。

### 待验（真机）
Android 真机：开有声书 → 显示悬浮字幕 → 按 home 让 Hibiki 退后台（悬浮窗仍在）→ 点字幕里的日文词 → 应弹出查词卡（不再无反应）。若仍失败，`adb logcat | grep FloatingLyricService` 看是否命中 PendingIntent/直启/前台化回退，据此进一步定位是否为特定 OEM ROM 完全封死后台启动。
