# 剩余 Siglus 原始路径适配

## Scope

用户在四部验收及 PR #1293 后要求继续剩余游戏，并明确使用 Fushi 已有转区能力。独立 codex/siglus-legacy-adapter 分支基线 4e03a79626；目标为 Rewrite trial 2.00、Angel Beats! trial 1.10、月の彼方で逢いましょう trial，仅 Windows。既有四部验收分支未修改。

## Proved

2026-09-07 23:54:53 原始 Rewrite Start.exe 经 Fushi --japanese-locale 启动为进程 35728；23:54:54 系统错误记录 C0000005、LE 偏移 001b52d0。实际首根因是 BUG-2232 初始化模块链表 sentinel 误作模块，早于 Fushi Hook 注入。已整合源码修复 779ebdcf0e 与真实 x86 ABI 回归。

使用固定官方 LE 源码 ae7160dc5deb97947396abcd784f9b98b6ee38b3、哈希固定 WDK/Libs、微软正式 v140 19.00.24247.2 及 LLVM 22.1.6 完成本地构建。v140 将旧 /GL 库生成为普通 IOBJ，LLVM 最终链接保留 kernel32 真正延迟导入；首阶段 DLL 不使用、不分发。未执行上游修改过的 _Compilers。修补 sentinel 后，自有 CP932 探针和普通 CreateProcessW 子孙进程均正常退出，ACP/OEM 932、User/System LCID 0411。

随后原始路径分别复现系统版本资源语言（BUG-2246）及本地化时区名称（BUG-2247）两道检查。中间运行库 B3D3824A26BE4E6D2D3A3F4367A72B26F060AF41360BD30DDA1933DF2CFCFCF1、自有版本探针 26364 返回 Translation 0411/04b0。修正 Fushi 时区显示字段后，2026-09-08 00:40:38 helper 65888 → 原始 Start.exe 74636 → 官方 StartMenu 50052 → SiglusEngine 70100，00:41:06 起出现 Key 标志及标题菜单。helper SHA-256 为 2CC72C7ADD22709ECE87D1FD5DDB0AA253155253841B1F4EB9B47BFD17F6374B。

Rewrite 原始 Start.exe SHA-256 24B396B22A177F6573C787161099D2B378F5F02FDEAFE2BBED0B5936C798343A；实际 SiglusEngine.exe 1.0.4.0 x86，SHA-256 6E01827E8D9427D0CF5FB4933224865E8CFF22BC78AE8264C15CDD5584F77253。游戏未复制至其他启动目录，未改写游戏、系统区域或安全设置。

最终候选 v5 SHA-256 `8DF7A41BE6AE8C6920CB06C05C60DAEFDA9D330A0212A1CC036DE9B877CA9079` 已通过生产 PE 契约，自有探针 26152 退出 0，ACP/OEM 932、LCID 0411、kernel32 Translation 0411/04b0。手工 SelfShadow 映射与正常 DllMain 映射有明确所有权；VERSION 安装前固定目标模块，失败清理保留仍可达 trampoline。

2026-09-08 01:08:31，私有测试 helper 25012 → 原始 Start.exe 71692 → 官方 StartMenu 64428 → SiglusEngine 46800（01:09:09）。helper 自动发现真实子进程，Fushi Hook LoadLibraryW wait=0、base=6B6B0000；helper ready、IPC v24 可读。helper SHA-256 `112DEDBC0DBF3738DCBC1ECC24C2577F5A5BF1DF499589B0A6C861E15F47F533`，Hook DLL `ECAB5F5BC0AB673314B2127464E45AB86EE4BAC8E229AB804FEEBE576CB7CE71`。组件位于本机 `.codex-test/siglus-engine-adapter/locale-lineage-v5-helper`，没有覆盖已验收 bundle。

载入原游戏存档后，原生 resolver 未匹配，既有 120 秒有界探测正常转为 LunaAllowed，并非永久 pending。Luna 在换句前只见标题；换句后 lane 4181100848359650377、seq 186、UTF-16 36 bytes 与当下旁白一致。仅记录元数据，不保存游戏正文。

本轮 native 完整构建与 CTest x86 87/87、x64 86/86 通过；版本 Hook 断言启用后定向重建双架构再次通过（各 15 组内部检查）。manifest/profile 生成检查、manifest 22、结构 48、workflow 6、PE 21、断言存活守卫 2 均通过。显式生产 workflow replay 退出 0，覆盖资源优先、PCM、显式 loopback、线程过滤、去重与会话清理。

统一私有测试 bundle 后，Fushi 63356 于 01:40:27 经正常 UI 使用 `--japanese-locale --launch <original Start.exe>` 启动 helper 48940；游戏 64432（父进程 13040）于 01:40:28 出现。实际运行组件落于 Fushi 自有 `voice_hook_runtime/9a932157bb92de5c/x86`，helper/Hook/LE 摘要与上述候选一致。01:44:09 推进正文，生产 UI 选中 SiglusEngine VA 482130 的干净线程：lane 3668595790166304498、seq 77、48 UTF-16 bytes，画面与工作台一致。`selected_text_thread_id` 回读匹配，`text_ready` 通过。

构建脚本审查修复 PowerShell location 与 .NET cwd 不同导致相对输出检查错位；统一 FileSystem 路径解析后检查及写入。直接执行生产 AST 函数的 8 条测试通过，含相对/绝对、现存拒绝、括号字面量及非文件系统拒绝，已登记守卫入口。

## 2026-09-08 旧版字形边界

同一 Rewrite 64432 会话的私有有界探针确认 glyph RVA D5290 为栈上 self 加 15 个 DWORD、AL 返回、ret 0x40；正文 caller D6287 的对象步长 0x1E0，坐标 +0x34/+0x38，24 字正文的设计坐标从 (240,560) 到 (930,560)。带姓名的新句区分出 D8042 姓名 caller。字符 +4 的五字样本高 16 位均为零；生产解码仍拒绝非零高位，不把下游截断当作许可。

已整合独立结构 resolver `0ad6b55afe`：唯一代码锚点、调用关系、字符串赋值与向量布局关联，不用固定 RVA/hash 准入。私有 hydrated image 实际解析结果与上述站点一致。它仅输出结构站点，尚未装配完整运行时 profile。

生产 glyph callback 提取为可直接测试的 include，分别声明现代 ECX 加 10 参数与旧版栈 16 参数 ABI；记录解码按 ABI 使用各自字段，浮点先取整和验证范围再转换整数。x86 实际间接调用测试运行 8192 次，检查参数位模式、AL、栈清理以及错误 caller/ABI、关闭采集和无效指针的拒绝。独立复核优化汇编为现代 ret 40、旧版 ret 64（十进制）。新旧记录解码双架构测试通过。

可见性反例已在原路径实测：01:55:22 至 01:55:59 稳定 Save 菜单期间，D6287 计数 470883→481993，后台仍布局正文。Close 隐藏对白后布局计数停止。Log 历史界面则使用同一 D6287 渲染其他位置的历史文字。因此 glyph caller、active 字段和文本匹配均不能独自证明当前正文可点击。只读状态对照及真实输入读写路径分别定位 Save 的 modal+AC、Close 的 hidden+2、Log 的 manager+3C35C；正在将这些状态与输入/viewport 的同一对象关系纳入独立证明。

此阶段完整 Windows native 构建及 CTest x86 90/90、x64 88/88 通过；全套 source-of-truth guards 与显式生产 workflow replay 退出 0。旧版 callback 尚未接入运行时安装，不由这些离线通过升级支持状态。

## 2026-09-08 旧版输入和正文对象整合

独立输入/viewport 结构证明、运行时快照、正文对象关系分别整合为
`3835d7ef6e`、`36a1de2cd0`、`a23e89c589`。正常链为
manager +3C2CC → group +1CC → render owner +154 → entry +100 → glyph；
另一 manager 向量不准入。当前真实内存只读验证通过，正文 14 字范围发生变化后，
旧范围不再冒充当前对象。worker 最多枚举 128 节点、64 路径，回调只对命中路径
作有界活体验证；通过非阻塞 SRW 锁交换元数据，不在回调中扫描整棵对象树。

完整候选将现代两类与旧版三者唯一匹配后才发布不可变 profile。旧版保持
GetKeyboardState 的 BOOL、其余 255 键及左键低位，复用既有按下/保持/抬起事务；
消息保持 ECX=lparam、EDX=wparam、栈 message 的 fastcall ABI。具名 user32
IAT 必须与独立解析的实时导出地址相等，不能仅因导入名称存在就安装。

实时视图双读验证 config→manager、window/input/modal/hidden 别名、窗口所属进程、
主消息 vtable、设计尺寸及引擎实际 viewport。按下、抬起和 worker 提交均复核
owner/viewport。Save、Close、Log、auxiliary 的必要拒绝条件接入，独立审查另发现
渲染循环的对象 +1FB 禁止位，结构输出补丁 `2769bf9239` 后也纳入拒绝门。
未把这些必要条件写成对所有 IME/script 状态的完整语义证明。

新增实际输入 ABI、API 调用次数、低位保持、视口偏移/拉伸/裁剪/溢出、
待提交期间视图失效及 owner 更换测试。整合阶段完整 Windows 构建、
CTest x86 94/94、x64 91/91、manifest/profile 检查、结构 48、manifest 22、
workflow 6 和显式生产 replay 全部退出 0。额外 +1FB 拒绝门另做双架构重建
与定向复验。尚未以这批离线结果升级支持状态。

02:34 原 Rewrite 会话保存至此前空白的 004；诊断探针确认 state=stopped，
随后经游戏菜单正常退出，旧 Fushi 捕获停止并正常关闭。下一会话必须加载新
隔离运行时，从原始 Start.exe 经 Fushi 转区启动，不能复用仍有诊断 trampoline
的旧游戏进程。

整合提交 `f396a85f7f` 的 x86 Hook SHA-256 为
`661BE2717B47519CAB7C49F50B693F5FDFB2BD89A5505BCF494F6D0CC7AE319C`；
已替换本地私有测试 bundle 的 DLL，旧 DLL 单独保留。测试 Fushi 57108 于
02:44:33 从同一私有 bundle 启动，helper 与 LE v5 摘要保持上述值。
Windows 防火墙权限弹窗阻挡界面，已请用户手动处理，未操作系统安全控件。
新候选的原始游戏启动和内嵌点击尚未执行，不能视作 runtime 通过。

## 2026-09-08 正文点击和弹窗生命周期

BUG-2250 已由 `b7ff46a75c` 修复：Siglus 身份探测期间为旧版专用键盘采样
保留 GetKeyboardState 安装位，避免提前安装的通用 Hook 被误认作引擎专用
sensor。生产安装函数的直接测试为 `6415fdff1b`。新会话已观察 required/ready
均为 E4，实际正文点击被隔离且没有推进台词。

用户随后报告点击后词典瞬间关闭。旧 PID 51284 的消费日志确认 showAt 后
约 112 ms 被 provider 失效关闭；独立读取显示对象和视图完全稳定。BUG-2251
根因为 worker 对相同元数据重复申请独占锁，被渲染共享锁挡住后误撤销 provider。
修正仅省去 fresh 且相同快照的写入，改变或无效的快照继续失败关闭。

新 Hook SHA-256 `C38766F11E53DABB35D53A2489112108F5307B3D97A1A98B5017A7C2B0CFAFFB`。
03:35:59 helper 74712 经原始 Start.exe/官方 StartMenu 59936 启动游戏 48540
（03:36:21）；实际 DLL 位于自有 runtime/e2465ea69e98ba8c/x86，加载摘要一致。
Fushi 69880 在游戏出现前于 03:36:00 崩溃，属于 BUG-2231 无障碍字符串属性
读取的新复现。恢复 Fushi 57060（03:38:33），经正常 UI 附着当前游戏，
选中 SiglusEngine VA 482130 线程后进行本轮点击验证。不能把恢复附着流程
描述成启动全程无中断通过。

原始正文中的两个词连续查询均有稳定词典且未推进台词。独立 1000 次读取
（15.312 秒）owner/view 全部有效、无变化，provider 2/3 status 2 保持稳定，
变化次数 0，hitseq 1 未被清除。Save 菜单、Log 历史和 Close 隐藏对白均使
geometry 归零；Save 返回后第三次点击恢复词典，仍是同一句、generation
239/20→239/21。Close 后点击原正文位置只恢复对白，没有误提交旧 hit。
随后正常 Return 换句，第四次点击对应新句且词典保持显示，source length
33→18、generation 872/30，确认没有复用上一句的文本和布局。

真实 SRW 争用测试 `473a766403` 已纳入 CTest；完整 Windows native 构建及
CTest x86 96/96、x64 92/92 通过，结构 49/49、manifest/profile 检查、
生产 workflow replay 退出 0。独立审查确认相同快照比较覆盖全部身份字段，
唯一 worker 写入及回调 live 校验保持不变。

BUG-2249 启动记录角色/转区回退修复已整合为 `8fa25b18a2`，定向测试 86/86
及定向分析通过；当前运行 Fushi/helper 尚未部署该修复，不能算运行时验收。

## 2026-09-08 用户制卡反馈与窗口比例回归

用户反馈 Rewrite 制卡没有明显问题，记录为用户已验证制卡交互；该反馈不替代
旧版逐句原音来源、配对和资源哈希的证据。当前进度经正常 Save 界面保存到
此前空白的 006（游戏显示保存时间 12:11），未覆盖已有 001–005。

同一 PID 48540、同一已加载 Hook 下，通过 Config 的显示详细设置由 100%
切为 75%，返回原句后点击正文没有产生新 hit，provider 2/3 status 1、
generation 0/0，且游戏没有推进。恢复原来的 100% 并返回同句后，同一词
立即出现词典：hit 10、char index 11/count 26、generation 1214/103，
provider 2/3 status 2。后续只读检查确认，失败点击其实已进入 native click ring，
char 11 投影为 [428,420,22,23]、client 960×540；ReadSnapshot、owner、render
和设计尺寸检查均通过。稳定正文仍会发生 partial capture epoch 变化，但尚无
该点击终结时的具体原因证据，不能据此删除 epoch 校验。

再次在 75% 同句单击成功，hit 11、generation 1214/104、view 960×540、
char 11/count 26，词典正常保持。因此确认缩放映射可用，另有偶发点击在
worker 提交前丢弃；不认定为 75% 独有问题。窗口已恢复用户原来的 100%。

本 worktree 完成 bootstrap 后 Windows Release 主程序构建退出 0（426.6 秒）；
尚未将该程序替换到运行会话，也未据此认定启动角色修复已通过运行验证。

## 2026-09-08 启动菜单等待分阶段验证

BUG-2252 已整合为 `ef7a284c75`：结构识别的官方启动器在其已验证进程链
存活期间等待用户选择；确认真实游戏后单独启动注入握手时限。迟到或重复的
启动记录不允许将已确认游戏身份降回菜单，也不能反复重置握手时间。
关闭整个菜单进程链、发现失败、helper 退出和输出结束各自明确终止等待。

188 项 Dart 定向测试、完整 Flutter analyze、Windows Release 构建均退出 0。
整合后的 native 完整构建及 CTest x86 97/97、x64 93/93 通过；manifest 22、
结构 49、workflow 6、manifest/profile 生成检查与生产 workflow replay 退出 0。
这些是自动化证据，菜单停留超过 30 秒再启动及关闭菜单的实际 UI 验收尚未完成。

Rewrite 48540 从上述 006 同句经 Quit/Yes 正常结束，进程退出已确认。
准备好的私有 v6 测试包尚未启动；旧 Fushi 57060 仍运行且最小化，恢复窗口
被工具的手动输入保护连续中断，已请用户恢复窗口。未强制终止应用或改写存档。

## Not proved

原始启动、自动跟随、注入和选定正文线程已有运行证据；当前候选恢复附着后的正文几何、查词停留、100%/75% 映射和菜单拒绝已通过上述范围。偶发点击提交丢弃、完整无中断重启及更多对象变化仍需验证。resource/pcm_ready、paired、e2e_verified 尚未通过；旧版原音 adapter 尚未实现，已有 loopback 不能当作原音捕获。Angel Beats! 与月彼本轮尚未运行。未升级 engine-support.yaml，未更新既有 PR 或正式随包运行库。

源码准备及正式工具构建脚本已维护，最终候选重建与 PE 契约自动校验均通过。上游仍含预编译 MyLib；当前源码补丁和依赖说明不宣称其完整对应源码，也不宣称已满足修改 DLL 的正式分发条件。

## Next gate

从原始入口加载带有界 worker 拒绝诊断的新候选，复验启动链并记录偶发点击
的实际终结原因；只据该原因修复当前正文边界，后续原音与真卡保持未验收。
