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
