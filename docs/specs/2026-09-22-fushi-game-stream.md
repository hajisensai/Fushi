# Fushi 局域网游戏串流与远程查词

状态：`implemented_unverified`。代码和定向回归已落地；真实 SGRE → Android LAN 音视频、Hook 台词和查词已取得证据，输入实效和 Anki 真卡尚未完成联合验收，不能据此升级任何游戏引擎的支持状态。

## 使用入口和边界

- Windows：先启动已有的 Galgame Hook 会话，再在游戏工作台点击「开始串流」。绑定的是这一次 Hook 会话的 HWND 和开始时间。HTTP 不能选择窗口或任意进程；唯一的例外是下文「从游戏库启动并串流」，它只接受库里的游戏 id，且默认关闭。
- Android：底栏「游戏」模块（2026-09-23 起 Android 也开，形态是串流客户端）按主机列出游戏库与正在进行的串流；「Fushi 互联」客户端区域的「加入游戏串流」入口保留。
- 首版仅 LAN、单客户端，WebRTC 不配置 STUN/TURN。SDP/ICE、加入、停止和制卡复用互联 HTTP、配对令牌以及 HTTPS 指纹校验。共享 WebDAV 密码不能授权串流控制。
- Android 只接收视频/音频、发送输入、显示 Hook 台词和查词。Hook、helper、窗口采集和 Anki 写入全部留在 Windows；iOS/macOS/Linux 无接收或游戏 Hook 入口。
- 触控按视频实际显示区域映射到客户区；肩键、方向键和确认/取消键可在本次会话中配置，也支持焦点导航及 Enter/Space 按下和松开，失焦会释放按键。普通 Windows 输入使用目标 HWND 的消息投递，检查进程身份和前台窗口，不使用全局键盘注入。目标不在前台时拒绝新增输入并回传 ACK 原因。
- SGRE 实测不消费确认键的窗口消息，现增加由其已验证 DirectInput 能力门选择的进程内确认适配；LAN6 首次观察到确认之后的新台词。该适配当前仅接受默认手柄「确认」，其余手柄键、原始键和坐标触控明确返回不支持；不得把全套控制视作 SGRE 已验证能力。DOWN 在游戏采样后确认，750ms 租约到期失效；UP 和清理允许在后台按同一进程身份发布零掩码，失败 DOWN 立即清理。内部 Hook IPC 升为 v25，已驻留 v24 DLL 的游戏需保存后重启，不能靠重新附着替换。
- 台词面板与视频侧栏共用 `SubtitleTranscriptRow` / `SubtitleTranscriptText`：整句展示、当前行底色、字体间距、复制按钮和文字命中逻辑一致；横屏显示侧栏，窄屏显示底部面板。点词从选中位置发送句子后缀，由主机词典进行最长匹配，不要求 Android 安装本地形态词典；键盘可移动台词光标并按 Enter 查词。查词结果复用 `FushiRemoteLookupClient` 和 `DictionaryPopupLayer`，固定到串流主机。面板可收起，未新增系统级悬浮窗。

## 2026-09-23：安卓游戏模块、仅窗口串流、Moonlight 式参数

- **游戏模块两种形态**：`GamesModuleForm`（`module_id.dart`）是唯一的平台判据——Windows = `localLibrary`（原游戏库 + Hook 工作台），Android = `streamClient`（`game_stream_library_page.dart`），iOS / macOS / Linux 不开。iOS 不开是技术原因（没有 WebRTC 接收入口），与 `StoreRestrictedCapability` 无关，`ios_store_compliance_guard_test` 以显式例外登记。Android 上 Windows 专属入口（游戏设置分类、下载中心游戏域、Hook 浮窗）按形态隐藏。
- **从游戏库启动并串流**：新端点 `/api/game-stream/library`、`/library/cover`（封面以 base64 回 JSON，走已钉扎的 POST 传输）、`/launch`、`/launch/status`，门槛与串流一致（HTTPS + 已配对 peer），另要主机开关「允许远程启动」（`game_stream_remote_launch`，默认关、设备本地、不随备份）。主机侧 `FushiGameStreamLibraryHost` 走与库页同一条 Hook 启动路径（无界面版 `ensureInjectorHeadless`），等窗口绑定（90 s）后以请求方的参数开流；该会话**预留给发起启动的 peer**，其他已配对设备 join 得 409。进度状态 `starting → waitingWindow → streaming | failed`，失败码见 `GameStreamLaunchFailure`。游戏已在跑、或已有等待中的同游戏串流时不重复启动。
- **仅窗口串流**：开播不再强制 `SetForegroundWindow`（WGC 本就能采被遮挡的窗口，最小化仍停播）。输入新增 `inputFocus`：默认 `background` —— `PostMessage` 定向投递到绑定 HWND，不再要求前台（身份 / 存活 / 最小化 / 隐藏校验保留）；`foreground` —— 按下前按需激活，给只在前台采样输入的引擎用。SGRE 原生确认键仍要求前台。runner 的具体拒绝原因（`PlatformException.message`）回传手机并本地化。
- **触控**：新增右键 / 中键与滚轮（能力位 `pointerButtons` / `wheel`，旧主机不发）；按下前先 move；两种触控方式（纯函数 `GameStreamTouchInterpreter`）——直接点击（双指点按 = 右键、双指拖 = 滚轮）与触控板（相对移动光标、点按 = 左键、按住再拖 = 拖拽）。旧主机下多指仍按旧语义忽略。另有实体手柄按键映射、硬件键盘（视频获焦时）与软键盘。
- **参数**：`GameStreamVideoSettings`（分辨率上限 360p–4K、帧率 15–120、码率 0.5–150 Mbps、自适应开关、带宽不足时的降级偏好、编码 auto/H.264/VP8/VP9/AV1、窗口输入模式、声音），解码时一律钳制。启动 / join 时带上；主机开流时按它设采集上限（runner WGC 适配从 `maxWidth/maxHeight/frameRate` 约束读取，上限 3840×2160 / 120 fps），join 时经 `setParameters` 调 `maxBitrate / maxFramerate / scaleResolutionDownBy / degradationPreference`，分辨率与帧率只能在采集上限内下调，会话回报实际生效值。编码由接收端在 answer 前 `setCodecPreferences` 决定（无需主机支持，设备不能解码则回退）。串流中改参数经「同一 client 重复 join」热更新，编码下次连接生效。性能浮层（分辨率 / fps / 码率 / 编码与解码器 / RTT / 抖动 / 丢包 / 丢帧 / 目标）来自接收端 `getStats`。
- **制卡修复（BUG-2636）**：见 `docs/bugs/BUG-2636-game-stream-lookup-mining.md`。
- 以上均为代码与单测层证据；安卓真机 ↔ Windows 真游戏的端到端（远程启动、后台输入实效、各档参数、真卡）尚未执行。

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
- LAN5 截图暴露了按字按钮展示和单字查询的问题。`7e70c117d49` 修正源文本位置与后缀查询，覆盖空白、重复词和 UTF-16 边界，页面/客户端 22/22 通过。按用户要求，`292834691f1` 进一步提取并复用视频字幕栏的整句组件；视频侧栏、文本命中、串流横竖屏和键盘事件隔离共 81/81 通过，8 文件静态检查通过。这些测试批次有重叠，不计入上述不同用例总数；新版侧栏仍待 Android 真机截图复核。
- `a849b2dc766` 修正真实 AnkiConnect 请求契约：夹具的 `HttpClientRequest.write` 默认使用 chunked，同机只读 `version` / `findNotes` 均返回 HTTP 200 但 `result:null`；相同固定长度 JSON 分别返回版本 6 / 空列表。这会使夹具在 preflight 的非空断言处失败，尚未进入生产制卡链，足以解释 LAN4 的失败路径，但历史日志不能证明没有其他问题。夹具现按 UTF-8 字节设置 `Content-Length`；真实 loopback HTTP 测试覆盖日文与 emoji 字节长度和非 chunked 请求，7/7 通过，2 文件静态检查通过。修复不改 Anki 设置；真卡及对应媒体仍待复测。
- 包含共享台词栏的 Android QA build7 已构建并安装到指定设备，源码 `292834691f1`，APK SHA-256 `d5d18100bf1db2227a2a7a293e43cc56c31368482982b912316a75c3fe1eb677`。已检查 APK 内确有共享台词组件且无 Windows Hook/helper 载荷；安装成功不等于新侧栏的设备端交互验收。
- SGRE 输入新增独立状态发布代际，避免旧回调覆盖新请求 ACK，以及请求在状态写入中被替换时暴露旧代际的混合载荷。`d195abade9d` / `30787f17295` 的确定性交错回归在 x64、x86 均通过 4 场景 / 25 检查；还原各错误分支的私有变异均失败，无生产测试钩子。普通原生输入回归增加后台 UP 身份与零掩码检查，修前 69 检查中 2 项失败，修后 69/69 通过。以上均为合成窗口/IPC 证据，不等于真实游戏已消费输入。
- `6f149102f9e` 拒绝同 `lineId` 渐进文本更新后、界面尚未重建时来自旧段落的查词操作。真实键盘 widget 回归先复现旧后缀错误发出，修后整页 11/11 通过，2 文件静态检查通过；新段落渲染后可以正常查词。
- 最终 v25 helper 双架构构建及完整原生 CTest 通过：x64 113/113、x86 117/117。manifest / profile 生成检查通过；manifest 23、adapter 结构 52、workflow/replay 6 项 Python 测试通过。归档 SHA-256：x64 `cb1445c5178dfa69b70cf7f478ac7f4781e7ca2ba5e4341aa053e4dae633aee7`，x86 `ea0939fa4297ca2c67f705436cf7b5b8b612075f712f0ddbef0eb5fefccf6f62`。尚未加载到用户当前旧游戏进程。
- Android QA build8 增量纳入渐进文本守卫，源码 `6f149102f9e`，APK SHA-256 `b26f2d598974cf1e4d461eef88edd8a4dbaf310591d50695dddb474c79f73862`，构建并安装成功。已检查共享台词组件存在且无 Windows helper 载荷。原生 SGRE 确认适配落在 `66f73774e39`，仅影响 Windows 及其 helper。
- Windows 最终 Debug 构建通过（237.4s），未运行测试游戏。随包 x64/x86 Hook DLL 与本轮原生构建哈希相同，分别为 `a6900ddff897329b5eaa6b52e2adf1cdb2f6c285cda4330f94f0f67ba69f8fd6` / `855b93a789c0b01904576d757a299b4dd2cfbbc40da0ffdf15e60aa06a5a155d`。等待操作者保存并退出旧 SGRE，再由测试会话早注入启动新进程；不能把构建通过写成 LAN6 通过。

- `gs-lan-host-20260922-6` / Android `lan6` 使用早注入的新 SGRE 进程，运行时读取已加载 x64 Hook DLL 的 SHA-256，与 v25 构建一致。首帧渲染成功，解码 1668 帧、接收视频 10,875,751 字节和音频 222,567 字节，音频能量非零。真实 Android 截图确认整句侧栏、当前行高亮及复制入口生效。
- LAN6 确认键保持 588ms，DOWN/UP ACK 接受，随后观察到 4 次新文本事件和不同的当前句文本哈希；比仅 ACK 多了一层游戏画面/台词变化证据。夹具仍把独立输入因果证明标为未验证。最新句没有 `audioResourceId`，客户端在句音前置断言处停止，未执行查词或发送制卡请求；主机确认零张验证通过的卡，正常撤销凭据并清理会话。不能用前面行的已匹配资源补齐最后一行，也不能从该断言推出 Anki 修复失败。
- `605ee6531c1` 调整夹具顺序：先将用户准备的有声句固定为同一 `lineId` 和文本，完成查词、远程制卡和主机媒体读回，再执行确认键测试，不再要求推进后的下一句也有声音。主机新增文本长度、时间戳、线程哈希和前后缀关系等脱敏元数据；重新附着同一游戏的历史记录确认两组 2→3→5 字片段来自同一线程，折叠开关已开启，但短片段未达到原有 4 字折叠门槛。该事实不能证明相邻已配语音属于最终短句，本轮未修改生产配对策略。两个夹具定向静态检查通过。
- Android QA build9 纳入上述夹具顺序，构建通过（53s），安装到 SM-X716B 成功；设备端 `base.apk` SHA-256 与本机产物一致，为 `d7559a705e204f3b7b0effaed4237d9cd7f791fe1dff70d0b627850e19215fd5`。源提交 `605ee6531c1`，生产 Android 功能未在此轮改动。此项仍只是安装证据，不能代替新的 LAN 制卡结果。
- `gs-lan-host-20260922-7` 仅重新附着并导出了上述历史片段元数据；等待新剧情准备的本地启动门在 10 分钟后超时。该轮未启动串流、无 Android 加入、无制卡请求；测试凭据已撤销，Hook 会话清理，游戏进程保留。不能把这次准备阶段超时算作音视频或制卡回归。
- 追加修正主机验收观察器的渐进截图误覆盖：在生产制卡实际选图的同步阶段固定本次 `lineId`、文本和 PNG 哈希，PNG 按内容哈希保存，读回时核对原始文件与 Anki 压缩图。新版本截图不能覆盖正在验证的旧版本证据。夹具回归 11/11 通过；恢复「验证时读取当前行槽」或「写阶段日志前过早冻结」的两个独立错误变体均在实际执行对应测试后失败，恢复修正后再次 11/11 通过。此处仅修测试证据，不改变生产截屏或制卡行为，也不代替真卡验收。

捕获启动时的前台条件需按本地主机按钮流程验证。上游仍记录着 Windows 后台启动返回无帧轨道的问题：[flutter-webrtc #2137](https://github.com/flutter-webrtc/flutter-webrtc/issues/2137)。依赖版本和 Windows 应用音频能力参见 [flutter_webrtc changelog](https://pub.dev/packages/flutter_webrtc/changelog)。

尚需完成：SGRE 输入实际响应、真实游戏最小化/销毁清理、Android 旋转/后台恢复，以及主机 Anki 真卡（按 `lineId` 核对截图与句音）的端到端证据。目标窗口隔离、销毁与生命周期已有单元/原生自建窗口测试；其证据范围不等于真实游戏验收。
