# Fushi 局域网游戏串流与远程查词

状态：`implemented_unverified`。代码和定向回归已落地；真实游戏、Android LAN 音视频和 Anki 真卡尚未完成联合验收，不能据此升级任何游戏引擎的支持状态。

## 使用入口和边界

- Windows：先启动已有的 Galgame Hook 会话，再在游戏工作台点击「开始串流」。绑定的是这一次 Hook 会话的 HWND 和开始时间；HTTP 不能创建串流、选择窗口或启动游戏。
- Android：在「Fushi 互联」设置的客户端区域进入游戏串流，选择已配对且启用的 Windows 主机，加入其已开启的会话。
- 首版仅 LAN、单客户端，WebRTC 不配置 STUN/TURN。SDP/ICE、加入、停止和制卡复用互联 HTTP、配对令牌以及 HTTPS 指纹校验。共享 WebDAV 密码不能授权串流控制。
- Android 只接收视频/音频、发送输入、显示 Hook 台词和查词。Hook、helper、窗口采集和 Anki 写入全部留在 Windows；iOS/macOS/Linux 无接收或游戏 Hook 入口。
- 触控按视频实际显示区域映射到客户区；肩键、方向键和确认/取消键可在本次会话中配置。Windows 输入使用目标 HWND 的消息投递，检查进程身份和前台窗口，不使用全局键盘注入。目标不在前台时会拒绝输入并回传 ACK 原因。
- 查词面板复用 `FushiRemoteLookupClient` 和 `DictionaryPopupLayer`；查词固定到串流主机。分词复用现有日语模块，无本地词典时按字回退。查词面板可收起，未新增系统级悬浮窗。

## 实现

`packages/fushi_engine/lib/sync/game_stream/` 保存 v1 wire 类型与会话服务；app 的 `game_stream_host.dart`、`game_stream_receiver.dart`、`game_stream_client.dart` 装配 WebRTC、原生窗口输入和配对传输。服务端提供 `/api/game-stream/sessions` 以及 `/join`、`/signal`、`/stop`、`/mine`，后四者也支持 `/sessions/{id}/...` 路径。

主机显式调用 `flutter_webrtc` 的 Windows 窗口桌面捕获，精确匹配十进制 HWND source id，要求视频和应用回环音频轨道同时存在，不回退到整桌面。视频上限目标为 1080p/60fps、8 Mbps，根据 WebRTC 可用带宽与 RTT 降低码率、帧率与分辨率。实时视频后端由 WebRTC 插件提供；逐行截图使用现有 WGC 通道。

可靠有序数据通道携带输入、ACK 与台词。两端信令序号独立，远端 SDP 之前到达的 ICE 先缓存。重复输入不会重新注入。Android 进入后台时发送按键释放消息、暂停输入与 HTTP 轮询，恢复时保留同一连接；短断线允许原连接恢复，失败的连接要求主机重新开启。窗口销毁、隐藏、最小化、Hook 会话结束、显式停止或 10 分钟无客户端活动会停止采集并释放按键。

台词以 `lineId` 和当前文本版本关联。Windows 收到台词时冻结截图，使用有界内存缓存（最多 16 张、32 MiB）；渐进文本复用同一 ID 时会更新截图请求。制卡只能使用该文本版本对应的截图和已有逐行音频资源，复用 `GalHookMiningCoordinator`、主机 Anki 设置和媒体压缩。旧行截图缺失或已经淘汰时明确失败，不重新截取当前窗口冒充历史画面。移动端不能上传截图/音频、覆盖主机牌组设置或指定媒体路径。

## 验证记录

- Windows Debug 构建通过，包含新原生输入通道和 WebRTC 插件。
- Android Debug APK 构建通过。
- 引擎协议/会话测试 18 项通过；app 串流、词典传输、制卡与引擎纯净性回归 82 项通过；页面及设置回归首轮 24 项通过。
- 渐进文本截图修复的 5 项定向测试通过；主机启动生命周期与分词/键位配置另有回归测试。改动文件定向静态检查通过，最终追加执行结果以本次任务记录为准。
- 真实窗口 spike 位于 `fushi/integration_test/game_stream_capture_spike_test.dart`，使用自建 WinForms 窗口和生产 host，严格检查真实帧，不能以 track 创建成功作为通过。初次运行已到达远端视频流阶段，但尚无解码帧证据。

捕获启动时的前台条件需按本地主机按钮流程验证。上游仍记录着 Windows 后台启动返回无帧轨道的问题：[flutter-webrtc #2137](https://github.com/flutter-webrtc/flutter-webrtc/issues/2137)。依赖版本和 Windows 应用音频能力参见 [flutter_webrtc changelog](https://pub.dev/packages/flutter_webrtc/changelog)。

尚需完成：真实 HWND 视频帧与应用音频、最小化/销毁清理、输入目标隔离，以及 Windows 游戏 → Android LAN 首帧/音频/旋转/后台恢复 → 递归查词 → 主机 Anki 真卡（按 `lineId` 核对截图与句音）的端到端证据。
