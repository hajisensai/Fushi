# 悬浮球（应用内 / Android 应用外）

2026-09-28 群聊需求（原话要点）：

- 悬浮球按场景出现不同按钮；
- 能调用 OCR、唤出查词弹窗——Android 在应用外悬浮弹出，iOS 跳转到应用内；
- 可配置「应用内常驻」或「系统内常驻」，不再是阅读器专属。

## 形态

2026-09-29 用户拍板：设置里单独一个「悬浮球」一级分类，是悬浮球**唯一**的配置入口
（此前查词页的「悬浮球」段、阅读页的「阅读器悬浮球」开关、阅读器按钮布局编辑器的
「悬浮球」槽全部删掉）；应用内默认开、应用外默认关；按钮按场景（语料 / 应用外）分别勾选。

两个独立开关（`settings_schema_floating_ball.dart`）：

| 偏好 | 默认 | 含义 | 平台 |
|---|---|---|---|
| `floating_ball.in_app`（bool） | 开 | Flutter 悬浮球挂在根 builder 上（`AppFloatingBallHost`），任何页面都在 | 全部 |
| `floating_ball.system`（bool） | 关 | Android 原生悬浮窗服务 `FloatingBallService`，在别的 app 上面也在；Fushi 自己在前台时原生球隐藏（应用内球开着就由它接管，场景按钮仍然可用） | 仅 Android |

非 Android 平台读到 `floating_ball.system = true`（例如备份从 Android 恢复）不起球。

旧版三态 `floating_ball.mode`（`off` / `in_app` / `system`）只作迁移读取：新开关从没写过时，
显式选过 `off` 的保持应用内关，选过 `system` 的两个都开。

### 展开按钮文字（2026-10-06）

设置 → 悬浮球 →「显示按钮文字」，偏好 `floating_ball.show_labels`（bool），默认开启。
关闭时只隐藏展开菜单的文字胶囊和对应点击区域，圆图标按钮保留 tooltip、无障碍名称与
原有点击操作；重新开启即时恢复。偏好存入设置数据库，重启后沿用，不改按钮勾选或球的位置。

- Flutter 应用内球：全部支持平台生效；保持原有多列 / 极窄视口下只显示图标的布局规则。
- Windows / macOS 应用外球：随 `startSystemBall.showLabels` 更新；旧调用未传时默认开启。
- Android 原生应用外球：现有设计只有图标按钮，没有可见文字胶囊；此开关不改变它，
  tooltip / contentDescription 继续保留。Android 应用内球与其它 Flutter 平台一样响应开关。
- iOS / Linux 没有原生应用外球，此设置只影响应用内球。

验证：`floating_ball_labels_test.dart`（文件 DB 重开 / 三平台 widget）、
`round8_system_ball_motion_test.dart`（实际宿主偏好刷新与原生桥接）、Windows
`floating_ball_hit_region_test.cpp`（实际 DirectWrite 标签、渲染像素与命中范围）；macOS
原生分支在 Windows 上仅能做静态契约核对，AppKit 实机显示仍需 macOS 验证。

### 关闭后自动恢复（2026-10-03 用户拍板）

`floating_ball.auto_restore`（`FloatingBallAutoRestore`）三态，决定点「关闭悬浮球」之后哪些球
在回到 Fushi 时自动重新出现：

| 值 | 应用内球的关闭 | 应用外球的关闭 |
|---|---|---|
| `both` 应用内外 | 只收这一页；换页或从后台回到 Fushi 即恢复 | 开关不动；下次打开 Fushi（冷启动读到关闭标记 / 任一次 `resumed`，桌面主窗重新拿到焦点也算）重新起球 |
| `in_app` 仅应用内（出厂） | 同上 | 关掉「应用外显示」开关（下表 `close` 的行为） |
| `off` 不自动恢复 | 关掉「应用内显示」开关，要到设置里重开 | 同上 |

没有应用外球的平台（iOS / Linux）设置里只给后两档，读到 `both` 按 `in_app` 显示。

### 场景与按钮

场景 `FloatingBallScope`（`floating_ball_config.dart`）：

| 场景 | 专属按钮 id（目录顺序） | 出厂勾选 |
|---|---|---|
| `reader` 阅读器 | 按钮布局里除书名外的全部 `ReaderControlItem`（`storageValue`） | 有声书上一句 / 播放暂停 / 下一句 |
| `manga` 漫画 | `previous` `next` `ocr_boxes` `ocr_volume` `ocr_rerun` `chapters` | 全部 |
| `video` 视频 | `play_pause` `prev_cue` `next_cue` `favorite` `screenshot` | 全部 |
| `general` 其它页面 | —（没有登记场景的页面） | — |
| `system` 应用外 | —（原生侧拿不到页面按钮） | — |

每个场景都还能勾选下面的全局按钮（出厂除 `sync` 外全勾）。勾选存在 `floating_ball.buttons.<场景>`
（逗号分隔 id，按目录顺序；空串 = 出厂，`-` = 全关）。旧版单份全局勾选
`floating_ball.actions` 只作迁移读取：没单独设过的场景沿用它对全局按钮的取舍。

`FloatingBallScene`（零尺寸 widget）挂在页面里，把「场景 + 本页此刻能提供的专属按钮
（id → 动作）」登记进 `FloatingBallSceneRegistry`；宿主取**当前路由**上最后登记的那一组，
再按该场景的勾选挑按钮（全局按钮看平台能力，专属按钮页面此刻没提供就跳过，例如漫画的
整卷 OCR 只在满足条件时提供）。路由切换经 `floatingBallRouteObserver` 通知宿主重算。

- 阅读器：登记全部可渲染的布局按钮，执行体与顶栏 / 底栏同一个 `_readerControlAction`；
  阅读器不再画自己的球。旧布局 JSON 里的 `floatingBall` 槽解码时按未知槽丢弃，里面的
  按钮回落出厂位置（有声书传输键在托盘）。
- 阅读器「关掉顶栏和底栏」（2026-09-30，取代专注模式；设置 → 阅读界面，或托盘里的
  「隐藏顶栏和底栏」键，偏好 `hide_toolbars`）：栏关掉后球**接管**。场景额外登记
  `pinnedIds` = 返回 / 设置 / 开回栏（`kReaderToolbarsTakeoverItems`，歌词模式再加模式
  切换），宿主不看勾选把它们排在最上，不给「关闭悬浮球」，此前在本页点过的关闭也作废，
  勾选全关也照样画球。偏好只在应用内球开着时生效（`readerToolbarsHidden`）：拨开关时球
  若关着就一并打开，球后来被关掉则栏自动回来。
- 视频 / 漫画：各自登记本页的常用动作。

全局按钮：

| id | 动作 | 平台 |
|---|---|---|
| `lookup` | 主窗查词：应用内是输入框 → 应用内查词弹窗（`FloatingLyricLookupHost`）；应用外球把 Fushi 唤到前台并打开查词页（`requestHomeDictionaryTab(focusSearch: true)`，与桌面「唤起主窗并打开查词页」同一语义） | 全部 |
| `popup_lookup` | 应用外查词：不进主窗，弹出与系统「处理文本」/ 截屏识字同一个独立查词窗 `PopupDictFlutterActivity`（只有搜索栏）。2026-09-29 用户提出：两个查词按钮是相反的取舍，别合并 | Android |
| `clipboard` | 读剪贴板 → 查词 | 全部 |
| `screen_ocr` | 截屏 → 系统 OCR → 点选文字行查词 | Android、iOS |
| `camera_ocr` | 拍照查词：系统相机拍一张 → 转正方向 → 系统 OCR → 点选文字行查词（2026-09-29 用户提出：悬浮球支持拍照，拍完识字查词） | Android、iOS |
| `sync` | 立即同步：与设置页「立即同步」、媒体页下拉刷新同一个入口 `runManualSyncWithFeedback`（重入、结果提示、逐通道冲突裁决、鉴权失效登出都由它管）。应用外球先把 Fushi 唤到前台再同步，结果在主窗里给。**出厂不勾**（多数人没配同步后端，出厂按钮点了只会说「同步不可用」），在设置里自己勾（2026-10-03 用户提出） | 全部 |

### 截屏 OCR

- **Android**：MediaProjection。Android 14 起每次截屏都要用户在系统对话框里同意，
  因此流程固定为「点球 → 系统确认 → 截一帧 → ML Kit 识别 → 全屏透明选取层框出文字行
  → 点字 → `PopupDictFlutterActivity`（锚点 = 被点字符的框，避让区 = 整行框）」。
  应用内与应用外走同一条原生流程。
- **iOS**：只能截自己的窗口（`drawHierarchy`，含 WKWebView 内容），交 Vision OCR，
  Flutter 选取页点字 → 应用内查词弹窗。看不到别的 app 的屏幕（系统限制，不做
  ReplayKit 广播扩展）。
- 桌面：不提供（按钮不出现）。

### 拍照查词

- 应用内（Android / iOS）：`image_picker` 的 `ImageSource.camera`（Android 系统拍照
  intent，manifest 不声明 `CAMERA`、不要运行时权限；iOS `UIImagePickerController`，
  用 Info.plist 既有的 `NSCameraUsageDescription`）→ `normalizeCameraOcrPhoto`
  （`camera_ocr_photo.dart`）把 EXIF 方向烘焙进像素并把长边压到 2560 → 系统 OCR →
  与 iOS 截屏同一个 `ScreenOcrPickerPage`，但图按 `ScreenOcrImageFit.contain` 等比居中
  （截屏是 `window`：与窗口同形，贴宽顶对齐）。
  - 必须烘焙方向：Android 的 `system_ocr` 通道用 `BitmapFactory.decodeByteArray`，不看
    EXIF；竖拿手机拍的照片像素是横的，不烘焙识别器看到的是躺倒的字，行框也和选取页
    按 EXIF 转正后画出来的图对不上。
- 应用外（Android 系统球）：相机要 Activity 结果、服务拿不到，所以与 `lookup` 同一个
  模式——原生先排「开相机」请求再把 Fushi 拉到前台，Dart 就绪后开相机，拍照、识别、
  选字都在主窗里做。

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
| `openPopupLookup` | — | null（弹出独立查词窗） | Android |
| `takePendingOpenLookupPage` | — | bool（系统球「查词」时主引擎不在而排队的请求；取即清） | Android |
| `takePendingCameraOcr` | — | bool（系统球「拍照查词」时主引擎不在而排队的请求；取即清） | Android |
| `takePendingSync` | — | bool（系统球「立即同步」时主引擎不在而排队的请求；取即清） | Android |
| `takeSystemBallClosedByUser` | — | bool（用户点过系统球关闭的持久标记；取即清。Dart 起系统球前先取，为 true 就改为关掉「应用外」开关；自动恢复选了 `both` 时照常起球） | Android |
| `captureScreen` | — | `Uint8List` PNG（失败抛 PlatformException） | iOS |
| `sensorHousingEdge` | — | String?（刘海 / 灵动岛此刻在哪条屏幕边：`left` / `top` / `right` / `bottom`，按界面方向换算；未知 null。iOS 横屏左右安全区对称，应用内球据此只避让外壳那一侧。只用于首次取值，方向变化走下面的 `sensorHousingEdgeChanged` 推送） | iOS |
| `takePendingIntentLookup` | — | String?（冷启动时排队的 App Intent 词；调用即表示 Dart 已就绪） | iOS |

`labels` 把文案从 Dart i18n 传给原生（原生不维护 17 种语言），键为动作 id 加
`open_app` / `close` / `notification` / `ocr_notification` / `ocr_hint` / `ocr_no_text` /
`ocr_model_unavailable` / `ocr_failed`；缺了原生用英文兜底。

原生 → Dart：

| 方法 | 参数 | 平台 | 说明 |
|---|---|---|---|
| `lookupFromIntent` | `{word: String}` | iOS | App Intent 触发；Dart 侧与 `fushi://lookup` 同一处理 |
| `screenOcrFinished` | — | Android | 每次 `startScreenOcr` 返回 true 后恰好一次：截到帧或流程放弃时发出。Dart 在调用前藏起 Flutter 球，收到后放回来（原生只藏得了原生球） |
| `openLookupPage` | — | Android | 系统球「查词」，Fushi 随后被拉到前台；Dart 就绪后打开查词页。主引擎不在时改为排队，由 `takePendingOpenLookupPage` 取 |
| `openCameraOcr` | — | Android | 系统球「拍照查词」，Fushi 随后被拉到前台；Dart 就绪后开相机。主引擎不在时改为排队，由 `takePendingCameraOcr` 取 |
| `openSync` | — | Android | 系统球「立即同步」，Fushi 随后被拉到前台；Dart 就绪后跑一轮手动同步。主引擎不在时改为排队，由 `takePendingSync` 取 |
| `systemBallClosedByUser` | — | Android | 系统球 / 常驻通知上点了关闭；Dart 把「应用外」开关关掉 |
| `sensorHousingEdgeChanged` | String?（同 `sensorHousingEdge` 的回话） | iOS | 界面方向变化（SceneDelegate 的 `windowScene(_:didUpdate:interfaceOrientation:traitCollection:)`）时主动推。横屏左 ↔ 右翻转窗口尺寸与对称安全区都不变，Dart 没有可靠的重查时机，必须由原生推（BUG-2911） |

Android 系统球的按钮：

| id | 行为 |
|---|---|
| `lookup` | 把 Fushi 带回前台并打开查词页（经 `openLookupPage` / `takePendingOpenLookupPage`） |
| `popup_lookup` | 拉起 `PopupDictFlutterActivity`（`openSearch=true`），空词；热引擎上原生以 `allowBlank` 推空词，Dart 查词页清掉上一次的结果，只剩搜索栏 |
| `clipboard` | 拉起 `PopupDictFlutterActivity` 并带 `readClipboard=true`；activity 拿到窗口焦点后自己读剪贴板（Android 10+ 后台服务读不到剪贴板） |
| `screen_ocr` | 走截屏 OCR 流程。选取层是一次性的：点一个字就关（它在所有 Activity 之上，不关会盖住查词窗），同一行别的字在查词窗的原句条里点 |
| `camera_ocr` | 把 Fushi 带回前台并开相机拍照查词（经 `openCameraOcr` / `takePendingCameraOcr`） |
| `sync` | 把 Fushi 带回前台并跑一轮手动同步（经 `openSync` / `takePendingSync`） |
| `open_app` | 把 Fushi 带回前台 |
| `close` | 用户关掉应用外悬浮球：落持久标记 + 推 `systemBallClosedByUser`，停服务；Dart 同步关掉设置里的「应用外」开关，两边保持一致（2026-09-29 用户要求；此前是「停服务、偏好不变，下次启动 app 时再起」）。2026-10-03 起自动恢复选 `both` 时开关不动、回到 Fushi 再起球（见「关闭后自动恢复」）。常驻通知上的关闭同此 |

## 不做的

- 不按外部 app 切换系统球的按钮：要知道前台是哪个 app 得用 UsageStats 或无障碍服务，
  无障碍服务此前因隐私问题已关闭。
- 不做 iOS 分享扩展（新 target 需要新的描述文件，会打断现有签名流水线）。
