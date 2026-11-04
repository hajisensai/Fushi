## BUG-4079 · app 外显式查词（深链 / fushi_cli）只排队、不打开查词页
- **报告**：2026-11-03（Linux 冒烟：Docker 里 `fushi_cli lookup 食べる` 回 ok，截图里主窗停在原 tab、没有词卡）
- **真实性**：✅ 真 bug，全平台。`fushi/lib/main.dart` 三处 app 外查词入口——单实例转交的 `fushi://lookup` 深链（`_handleExternalVideoCall`）、ctl `lookupWord`（`_startCtlServer`）、冷启动深链（build 首启分支）——都只调 `DesktopLookupService.instance.triggerLookup(word)`。该方法按契约只排队（`fushi/lib/src/sync/desktop_lookup_service.dart` `triggerLookup` 文档），唯一消费者 `HomeDictionaryPage` 不保活，只在挂载时 / 挂载期间收通知消费；用户不在查词 tab 上时词就一直挂在 `pendingText`，界面无反应。应用内同类入口（悬浮字幕点词 `lyrics.part.dart`、导航 peek `home_nav_peek.dart`）都会接着调 `requestHomeDictionaryTab()`，唯独 app 外入口漏了。
- **[x] ① 已修复** — 新增 `AppModel.queueExternalLookup(text)`：排队成功才发 `requestHomeDictionaryTab()`（HomePage 切 tab，阅读器 / 播放器压在上面时推独立查词路由）；`triggerLookup` 改为返回是否真的排进（剥注音 / 截断后为空不排、也不切 tab）。`main.dart` 三处入口全部改走它。顺手删了 `home_page.dart` 里引用不存在的 `resolveDesktopLookupConsumer` 的过期注释。
- **[x] ② 已加自动化测试** — `fushi/test/models/app_model_external_lookup_test.dart`：排队 + tab 请求 seq 自增且不抢焦点；空白文本不排队不切 tab；源码守卫钉住 `main.dart` 不再直接调 `triggerLookup`、三处都走 `queueExternalLookup`。
- **备注**：Linux 包上复测（`fushi_cli lookup` 后截图应停在查词页并出词卡）随下次 Docker 场景跑补。
