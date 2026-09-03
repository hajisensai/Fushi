# galgame 转区（日语区域）自动判定：从「全转区」改成「按证据判需要」

- 日期：2026-09-02
- 分支 / worktree：`worktree-gal-locale-auto-detect`（起点 `origin/develop` = `74c489dc20`）
- 关联：[[BUG-1038]]（转区落地）、[[BUG-1477]]（每游戏三档开关 + 「32 位 ⇒ 日文原版」判据错误）、[[BUG-1691]]（转区不可见）
- 用户原话（2026-09-02）：「转区需要自动判断是否需要转区，而非全转区（除非无法实现）」

## 0. 结论先行

- **现状**：`auto` = 「系统 ACP≠932 且目标 32 位」⇒ 转区。中文系统上**每一个 32 位游戏都被转区**，判据是工程限制不是语义（BUG-1477 已指出），BUG-1477/1691 都把「能不能自动判对」写成了不可能。
- **本轮判断**：**部分可实现**。「这个游戏的文本是不是 CP932 字节」没有单一真值，但有一组**便宜、离线、可单测**的证据源，在库里三个真实样本上已验证（见 §2）。方案是**证据驱动的三态判定**：`需要 / 不需要 / 未知`，只在「需要」时转区。「全转区」只保留为用户显式选 `on`。
- **不做**的事：不读 XP3/引擎归档内容（大多数加密，且一引擎一格式）；不为 KiriKiri Z 的 `getLangName.dll` 加「内建多语言 ⇒ 不转区」门（BUG-1691 的保留意见：样本只有 2 个）；不引入运行时探测（先启动再看崩不崩）。

## 1. 数据结构（先定这个，再谈代码）

```dart
/// 「本游戏是否需要 CP932 环境」的三态结论 + 证据清单。纯值对象，三端可单测。
enum GalJapaneseLocaleNeed { needed, notNeeded, unknown }

enum GalJapaneseLocaleEvidence {
  userLanguageJapanese,      // GalgameEntry.language 以 ja 开头
  userLanguageOther,         // 用户声明了非日语内容语言
  manifestUtf8CodePage,      // exe manifest <activeCodePage>UTF-8</activeCodePage>
  versionInfoJapanese,       // RT_VERSION 语言目录 / Translation = 0x0411
  versionInfoChinese,        // 0x0804 / 0x0404 / 0x0C04 / 0x1004
  exeShiftJisStrings,        // exe 非代码段 NUL 串段里假名串 ≥ 3 条
  dirFileNameJapanese,       // 顶层文件名含假名
  dirFileNameChinesePatch,   // 顶层文件名命中 汉化|中文|简体|繁体|繁體|CHS|CHT|chinese|hanhua
  dirTextShiftJis,           // 顶层文本文件（无 BOM）假名对 ≥ 20 且 GB2312 对 ≈ 0
  dirTextGbk,                // 顶层文本文件（无 BOM）GB2312 对 ≥ 20 且假名对 ≈ 0
  dirTextSimplifiedHanzi,    // UTF-8/UTF-16 文本含 ≥ 5 个简体专用汉字且无假名
}

class GalJapaneseLocaleVerdict {
  final GalJapaneseLocaleNeed need;
  final List<GalJapaneseLocaleEvidence> evidence; // 触发了的证据，UI 直接列出来
}
```

判定规则（纯函数 `judgeJapaneseLocaleNeed(evidence)`）：

1. 用户声明语言优先：`userLanguageJapanese ⇒ needed`；`userLanguageOther ⇒ notNeeded`。这是唯一的人工真值，压过一切自动证据。
2. **任何一条负向证据 ⇒ notNeeded**（`manifestUtf8CodePage` / `versionInfoChinese` / `dirFileNameChinesePatch` / `dirTextGbk` / `dirTextSimplifiedHanzi`）。理由：转错的代价是**启动即闪退**（BUG-1477），不转的代价是乱码——不对称，负向必须压过正向。汉化补丁常常只改脚本包不改 exe（BUG-1477 备注），所以负向证据主要靠**目录**而不是 exe。
3. 否则任何一条正向证据 ⇒ `needed`——**但 `versionInfoJapanese` 单独出现不算**（审查跟进）：0x0411 只回答「发行商是日本的」，KiriKiri Z / Unity / Ren'Py 的日文游戏一样带它却不需要 CP932；它只与字节级/目录级正向证据一起才算。
4. 否则 `unknown`。
5. `auto` 没转区时另记 `GalJapaneseLocaleSkipReason{notNeeded, unknown, systemAlreadyJapanese, targetNot32Bit}`：语义门（改 `on` 有用）与工程门（改 `on` 也没用）分开，事件与状态卡按原因说话。

`resolveJapaneseLocale` 增加 `need` 形参（默认 `unknown`，老调用不变），`auto` 分支改为：

```
auto: need == needed && systemAnsiCodePage != 932 && is32Bit
```

**关键决策（需用户确认）**：`unknown` 时**不转区**。这是「自动判断是否需要」的字面含义，也是「而非全转区」的要求。代价：证据完全空白的日文原版会先乱码，用户看到会话卡上的「未转区 · 证据不足」后改 `on`。备选是 `unknown ⇒ 沿用旧判据（32 位就转）`，那样只修汉化版闪退、不改「默认全转」。**推荐前者**。

## 2. 证据源的真实样本验证（2026-09-02 本机，Python 原型）

| 样本 | 版本资源语言 | exe 假名串段 | 目录 | 期望 | 新判定 |
|---|---|---|---|---|---|
| 屋上の百合霊さん（RScript，日文原版） | 0x0411 | 31 条（假名对 257 / GB 对 3） | 文件名含假名；`ReadMe_*.txt` 无 BOM，假名对 1993 / GB 对 0 | 转 | needed ✔ |
| 天使☆騒々 R18（KiriKiri Z 官方多语言，`.sig` 签名） | 0x0411 | 0 条（假名对 21，全是噪声） | 无文本文件、无假名文件名 | 不转（Unicode 引擎，BUG-1691） | **unknown ⇒ 不转 ✔**（审查跟进后 0x0411 单独只是佐证） |
| 天使☆騒々 bgimage 版（同上 + 日文 readme） | 0x0411 | 0 条 | `お読みください.html`（UTF-8 BOM，日文）、`patch.txt` 无 BOM 假名 304 / GB 0 | 不转 | needed（Shift-JIS 文本 + 假名文件名）— **证据模型解不了这一格**，用户设 `language`≠ja 或 `off` |
| charmap.exe（对照，纯英文） | 0x0409 | 0 条（假名对 6 = 噪声；「GB 对」337 = 噪声） | — | 不转 | unknown ⇒ 不转 ✔ |

两条硬结论：

- **exe 字节里的「GB2312 区字节对」是噪声**：纯英文 charmap.exe 也有 86 条「GB 样」串段。所以 exe 层**只做正向**（假名串段 ≥ 3 条），**不做**「GB 对多 ⇒ 中文」。
- **文本文件里的 GB/假名统计是干净的**（readme 1993:0），负向证据放在目录文本文件上。

阈值来源：假名串段的噪声上限在两个非日文二进制上是 0 条；取 ≥ 3 条留余量。

## 3. 改动清单

| 文件 | 改什么 | 为什么 |
|---|---|---|
| `fushi/lib/src/mining/galgame_japanese_locale.dart` | 加 `GalJapaneseLocaleNeed` / `Evidence` / `Verdict` / `judgeJapaneseLocaleNeed()`；`resolveJapaneseLocale` 加 `need` 形参，`auto` 改成 §1 规则 | 判定的真相源只有一处 |
| 新 `fushi/lib/src/mining/galgame_japanese_locale_probe.dart` | 纯函数：`classifyTextBytesForLocale(Uint8List)`、`classifyFileNamesForLocale(Iterable<String>)`、`classifyPeForLocale(Uint8List)`（版本资源语言 / manifest UTF-8 / 非代码段假名串段）；异步 `probeGalJapaneseLocaleNeed({exePath, language})` 做有界 IO（exe 前 16 MB、顶层目录 ≤ 2000 项、文本文件 ≤ 20 个 × ≤ 256 KB） | 三端可单测，IO 与判定分离 |
| `fushi/lib/src/mining/galgame_exe_icon.dart` | 把 `.rsrc` 目录遍历抽成 `pe_resources.dart` 的 `readPeResourceLeaves(bytes, typeId)`，icon 解析改为调用它 | 「不从零重写」：RT_ICON 与 RT_VERSION/RT_MANIFEST 共用一套遍历；`galgame_exe_icon_test.dart` 守住行为不变 |
| `fushi/lib/src/mining/galgame_audio_source.dart` | `EngineHookGalAudioSource` 加 `contentLanguage` 与可注入的 `japaneseLocaleNeedProbe`；`start()` 里先探测再 `resolveJapaneseLocale(need: …)`；`japaneseLocaleApplied` 旁加 `japaneseLocaleVerdict` | 命令行 `--japanese-locale` 与会话事实同源（BUG-1691 的纪律） |
| `gal_hook_session_controller.dart` | `GalEngineSourceFactory` / `_defaultEngineFactory` / `launchGame` 透传 `contentLanguage`；`GalHookSessionState` 加 `japaneseLocaleVerdict`；事件 `launch.japanese_locale_applied` 带 `need` + `evidence` | 三个启动点零额外查询：`GalgameEntry.language` 本来就在手上 |
| `games_library_page.dart` / `galgame_home_page.dart` / `texthooker_page.dart` | 三个启动点把 `entry.language` 一并传下去 | 同上 |
| 捕获工作台状态卡（BUG-1691 那块） | 「已转区」旁加「自动 · 证据：…」；`unknown` 未转区时显示「未转区 · 证据不足，乱码请改『始终开启』」 | 判错必须可见，用户才够得着兜底 |
| i18n（`fushi/tool/i18n_sync.dart --add`） | `game_session_japanese_locale_evidence_*`（11 条证据名）+ `game_session_japanese_locale_skipped_unknown` | 手改 json 禁止 |
| 测试 | `galgame_japanese_locale_test.dart`：真值表加 `need` 三态；新 `galgame_japanese_locale_probe_test.dart`：假名/GBK/UTF-8 简体合成文本、文件名分类、手工拼装最小 PE（.rsrc 含 RT_VERSION 0x0411 / 0x0804 与 RT_MANIFEST UTF-8）；`gal_japanese_locale_visibility_test.dart`：verdict 进会话、事件带证据；`galgame_exe_icon_test.dart` 不改断言 | 每条新守卫先变异实测 |
| `docs/bugs/BUG-NNNN-gal-locale-auto-need.md` | 记根因 + ①② | 一 bug 一文件 |

## 4. 影响范围 / 风险

- 行为变化只在 `auto` 档：`on` / `off` 不动；attach 路径不动；老数据空串仍回落 `auto`。
- **有意的行为变化**：中文系统上无任何日文证据的 32 位游戏不再转区（§1 决策）。BUG-1038 的样本（KiriKiri 2 日文体验版）exe 里有 Shift-JIS 串 + 0x0411 ⇒ 仍转区，回归用它验。
- 探测成本：读 exe ≤ 16 MB + 顶层目录一次 + ≤ 20 个小文本文件，启动前一次，毫秒级；失败（IO 异常）一律当 `unknown`，绝不阻塞启动。
- 不碰 native / injector / hook；`--japanese-locale` 的 CLI 契约不变。

## 5. 验证

- `flutter analyze`（含 test）零问题；定向 `flutter test test/mining test/database --no-pub`；目录枚举型守卫整批。
- 真机：用 `fushi_voice_injector.exe --launch` 同款参数在三个样本上核对命令行是否带 `--japanese-locale`，与 §2 表一致；工作台状态卡截图留证。
