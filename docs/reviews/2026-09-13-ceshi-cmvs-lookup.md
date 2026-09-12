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
