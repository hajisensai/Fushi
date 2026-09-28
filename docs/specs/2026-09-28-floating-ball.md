# 全局悬浮球（应用内常驻 / Android 系统常驻）

2026-09-28 群聊需求（原话要点）：

- 悬浮球按场景出现不同按钮；
- 能调用 OCR、唤出查词弹窗——Android 在应用外悬浮弹出，iOS 跳转到应用内；
- 可配置「应用内常驻」或「系统内常驻」，不再是阅读器专属。

## 形态

全局模式偏好 `floating_ball.mode`：

| 值 | 含义 | 平台 |
|---|---|---|
| `off`（默认） | 不显示全局球；阅读器旧的内置球（`reader_floating_ball`）照旧按自己的开关工作 | 全部 |
| `in_app` | Flutter 悬浮球挂在根 builder 上（`AppFloatingBallHost`），任何页面都在 | 全部 |
| `system` | Android 原生悬浮窗服务 `FloatingBallService`，在别的 app 上面也在；Fushi 自己在前台时原生球隐藏、改由 Flutter 球接管（这样场景按钮仍然可用） | 仅 Android |

非 Android 平台读到 `system`（例如备份从 Android 恢复）一律按 `in_app` 处理。

### 场景按钮

`FloatingBallScene`（零尺寸 widget）挂在页面里，把本页的按钮登记进
`FloatingBallSceneRegistry`；宿主取**当前路由**上最后登记的那一组，排在全局按钮前面。
路由切换经 `floatingBallRouteObserver` 通知宿主重算。

- 阅读器：全局模式开着时，阅读器不再画自己的球，而是把布局编辑器
  `ReaderControlSlot.floatingBall` 槽里的按钮登记成场景按钮（按钮仍在原编辑器里配置）。
- 视频 / 漫画：各自登记本页的常用动作。
- 没有场景的页面只显示全局按钮。

全局按钮（`floating_ball.actions`，逗号分隔，缺省全开）：

| id | 动作 | 平台 |
|---|---|---|
| `lookup` | 输入框查词 → 应用内查词弹窗（`FloatingLyricLookupHost`） | 全部 |
| `clipboard` | 读剪贴板 → 查词 | 全部 |
| `screen_ocr` | 截屏 → 系统 OCR → 点选文字行查词 | Android、iOS |

### 截屏 OCR

- **Android**：MediaProjection。Android 14 起每次截屏都要用户在系统对话框里同意，
  因此流程固定为「点球 → 系统确认 → 截一帧 → ML Kit 识别 → 全屏透明选取层框出文字行
  → 点字 → `PopupDictFlutterActivity`（锚点 = 被点字符的框，避让区 = 整行框）」。
  应用内与应用外走同一条原生流程。
- **iOS**：只能截自己的窗口（`drawHierarchy`，含 WKWebView 内容），交 Vision OCR，
  Flutter 选取页点字 → 应用内查词弹窗。看不到别的 app 的屏幕（系统限制，不做
  ReplayKit 广播扩展）。
- 桌面：不提供（按钮不出现）。

### iOS 从应用外进来

iOS 不允许应用外悬浮。补两条入口，都汇到应用内查词弹窗：

1. `fushi://lookup?word=<词>` 深链（快捷指令「打开 URL」即可用）——此前 iOS 上这条链接
   被忽略；
2. App Intent「在 Fushi 中查词」（iOS 16+，主 app target 内，不新增扩展 target、
   不需要新的描述文件），出现在快捷指令 / Siri / 操作按钮里。

## 平台通道契约 `app.fushi.reader/floating_ball`

Dart → 原生：

| 方法 | 参数 | 返回 | 平台 |
|---|---|---|---|
| `canDrawOverlays` | — | bool | Android |
| `requestOverlayPermission` | — | null（跳系统设置页） | Android |
| `startSystemBall` | `{actions: List<String>, labels: Map<String,String>, ocrLanguage: String}` | bool（无权限 false） | Android |
| `stopSystemBall` | — | null | Android |
| `isSystemBallRunning` | — | bool | Android |
| `setAppForeground` | `{foreground: bool}` | null | Android |
| `startScreenOcr` | `{language: String, labels: Map<String,String>}` | bool（流程是否已启动；无悬浮窗权限或已有一次在进行时 false） | Android |
| `captureScreen` | — | `Uint8List` PNG（失败抛 PlatformException） | iOS |

| `takePendingIntentLookup` | — | String?（冷启动时排队的 App Intent 词；调用即表示 Dart 已就绪） | iOS |

`labels` 把文案从 Dart i18n 传给原生（原生不维护 17 种语言），键为动作 id 加
`open_app` / `close` / `notification` / `ocr_notification` / `ocr_hint` / `ocr_no_text` /
`ocr_model_unavailable` / `ocr_failed`；缺了原生用英文兜底。

原生 → Dart：

| 方法 | 参数 | 平台 | 说明 |
|---|---|---|---|
| `lookupFromIntent` | `{word: String}` | iOS | App Intent 触发；Dart 侧与 `fushi://lookup` 同一处理 |
| `screenOcrFinished` | — | Android | 每次 `startScreenOcr` 返回 true 后恰好一次：截到帧或流程放弃时发出。Dart 在调用前藏起 Flutter 球，收到后放回来（原生只藏得了原生球） |

Android 系统球的按钮：

| id | 行为 |
|---|---|
| `lookup` | 拉起 `PopupDictFlutterActivity`（`openSearch=true`），空词；热引擎上原生以 `allowBlank` 推空词，Dart 查词页清掉上一次的结果，只剩搜索栏 |
| `clipboard` | 拉起 `PopupDictFlutterActivity` 并带 `readClipboard=true`；activity 拿到窗口焦点后自己读剪贴板（Android 10+ 后台服务读不到剪贴板） |
| `screen_ocr` | 走截屏 OCR 流程。选取层是一次性的：点一个字就关（它在所有 Activity 之上，不关会盖住查词窗），同一行别的字在查词窗的原句条里点 |
| `open_app` | 把 Fushi 带回前台 |
| `close` | 停服务（模式偏好不变，下次启动 app 时再起） |

## 不做的

- 不按外部 app 切换系统球的按钮：要知道前台是哪个 app 得用 UsageStats 或无障碍服务，
  无障碍服务此前因隐私问题已关闭。
- 不做 iOS 分享扩展（新 target 需要新的描述文件，会打断现有签名流水线）。
