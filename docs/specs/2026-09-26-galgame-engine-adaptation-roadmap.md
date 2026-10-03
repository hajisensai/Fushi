# Galgame 引擎适配路线图（2026-09-26）

按「玩家多 → 小众」逐个引擎推进，一直做下去。本文件是**排期与验收口径**，引擎支持状态的唯一真相源仍是 `native/galgame_hook/engine-support.yaml`，操作流程见 [docs/agent/galgame-hooking.md](../agent/galgame-hooking.md)。

## 1. 两条硬规则（根 `CLAUDE.md`）

1. **只做引擎级适配**：修的是引擎 / 引擎变体的通用判据与生命周期，不加按 exe 哈希、文件名、标题写死的特判。判据取自引擎结构特征，并用同引擎多个版本的样本 + 他引擎负向样本验证。
2. **适配成功 = 四条同时满足**（在用户原始启动路径上）：
   - ① **文本**：选定线程是干净正文；
   - ② **音频**：拿到与该句对应的语音（引擎资源或 PCM；纯 Loopback 不算）；
   - ③ **内嵌查词**：游戏画面内弹出 Fushi 查词卡；
   - ④ **点击查词不推进**：点台词里的词能查到该词，且这次点击不推进剧情。
   缺一条只报「部分适配」并写明缺哪条。

## 2. 排序口径

- 优先级 = 该引擎覆盖的**作品数 × 中文学日语玩家里的常见度**。下表是按社区常见度的估计，**待用实际数据校准**（Fushi 游戏库里的 exe 引擎分布、发现源下载量）；校准后直接改本表顺序。
- 同一优先级内，先做「离四条最近」的引擎（已 partial 的优先于未实现的），尽快把可用面铺开。
- 一引擎一任务、一独立 worktree（SOP §1）。每个引擎至少覆盖**两个不同年代 / 发行形态的样本**（光盘版 + Steam 版、原版 + 汉化版、老版本 + 新版本），避免只修好一个构建。

## 3. 现状基线（2026-09-26，来自 engine-support.yaml）

| 状态 | 引擎 |
|---|---|
| verified | SiglusEngine、Unity IL2CPP、XAudio2/DirectSound 通用采集 |
| partial | KiriKiri2 / KiriKiri Z、TyranoScript、Artemis、CatSystem2、Malie、QLIE |
| implemented_unverified | RealLive、BGI/Ethornell、CMVS、elf AI6、Ren'Py、Unity Mono、Leaf/AQUAPLUS、HUNEX GGE、smash/fzmedia、SGRE、Unreal、AOS/SFA |
| 未实现（只有通用文本 / Loopback） | YU-RIS、FVP（Favorite）、Softpal/Unison、NeXAS、Majiro、AliceSoft System4、EntisGLS、Livemaker、NScripter/ONScripter、Escu:de、ExHIBIT 等 |

游戏内查词几何来源：KiriKiri、Ren'Py 有运行时布局；Siglus、Leaf、HUNEX、SGRE、smash、CMVS 有引擎精确布局；其余引擎只有手动校准（`attached_calibrated`），③④ 基本都还没打通。

## 4. 路线图

### P0 · 跨引擎前置（先做，所有引擎受益）

| 项 | 内容 | 为什么先做 |
|---|---|---|
| BUG-2710 | KiriKiri 查词关卡后下一次点字被吞一次 | 查词交互的共性时序（卡片可见性应答），很可能不止 KiriKiri |
| BUG-2703 | 日文命名的 SE 被当语音候选 | 语音 / SE 分类要换成引擎级信号（播放通道 / 归档），各引擎都会遇到 |
| 制卡 E2E 装置 | 驱动宿主 `mine` + 假 AnkiConnect，形成每引擎一条命令的「四条 + 真卡」验收脚本 | 让每个引擎的验收可重复、可比 |
| 启动路径 | BUG-2126（LE + x86 崩）、BUG-1192（SteamStub 需正版样本） | 光盘版 / Steam 版差异大多卡在启动层 |
| 引擎识别表 | 对用户库 / 下载库里的 exe 做静态引擎识别并统计分布 | 用真实数据校准第 2 节的排序 |

P0 进展（2026-09-26 晚）：

- **BUG-2710**：宿主层已排除——同一套直连卡 + 系统钩子在 CLANNAD（Siglus）上按原序列四连击，关卡后第一击正常出卡；问题收窄到 KiriKiri 注入侧。宿主点击状态与注入侧 submit 发布结局的诊断日志已加，待 KiriKiri 样本复现。
- **制卡 E2E 装置**：真机驱动 `fushi/integration_test/gal_realgame_driver_itest.dart` 新增 `fakeanki` 与 `accept4 <x> <y> [ox oy]`。游戏停在一句对白上后，一条命令依次判 ① 文本 ② 非 Loopback 语音 ③ 点字出卡 ④ 不推进 ⑤ 关卡不推进 ⑥ 关卡后再点能出卡（BUG-2710 回归）⑦ 写进假 AnkiConnect 的卡带台词 / 语音 / 图片，末行 `verdict=full|partial`。已过定向 analyze，**尚未在真游戏上跑过**（本轮可用样本都被其它会话占用）。
- **样本**：本机现存 galgame 只剩 CLANNAD、SGRE、WoH，且各有会话在用；KiriKiri 样本需要重新取得。Steam 版千恋＊万花（AppID 1144400，用户已拥有、只装了成人补丁）装上后可同时解 BUG-2710 与 BUG-1192（正版 SteamStub 样本）。

### P1 · 主流引擎（玩家最多）

| 顺序 | 引擎 | 当前 | 缺哪条 | 下一步 |
|---|---|---|---|---|
| 1 | **KiriKiri2 / KiriKiri Z**（柚子社、Palette、FSN RN 等） | partial；千恋＊万花光盘版原版四条通过（PR #1673） | 其它变体未逐一过四条 | 按变体各取样本：经典 KAG3（K2/BCB）、KAGEX（2016 柚子社）、msgwin 插件型（2023 柚子社）、Palette（9-nine）；汉化加壳 exe、Steam 版各一 |
| 2 | **SiglusEngine / RealLive**（Key / VisualArt's） | Siglus verified 1 款；RealLive 未验证 | RealLive ①–④；Siglus 多作品的 ③④ | Siglus 再补 Rewrite、Summer Pockets 一类；RealLive 取老版本 Key 作品 |
| 3 | **Unity**（IL2CPP / Mono，新作与 Steam 作品） | IL2CPP verified；Mono 未验证 | Mono 全部；两者的 ③④ 只有手动校准 | 先 Mono 的 ①②，再做 TextMeshPro 运行时布局取几何 |
| 4 | **BGI / Ethornell** | 宿主 accept4 `verdict=full`（1.519.6 体験版，2026-09-30） | ①–④ | 1.6 代（2016 ARC20）真机未跑；manifest 几何门未跑 |
| 5 | **CatSystem2** | partial | ③④ | 从 CS2 的文本绘制边界取几何 |
| 6 | **Artemis** | partial | ③④ | 同上；覆盖 PC 与移植构建 |

P1 进展（2026-09-27，分支 `claude/galgame-p1`；样本一律经 Fushi 发现源「真红小站」下载）：

| 引擎 / 样本 | ① 文本 | ② 语音 | ③ 查词 | ④ 不推进 | 状态与下一步 |
|---|---|---|---|---|---|
| KiriKiri Z · 千恋＊万花 光盘版（KAGEX） | ✅ | ✅ | ✅ | ✅ | accept4 `verdict=full`，含真卡写入 |
| KiriKiri Z · PARQUET 2021（ゆずソフトSOUR，msgwin 插件登记但不画正文） | ✅ EmbedKrkrZ | ✅ game_resource（opus/ogg） | ✅ | ✅ | BUG-2721 修复后宿主 accept4（物理像素坐标）过四条 + 真卡；样本已删 |
| KiriKiri2 · 夏空カナタ（2008） | — | — | — | — | 下载包自带汉化补丁（正文乱码），不作样本；已删 |
| RealLive · planetarian Kinetic Novel（2004，脚本打进 .pak，语音 NWK） | 待宿主 | ✅ 运行时导出 `Z0001.nwk_529.wav` | 缺几何 | 缺几何 | 新增结构识别 + NWK/NWA 解码（离线 856/856 条）；③④ 需 RealLive 字形几何 provider |
| RealLive · 智代アフター 2005 日文原版（光盘直拷，x86，800x600 独占全屏） | ✅ Luna `RealLive · 0x415b00` 正文 context（记忆按典型行长自动恢复） | ✅ BUG-2732 修复后 `matched/game_resource`（`Z0629.nwk_<id>.wav`） | ✅ 引擎精确字形 provider（kind 2 id 18） | ✅ 引擎键表 VK_LBUTTON 帧级屏蔽 | 宿主 accept4 `verdict=full` + 真卡（最终 DLL 5C6FAB28…）；真机两处更正：Focused() 用 GetFocus、相邻字格重叠不算换页；manifest 几何门未跑，仍 `implemented_unverified`；单样本 |
| SiglusEngine · planetarian HD Steam | — | — | — | — | 下载包为汉化 + Steam 模拟器，无日文 Scene.pck，不适合；需另取日文 Siglus 样本 |
| CMVS | — | — | — | — | BUG-2718：runner 白名单漏 id 16，精确布局 hit 被丢；已修并加三处镜像守卫，无样本未真机 |
| Unity Mono · Sentimental Death Loop（2023，Unity 2021.3 x64 Mono，Fungus 框架） | ✅ `Unity Mono Fungus Say` 道（SayDialog.DoSay，剥 Fungus 标签） | ✅ 67b8fd3dc51：`*voice*.bundle` AudioClip 经 injector 抽取，宿主 `matched/game_resource`（`sce_0006.wav`） | ✅ provider id 20 框架分支 2（UGUI Text 的 TextGenerator 字形） | ✅ | 宿主 accept4 `verdict=full` + 真卡（noteId 1790549375831）；manifest 几何门未跑，仍 `implemented_unverified` |
| Unity Mono · デスマッチラブコメ！ Steam 版（2020，Unity 2019.2 x86 Mono，逐字 TextMesh 框架） | ✅ `Message.Mes` 正文道 | 样本无语音 | ✅ provider id 20 框架分支 1 | ✅ | 宿主 accept4 ①③④ + 真卡（noteId 1790528375097；67b8fd3dc51 后回归 noteId 1790549375833） |
| Artemis · アマナツ Perfect Edition Ver2.0.0（x64，PF8） | ✅ Luna 0x14018d260 | ✅ game_resource `222273750_fem_kog_00019.ogg` | ✅ 引擎精确字形 provider（kind 2 id 17） | ✅ 帧级按键表清零 | 宿主 accept4 `verdict=full` + 真卡（ffd072e0f6d）；manifest 几何门（200 正探针等）未跑，仍 `implemented_unverified`；单样本，需第二个 Artemis 版本 |
| BGI · 放課後しっぽデイズ 2013 光盘版（mds+mdf） | — | — | — | — | 无法起样本：① `GetSystemDefaultLangID()&0x3ff==0x11` 否则静默退出（中文系统须该游戏开「日文转区」，LE 下返回 0x0411 已过）；② 单实例互斥量 `Buriko General Interpreter for <游戏> is executing.`，本机退出的进程常卡成杀不掉的僵尸并继续持有它，新实例 `FindWindowA` 落空后静默退出（上午「BGI 自己退出」的真因）；③ 主循环在不建窗的情况下返回，盘上 `BGI.hvl`→`BHVC.exe` 为光盘保护校验，拷出的镜像过不了——不做 DRM 规避，需无光盘保护的 DL 版样本。样本已删 |
| SiglusEngine · CLANNAD Steam（SiglusEngine_Steam 1.1.134，x86，日语社区补丁） | 2026-09-25 已验（原生消息 hook） | 2026-09-25 已验（OVK 逐句，与 `koe/z0414.ovk` 条目 SHA-256 一致） | 2026-09-25 已验（Shift/单击查词命中） | 2026-09-25 已验（单击字形不推进） | 宿主 accept4 + 真卡未跑成：2026-09-28 本机 D3D9 present 卡在 `d3d9→dwmapi`（**不注入的裸启动同样卡**，白屏），属环境问题；环境恢复后补跑 |
| SiglusEngine · Harmonia 2017（真红小站包） | — | — | — | — | 原版 `SiglusEngine.exe` 弹 AlphaROM `[1200]` 认证框无法启动；包内另有汉化 exe + `SiglusUniversalPatch.dll`（改动过的引擎 + 中文脚本），不作样本。Siglus 维持 CLANNAD Steam 的既有验证。已删 |
| YU-RIS · euphoria（CLOCKUP 2011，update 1.02 exe）+ アイカギ（あざらしそふと 2016，移开散放汉化目录） | ✅ `YU-RIS exact`（源 9，引擎消息文本 S+T；丢行内换行码 0xEFF0、注音 ≪基字／读音≫ 取基字） | ✅ game_resource（按文本事件 ID 配对：`…textseq239_kan_m01_0073.ogg` / `…textseq37_shi_01_comn_04_0003.ogg`，取自引擎交给 ov_open_callbacks 的解码器输入，不读归档） | ✅ provider 22 | ✅ 鼠标（按键表屏蔽）+ 触屏（提升的触摸点按在主窗口过程认领；点字/卡内/卡外/横滑/长按均不推进） | 2026-10-03 宿主 accept4 两样本 `verdict=full`，真卡 noteId 1791002595603（euphoria #16）/ 1791002595605（アイカギ #34）；宿主 Hook Text 浮窗会吞其下方点击（アイカギ 测试时挪开窗口）；`implemented_unverified` |
| SiglusEngine · P1 结论（2026-09-30 用户拍板） | 2026-09-25 CLANNAD Steam 已验 | 2026-09-25 已验（OVK 逐句哈希一致） | 2026-09-25 已验 | 2026-09-25 已验 | 用户确认「先当做通过」：依据 CLANNAD Steam 2026-09-25 的逐条真机证据 + 既有多版本 Siglus 适配（anemoi 1.1.141.3 verified、Angel Beats PR #1315、BUG-2653/2712/2768/2769）；**本轮未补宿主 accept4 + 真卡**（CLANNAD 需已登录 Steam，用户不走 Steam 版）。补测尝试：Key 官方《Rewrite》体験版（RewriteTE_Ver200，2011）与真红 tone work's《月の彼方で逢いましょう SSR》（SiglusEngine 1.1.134.0 原版 exe，包内另附汉化 `SiglusUniversalPatch`）同样带 `CheckLanguage`（kernel32 版本资源判日文 Windows），本机中文 Windows 无 32 位 ja-JP MUI 均过不了；同版 1.1.134 的 CLANNAD Steam 曾在本机正常运行，说明 Steam 构建关闭了该检查。非 Steam 原版 Siglus 在本机要补 accept4，需要用户装日语显示语言包（含 32 位 MUI）或提供已登录的 Steam |
| SiglusEngine · 2026-09-30 取样（均不作样本、已删） | — | — | — | — | ① 真红「CLANNAD steam版」2015 与「クドわふたー 全年齢 DL版」实为 **RealLive**（`Seen.txt`/`REALLIVE.EXE`）；② 真红「CLANNAD HD Edition steam版」与本机 Steam 版逐字节相同（exe/steam_api/SceneZH），附带 SmartSteamEmu 破解加载器——不用；③ 真红 LOOPERS 根 exe 为免 CD 补丁（与「免CD补丁备份」原版不同）；④ Key 官方《Summer Pockets 体験版》（官网 dlsv.product.jp）经 `Start.exe` 与直启 `SiglusEngine.exe` 都弹「日本語版Windows判定」：LE 下 `GetLocaleInfoW(LOCALE_SYSTEM_DEFAULT)`=0411、时区「東京 (標準時)」均通过，卡在 `CheckLanguage` 读 `GetSystemDirectory\kernel32.dll` 版本资源 `\VarFileInfo\Translation` 要求 0411——取决于 32 位 MUI（本机无 `SysWOW64\ja-JP\kernel32.dll.mui`），属明示地区锁，不做规避。Siglus 真机样本仍是 CLANNAD Steam（需已登录 Steam 客户端） |
| Malie · Dies irae ～Interview with Kaziklu Bey～ 2016（真红包，原版 malie.exe 7F7506F4…，x86；汉化散放 exec.dat/字体/mai.dll 已移出样本） | ✅ `Malie exact`（ENGINE:MALIE:message_segment，点击单元解析器 + RICHTEXT3D reveal，剥语音标签与注音） | ✅ Ogg 解码器输入（libogg ogg_sync_wrote 的 refill 调用点），按句内语音标签配对：`matched/game_resource …_textseq10_vir_v_vir0002.ogg` | ✅ 引擎精确字形 provider（kind 2 id 28，RICHTEXT3D draw 的字形框 + 世界矩阵，设计 1024x600 拉伸铺满客户区） | ⚠️ 仅鼠标（客户区子窗口窗口过程吞 WM_LBUTTONDOWN/UP），触摸未测 | 宿主 accept4 text/audio/lookup/no_advance/dismiss/relookup 全 PASS；宿主 accept4 card=FAIL（重建宿主的隔离数据根未装词典：查词卡显示「未找到搜索結果」，mine 没有加卡；待装词典后重跑，见 efd56751aa 与 engine-support.yaml）；写死的 CFI 密钥与自解密已删，身份改按 exe 结构（CFI I/O scheme 表）；单样本，manifest 几何门未跑，仍 `implemented_unverified` |
| Malie · 潮風の消える海に 2007 / 神咒神威神楽 曙之光 2013 / Dies irae Acta est Fabula 2009（真红包） | — | — | — | — | 均为破解版（去激活 dump / 通用破解器 kDays.dll / NoSerial 补丁），不作样本，已删 |
| BGI · あざスミ 2019（SMEE，真红小站 files 包） | — | — | — | — | 目录名含 〜（U+301C）无法经 CP932 往返，`CreateFileA` 读自身 exe 得 err=123 后退出（改 ASCII 目录可过）；原 exe 被销售平台 DRM（`Paltiosoft\Wrapping`）包裹，包内是第三方破解（`Mai@KF.dll` + `.exe.org`），不作样本、已删 |
| BGI · 穢翼のユースティア 官方 Web 体験版（2011，オーガスト，Ethornell 1.519.6，x86，PackFile 归档；官方 Setup 安装后从开始菜单路径启动，日文转区；本机 200% 缩放下该 exe 设 HIGHDPIAWARE 兼容层） | ✅ `BGI exact` 道（898ebe3e862：hook SetTextImpl，整句 CP932 正文，两代调用约定按结构解析） | ✅ d2d905c32ab：按归档内容判语音包（全成员单声道 `bw`），宿主 `matched/game_resource`（`data04099.arc_aiy710000010.ogg`） | ✅ 引擎精确字形 provider（kind 2 id 21，消息页格子链表 + owner 图层位移） | ✅ 窗口过程吞 WM_LBUTTONDOWN/UP | aed7662a204 后宿主 accept4 `verdict=full` + 真卡（noteId 1790765888185，「放せよっ！」）；2016《千の刃濤》ARC20 体験版只做了静态解析（未安装跑不起）；manifest 几何门未跑，仍 `implemented_unverified` |
| CatSystem2 · グリザイアの有閑（2015，cs2 2.6.1.x，x86，D3D9） | ✅ 选 `EmbedCS2` 正文道（二次发出已修 280ccf95226；渲染道也干净但比语音晚 0.3–1.7 s，长句超出配对窗口） | ✅ bf525615e69：在引擎自己的 `Archive::ReadEntry` 原地解密后截取整段 Ogg（加密 KIF，未实现任何解密），宿主 `matched/game_resource`（`pcm_e.int_SAC_griani_003_002.ogg`） | ✅ 引擎精确字形 provider（kind 2 id 19） | ✅ | 宿主 accept4 `verdict=full` + 真卡（noteId 1790534808080）；manifest 几何门未跑，仍 `implemented_unverified`；单样本 |
| FVP · いろとりどりのセカイ（2011，FAVORITE，World.exe 原版，x86，D3D9，1024x640；真红小站包，汉化补丁未覆盖 `World.hcb`/`voice.bin`，经 ASCII 联接目录日文转区启动，本机设 HIGHDPIAWARE） | ✅ `FVP exact` 道（hook 文本对象 Print，站点由 TextPrint syscall 注册结构解析，剥 `[ruby|base]` 注音，每个文本缓冲一条线） | ✅ 596bc6c78ec 后宿主 `matched/game_resource`（`…_fushi_textseq288_voice_00000010.ogg`；取 AudioPlay→SoundLoad 解码器输入的单声道 Ogg，绑到随后打印的台词，未读归档） | ✅ 引擎精确字形 provider（kind 2 id 23，PutGlyph 笔位 + DrawSprite 平移原点） | ⚠️ 仅鼠标（子窗口过程吞 WM_LBUTTONDOWN/UP；鼠标落在覆盖客户区的子窗口，两个窗口过程都挂），触摸未测 | 宿主 accept4 ①–④（④ 仅鼠标）与关卡/再查 PASS，**card=FAIL**（当时宿主未装词典，待装词典后重跑，见 c9fb999a06）；第二样本《星空のメモリア EH HD》原版备份 exe 仅离线解析通过；触摸未测；仍 `implemented_unverified` |

取样注意：本机网络为 Clash TUN（fake-ip），UDP tracker 与 DHT 全部超时，Fushi 内置 torrent 引擎拿不到元数据（Sukebei 四个种子均停在 metadata 0%）；日文原版改走真红小站 HTTP 源（有「[日期][品牌] 原名.rar」原版包）。

宿主注意：驱动测试原 45 分钟超时会杀掉宿主与内存里的下载队列（旧的「exit 79」），已改 6 小时。

### P2 · 常见但覆盖面较窄

| 顺序 | 引擎 | 当前 | 下一步 |
|---|---|---|---|
| 7 | QLIE | partial | ③④ |
| 8 | Malie | implemented_unverified（Amantes 旧 verified 记录已随 CFI 线退役撤回） | 在 decoder-input 线上重跑 ①–④ + 真卡（④ 含触摸） |
| 9 | CMVS（Purple Software） | 未验证（已有精确布局） | 原始路径过四条 |
| 10 | elf AI6 | 未验证 | ①–④ |
| 11 | YU-RIS | 未实现 | 新 adapter：文本 / 语音资源边界 |
| 12 | FVP（Favorite） | 未实现 | 新 adapter |
| 13 | Softpal / Unison | 未实现 | 新 adapter |
| 14 | NeXAS | 未实现 | 新 adapter |
| 15 | Ren'Py | 未验证 | ①–④（已有运行时布局） |
| 16 | TyranoScript / NW.js | partial | ③④（WebView 路线） |

### P3 · 小众 / 老引擎 / 单品牌引擎

Majiro、AliceSoft System4、EntisGLS、Livemaker、NScripter/ONScripter、Escu:de、ExHIBIT、AOS/SFA、Unreal，以及已有单品牌精确 profile、待原始路径验收的 Leaf/AQUAPLUS、HUNEX GGE、smash/fzmedia、SGRE。按 P0 的库分布统计决定先后。

## 5. 每个引擎的固定流程

1. **取样本**：优先官方体验版或小体积版本，下到 D 盘，测完删除；每个引擎至少两个不同版本 / 发行形态。
2. **身份台账**：exe 路径 / SHA-256 / 架构、启动器与真实进程关系、壳与 TLS 回调、关键模块（SOP §2）。
3. **原始路径逐关**：按 `process_found → helper_ready → ipc_ready → text → resource/pcm → paired → 查词几何 → 点击消费` 逐关推进，只修第一个未通过的边界。
4. **引擎级修复**：判据来自引擎结构；配跨引擎负向样本或负向测试。
5. **验收**：Fushi 宿主（`gal_realgame_driver_itest`）走原始路径，四条逐条留证据（台词、音频后端、查词卡截图、点击前后台词计数）；能写卡的再补一张真卡。
6. **落账**：`docs/bugs/` 一 bug 一文件；`engine-support.yaml` 只有四条 + 真卡齐全才升级状态，否则只加测量记录。

## 6. 完成度看板（随适配推进更新）

| 引擎 | ① 文本 | ② 音频 | ③ 查词卡 | ④ 点击不推进 | 已验样本 |
|---|---|---|---|---|---|
| KiriKiri Z（KAGEX，千恋＊万花光盘原版） | ✅ | ✅ | ✅ | ✅ | 1 |
| KiriKiri Z（喫茶ステラ原版 / 汉化版） | ✅ | ✅（资源） | 未测 | 未测 | 2 |
| 其余引擎 | 见第 3 节 | | | | |
