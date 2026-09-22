# Fushi 局域网游戏串流与远程查词

状态：`implemented_unverified`。代码和定向回归已落地；真实 SGRE → Android LAN 音视频、Hook 台词和查词已取得证据，输入实效和 Anki 真卡尚未完成联合验收，不能据此升级任何游戏引擎的支持状态。

## 使用入口和边界

- Windows：先启动已有的 Galgame Hook 会话，再在游戏工作台点击「开始串流」。绑定的是这一次 Hook 会话的 HWND 和开始时间；HTTP 不能创建串流、选择窗口或启动游戏。
- Android：在「Fushi 互联」设置的客户端区域进入游戏串流，选择已配对且启用的 Windows 主机，加入其已开启的会话。
- 首版仅 LAN、单客户端，WebRTC 不配置 STUN/TURN。SDP/ICE、加入、停止和制卡复用互联 HTTP、配对令牌以及 HTTPS 指纹校验。共享 WebDAV 密码不能授权串流控制。
- Android 只接收视频/音频、发送输入、显示 Hook 台词和查词。Hook、helper、窗口采集和 Anki 写入全部留在 Windows；iOS/macOS/Linux 无接收或游戏 Hook 入口。
- 触控按视频实际显示区域映射到客户区；肩键、方向键和确认/取消键可在本次会话中配置，也支持焦点导航及 Enter/Space 按下和松开，失焦会释放按键。Windows 输入使用目标 HWND 的消息投递，检查进程身份和前台窗口，不使用全局键盘注入。目标不在前台时会拒绝输入并回传 ACK 原因。
- 查词面板复用 `FushiRemoteLookupClient` 和 `DictionaryPopupLayer`；查词固定到串流主机。分词复用现有日语模块，无本地词典时按字回退。查词面板可收起，未新增系统级悬浮窗。

## 实现

`packages/fushi_engine/lib/sync/game_stream/` 保存 v1 wire 类型与会话服务；app 的 `game_stream_host.dart`、`game_stream_receiver.dart`、`game_stream_client.dart` 装配 WebRTC、原生窗口输入和配对传输。服务端提供 `/api/game-stream/sessions` 以及 `/join`、`/signal`、`/stop`、`/mine`，后四者也支持 `/sessions/{id}/...` 路径。

主机显式调用 `flutter_webrtc` 的 Windows 窗口捕获入口，精确匹配十进制 HWND source id，要求视频和应用回环音频轨道同时存在，不回退到整桌面。仓库的版本化插件补丁将 `fushiClientArea` 请求接到 WGC → WebRTC custom source 适配：复用已有 D3D/客户区裁剪，以纹理实际 RowPitch 转 I420，输出限制在 1920×1080 内，首个真实帧转换成功后才完成启动。补丁缺失或无法定位客户区时明确失败。视频上限目标为 60fps、8 Mbps，根据 WebRTC 可用带宽与 RTT 降低编码码率、帧率与分辨率；逐行截图仍使用现有 WGC 通道。

可靠有序数据通道携带输入、ACK 与台词。两端信令序号独立，远端 SDP 之前到达的 ICE 先缓存。重复输入不会重新注入。Android 进入后台时发送按键释放消息、暂停输入与 HTTP 轮询，恢复时保留同一连接；短断线允许原连接恢复，失败的连接要求主机重新开启。窗口销毁、隐藏、最小化、Hook 会话结束、显式停止或 10 分钟无客户端活动会停止采集并释放按键。

台词以 `lineId` 和当前文本版本关联。Windows 收到台词时冻结截图，使用有界内存缓存（最多 16 张、32 MiB）；渐进文本复用同一 ID 时会更新截图请求。制卡只能使用该文本版本对应的截图和已有逐行音频资源，复用 `GalHookMiningCoordinator`、主机 Anki 设置和媒体压缩。旧行截图缺失或已经淘汰时明确失败，不重新截取当前窗口冒充历史画面。没有对应语音时沿用现有制卡行为写入无句音的卡并显示缺音提示，不替用其他台词的声音。移动端不能上传截图/音频、覆盖主机牌组设置或指定媒体路径。

## 验证记录

- Windows Debug 构建通过，包含新原生输入通道和 WebRTC 插件。
- Android Debug APK 构建通过。
- 引擎协议/会话测试 18 项通过；app 串流、词典传输、制卡与引擎纯净性回归 82 项通过；页面及设置回归首轮 24 项通过。
- 追加的主机启动取消、渐进文本截图、分词和键位配置回归 12 项通过（其中 5 项与前述批次重叠）；后续 SDP 答复失败保留 offer 游标、手柄焦点释放两项也通过，首轮合计 133 项不同的定向单元/组件测试。又追加触摸取消/布局变化 4 项、后台/ICE 旧输入队列失效 2 项、前台切换取消/缺失采集补丁拒绝 2 项，合计 141 项。改动文件定向静态检查通过。
- `powershell -ExecutionPolicy Bypass -File tool/run_game_stream_input_test.ps1` 编译真实原生输入实现，55 项断言通过，覆盖隐藏/最小化后的释放、进程身份、键盘扫描码及目标 DPI 坐标/边界。测试只向自建窗口发消息、不激活窗口；移除目标 DPI scope 的临时变体失败 5 项，确认新增测试能检出回归。
- `tool/run_game_stream_capture_test.ps1` 的 18 项断言通过，验证 BT.601 固定颜色、纹理行距、裁剪原点、奇数尺寸和 1080p 上限。
- 真实窗口 spike 位于 `fushi/integration_test/game_stream_capture_spike_test.dart`。初始默认桌面路径在 PMv2/200% DPI 下启动成功但零帧；同类独立 probe 在 DPI-unaware 模式出帧、PMv2 模式零帧。接入 WGC 后，运行 `win-itest-20260922-204734-8bc39160` 通过：生产 host 本地首帧、WebRTC 接收解码/渲染首帧、非零应用音频能量、窗口最小化后的自动停止。输入客户区为 1248×642；该证据使用自建 WinForms 窗口，尚不代表游戏与 Android 联合验收。
- 隔离 Android QA APK `app.fushi.reader.streamqa` 已构建并安装到 SM-X716B，不覆盖正式应用或其数据。LAN fixture 使用隔离主机库、预置测试配对和独立测试牌组；配对批准 UI 不属于此夹具的验证范围。输入 ACK、观察到的台词变化和可归因的游戏输入实效分别记录。
- 首轮 SGRE 实测发现跨线程窗口激活完成前过早校验；本地启动改为在 `SetForegroundWindow` 成功后通过有界 `WM_NULL` 同步目标队列，再检查窗口身份及前台状态。激活请求被系统拒绝时仍返回错误，不重试抢焦点。后续 LAN fixture 等待操作者准备有声剧情、写入本地 `local-start.request` 并保留游戏前台后才调用生产启动路径，不再通过输入队列附着模拟本地点击。
- 真实 SGRE 主机运行 `gs-lan-host-20260922-3` 已得到当前游戏画面及关联语音资源事件；等待客户端超过 10 分钟后按 `expired` 停止，撤销测试凭据并正常退出。Android 这轮未加入：先修复 PowerShell 5.1 的 UTF-8 凭据读取，再修复测试页初始化前访问焦点的问题。不能把此轮写成 Android LAN 验收通过。追加测试错误 handler 恢复回归 1 项，连同主机 5 项重新执行，6/6 通过；不同定向单元/组件测试合计 142 项。
- `gs-lan-host-20260922-4` / Android `lan4` 使用已运行的 SGRE 游戏（校验 HWND、PID、镜像路径及 SHA-256）完成真实 LAN 连接。安卓首帧 640×360，统计解码 731 帧、接收视频 2,622,588 字节、音频 134,422 字节且 `totalAudioEnergy` 非零；后续解码日志记录 1280×720。同步台词与主机 `lineId` / 文本 SHA-256 一致，主机词典查询及递归查询返回结果。两次输入 ACK 接受，但三秒内未观察到台词变化，不能据此称为游戏控制通过。
- 同轮远程制卡被 HTTP 路径拒绝，没有验证通过的卡；旧传输丢弃非 2xx 错误体，不能从原日志确定具体拒绝点。已补结构化 HTTP 错误分类、主机 mine 异常边界和 preflight/hostMine/verify 阶段证据，待复测确定根因。Android 夹具追加真实按住确认键及首帧即时截图；测试脚本保留隔离 QA 包以导出失败证据，测试结束仍清除本轮配对凭据。
- `gs-lan-host-20260922-5` / Android `lan5` 在 `a38b6c19092` 的构建上再次取得首帧、2371 帧解码和非零音频能量，保存了真实游戏与台词抽屉的安卓截图。确认键实际保持 762ms，DOWN/UP ACK 都接受，但没有新台词事件，SGRE 的消息输入实效仍未通过。该轮在查词前失败：隔离接收器无形态词典，按单字显示，而新台词没有旧的稀疏词表单字；夹具词表已补全假名，避免要求操作者反复寻找特定台词。此轮未发送制卡请求，不能据此判断上轮制卡拒绝已修复。
- 追加 HTTP 拒绝分类与鉴权/fallback 回归 7 项、mine handler 异常与非 ASCII short alias 回归 3 项、制卡阶段诊断回归 5 项、排队输入超时与控制通道关闭回归 3 项。新增生命周期用例先复现缺陷，修复后 receiver 15/15、host 6/6 通过；传输层 28/28、阶段诊断 6/6、协议 21/21 通过。不同定向单元/组件测试合计 160 项；改动文件静态检查通过。生命周期修复晚于 LAN5 构建，不能把 LAN5 作为这项修复的实机证据。

捕获启动时的前台条件需按本地主机按钮流程验证。上游仍记录着 Windows 后台启动返回无帧轨道的问题：[flutter-webrtc #2137](https://github.com/flutter-webrtc/flutter-webrtc/issues/2137)。依赖版本和 Windows 应用音频能力参见 [flutter_webrtc changelog](https://pub.dev/packages/flutter_webrtc/changelog)。

尚需完成：SGRE 输入实际响应、真实游戏最小化/销毁清理、Android 旋转/后台恢复，以及主机 Anki 真卡（按 `lineId` 核对截图与句音）的端到端证据。目标窗口隔离、销毁与生命周期已有单元/原生自建窗口测试；其证据范围不等于真实游戏验收。
