## BUG-3929 · Rewrite Harvest festa!（九参一代 SiglusEngine）不识别引擎：台词混入人名、内嵌查词不可用
- **报告**：2026-11-01（用户：HF 的台词里混进了人名，有语音；内嵌查词不可用）
- **真实性**：✅ 真 bug。HF（SiglusEngine 1.0.17.19，x86，保护壳把 .data 与导入表合并进 `.text`）是对齐栈帧、普通栈帧、八参、旧版十六参之外的又一代代码，现有四个家族判据全部不命中：
  1. 字形排版函数是 `__stdcall` 九个 DWORD（含 self，`ret 0x24`），排完不把绝对坐标写回字形：字形只存行内整数偏移（+0x14/+0x18），绝对位置 = 行内偏移 + 对话遍历函数传入的第 8/9 个参数（行原点）。旧解码器都要从字形里读写回的浮点坐标，`siglus_glyph_record.h` 的 `DecodeSiglusGlyphRecord` 对它没有可用布局，查词档案建不起来。
  2. `siglus_lookup.inc` 的 `ResolveSiglusLiveFamily` 没有这一代的分支，家族判不出，原生文本所有者也就落不到 Siglus 消息通道；文本走 LunaHook 的高频线程，人名牌与台词混在同一条线程里（用户看到的「混入人名」）。
  3. 节头合并后节属性不能区分数据与代码，旧判据里「槽位必须在可写不可执行节」一律失败。
- **[x] ① 根因修复** — `6ec00bbc53`、`35b12d0c28`、`6ad4e9fca8`、`a9f886b46b`（鼠标路径真机已验，触摸见下）。按引擎结构新增「九参一代」家族，不按标题 / 哈希：
  - `siglus_ninearg_family.h`：字形入口 / 字体 / 坐标 / 返回尾声、对话遍历、渲染入口与两个互斥对话 pass、组渲染（经普通组绘制的调用边到达，再原位匹配，因为它有共用入口的兄弟函数）、消息包装、按键采样、输入消息、归一化、设计尺寸、owner、可见性、输入门共 20 组特征，外加调用边、共用越界 helper、cookie、槽位一致性与输入消息跳转表全部互证；槽位只要求镜像内、4 字节对齐、可读（`DataSlot`），真伪交给实时别名证明。
  - `siglus_ninearg_runtime.h`：实时快照（config→owner→window/input/modal/hidden/aux 别名、窗口 vtable+4 = 主消息处理函数、config 与 owner 两处设计尺寸一致、视口）两遍读取一致才采用；owner 链遍历 groups(0x764) → 渲染 owner(0x1640) → 对话条目(0x114) → 字形(0x270)。
  - `siglus_glyph_record.h` / `siglus_lookup_glyph.inc`：`kStackNineArguments` 与 `DecodeSiglusNineArgGlyphRecord`（行内偏移 + 行原点，int64 求和、越界拒绝）；`Detour_SiglusNineArgGlyphLayout` 只在返回点等于对话遍历的字形调用返回点、且字形属于当前 owner 链时发布。
  - `siglus_legacy_message_capture.h` / `siglus_message_capture.inc`：原生消息通道接管 HF 的对话包装函数（只有正文经过它，人名牌调用方被排除）；这一代包装函数不带脚本语音键、内层调用时 ESI 保持调用方的值，布局新增 `script_voice=false`，消费时 ESI 绑定到入口保存值；语音继续走 OVK 捕获 + 配对。
  - 输入：按键采样经保护壳私有替身槽调用 `GetKeyState`，复用 `VerifyProtectorKeyStateSlot` 实时证明；输入消息沿用旧版 fastcall 入口。
- **[x] ② 自动化测试** — `native/galgame_hook/tests/siglus_ninearg_family_test.cpp`（合成镜像：完整 / 重定位 / 节头合并正向；架构与节属性；23 组特征逐一在数据节放诱饵仍通过、在代码节放重复即拒绝；23 处调用边改向；字形尾声 / 字体顺序 / 渲染 pass 顺序 / 组渲染原位匹配；19 处槽位与 cookie 变异；跳转表 4 种变异；Luna 外部 detour 与内部 E9），`tests/siglus_ninearg_runtime_test.cpp`（快照正向与重定位、每一次读取失败都不重试、两遍之间标志漂移拒绝、4 个阻断标志、14 种别名 / 尺寸 / 视口变异；owner 链遍历与当前字形归属、向量替换 / 根变化 / 错位 / 步长 / 重叠 / 空字形；九参字形解码边界），`tests/siglus_glyph_abi_test.cpp`（九参 `__stdcall` 栈平衡与 AL 返回、捕获正向与错误调用方 / 结果 0 / 越界 / 非 owner / ABI 不符），`tests/siglus_message_capture_test.cpp`（`TestNineArgProductionObservers`：静默语音键、ESI 绑定保存值、静默布局带脚本槽不武装）。x86 145 / x64 141 项 CTest 全绿，`tools/run_guards.ps1` 全绿。离线镜像：HF 全部站点解析正确，Rewrite+ 为负样本不命中。
- **真机首轮暴露的后续根因与修复**（同一 bug，均为引擎级）：
  1. **静默消息通道吞掉语音**（`35b12d0c28`）：九参一代的消息包装函数不带脚本语音键，但旧门把「消息通道已安装」一律视为「语音归消息通道」，未证明的 OVK 读取被挡在时间配对之外。新增 `IsSiglusMessageVoiceOwned()`，静默通道（`g_siglus_message_silent_voice`）不拥有语音，`QueueSiglusVoice` 与导出 worker 只在拥有语音的通道上拦截。
  2. **逐帧重排让查词按下失效**（`35b12d0c28`）：HF 每帧重排整行字形，worker 常在一遍重排中途切片，旧规则把未完成的尾部当布局变化、作废档案并抬升 epoch，按下一直是 PendingEpoch。`IsSiglusLookupIdenticalRedrawTail` 认定「与上一完整遍逐字形相同的未完成尾部」不改变布局；内容或尺寸不同的尾部仍作废。
  3. **查词交付被持续重排饿死**（`6ad4e9fca8`）：提交检查要求字形生产者静止，逐帧重排下永不静止，查词卡要等数秒。点击事件记下释放时刻的字形序号 `release_glyph_seq`，`CheckSiglusLookupSubmission` 只等这之前的字形处理完。
  4. **语音配不上台词**（`a9f886b46b`）：Siglus 脚本先执行 koe 读 OVK、再提交正文，HF 实测语音比台词早 0–31 ms；host 的无标记 OGG 窗口是早 130–330 ms，多数句子落空。静默通道下 OVK 任务记下本通道线程号与读取时的 `text_write_count`，worker 用 `ResolveFollowingSelectedText` 在 `kSiglusFollowingTextWindowMs`（1500 ms）内取本通道之后提交的第一行，把事件号写进文件名（`fushi_textseq<seq>`），host 按事件号配对；过期则照旧无标记导出。候选取自 hook 自有的消息通道（`CollectLaneCandidates`），不看 host 选中线程。
- **真机证据（2026-11-01，用户本地构建）**：① 正文不含人名 ✅；② 语音：新会话 6 个 OVK 全部带事件号（textseq1/4/5/6/9/16），用户确认逐句有语音 ✅；③ 游戏画面内弹出查词卡、被查词高亮覆盖原字 ✅；④ 鼠标点词不推进 ✅，**触摸（点按 / 卡内后卡外 / 卡上横滑 / 卡外滑动 / 长按）未测**。
- **备注**：触摸门未跑，按「适配成功」定义只能算部分适配，支持状态保持 `implemented_unverified`。
