## BUG-1477 · 汉化版被强制转区后启动即闪退：转区没有开关，判据把「32 位」当成「日文原版」
- **报告**：2026-08-09（用户本人）
  - 原话：下的汉化版 galgame，Hibiki 转区启动原版 exe 报错闪退，直接双击才能玩。
- **真实性**：✅ 真 bug，两处独立缺陷叠加。
  - **① 没有开关，而且不是「忘了传」**：判据在
    `fushi/lib/src/mining/galgame_audio_source.dart`（修复前）是
    `launchMode && automaticJapaneseLocale && await exeIs32Bit(exe) == true`；
    `automaticJapaneseLocale` 默认 `true`，唯一实例化点
    `gal_hook_session_controller.dart` 的 `_defaultEngineFactory` 从不传它。
    更致命的是 **`GalEngineSourceFactory` typedef 里压根没有这个形参** —— 整条
    UI → source 的通路上没有这个自由度。settings_schema / i18n / fushi_core 偏好
    三处也都无对应项，全仓 `automaticJapaneseLocale` 只命中 6 个文件（native
    injector、README、本文件、2 个测试、2 篇 bug 文档）。**确认无开关且不可达。**
  - **② 判据本身是错的**：`exeIs32Bit` 读的是 **PE COFF Machine 字段**，只回答
    「i386 还是 amd64」，与文本编码毫无关系。它的真实用途是**选 helper 架构**，
    转区判据是搭便车 —— [[BUG-1038]] 落地时把「Locale Emulator 只有 x86 版」这个
    **工程限制**当成了「32 位 ⇒ 日文原版」这个**语义判据**。
    汉化版恰好落在最坏格：32 位（老引擎）+ 字符串已转成 GBK/UTF-8 → 强制 CP932 后
    游戏 `MultiByteToWideChar(CP_ACP, ...)` 用 CP932 解 GBK 字节流，非法序列导致
    字体/字表索引越界 → 闪退。
  - **③ native 侧没有崩溃回退**：`native/galgame_hook/injector/injector_main.cpp`
    的 fallback 只覆盖「LE 运行库缺失」和「`LeCreateProcess` 返回非 0」；
    **进程创建成功之后再崩，没有任何检测、重试或提示**。（本轮未动，见备注。）
  - 临时绕法（已核实成立且是必然短路）：先双击运行游戏，再点顶栏「连接并捕获」。
    `launchMode` 是判据的第一个合取项，attach 路径 `launchExe: null` ⇒ 必然短路。
    代价是失去早注入（KiriKiriZ 等「启动即建 DirectSound 设备」的引擎会漏掉启动期音频）。
- **[x] ① 已修复** — 补**每游戏一档**的开关 + 重写判据：
  - 新增 `GalJapaneseLocaleMode{auto, on, off}`（`galgame_japanese_locale.dart`），
    持久化用稳定字面量 key 而不是 `enum.name`/`index`（与 `magpie_upscaling.dart` 同纪律）。
  - **为什么每游戏而不是全局开关**：同一个库里日文原版和汉化版并存 —— 原版不转区满屏
    乱码，汉化版转区启动即闪退，全局值两边都不对。这不是偏好，是本仓已经为同形问题
    定过案的结论（[[BUG-1191]] 把窗口超分从全局偏好改成每游戏一列）。
  - DB：schema **v74 → v75**，`galgames` 加 `japanese_locale_mode` TEXT DEFAULT ''
    （与 v62 的 `upscaling_mode`、v56 的 `launch_args` 同型）+ DAO 单列 setter + repo setter。
    ⚠️ 空串回落的是 **auto 而不是 off** —— 转区是用户明确要过的功能（BUG-1038），
    加了开关就把老用户默默关掉才是破坏用户空间。
  - 🔴 `galgame_detail_page.dart` 的保存是**逐字段重建**不是 `copyWith`（代码注释自己
    警告过），新列必须显式透传，否则用户每次在编辑页保存就把该设置静默清回默认。已加。
  - 接线：`GalEngineSourceFactory` typedef / `_defaultEngineFactory` / `launchGame`
    各加形参，三个 launch 调用点（游戏库页、galgame 首页、捕获工作台）都从
    `GalgameEntry.japaneseLocaleMode` 读，零额外查询。工作台那条走
    `findGalgameByExePath`；库里没有这个 exe（临时选的文件）→ auto，与旧行为等价。
  - UI 入口：游戏卡右键菜单「日语区域（转区）· <当前档>」，与超分那项并列同处，
    三档单选对话框照抄 `MagpieUpscalingModeDialog` 的形状。Windows-only。
  - 判据改成 `resolveJapaneseLocale()` 纯函数：`off` 永不转、`on` 只看 launchMode
    （不看位数——将来 LE 有 x64 版时自然生效）、`auto` = **一道否定门**
    （系统 ACP 已是 932 ⇒ 不转，本就日文区，转了纯属多一层失败面；经纯 Dart FFI
    问 `kernel32!GetACP`，不新开 MethodChannel）**+ 一道工程门**（LE 只有 x86 版）。
- **[x] ② 已加自动化测试**
  - `fushi/test/mining/galgame_japanese_locale_test.dart`：三档 × attach/launch 真值表、
    ACP 门、位数门、key 编解码稳定性、空串/脏值回落 auto（**不是** off）。
    已做变异实测：让 `off` 档失效退回老判据 ⇒「汉化版选这档」用例即红。
  - `fushi/test/database/migration_v75_galgame_japanese_locale_mode_test.dart`：
    老行零破坏 + 回填空串、单列写入不碰其它列、整行 upsert 省略该列不清空、
    迁移幂等、fresh 库 onCreate 建列。
  - 顺带修正被 schema 版本号硬编码影响的既有测试（14 个文件的 `74` → `75`），
    以及 v63 那条「不得 ALTER/DROP/rebuild 既有表」的 DDL 全文比对 —— 它现在对
    `galgames` 改成「摘掉 v75 那一列的片段后必须逐字节相同」，容下这次合法加列的同时
    **不弱化**原判据。
  - `flutter analyze`（含 test）零问题；`test/database` 538 + `test/mining`+`test/lookup`+
    详情页 + i18n 1610 tests PASSED。
- **备注**：⚠️ **两处已知未做**：
  - **exe PE 资源语言 ID 门**（判出 zh 就一定别转）：`galgame_exe_icon.dart` 已有完整的
    PE 资源树解析器、第三层就是 LANGID 只是被丢弃，但接上它要重构一个正在工作的
    解析器，而这条门**只能可靠地否定、不能可靠地肯定**（汉化组常常只改脚本包不改
    exe 资源）。收益有限、风险不小，本轮不做。真正兜底的是 `off` 这个用户可选档位 ——
    `auto` 不可能在所有情况下判对，exe 位数与文本编码之间根本没有因果关系。
  - **native 侧转区后崩溃无回退**（上面的 ③）：进程创建成功之后再崩没有任何检测。
    做的话应当在 launch 路径观察「进程在首个窗口出现前退出且退出码异常」并提示
    「该游戏可能不需要转区，试试把它的日语区域设为关闭」。
