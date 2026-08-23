## BUG-1787 · 字体库作用域参数不生效：从游戏入口导入的字体挂到小说正文

- **报告**：2026-08-23（用户：管理字体里"缺少游戏之类的"，"我记得近两个外部 pr 修复了这个问题，怎么没生效"）
- **真实性**：✅ 真 bug（三个独立缺陷叠在一起）

### 用户认知与实际的错位（先澄清，这部分不是 bug）

用户说的"近两个外部 PR"是 **#858**（2026-08-15 合入，commit 计数 9695）与 **#872**
（2026-08-16 合入，计数 9747）。两者都真实落在 develop 上，用户装的版本远在其后，
**代码确实在包里**。但它们做的是「**内容语言**」——给资源标语言，自动挑对应的 CJK
字体链（`resolveContentLanguage` / `content_font_chain.dart`），解决的是日文汉字被渲染
成中文字形。#872 标题里的"游戏"指给游戏条目指定语言，入口在**游戏库单个游戏的右键/
长按菜单**（`games_library_page.dart:851 _editGameLanguage`，菜单动作 `'language'` 在
`:1634`），**不在字体管理页**。

用户找的是字体库里「这个字体用在哪些用途」那排开关（`FontTarget`），那是另一个维度。

**用户口中的"近两个外部 PR"实际是这两条**（作者均为外部贡献者 W1ght，均 2026-08-22 合入）：
- **PR #938** `feat(galgame): 完成 Windows 浮窗与 SGRE 原始语音制卡链路`
  （`d945be5796`，计数 10043）——**正是它加的 `FontTarget.gameLookup`**，即字体库里
  「游戏查词窗口字体」那一项，以及「设置·游戏·Hook 文本字体」入口。
- **PR #941** `fix(galgame): 隔离 XAudio2 codec trampoline`。

⚠️ 注意 `gameLookup` 是 **2026-08-22** 才有的，**晚于** #858/#872。所以：
① 构建于 8-22 之前的包，字体库里本来就没有"游戏"这一项，与那两条内容语言 PR 无关；
② #938 做对了调用侧（认真传了 `target: FontTarget.gameLookup`），却栽在下面根因①的
类型退化上——**入口加了、参数传了、就是不生效**，这正是用户的观感来源。

另注：wrds 此前在 `feature/gal-hook-lyric-overlay-style` 上写过一版同类功能
（`3cf2a2ccb3`，枚举名 `galHookText`，键 `gal_hook_fonts`），**未合入 develop**，与 #938
的 `gameLookup` / `game_lookup_fonts` 是两套独立实现。若哪天要合那条分支，两个偏好键是
硬冲突，需要迁移而非改名；且 wrds 版的 native 默认字族 `Yu Gothic`（非 UI 版）与"默认
全宽假名"两项改动也没跟进到 develop。

### 根因（三条，都在"设了不生效"这一类）

**① 作用域参数是死参数** — `fushi/lib/src/pages/implementations/custom_fonts_page.dart`

`CustomFontsPage.target` 声明了、调用方也认真传了
（`settings_schema_game.dart:115` `CustomFontsPage(target: FontTarget.gameLookup)`），
但 `_CustomFontsPageState` **裸继承 `BasePageState`**（未填泛型实参）。
`BasePageState<T extends BasePage>` 的 `T` 因此退化成 `BasePage`，`widget` 的静态类型
跟着退化，`widget.target` 在 State 里**编译期就不可达**——不是"忘了用"，是**用不了**。

于是四个新增字体的入口全部硬编码 `targetEnabled: {FontTarget.body: true}`：
`_addSingleFont`、`_extractFontsFromArchive`（override 与批量两支）、`_addSystemFont`。

实际后果：用户从「设置·游戏·Hook 文本字体」进字体库、导入一个字体 → 该字体挂到
EPUB 正文 → 游戏 hook 台词浮窗一直不变。这就是"字体库里缺游戏 / 设了不生效"。

**② 用途开关默认折叠，"游戏"这一项看不见** — 同文件 `_CustomFontCatalogTileState`

`_rolesExpanded = false`，折叠态只显示**已启用**用途的摘要（`_rolesSummary`）。没启用过
就等于这个选项不存在，用户扫一眼确实"没有游戏"。

**③ WOFF/WOFF2 勾游戏用途静默失效** — `fushi/lib/src/models/app_font_loader.dart`

`resolveForNativeOverlay` 只接受 `.ttf/.otf/.ttc`（native 分层窗的 DirectWrite 本地文件
API 吃不下 WOFF/WOFF2），不可用项直接 `continue`。而 Flutter 侧的 `_resolveEntry` 能解码
WOFF/WOFF2。同一个字体在正文/界面/词典生效、在"游戏查词"悄悄落回 Yu Gothic UI，
UI 上零反馈。

**附带发现（非本 bug 主线，一并修）**：`FontTarget.gameLookup` 的枚举注释写它覆盖
"click-to-lookup overlay" 是**错的**——游戏内查词卡走 `FontTarget.dictionary`
（`popup_settings_injection.dart:163`，与 app 内词典弹窗同源），`gameLookup` 只覆盖
hook 台词浮窗。照旧注释接线会接错。守卫
`test/reader/font_targets_wiring_guard_test.dart:128-130` 其实已钉死这条分界。

### 另有三个渲染面根本没接字体库（用户"支持一下各个地方"的实质）

| 渲染面 | 此前 | 现在 |
|---|---|---|
| texthooker 游戏文本页（台词 + 逐字命中区） | 跟 `ThemeData` 主题字体 = appUi 链，与 hook 浮窗两套字体 | 接 `FontTarget.gameLookup` |
| 视频字幕列表侧栏 | 无 `fontFamily`，画面上是字幕字体、列表里是界面字体 | 接 `FontTarget.videoSubtitle` |
| 有声书歌词模式 | 硬编码 `"Noto Serif JP","Noto Sans JP",serif`，同一本书切视图就换字体 | 接 `FontTarget.body`（注入 `@font-face`），原 Noto 链保留兜底 |

- **[x] ① 已修复** — `739b60964d`（填上 `BasePageState<CustomFontsPage>` 泛型实参，
  target 自然可达，无需任何 cast；四处硬编码收敛成单一 `_newFontTargets()`；非默认
  作用域进来时用途开关出生即展开）、`e21fd75180`（三个渲染面接回各自 target +
  `nativeOverlayCanUse` 判据由 loader 与 UI 共用 + `isFontTargetAvailableOnPlatform`
  平台门 + 纠正枚举注释）、`b84561db09`（带作用域时把用途写进页面标题）、
  `8fd115446e`（置灰原因改用现有 i18n key，避免重排 `strings.g.dart`）。
  用户未设字体时所有链路逐字节等于改动前。

- **[x] ② 已加自动化测试** — `fushi/test/pages/custom_fonts_scope_guard_test.dart`
  （`a1785945bc`，6 条断言）。旧守卫
  `test/settings/game_overlay_appearance_settings_guard_test.dart:30` 只断言源码里出现
  `'CustomFontsPage(target: FontTarget.gameLookup)'` 这串字面量——**传参被断言了、消费
  没有**，整个缺陷从它眼皮底下过去。新守卫补的正是缺的那一半：泛型实参在、不得再出现
  硬编码 `FontTarget.body: true`、`_newFontTargets()` 必须由 `widget.target` 派生、
  四个入口计数锁 4、平台过滤只影响显示（回写仍 `FontTarget.values` 全量）、格式判据
  由 loader 与 UI 共用。结构断言全部在 `maskComments` 剥注释后的代码上做。

  **变异实测**：把 `_addSystemFont` 的 `_newFontTargets()` 改回硬编码
  `{FontTarget.body: true}` → 守卫红，两条断言同时命中（硬编码检测 + 入口计数 4→3）；
  回滚后 sha256 与变异前逐字节一致
  （`d4e55ea345f055d2c51119546bd5a9053c7c318cde805e4e42097a5b6fdd5c4d`），守卫恢复 6/6 绿。

### 备注

- **未做（有意，待产品决策）**：**弹幕**是全仓唯一连界面字体都不继承的文本面
  （`video_danmaku_text_metrics.dart:30` `inherit: false`）。那个 flag 是**几何正确性的
  一部分**而非风格偏好：测量侧是纯函数、拿不到主题，两边一漂开，弹幕就会没滑出屏幕
  被判过期而突然消失。要接字体必须连测量缓存键一起改，且"弹幕该不该跟字幕字体"产品
  语义不明确（弹幕 ≠ 字幕），故未擅自改。
- **同样未做**：浏览器扩展查词浮窗（硬编码 `:lang()` 链且**无字体下发通道**，
  `app_model.dart` 的 `browserExtensionThemeColors()` 只发颜色/圆角/尺寸）、句子分享图
  导出（硬编码 Noto）、Android 悬浮歌词（`FloatingLyricService.java:133`
  `Typeface.DEFAULT`）、`FloatingLyricWindow` 的另两个实例（有声书悬浮歌词条 / 剪贴板
  文本窗，native 侧恒 `Yu Gothic UI`）。各自需要新开下发通道，超出本轮范围。
- **`gameLookup` 只吃第一条可用项**（`resolveForNativeOverlay` 首个命中即 return），
  缺字回退靠 native 追加的系统字体集，**不是**用户列表里的第 2 条——与 `appUi` 的整链
  语义不一致。native 侧要支持整链需改 DirectWrite 私有集合构建，未做。
- **未真机复测**：本轮属 UI/字体链改动，代码正确 + 全量单测无回归，但未在 Windows
  真机走"游戏设置 → 导入字体 → 起游戏看 hook 浮窗"的原始失败路径留截图证据。
- 验证：改动前 `develop` 基线全量 **20265 测试全绿**；36 条目录枚举型守卫整批
  **250 测试全绿**（等于文档记录基线）；rebase 到 `42af53252f` 后 `flutter analyze`
  全量（含 test）No issues。
