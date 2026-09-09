# 剩余 Siglus 原始路径适配

## Scope

用户在四部验收及 PR #1293 后要求继续剩余游戏，并明确使用 Fushi 已有转区能力。独立 codex/siglus-legacy-adapter 分支基线 4e03a79626；目标为 Rewrite trial 2.00、Angel Beats! trial 1.10、月の彼方で逢いましょう trial，仅 Windows。既有四部验收分支未修改。

## Proved

2026-09-07 23:54:53 原始 Rewrite Start.exe 经 Fushi --japanese-locale 启动为进程 35728；23:54:54 系统错误记录 C0000005、LE 偏移 001b52d0。实际首根因是 BUG-2338 初始化模块链表 sentinel 误作模块，早于 Fushi Hook 注入。已整合源码修复 779ebdcf0e 与真实 x86 ABI 回归。

使用固定官方 LE 源码 ae7160dc5deb97947396abcd784f9b98b6ee38b3、哈希固定 WDK/Libs、微软正式 v140 19.00.24247.2 及 LLVM 22.1.6 完成本地构建。v140 将旧 /GL 库生成为普通 IOBJ，LLVM 最终链接保留 kernel32 真正延迟导入；首阶段 DLL 不使用、不分发。未执行上游修改过的 _Compilers。修补 sentinel 后，自有 CP932 探针和普通 CreateProcessW 子孙进程均正常退出，ACP/OEM 932、User/System LCID 0411。

随后原始路径分别复现系统版本资源语言（BUG-2352）及本地化时区名称（BUG-2353）两道检查。中间运行库 B3D3824A26BE4E6D2D3A3F4367A72B26F060AF41360BD30DDA1933DF2CFCFCF1、自有版本探针 26364 返回 Translation 0411/04b0。修正 Fushi 时区显示字段后，2026-09-08 00:40:38 helper 65888 → 原始 Start.exe 74636 → 官方 StartMenu 50052 → SiglusEngine 70100，00:41:06 起出现 Key 标志及标题菜单。helper SHA-256 为 2CC72C7ADD22709ECE87D1FD5DDB0AA253155253841B1F4EB9B47BFD17F6374B。

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

BUG-2356 已由 `b7ff46a75c` 修复：Siglus 身份探测期间为旧版专用键盘采样
保留 GetKeyboardState 安装位，避免提前安装的通用 Hook 被误认作引擎专用
sensor。生产安装函数的直接测试为 `6415fdff1b`。新会话已观察 required/ready
均为 E4，实际正文点击被隔离且没有推进台词。

用户随后报告点击后词典瞬间关闭。旧 PID 51284 的消费日志确认 showAt 后
约 112 ms 被 provider 失效关闭；独立读取显示对象和视图完全稳定。BUG-2357
根因为 worker 对相同元数据重复申请独占锁，被渲染共享锁挡住后误撤销 provider。
修正仅省去 fresh 且相同快照的写入，改变或无效的快照继续失败关闭。

新 Hook SHA-256 `C38766F11E53DABB35D53A2489112108F5307B3D97A1A98B5017A7C2B0CFAFFB`。
03:35:59 helper 74712 经原始 Start.exe/官方 StartMenu 59936 启动游戏 48540
（03:36:21）；实际 DLL 位于自有 runtime/e2465ea69e98ba8c/x86，加载摘要一致。
Fushi 69880 在游戏出现前于 03:36:00 崩溃，属于 BUG-2337 无障碍字符串属性
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

BUG-2355 启动记录角色/转区回退修复已整合为 `8fa25b18a2`，定向测试 86/86
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

BUG-2358 已整合为 `ef7a284c75`：结构识别的官方启动器在其已验证进程链
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

BUG-2359 诊断提交 `6581c41cbe` 在 worker 终结提交时保留最近 8 条纯元数据，
区分 epoch、generation、文本身份、视图/窗口、重复和 registry 拒绝；不修改
既有拒绝条件，也不把历史丢弃原因写成已证明。整合后完整双架构构建及
CTest x86 97/97、x64 93/93、结构检查 49/49 再次退出 0。正式生产 worker
定向用例包含 20 个场景及 12 类拒绝变体。bug check 在仓库根执行退出 0；
跨源报告的是既有分支编号冲突，本次新增 BUG-2358/2253 未出现冲突。

私有 v6 已装入上述新程序/helper/Hook，并逐文件比对构建源 SHA-256。
x86 Hook 为 `E1E5616F5B4D248242A3A005EB604505089D2FD76E3797E246D9F12428B0FE4A`，
x64 Hook 为 `D2ED6216091572B68C462A85BEFD65BB7BC58607B76C8D49CBF58BB99DEE741E`。
本地组件清单保存在未入库的 `legacy-fushi-v6-prepared.json`；尚未加载到真实游戏。

## 2026-09-08 v6 原始启动与首次点击

用户恢复窗口后，旧 Fushi 57060 经停止监听及窗口关闭正常退出，新 v6
Fushi 70100 于 12:48:59 启动。正常工作台选择原始 Start.exe 后，helper 44680
于 12:50:45.998 启动，命令含 `--japanese-locale --wait-ms 30000`；Start 49544
产生官方 StartMenu 29592（12:50:46.250）。菜单停留约 86 秒后正常点击窗口
模式，真实游戏 6464 于 12:52:12.106 出现，父 PID 为 29592。

新游戏实际加载 runtime/737a12a4912b6ba8/x86 的 Hook，与上述 E1E5616F…
完整 SHA-256 相同；helper SHA-256 为
`12AD80AF810055EA3237BF64BC1D9EFCF7E1779C48E8624FFA9C5EF99C18FE5C`。
IPC v24、required/ready E4，Fushi 自动绑定真实游戏窗口 32309600，并进入
等待台词线程状态。006 正常读取后选择 0x482130 的正文线程（显示 #e990），
当前正文事件 85 到达。此轮长菜单等待、自动跟随和握手未超时，宿主未重启；
关闭菜单结束等待的负向 UI 用例仍未执行。

12:55:14 左右首次点击 100% 正文的字符位置时，游戏直接推进下一句，没有
词典弹窗。随后只读新诊断环 count=0，尚无 worker 终结记录；仅凭零记录
不能排除等待中的提交，也不能认定先前 BUG-2359 的具体拒绝原因。
后续宿主日志确认 nativeInputAllowed=true、request/applied=5/5，但并不证明
点击瞬间同样满足全部条件。当前停在下一句，先检查按下时的目标/身份/准入，
不把这次输入泄漏归入已解决的弹窗消失问题。

## 2026-09-08 同会话点击分支与倍率复核

首次失败之后、第二次操作之前，13:00:28 的只读元数据确认 click ring 的
发布与消费计数均为 0，排除该次点击已排队等待 worker 的解释。该时刻的
采样已同步、owner Idle、目标有效且布局完整，只能说明检查时健康，不能
还原首次按下瞬间的拒绝原因。准入 request/applied=5/5；第二次成功之后
通用 shield observed_mask 仍为 0，因此该字段不代表 Siglus poller 未运行。

13:01:33 短句点击成功，worker 记录 1 为 Published，event 175、generation
16、epoch 383 均一致。重读原有 006 后，13:08:08 和 13:08:36 对同一正文
字符的两次点击均成功，记录 2/3 的 event 1445、generation 29 不变，epoch
分别 493/547；两次关闭词典均没有推进剧情。13:13:39 经原生设置切到 75%
后的点击也成功，记录 4 的 event 1445、generation 30、epoch 665 一致，
glyph frontier 与消费数均为 971531。证据存于本机 rewrite6464-click2.json
至 rewrite6464-click5-75pct.json；未提交截图或游戏内容。

配置操作中 Fushi Hook Text 的透明区域遮挡部分菜单按钮，暂经其自身关闭
按钮收起后操作；测试结束恢复 100% 与浮动字幕。同一存档仍保留，未新建或
覆盖存档。这些成功样本不抵消首次输入泄漏；需增加按下边沿的私有有界诊断，
覆盖 worker 入队之前的目标、视图和准入拒绝，保持所有现有接管条件。

## 2026-09-08 既有语音导出的只读核对

本轮 006 读取产生的现有导出已与原安装归档核对：z1002.ovk 的 member 294
位于 table index 24、offset 1296701、length 114040、sample_count 158790。
导出同为 114040 字节，与唯一源条目 SHA-256 相同：
`f2b1cea1cf76546daee38d895cad808992da9d96ec3d914fa143c917e7eeee72`。
主代理用本机 verify-rewrite6464-resource.py 独立复核，退出 0；仅读取索引、
目标条目和现有导出，没有复制或提交游戏载荷。这证明该导出字节来自原资源，
不证明它与当前正文存在稳定事件绑定。

现有 legacy ReadFile 路径在 siglus_adapter.inc 的 QueueSiglusVoice 中令
text_event_id=0；siglus_message_capture.inc 明确拒绝旧版 glyph ABI。姓名事件
1443 与正文事件 1445 在工作台显示同一 OGG，消费端对这种没有事件标记的资源
仍走时间匹配。不能用 UI 的音频就绪、原资源哈希一致或用户制卡反馈替代
原生语音所属台词事件的证据；该缺口在点击边界完成后处理。

## 2026-09-08 按下与释放诊断候选

`b82251abee` 接入按下准入与已接管但未入队的释放诊断；仅写私有 8 × 160 字节
标量环，不改变游戏输入接管、目标验证短路或游戏视图读取次数。独立复审无阻塞问题。
新 epoch 的首次持续按住也记一次，读端不能把每条记录解释为新的物理按下。

整合后 x86/x64 Release 构建退出 0，CTest 分别 98/98、94/94；manifest 22、
结构 49、workflow 6 个检查全部通过，两项生成检查与生产 workflow replay 退出 0。
真实生产 include 的定向测试覆盖 65 个按下拒绝、9 个释放拒绝、TLS 生命周期与
线程隔离，以及实际 ReadProcessMemory 并发读者对半发布记录的拒绝。

本机 v7 候选沿用 v6 Fushi 主程序，仅替换构建后的 native 文件。x86 Hook SHA-256
为 `bc9238afee6d78864a835bdb3dc5f39e9fd1473ea7fda700adddcd106f9d0598`，
x64 为 `e95b9b427c94ea178f1150af86f6061931e21f2da8efab47214d7a34f7927fed`。
私有读端经四组模拟环检查通过，并在 x86 最终 DLL 与 COFF 唯一匹配诊断函数；
该查词实现受 `_M_IX86` 限定，x64 无此符号，读端明确拒绝定位，不伪造运行结果。
旧游戏与 v6 已正常退出。v7 Fushi PID 66124 在本机 13:34:26 启动，尚未启动游戏；
系统网络权限弹窗目前挡住操作，工具没有暴露该弹窗的可操作窗口。未升级支持状态。

## 2026-09-08 v7 原始启动与设备丢失中断

系统弹窗处理后，v7 Fushi PID 66124 从原始 Start.exe 启动；helper PID 74712
于本机 14:21:24 出现，Start PID 25732 → StartMenu PID 32080 → 游戏 PID 72620。
游戏于 14:22:26 从官方窗口模式入口创建，实际载入运行库目录
`voice_hook_runtime/4cfc2b8f770965ac/x86`，Hook SHA-256 与上述 v7 候选一致。
只读诊断函数匹配、加载模块身份检查和环读取均通过。

本轮窗口截图尺寸曾由 1924×1122 变为 2564×1494，工具缓存坐标因此失效两次；
均重新观察后才输入。读取保留的 006 存档、确认前后，游戏显示未响应，Fushi
仍运行但尚在首次正文线程选择弹层。未完成本轮受控正文查词、配对或制卡。

只读线程栈和有限标量现场显示，游戏主线程随后持续执行自身 RVA 0x9eb90
附近的设备恢复循环（Sleep(100) 后检查 RVA 0x16e5d0）。该检查调用设备
vtable +0x40 的 Reset，实际地址归属系统 d3d9 模块；代码对 HRESULT
0x88760868 置 device-lost 标志，现场对应两个标量为 1/0。当前呈现参数仍是
1280×720、Windowed=1。这里证明设备恢复边界卡住，不能仅凭窗口尺寸变化
推断其触发原因，也不能归因为新增 Hook 诊断。没有修改游戏内存或设置。

首次非侵入调试读取受在线符号超时影响，中止后显式恢复其留下的一层线程
挂起；后续均使用本地符号与不挂起模式读取并正常脱离，CPU 持续增加，仍未
响应。原先的窗口未响应出现在调试器介入之前。私有诊断、栈与元数据只存本机，
不提交游戏载荷。工具重选窗口后的 activate_window 再次超时，需先结束该
游戏会话再从原入口重跑；保留 006 存档，没有覆盖存档或升级支持状态。

后续同一 PID 在本机 14:34 左右又产生新台词，正文选择弹层也已关闭，因此这次
是间歇性恢复，不能把先前的设备恢复栈外推成整个时段持续卡在同一位置。再次检查
窗口仍未响应；正常 Alt+F4 也由工具超时结束，没有强制终止游戏。当前工作台选择
的是合并历史线程，并非先前验收的正文线程，不能用这轮 UI 内容替代受控查词证据。

## 2026-09-08 v8 零前缀 reserved 缺口候选

代码提交 `3b1b456259` 将尚未消费新字形的传输缺口与语义布局失效分开。
独立审查无阻塞；旧生产 worker 在新增排程上退出 91，修后 worker 双架构
各 25 组（15 个 gap 场景、12 类既有拒绝）通过，snapshot 定向通过。
整合后的 x86/x64 Release 全构建退出 0，CTest 分别 98/98、94/94，
manifest 22、结构 49、workflow 6、两项生成检查和生产 replay 全部通过。
BUG check 退出 0，84 个已有跨分支编号警告，没有新增 BUG-2359 撞号。

本机候选为 `.codex-test/siglus-engine-adapter/legacy-fushi-v8/fushi.exe`，
主程序与 v7 相同，仅更新 native 构建产物。x86 Hook SHA-256 为
`039e7fe5663fdb65ebcafa7ca8deb1f11020611044f9a410566bff73cc2e615a`，
x64 为 `3e306656a5e64d68c6959ddeda7ee8e0bb852c4e5a17e0c76af347c2d0d9232b`。
详细文件身份在本机 legacy-v8-prepared.json；没有热替换旧进程内的 DLL。
旧 Rewrite PID 72620 仍未响应，正常关闭操作超时，v8 尚未注入或实机验证。
完整离线门不代表历史首次按下泄漏、已知 partial 重绘或原音配对已解决。

继续运行时，旧游戏虽短暂报告 Responding=true，重选窗口后的两次前台激活仍超时。
核对原始镜像路径和启动时间后，结束本轮游戏 PID 72620；v7 Fushi PID 66124
随后通过 Alt+F4 正常退出。006 已保存文件保留，未保存的会话进度不作保留声明。
新路径 v8 宿主 PID 43668 产生不可控的 Windows PickerHost 权限弹窗，结束该
宿主后，确认没有游戏及旧宿主实例，再把 v8 两架构 native 文件复制到既有 v7
测试目录。该目录名称自此不能代表 native 版本：当前 x86 候选必须以上述
`039e7fe5…cc2e615a` 哈希识别，历史 v7 的 prepared 记录仅表示当时文件身份。

复用既有路径的 Fushi PID 24428 于本机 15:01:37 启动，仍弹出网络权限提示。
工具枚举到 PickerHost 进程但 windows 为空，点击实际返回“not target window”。
用户已授权操作此类弹窗，本次需要人工操作是工具缺少目标句柄，而非再次索取
授权。已请求用户点击允许；此刻没有启动或注入新游戏。完整本机记录位于
legacy-v8-host-restart.json，v8 原目录也保留同哈希候选。

## 2026-09-08 v8 原始路径受控复测

权限提示消失后，Fushi PID 24428 从原始 Start.exe 经 CP932 启动，
helper PID 55192 与 StartMenu PID 41152 于 15:15:05 出现；官方窗口模式
入口于 15:15:41 创建游戏 PID 72288。实际 helper/DLL 位于
`voice_hook_runtime/efbbac4577dd09f4/x86`，加载 Hook SHA-256 为
`039e7fe5663fdb65ebcafa7ca8deb1f11020611044f9a410566bff73cc2e615a`，
与 v8 构建一致。宿主仍在旧 v7 目录，不以目录名判断 native 版本。

读取保留的 006 存档后，选择实时正文 `SiglusEngine / 0x482130 / #7978`。
四次受控单击均显示对应词典并停留，外部单击关闭弹窗没有推进台词：

| 查词队列 | 游戏尺寸 | 正文 event/current | generation/current | epoch/current | worker 终结 |
| --- | --- | --- | --- | --- | --- |
| 1 | 100% | 154/154 | 15/15 | 136/136 | Published |
| 2 | 100% 同字重复 | 154/154 | 15/15 | 300/300 | Published |
| 3 | 75% 同字 | 154/154 | 16/16 | 380/380 | Published |
| 4 | 恢复 100%，推进后短句 | 1571/1571 | 19/19 | 522/522 | Published |

这是游戏内部 100%/75% 尺寸，系统缩放仍是 200%。恢复尺寸后的 Return
激活了鼠标悬停的 Memory 菜单，退出菜单后改用场景空白单击完成正常换句；
不把该次 Return 计为换句验证。四条只读环记录均稳定，正文和字形前沿已消费完。
该运行覆盖长句、重复、尺寸往返和新短句，但不证明历史所有点击、真实零前缀
缺口触发或已知 partial 重绘问题已全部解决。

继续正常推进至角色语音句，15:29:48 工作台姓名 event 1664 与正文 event 1665
同时显示同一资源。新导出为 OVK member 296，表项 25、偏移 1410741、
长度 104782 字节、sample_count 147888；只读核对与源表项逐字节哈希相同：
`846da8546da5f73c50eba43e7051c52613c92f820efdfc1fd2577c41c78796b8`。
本机证据为 rewrite72288-identity.json、rewrite72288-click4-short-worker.json
和 rewrite72288-resource296-hash.json。仍未取得稳定事件配对；姓名与正文
共享导出再次展示现有时间匹配的边界，不按 UI 音频就绪升级支持声明。

## 2026-09-08 legacy 消息与资源因果边界

同一原始路径 PID 72288 内，有限断点只输出寄存器、地址及编号，不读取或提交
游戏台词与音频载荷。原先保留的映像与当前相关代码段只读比较一致。消息外层
先接收旧版 28 字节字符串，内层在同一线程以 `ESP=S-0x68`、`ECX=S+4`、
`EDI=owner` 交接；EBX/EBP 分别等于外层的两个位置参数，ESI 为零。无声句的
脚本 voice key/second 均为 UINT32_MAX；新的有声句先发出 voice request，
再交接相同 key 的正文，最后写入 owner。不能在内层要求旧 owner 已等于新 key。

独立资源链动态观察到同一 key 经 Play/Resource 按 100000 拆成 archive/member，
命中 16 字节 OVK 表项并传入 OggOpen。OggOpen 的 EDI/EBP 是偏移/长度，
EBP 不是帧指针；两个 key 副本、member、reader、路径值对象地址和两个返回地址
均与独立静态调用关系相符。这证明引擎中的因果关系，尚未证明新 native IPC 配对。
本次源 member 312：表项 26、偏移 1515523、长度 84444、sample_count 115478；
既有原资源捕获与源表项 SHA-256 一致：
`b8e2e007ace860b4a5d4ee96d812e21d9906415ac7082cdd67653d3fd745f71b`。

所有断点会话均正常脱离并继续游戏。最后一次脚本的条件表达式最初被 CDB 拒绝，
当场修正后取得内层证据并 `qd` 退出 0；没有把报错前停在别的调用点当作成功。
重启验证前已在空白 007 槽保存当前进度，006 保留。元数据日志仅留在本机测试目录。

## 2026-09-08 v9 旧版原生消息与资源接入离线门

旧版消息与资源纯契约分别由 `6f726e8214`、`2963e8a29b` 接入。
消息安装先要求独立的 legacy 资源结构证明，保留未匹配家族的原捕获路径；
两个消息 Hook 全部就绪后才发布正文事件，资源 Hook 单独就绪后才允许稳定
voice key 绑定。回调只冻结有界值，文件身份、OVK 表项校验与 IPC 配对复用 worker。
未增加文本/时间 latest fallback，未修改消费端 IPC 契约。

生产 observer 测试覆盖 28 字节 proxy 描述、旧 owner 与当前 key 不同、静默句、
同栈重复、跨线程和坏载荷。生产 naked source 测试在真实测试栈构造 FPO 调用，
校验 EDI 偏移/EBP 长度、原寄存器、flags、LastError、ret 12 栈平衡与队列发布。
x86 两项直接运行分别 3216/246 checks 退出 0（并发队列检查数受排程影响）。
资源纯测试双架构各 857 checks 退出 0。首轮整合构建发现测试参数 `small` 与
Windows SDK 宏冲突，改为 `use_inline` 后 x86/x64 Release 全构建均退出 0，
完整 CTest 分别 101/101、97/97 通过。manifest 22、结构 49、workflow 6、
两项生成检查与生产 replay 均退出 0。新生产路径尚需原始启动验证。

## 2026-09-08 v9 原始路径失败与 v10 准入修正

v9 从原始 CP932 启动器再次创建游戏 PID 47716，实际加载 Hook SHA-256
`42acabd23ebbfaee484ce111ca97e0ce6a5bc88455e7b7c9a75fa21040ffc250`。
消息 profile 已解析出完整的外层、正文、语音入口与脚本槽，但安装状态为 -1，
实际 IPC 只有 Luna 的姓名/正文线程，没有原生 `SiglusEngine message`。
本机有界只读检查通过当前 DLL 与 COFF 函数匹配定位，只读状态及 profile 元数据；
不能将完整 profile 解析成功当作安装通过。

根因是两个 legacy live 函数误加了新版 Ogg 的 `0x55` 首字节检查，而已证明的
旧版 Ogg 入口是 `83 EC 20` 的 FPO 序言。删除这两项冗余检查，仍由完整旧版
资源签名、唯一入口及 vtable/callgraph 关系拒绝被改写的 Ogg；保留正文入口
`0x6a` 门以拒绝已被 Luna 占用的入口。新版家族的校验保持原样。
两项生产 live 函数集中到 `siglus_legacy_live_admission.h`，测试直接调用同一实现。

新增回归只替换加载映像入口，真实运行完整消息/资源解析器与 live 函数：
原函数在 x86/x64 各自的 source/message 正例均退出 91；修正后每架构 315
checks 退出 0，覆盖完整旧版入口、重定位、外部跳转和破坏资源关系的拒绝。
该测试不代替真实 PE 映射、Hook 安装和回调运行的验证。整合后两架构 Release
全构建退出 0，完整 CTest 为 x86 102/102、x64 98/98 通过；manifest 22、结构 49、
workflow 6、两项生成检查和生产 replay 均退出 0。

v9 游戏已正常退出，进度保留于 007。v10 测试宿主 PID 73400 于 16:26:19 启动；
私有候选 x86 Hook SHA-256 为
`3c2bf4d52269231920744dca3f162e2646010ba48549b880591abeb308e5d71b`。
窗口工具在重新枚举并重新选择宿主后仍两次报
`foreground window did not report a process id`，无法读取/操作页面，已请用户将
Fushi 切到前台以恢复窗口操作。尚未创建 v10 游戏会话，不能记录 runtime 或 paired。

## 2026-09-08 用户验收 Rewrite 后转入其余样本

用户再次确认手动制卡通过，要求停止本轮 Rewrite 测试并继续其他游戏。
随后可见 Fushi 原生 `SiglusEngine message` 线程、278 条正文和一条已制卡记录，
资源文件名含 textseq；这补充了用户验收与原生正文已运行的观察。未重建同会话
完整身份/语音哈希链，故不将界面观察独自作为稳定配对或正式支持升级证据。

本轮窗口工具最初仍报前台 PID 缺失；重新初始化工具连接后恢复，未改系统设置。
下一样本 Angel Beats! trial 1.10 经 Fushi 原始 Start.exe/CP932 启动：helper
17364 于 16:41:42 创建原始 Start 59920 → StartMenu 44968；官方窗口模式
于 16:42:11 创建游戏 45060。引擎 1.1.80.4 x86，exe SHA-256
`c09a0a415f2333fff53fe648245a268c6b15e9e40074d9c18ba0bed5c21dd0ee`，
实际加载 v10 Hook `3c2bf4d5…08e5d71b`。日语环境检查通过并进入初始对白，
IPC v24 可读；专用 profile 暂未匹配，geometry 未发布，随后有界回退出现
GDI/Luna 文本。当前先定位该家族准入，不把回退线程作为内嵌适配完成。

## 2026-09-08 月彼启动时序修复候选

原始 CP932 目录的 Start 71212 → StartMenu 48776 于 16:47:00 创建月彼
游戏 22472，x86 引擎 1.1.134.0，exe SHA-256
`1a1067098727530e11cb522aa21ae784db681138f675a12f15efa116f2f61316`。
同一会话使用 v10 Hook；LE 提示 kernel32 先于其初始化加载，随后游戏提示需要
日语 Windows。正常确认错误后游戏退出，没有进入文本、音频或制卡阶段。

实际路径只按外层 Start.exe 计算延迟附着，跟随最终 Siglus 子进程后直接注入，
没有重新应用现有窗口就绪条件。BUG-2360 在最终身份确认后补回该条件；独立审查
又发现 host 在 injectionFailed 后自动恢复到普通 PID 附着会绕过此门，故附着
入口也复用相同条件和带 SYNCHRONIZE 的进程权限。失败只关闭自身句柄，不注入、
不恢复或结束游戏。未新增固定等待，也未改变 LE 初始化检查。

窗口就绪只是现有附着策略：同 PID 可见且有非空标题的窗口，并排除 Enigma 标题。
游戏自身错误对话框可能满足条件，不能把它当作 LE 初始化成功的证明。
首轮复验前，窗口工具明确报告物理 Esc 停止，已停止本轮所有界面操作。
候选仅构建，尚未替换运行中宿主的随包 helper，也没有创建 v11 游戏会话。

修复提交 `4e168b8a01`；调度测试 `25811f7b1e`、`ffe027adb5` 在两个架构各
42 checks 通过。移除附着门的可编译负对照退出 91，能捕获自动恢复绕过。
两架构 Release 全构建及最后新增测试目标构建均退出 0；完整 CTest 为 x86
103/103、x64 99/99 通过。两项生成检查、manifest 22、结构 49、workflow 6
和生产 replay 均退出 0。当前候选 x86 injector SHA-256 为
`31e743ecc3bea22d0c9aa472fc68556a92af7331f7697fa2b86ddf4fa2a7aa44`，
x64 为 `833380eb0a418df9d75346858ce26f7ed4b30b07d93edabcf12e21c78c5400c7`。

Angel Beats 的有界代码分析已确认正文候选 glyph 使用 8 个 DWORD 栈参数，
返回清栈 0x20；现有现代家族为 10 个参数。不能只放宽原有签名接入，需要独立
ABI、正文调用关系与几何/输入证明。当前仍停在专用 profile 准入边界。

## 2026-09-08 月彼 v11 原始路径与用户制卡验收

私有测试包替换两架构 injector，内容暂存产生新运行目录 `5c8cfaabc03fb972`，
宿主 73400 保持运行。helper 27604 于 17:10:08 从原始 CP932 Start.exe 启动，
Start 4428 → StartMenu 41808 → 游戏 70052（17:10:49）。实际 injector 哈希
与上述 x86 候选相同；游戏仍为 `1a106709…f61316`，实际 Hook 为
`3c2bf4d5…08e5d71b`。本机私有台账保存完整路径和组件哈希。

本次没有 LE 初始化错误或日语 Windows 拒绝，进入标题后正常进入正文。
IPC v24 与专用 profile 匹配、glyph/key sampler 均已观察；随后原生
`SiglusEngine message` 达到 140 个文本事件，查词命中 7 次，设计画布
1920×1080，provider 2/3。Fushi 可见对应正文及 `game_resource` 音频文件，
资源名含同一 textseq140。用户随后明确确认「月の彼方で逢いましょう 制卡验证通过」。
将月彼记为用户制卡验收通过，不再重复该游戏测试；本轮没有独立重建源 entry
字节哈希与完整真卡数据库因果链，正式能力矩阵保持原证据边界。

窗口工具中途报告物理 Esc，停止了本轮 UI 操作；用户制卡确认后工作转入
Angel Beats 的独立八参数结构分析，不再推进月彼。

## 2026-09-08 Angel Beats 八参数基础层（未启用）

用户指定后续只完成 Angel Beats。原始 Start.exe → StartMenu 3768 → 游戏
68368（17:14:58，x86，原 exe 哈希仍为 `c09a0a41…1dd0ee`），helper 68912
使用 `31e743ec…7aa44`，实际注入仍是 v10 Hook `3c2bf4d5…08e5d71b`。
新实现没有替换本次游戏的 DLL，也没有把回退文本记为专用 profile 通过。

新增八参数 ABI 转发及字形记录解码，独立核对 ECX、8 个 DWORD、AL 返回值和
0x20 栈清理。x86 测试实际包含生产 callback，三种 ABI 共调用原函数 12291 次，
覆盖跨 ABI、错误调用点、空结果、无效内存和非有限坐标；其 owner mock 仅验证
callback 调度，不能证明生产归属校验已接好。生产安装明确拒绝尚未整合的八参数
profile，真实 owner 入口也拒绝未知 ABI，保留已有十参数及十六参数路径。

独立结构解析器核对正文→Scenario→字形、字体/坐标写入、输入采样/窗口处理器、
全局对象发布及正常正文渲染组。正常组证明连接脚本选择器、VM 的已识别分支、
对象索引和实际渲染集合；不执行游戏 VM，不把表达式槽当作对象指针。运行时
membership 必须进一步与当次正文 ECX、选中 surface 和字形集合交叉核验。
测试采用合成映像，不依赖游戏名、exe 哈希或固定加载基址准入。

新增纯函数运行时快照、单次消息 ticket 和正常组归属读取：所有内存读有界，
地址按 x86 检查溢出，双读拒绝观察到的变化；双读不是引擎原子事务，不能排除
两次读取之间的 ABA，消费端仍须绑定当前文本 occurrence 并重新核验。
原盘 glyph/input/owner 联合解析成功。原样 runtime 实现在 PID 68368 只读验证
52 次标量读取、0 失败；scene 与 engine owner 别名成立，实际 HWND 属于该 PID，
设计及 viewport 均为 1280×720，三项必要输入 flags 为 0。
这些结果只证明该时刻的结构与 runtime primitive，未证明菜单/非对白禁用、
实际字形归属、点击稳定性、语音配对或真卡写入。

最终 Windows x86/x64 Release 全构建退出 0；完整 CTest 分别为 109/109、
105/105 通过。两项生成检查、manifest 22、结构 50、workflow 6 和生产 replay
均退出 0。独立审查指出旧 owner 函数对所有非 legacy ABI 默认返回 true；已改为
仅十参数直通，十六参数走既有校验，其余拒绝，并新增未整合八参数的安装/归属
结构守卫。未修改正式支持矩阵或四标题上游 PR。

本轮窗口工具再次明确报告物理 Escape 停止，随后没有再调用 Computer Use、
重启游戏或绕过界面停止执行输入。只完成源代码、合成测试和只读元数据核对。
下一步仍是将完整八参数结构及 occurrence 归属接入生产 profile，并回原始启动
路径验证专用正文与内嵌查词；该边界通过后继续对应引擎音频和制卡。

## 2026-09-08 Angel Beats 八参数生产接线与点击失效定位

八参数 glyph/input/normal-owner 结构联合解析已接入生产准入，与十参数、十六参数
互斥；正文外层 ticket 与 Scenario 的实际对象冻结绑定到单调 occurrence 和真实
IPC event ID。worker、字形回调和输入均重新核对正常正文组、surface、glyph vector、
viewport、HWND/PID。字形仅接受已证明的单位缩放和零旋转；未知变换撤销几何。
旧语音映射继续明确排除八参数，不将 Loopback 记为引擎音频通过。

v13 从原始 Start.exe 经 Fushi 的 `--japanese-locale` 启动，helper 17720，真实
游戏 PID 27452（18:33:07，x86）；实际 DLL `07c67817…309156` 与部署哈希一致。
原生 `SiglusEngine message` 正文已捕获并选中，字形、输入采样、结构准入都通过。
但用户报告点击无效，实机点击正文直接推进，命中计数仍为 0。私有只读元数据
证实 WM 与 GetKeyState 的同次 down 都是 `kTargetInvalid`，不是坐标未命中。

当前正文/binding/worker occurrence 均为 14，15 个字形曾形成完整布局；连续
字形事件无 invalid 标记。worker 读到上一轮完整布局加下一轮前缀时，尾部未对齐
导致当前布局失效。这是逐字 transport 与完整布局消费之间的边界错误（BUG-2361）。
现八参数回调按真实 vector ordinal/count 收齐完整批次，绑定 occurrence、body、
surface 和 vector begin/end/capacity，所有 slots 写完后一次提交 frontier；相同
重绘仍逐批发布以允许窗口/菜单恢复，实际变化或提前终止仍发布失效屏障。
生产 consumer 回归在每次 slot 写入时消费，覆盖跨 ring wrap、旧 occurrence、
失效后同句恢复；纯收集器涵盖向量重新分配、错序与容量边界。

v13 全部离线门通过：x86 CTest 111/111、x64 107/107；v14 初轮全构建与
CTest 112/112、108/108 通过。补充 vector 身份后的最终构建和完整 CTest 同样
112/112、108/108 通过。v14 由原始 Start.exe 经日语转区重启，helper 64136，
游戏 77612（19:02:19），实际 x86 DLL `82e7af2f…082439` 与部署一致。
读取 slot001 后布局持续有效，generation/epoch 为 6，15 字形完整，WM down
两次均为 `kLookupOwned`；但没有对应采样 down，队列仍为 0。WM 只屏蔽却丢弃
payload，依赖短点击必被 GetKeyState 观察的假设不成立。

v15 改由已证明的 WM sink 在 down 冻结命中票据，up 重验当前正文、几何、epoch、
窗口线程及前台后提交一次。GetKeyState 保留输入屏蔽和弹框关闭职责；其弹框按住
尾部使用独立业务状态，避免弹框消失后泄漏按下。取消/失焦撤销票据但仍吞掉已拥有
的释放；新 down 回收丢失 up 的旧票据。十参数与十六参数保持既有采样提交路径。
独立审查指出的跨线程状态访问、弹框按住尾部及诊断状态混用均已修正。

最终 Windows x86/x64 Release 全构建退出 0；完整 CTest 为 113/113（40.24 秒）、
109/109（25.96 秒）。新增真实 click policy 事务 harness 每架构 179 项检查，
覆盖 WM-only 短点击、采样交错、重复释放、取消/失焦、跨线程、目标/epoch 失效、
丢失释放及旧 ABI 回归。两项生成检查、manifest 22、结构 50、workflow 6 和生产
replay 均退出 0。

原始 Start.exe 经 Fushi 日语转区启动 v15，官方菜单 PID 6436 → 游戏 PID 73784
（19:25:27，x86），helper 69692，宿主 32700。实际 DLL SHA-256 为
`d38d5061119e9b02a6c9f75f3748cb1baa924ff9b33c1df4465e4459dbd886c4`，
与部署一致。实机两句共 3 次点词均显示词典，点词不推进；弹框持续保持、关闭后
同句再次查词、外点只关闭、下一次外点正常推进、新句查词均通过。文本事件为 2，
目标代次由 `1/7` 更新为 `2/13`。私有台账仅记录元数据，游戏载荷未入库。

## Not proved

Rewrite 按用户手动制卡验收记为通过，不再要求用户重复测试；上述旧会话未覆盖的
严格同会话身份与逐句资源哈希链仍保持证据限制，不由用户验收推断补齐。
Angel Beats 专用 profile、原生正文、字形、整批几何及内嵌查词在 v15 原始路径
实机通过；引擎语音配对与真卡 E2E 尚未验收。月彼启动复验和用户制卡验收
已通过，源 entry 字节哈希尚未独立核验。未升级
engine-support.yaml，未更新既有四标题 PR 或正式随包运行库。

源码准备及正式工具构建脚本已维护，最终候选重建与 PE 契约自动校验均通过。上游仍含预编译 MyLib；当前源码补丁和依赖说明不宣称其完整对应源码，也不宣称已满足修改 DLL 的正式分发条件。

## Next gate

Angel Beats 核对八参数正文 occurrence 对应的引擎语音资源访问与身份绑定，
先通过 resource/PCM 边界；不以 Loopback 替代引擎语音适配。Rewrite 与月彼不再
重复验收。
