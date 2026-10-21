## BUG-3656 · android-notification-small-icon-headset
- **报告**：2026-10-21（用户：「fushi 无论是下载还是悬浮球正在运行，系统顶栏里显示的都是耳机图标」「有时候还能看见反相图标」，附状态栏截图）
- **真实性**：✅ 真 bug，两个根因：
  1. `fushi/android/app/src/main/res/drawable/ic_stat_fushi.xml` 的路径就是 Material「headset」图标（当年给有声书媒体通知画的），后来下载保活 / 悬浮球 / 悬浮词典 / 悬浮字幕 / 屏幕 OCR 五个前台服务的 `setSmallIcon(R.drawable.ic_stat_fushi)` 全部复用它（`DownloadKeepAliveService.java:241`、`FloatingBallService.java:1517` 等），所以任何 Fushi 通知在状态栏都是耳机。
  2. 「反相图标」= 更新提醒 `fushi/lib/src/updates/local_update_notifier.dart:175` 用 `AndroidInitializationSettings('@mipmap/ic_launcher')`：系统只取 smallIcon 的 alpha，彩色启动图标被剪影成一团黑块。
- **[x] ① 已修复** — `ic_stat_fushi.xml` 换成启动图标海兔的单色白剪影（眼睛 evenOdd 镂空），由新脚本 `tool/android/gen_notification_icon.py` 从 `drawable-xxxhdpi/ic_launcher_foreground.png` 生成，换 logo 重跑即可；资源名不变，所有原生通知与 audio_service 一起换掉。更新提醒改用 `kAndroidNotificationSmallIcon = '@drawable/ic_stat_fushi'`。顺带（用户同条要求参照 Google「点按翻译」）：悬浮球常驻通知点按 = 直接弹出读剪贴板的查词窗（`PendingIntent.getActivity` 直达 `PopupDictFlutterActivity`，避开 Android 12+ 通知蹦床限制），「打开 Fushi」改为通知按钮，正文新增 i18n `floating_ball_notification_tap_hint`。
- **[x] ② 已加自动化测试** — `fushi/test/android/notification_small_icon_guard_test.dart`（4 条：图标非 headset 路径且单色白 + evenOdd；原生 `setSmallIcon` 不用 mipmap；Dart 通知小图标不用 mipmap；悬浮球通知 contentIntent 是 getActivity 直达读剪贴板）。变异实测：放回旧 headset XML 与 `@mipmap/ic_launcher`，对应两条变红。
- **备注**：状态栏图标只能真机目测，本轮未上真机；资源已用 aapt2 单独编译通过。Google「显示浮动图标」开关（只留通知、隐藏悬浮球）本轮未做。
