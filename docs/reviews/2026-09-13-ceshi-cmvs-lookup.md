# ceshi CMVS 内嵌查词复核

## Proved

2026-09-13 从用户原目录运行 ChronoClock trial v2 的 `cmvs64.exe`，取消修改启动设置后进入主菜单并点击 START，随后点击正文推进，观察到正常日文正文。旧资料中的启动/locale 阻塞在本轮未复现。没有修改系统 locale。

- EXE SHA-256：`AA89205A61C7078A167F9E6668EEA2E4328BDD5C9CBCDD6F45B238CF475ACEA2`，x64。
- 游戏 PID 62980；正常启动后附着，helper PID 66880。
- helper 和 DLL 来自本独立 worktree `native/galgame_hook/build-x64/Release/`；源码基线 `a5fc01fd6b`。
- DLL SHA-256：`D263C0E18CB7477943D34AA4EB6ED7CFCD18FF269F8FDE8AFEDE007AAA451921`。
- helper SHA-256：`EE84AB00A91C54C0A265DC6E38CD3439E3DE901BA1C23B9FA869F9547813EB4A`。
- 注入日志记录两个 LoadLibrary 成功、Luna connected；生产 lookup probe 读到 IPC v24，启用 lookup 后 `text_writes=2`、`hits=0`、`frames=0`、`geometry=0/0`、`lookup_diag=0`。这仅证明文本区有写入，不证明已选正文线程。
- 本机日志：`.codex-test/cmvs-lookup/`，未纳入游戏内容。

当前 `CmvsAdapter` 只有文本及 PCM 能力，没有几何采集或 lookup admission 实现；零几何读数与源码一致。

## Not proved

尚未建立当前正文索引与最终屏幕字格的映射，没有新增生产 adapter，不能称内嵌查词完成，也不能认定游戏无法适配。没有进行字形命中、弹窗显示、输入屏蔽或制卡 E2E。

静态 EXE 使用 D3D9 绘制，导入 GetGlyphOutlineA。后者提供字体栅格化数据，不提供最终屏幕坐标，不能直接当布局 provider。保留 CMainFrameDraw / CTexture / CRenderTexture RTTI，但未证明正文布局对象契约。

## Checks

x64 CMake 配置及 hook、injector、lookup probe、ring probe 四个目标构建成功。存在既有构建警告；未做代码修改，因此没有运行 CTest、x86 或 Flutter 测试，构建不等于查词测试通过。

## Next gate

确认正文线程与 CMVS 文本布局/纹理绘制对象的对应关系，取得 source-index → glyph rect → 客户区投影契约后再实现严格 provider。游戏通过自身退出菜单关闭。

## 2026-09-13 静态布局链补充（同一 EXE 哈希）

以下仅是本机 PE 指令数据流证明，尚无这条布局链的运行时身份或命中证明；RVA 不能泛化到其他 CMVS 版本。

- 字格建图函数的实际入口是 RVA `0x2d580`，不是前一段函数末尾的 `0x2d578`。它分配 atlas tile、调用 `0x57580` 栅格化、上传位图并创建 sprite。`0x2d820` 遍历 owner 的 `+0xb8` 单链表，在裁剪检查通过且节点 sprite id 为 `-1` 时调用该函数。
- 链表节点分配大小为 `0x40`：`+0x00` next，`+0x08` sprite id（初始 `-1`），`+0x0c` 起为复制的 `0x28` 字节字形属性；`+0x0e` 是 CP932 字码，`+0x10` 复用为 atlas tile id，`+0x18/+0x1c` 是布局 cursor 截断得到的整数 x/y，`+0x20` 是字号，`+0x38` 是字形位图指针。销毁函数 `0x2cfb0` 释放节点及位图并清空表头，不能跨刷新保留裸节点地址。
- 生产者 `0x2df30` 的 RCX 是 owner，RDX 是 CP932 源串。它按源顺序追加节点，处理双字节、单字节、换行及 `{base/reading}`：base 建节点，reading 跳过；`\\c` / `\\t` / `\\w` 不生成字格，`\\n` 移动 cursor。因此原始字节偏移、清洗后的正文索引与链表序号不是同一个坐标域，后续 provider 必须显式构造映射。
- owner 的 `+0xb0/+0xb4` 是布局 cursor；`+0x10/+0x14/+0x18/+0x1c` 由 `0x2d150` 设置布局范围；`+0x08/+0x0c` 是基准平移，`0x2d040` / `0x2d0c0` 将其按 owner `+0x160 / +0x168` 比例传给 sprite。`0x2d820` 采用 `+0x20/+0x24` 及 `+0x28/+0x2c` 做可见范围检查，不能用未裁剪的全链表声称字形可命中。
- 唯一直接生产调用点 `0x703d2` 来自 VM handler `0x70390`，按 VM 参数索引 root `+0x10e8` 开始的 8 个 owner 槽。每帧 `0x148e0` 同样遍历这 8 个槽调用 `0x2d820`。尚未证明哪一个槽属于当前选中的正文线程；不能按槽号、长文本或位置猜测正文身份。
- owner `+0x00` 是父 sprite；其 `+0x1808` 是子 sprite 链，链项 `+0x08` 为 id、`+0x10` 为 sprite 指针。sprite `+0x1830` 指向绘制状态；`0x39340` 转发到 `0x1e3c0` 写该状态 `+0x08/+0x0c/+0x10/+0x14` 的 atlas 区域，`0x39380` 转发到 `0x1e3f0` 写 `+0x20/+0x24` 的整数位置。`0x396e0` 只写 sprite `+0x1870/+0x1874`，其最终比例语义仍需沿消费端证明。
- 绘制继续经 `0x396f0` → `0x1f320`，后者接收父状态、额外偏移和绘制目标；存在父级状态与 transform 分支。因此 atlas 区域或 owner 局部位置都不能直接当作客户端像素矩形。

当前仍不添加 resolver 或 lookup admission。下一步最小动作是在正常正文会话采样 root 的 8 个 owner 槽，核对选定文本身份与节点序列，并沿真实 sprite 绘制状态取得客户端投影；采样前由主代理协调窗口，避免与其他引擎 UI 验证抢焦点。静态进展不足以判定该游戏无法适配，也不足以作为删除依据。

只读采样定位补充：主入口 `0x1efa` 分配 `0x147b8` 字节 root，构造器 `0x8b70` 在 `root+0x00` 写入 `module_base+0xd53e8` 的 vtable，并初始化 `+0x147b0=0`、`+0x147b4=1`。主循环 `0x1fd8` 将同一 root 传到 `0xd400`，再到 `0x148e0`。这提供后续可写堆候选定位与多字段校验入口，仍须用真实 HWND/槽内容核验唯一实例。已在不入库的 `.codex-test/cmvs-lookup/read_layout.py` 准备只读元数据采样器并通过 Python 语法编译；它只输出字符摘要、计数与前六格几何，不输出真实台词，尚未对游戏运行。

## 2026-09-13 正文只读复测及独立 reader

新会话 PID `59760`、module base `0x140000000`、root `0x2570080`、HWND `0x1131606`。没有新增 Hook；主代理操作窗口，本任务仅 `ReadProcessMemory`。

### 运行时排除旧候选

首句和后续正文中 `root+0x10e8` 的 8 槽全空。前一节的 0x40 节点链因此不是本样本当前正文路径；其静态契约仍可复核，但不能用于正文 admission。

### 实际出现字格的第二套布局

`0x59740` 构造 0x180 字节 owner，root `+0x1020` 保存 12 个指针；其字格创建函数 `0x58090` 分配 0x48 节点，表头改为 owner `+0xa8`。节点 `+0x0c` 的属性长度 0x28、`+0x0e` CP932 字码、`+0x18/+0x1c` 字格布局位置、`+0x20` 字号等有独立指令链证明。每帧 `0x14a20` 对这 12 槽调用 `0x586e0` 更新，`0x14e00` 将 owner 的 sprite 交给绘制队列。

- 第二句：slot 7 的 owner `0x2646090` 有 33 字格，基点 `(250,567)`，首格 `(30,45)`，字号 30；sprite id 从 6 开始。
- 第三句：同 owner 变为 20 字格，基点 `(295,612)`，首格仍 `(30,45)`，sprite id 从 39 开始。两句的行数及位置变化与主代理观察一致；其他非空 owner 为 slot 10，但其字格链为空。
- 第三句节点按顺序 CP932 解码所得 UTF-16LE 摘要 `f3db08ba94bd34e5d873d30352e63fa3c54a18ea48190e865604cc0032b79ad9`。该摘要尚未与所选 Luna 正文线程比对；不保存真实台词。
- parent sprite 整数位置与 owner 基点相同；子 sprite 位置为字格位置减 2，atlas 34x34 包含栅格化边距，不能拿 atlas tile 坐标当客户区矩形。
- owner 设计维度为 1280x720；当前渲染 surface（root `+0x7b0` 所指 renderer 的 `+0x08`）也是 1280x720。静态最终 Present 的 source/destination 参数为空，但 backbuffer 到客户区的完整缩放/偏移与窗口变化尚未取得独立证据，未发布客户区几何。

新增 `cmvs_dialogue_layout_reader.h` 只读这套布局的有界快照，不扫描进程、不选择正文槽、不发布文本/geometry、不启用 lookup。调用者仍须先核验文件哈希，再给定已验证 root 与明确的槽。链最多 512 格；循环、越界读、非法 CP932、重复 sprite id、错误根对象、节点或 owner 在双读间变化时返回失败且清空输出。双读不是引擎帧锁，尚不能替代生产生命周期契约。

### 已执行验证

- `fushi_cmvs_adapter_test` x64 / Win32 均构建成功，CTest 各 1/1 通过，包含 12 组 reader 合成正负例及既有配置身份案例。Win32 是解析器编译与合成测试，不代表 cmvs32 游戏已验证。
- 本机不入库的 x64 只读命令行 harness **直接调用新增 C++ reader** 读取 PID 59760：slot 7 返回 captured、20 glyph，其余 11 槽返回 empty；没有用 Python 解析结果冒充生产 reader 结果。
- manifest/profile 生成检查退出码 0；manifest 23、结构 50、workflow 6 条 Python 测试全部通过。
- 未做全量 native CTest、双架构全部目标构建、Flutter 测试、所选正文线程匹配、弹窗命中、输入屏蔽或制卡 E2E。变更尚未接入生产路径，不能宣称内嵌查词完成。

### 正文身份与缩放复核的后续结果

- 主代理目视转写第三句后在内存计算的 UTF-16LE SHA 与上述 20 字节点摘要完全一致；不存原句。
- 第四句变为 4 字节点，基点 `(535,291)`，sprite id 59 起；节点 UTF-16LE SHA `f99add8e66a04ad6dd4d52143616b0b6ecc7868d5c9312384387ce5a0ca4ad9e` 与主代理所选 `EmbedCMVS` lane（thread `618113978262494747`、event `41`）一致。
- 新增 `cmvs_dialogue_text_resolver.h`，严格 CP932 解码后按既有 lookup 空白规则与指定 UTF-16 源逐字比较，返回每个非空白字格在所选文本里的 source index。拒绝前缀、后缀、其他字符、无效编码及空句，不选择线程。
- 通过不入库 x64 harness **直接调用新增 C++ reader 和 resolver**，只读 IPC 当前所选 lane 与游戏内存，得到 `capture=0 count=4 selected_thread=618113978262494747 event=41 selected_chars=4 text_match=1 mapped=4`。早一次 harness 编译因未设置 `/utf-8` 被源码中文注释编码错误阻断；补齐编译选项后构建成功并重新执行，旧 exe 输出不算 resolver 证据。
- 双架构定向 CTest 在增加 resolver 正负例后再次各 1/1 通过。
- 同句 Alt+Enter 后，PerMonitorV2 probe 读取真实 client 与 window 都为 `3840x2160`、DPI 144；主代理看到的截图展示为 `2560x1440`，两种坐标不可混用。owner 和字格设计坐标不变；渲染 surface `+0xb8` 从 0 变 1，`+0xc8/+0xcc` 为 3840/2160。没有把截图展示比例硬编码为 provider 投影。

正文串身份现已通过，但完整绘制投影、可见字格状态与 frame 生命周期仍未达到生产 admission；新增 reader/resolver 无运行时接线、无支持矩阵变更。

## 生产接线候选（待新会话查词 E2E）

`cmvs_lookup.inc` 已接入现有 CMVS adapter，声明 provider `(engine_exact_layout,16)`；Dart 对应允许表由主代理在同分支提交 `65aa3ea2bb`，该提交须与 native 接线一起交付。IPC 没有结构/版本/偏移变化。支持矩阵仅登记 `implemented_unverified`。

- 仅同一 x64 EXE SHA 启用 `0xd400` 原始主循环入口 Hook，覆盖脚本执行、布局更新、绘制及 Present；它的 root 来自真实函数参数，不扫描堆或绑定固定 slot 7。
- 回调在循环结束后用固定 4 MiB 池复制有界原始内存块，遍历总计最多 512 字格及 512 子 sprite。没有文本解码、坐标运算、文件/IPC IO 或等待 worker。快照锁忙时丢弃本帧且递增完成代数，旧帧不能继续命中。
- worker 从不可变副本复用 reader 与 selected-lane resolver；只有唯一可见布局与当前所选整句匹配、sprites 无旋转/淡出/其他未实现变换、presentation 成立才 OfferReady。读取字体栅格、窗口大小或源串任一部分，均不能单独建立准入。
- 原始子 sprite 的绘制矩形用于命中。重叠字形区域没有唯一字格时不发布命中。选中源 UTF-16 index、文本道 event seq 与本帧代数独立传递；发布前再次核对 frame、selected event/text/thread 和 client 尺寸。
- 当前只复用 Shift 触发、通用输入屏蔽事务及既有 overlay/direct-card 呈现；没有实现裸左键拦截，也没有宣称输入屏蔽实测通过。
- 窗口模式的 physical client 为 1280x720，post 对象为空，严格采用 identity；全屏 physical client 3840x2160，post 对象存在且实际 D3D9 StretchRect 读取 surface `+0x50` 的 `(0,0,1280,720) → (0,0,3840,2160)`。恢复窗口后旧 StretchRect 字段仍留在内存，但 post 对象已销毁，resolver 明确忽略这些旧值。

候选构建目录为 `native/galgame_hook/build-cmvs-runtime-x64/Release/`。DLL SHA `92ABD313E8B73AC5239513A49C7F66B96B35E1A3DDFF1526C1523AC3BBB6DEE9`，injector SHA `E62486C156B50E2B0B5B34A3F620620F1A36CE96FF868F633FB32995EDD35D33`。旧 build-x64 DLL 被第二会话加载，链接出现 LNK1104，因此使用新的独立构建输出；不把被锁旧 DLL 的运行当本候选验收。

候选已完成双架构 hook DLL 编译，x64 / Win32 的 CMVS、geometry registry、line text match 定向 CTest 各 3/3；manifest 23、结构 50、workflow 6 条 Python 测试通过。新增 presentation/quad 合成负例覆盖旧全屏矩形残留、客户端尺寸不符、目标越界、post 生存期变化、隐藏父 sprite、透明子 sprite 与旋转。正在补充全量 native 构建/CTest；新候选尚未记录真实 geometry OfferReady/Shift hit/popup/input/card 结果。

正式 `tools/build_distribution.ps1 -RunTests` 已执行成功（退出 0）：`build/x64` 全量 CTest **111/111**、`build/x86` 全量 **115/115**。两个正式 zip 与 source fingerprint 位于 `native/galgame_hook/dist/`；x64 zip SHA `791305cf0bb321b3080e76bff85fb6e1070ab3a102e79c2390e51204e3e2d930`，x86 zip SHA `3ac4cf7db0a09e85fca2ecb5f0333015e67633d7802cc13b7eaf91d419a44aae`。正式输出 x64 DLL SHA `D4309F049381E8F892B5964AC9A24C5E9F88AB034BA7F5775975E099E3EC88F9`；此前 92ABD 候选来自另一构建路径，E2E 必须记录实际安装/加载的正式包哈希。主代理负责安装至同 worktree 的新 Flutter Windows bundle 并执行真实查词验收。

## 安装启用失败状态修复

主代理复核确认：公共 `HookFn` 在 `MH_CreateHook` 成功、`MH_EnableHook` 失败时，会留下非空 trampoline 并返回 false。CMVS 原先把非空 trampoline 当成功缓存，导致后续安装查询、sensor available 与 admission 可错误报告 `SensorInstalled`。

本轮仅在 CMVS 增加独立 `HookInstallation` 状态：只有安装调用返回 true 且具备 forwarding trampoline 才 enabled；失败保持失败，不因残留指针或后续查询转为成功。三个生产判据均读取 enabled，shutdown 清除 enabled；公共 `HookFn` 未改。C++ 回归通过注入真实失败契约（先填 original、再返回 false）验证非空指针不会产生成功，另测成功/缺失 trampoline/shutdown；结构守卫钉住 adapter admission、sensor available 和 worker 的接线。

正式 `build_distribution.ps1 -RunTests` 重包退出 0；x64 全量 **111/111**、x86 全量 **115/115**，Python 结构 **51/51**、manifest **23/23**。新的 `dist/voice_hook_x64.zip` SHA 为 `1fe048d1a4721f29569e64ca3d1d50564a7ea339778f4e39e26177d5fa49134c`，x86 zip SHA `51bf5330ad98254dcbed40e135ecb7d35e50ba37161a68b9a2623481d40feb48`；source fingerprint `f49ae4c545d7b53ab67f0bdaa683468bc1e80d369887b89780b60243f33128f2`。正式 x64 DLL SHA 更新为 `F4E06503B3D45DCA4F4A8D197FDDD7A9693A03B5201323F15ADA0F1DEEB7ABF0`。尚未注入新 DLL，GUI 等用户处理防火墙弹窗；没有新增真实查词验收声明。

## Shift 输入所有权：真实失败、判因与修复候选

主代理在 PID 64596、host PID 67840 中选定 `EmbedCMVS` thread `2591956086751223238`，确认 provider `2/16` ready 且 hover 与正文逐字位置一致。单次工具 Shift 短按后正文推进，第一次 hits 仍为 0；受控第二次复现时 text_writes 6→8、hits 0→1、frames 仍为 0。后者不能视为词典验收通过。

主代理加载不入库的只读 observer（SHA `434F12586C763734159D40921C9F1323D3725ACA379F4ABC6AB4683A3430EFB1`）后，两个已证明入口只转发和记录，不改键盘/消息。受控复现记录：tick 48915000，`0x53fe0` 收到缓存 VK_SHIFT/LShift 为 0x80/0x80，将 input `+0x660` 从 0 升为 1；同 tick `0x16e80` 处理 Shift WM_KEYDOWN，TranslateAccelerator 返回 0。15ms 后 WM_KEYUP 返回 0，输入计数 1→0。命中 wire 无时间戳，未编造 hit 相对毫秒时间。静态主链是 `0x18430 → 0x53f60(GetKeyboardState, input+0x258) → 0x53fe0 → 0x52ac0`；现场 input `+0x3f6` 绑定值 23 恰索引 `+0x604+23*4=+0x660`，生成 mapped down/held/up。原 worker 独立轮询 GetAsyncKeyState 没有键盘所有权：可漏掉 15ms 短按，也允许引擎原动作与 lookup 并发。

修复仅对同一已验证 CMVS x64 hash，在 `0x53fe0` 消费缓存之前建立 Shift 事务：

- frame Hook 与 input Hook 都明确启用成功才报告 SensorInstalled。
- 只在有效已投影正文目标、所选 thread 原子一致、registry native admission 允许、当前物理指针仍在该字格且队列可预留时取得首次 down 所有权。
- 按下在外部/无效区或队列不可用时，整个 held 周期不再中途抢键。已认领的 Shift 只清除缓存中 VK_SHIFT/LShift/RShift 的 high bit，其他键与低位保持原样；owned 状态跨移出/失焦保留直到物理及缓存 release，形成完整 down/up 配对。
- 回调只做固定目标复制、轻量身份/指针检查和有界四槽入队；不解码、不发布 IPC、不做延时或轮询重试。callback 的 shift_lock→registry shared read 没有对应的 worker 反向持锁路径：worker 均先释放一个锁再取得另一个。
- 队列绑定原正文 event/thread、owner/head/node、字格身份、UTF-16 source index、窗口与投影；普通 redraw 的 raw frame 序号不是逻辑身份。worker 对真换句/字格/窗口变化取消原请求，绝不取 latest 别句替代。暂时的 raw buffer 竞争保留待消费请求；不依赖瞬时 worker Shift 电平。

新增回归覆盖上述配对/外部按下/失焦/队列满、down+up 均早于 worker 的短按、同句普通重绘可消费、真换句与几何变化拒绝，以及只屏蔽三个 Shift 键的边界。结构守卫确认消费者先 mask 再调用原函数、worker 不再采样 Shift、按原 request 发布。结构 **52/52**、manifest **23/23** 通过；正式重包 `-RunTests` x64 **112/112**、x86 **116/116**，退出 0。

最新正式 dist：x64 DLL SHA `4AA5048A83E0908B472EC412189B88BC90829D3B977A84F7AF95476D0F71D275`；x64 zip `182b9d7ba3453a5a9d623e8be9d750cbc60324706e231fbf5ec218f8a08797ea`；x86 zip `d18f2e9007a3a1a22ef3d9156c3dff4698d4aff5d0823fa92a0bdca0fd7da093`；source fingerprint `eb5ef02733f2f953a0d9e047db5e24930ff34d26f73d5595984fbf5fda3062a4`。需要新 CMVS 会话复测，不能与当前 passive observer 在同一 0x53fe0 地址叠加；词典弹窗与输入/制卡 E2E 尚未升级为通过。
