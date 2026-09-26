## BUG-2712 · Siglus（CLANNAD）选项画面查词查到上一句、没有查词框、全屏看不到弹窗
- **报告**：2026-09-26（用户：冷盈閑酔，群内录屏；CLANNAD Steam 版 + 日语补丁）
- **真实性**：✅ 真 bug（前两项）；第三项「全屏看不到弹窗」本机未复现，见备注。
  - **选项查到上一句**：CLANNAD 走 Siglus 十参数字形布局家族。同一个字形入口
    `0x1db450` 有四个调用者，适配器只收台词调用点
    （`native/galgame_hook/hook/adapters/siglus_lookup_glyph.inc` 的返回地址过滤），
    选项字形被静默丢弃；而查词命中表只在「新文本快照到达」时失效
    （`siglus_lookup_worker.inc` 的 `ConsumeSiglusLookupCaptures`），选项出现不产生新文本，
    上一句的字形矩形一直有效。选项恰好排在上一句占用的消息框行上，于是光标在「助」
    （选项第 1 字）上查出上一句第 1 字起的「こいつら」。
  - **真机取证**（Frida 挂 `0x1db450`，读档 0062 停在该选项）：台词调用点返回 `0x1dd010`、
    名字框 `0x1dfa45`、选项 `0x1e1abe`。选项上屏后台词调用点**完全停止**布局，选项调用点
    每渲染帧重放一整遍、顺序恒定（5.1 万帧全是同一遍 10 个字形「助ける／腕を振りほどく」，
    两行 y=788 / 834）；台词显示期间选项调用点从不出现。另：Siglus 只在有动画时重布局，
    静止画面可以几十秒不调用——所以「停画即失效」不可行，只能按调用点身份切换。
  - **没有查词框**：Siglus 适配器从未调用 `RequestLookupHoverHighlight` /
    `ReadLookupTermHighlight`（SGRE 的 BUG-2086 / BUG-2087 那套），所有台词都没有悬停框
    和被查词框，不只选项。
- **[x] ① 已修复** —
  - LunaScenario 家族 profile 新增可选的选项调用点签名 `kSelectionCall`
    （`siglus_autoprofile.h`，唯一且 `call` 到字形入口才采用，否则为 0、行为不变），
    exact 结构校验与锚点比较同步覆盖该字段。
  - 字形事件带种类（台词 / 失效 / 选项，`siglus_lookup_worker_types.inc`）；
    `CaptureSiglusLookupGlyph` 只多放行这一个已证明的选项调用点，名字框等其余调用者仍拒绝。
  - worker 选项模式（`siglus_lookup_worker.inc`）：选项字形到来即退役上一句的几何 / 点击目标 /
    provider；用 `SiglusSelectionPassBuilder`（`siglus_selection_line.h`，首字形重现即一遍结束，
    换行处插 LF）从字形本身拼出选项行作为 active line，复用同一套几何与提交校验；
    台词调用点重新布局或新台词到达时切回，同文重发不切。选项命中沿用当前台词的
    text identity（与 SGRE 剧情+UI 合并行同一先例），制卡绑定到选项前那句台词，不编造序号。
  - 查词框：tick 里仿 SGRE 用 RAII 默认清框；无卡片时画光标下字格，卡片可见时画宿主给的
    被查词区间（同一行字格并集）。被查词框只在当前布局代数等于最近一次被宿主接受的命中代数时画。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/siglus_lookup_worker_test.cpp`
  （`TestSelectionPassBuilderSplitsRowsAndBoundsPasses` / `TestChoiceRetiresDisplacedDialogueAndBecomesTheLine` /
  `TestDialogueRedrawEndsChoice` / `TestNewDialogueEndsChoiceButRepublishedBodyDoesNot`，含查词框几何）、
  `tests/siglus_glyph_abi_test.cpp`（选项调用点准入与拒绝面）、`tests/siglus_autoprofile_test.cpp`
  （选项签名可选 / 未链接 / 歧义）、`tests/adapter_structure_test.py`（新台词结束选项模式的顺序守卫）。
- **真机验证**（2026-09-26，本机 CLANNAD Steam `SiglusEngine_Steam.exe` SHA-256 `116A1B6A…DEA2D`，
  x86；真机驱动 itest `gal_realgame_driver_itest.dart` 附着，游戏内驻留 hook DLL SHA-256
  `9E168579…ABB7` = 本分支 `native/galgame_hook/dist/voice_hook_x86.zip` 内同名文件；读档停在该选项）：
  - 台词「こいつら、しつこいんだ」：悬停框落在光标下的「し」，Shift 查出「しつこい」、被查词框框住「しつこい」。
  - 选项画面：悬停框落在选项的「助」上；Shift 查出「助ける」（修复前是「こいつら」），
    第二行查出「ほどく」（跨 LF 的字序号正确），被查词框随之框住。
  - 选完「助ける」进入下一句「てめぇら、うるせぇぞ」：悬停框立即落在新台词上，Shift 查出「うるせぇ」——
    选项模式已退出。
  - 窗口化与无边框全屏各测一遍，结果相同；共享内存探针 `fushi_voice_lookup_probe --no-enable`
    看到每次查词 `hits` +1、命中行为「助ける⏎腕を振りほどく」。
  - 为选选项临时备份了 `savedata_zh/`，验证后逐文件还原（`diff -rq` 一致）。
- **备注**：
  - 全屏看不到弹窗：本机 CLANNAD 全屏是无边框窗口（样式 `0x96000000`，非独占），
    `D3DKMTQueryVidPnExclusiveOwnership` 对它返回 UNOWNED、系统级检查为 0，runner 的
    桌面叠加可用性各项事实全部成立；实测全屏下弹卡正常显示在游戏之上、查词框也在。
    测试中出现过「关卡后第一次 Shift 不弹」，查实是驱动 `shiftmove` 先按 Shift 再挪光标——
    Siglus 只在 Shift 按下那一刻取样，那时光标还在卡片的 × 上；真实操作（先指字再按 Shift）不受影响。
    若报告者机器上 D3D9 全屏确为独占，桌面窗口本就无法覆盖（Siglus 没有 KiriKiri 那样的进程内
    呈现器），需要报告者的 Fushi 日志再定；他说的「看不到框」也可能就是本条修掉的查词框缺失。
  - 单击查词开着时，点在选项**文字**上会查词而不是选择（与正文「点字不推进」一致）；
    鼠标选择请点该行文字以外的区域，或用键盘。
