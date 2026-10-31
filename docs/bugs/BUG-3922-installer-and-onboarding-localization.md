## BUG-3922 · 安装器只有中文、onboarding 部分文字没翻译
- **报告**：2026-10-31（issue #2716：非中文系统用户反馈 Windows 安装器整屏中文、首次启动向导有些地方没翻译）
- **真实性**：✅ 真 bug。安装器根因 `fushi/windows/installer/fushi.iss` 的 `[Languages]` 只有 `chinesesimplified` 一项 + 不带语言前缀的 `[Messages]` + `[Code]` 写死中文 + Inno 默认 `UsePreviousLanguage=yes`；onboarding 根因是 39 个 `onboarding_*` key 在 15 种语言里存的是英文原文，外加 `fushi/lib/src/pages/implementations/onboarding_wizard_page.dart` 的 `_ankiBackendLabel` 对所有语言写死全角括号 `AnkiConnect（host:port）`
- **[x] ① 已修复** — 安装器：`[Languages]` 扩到与 app 一一对应的 17 种（english 第一）、`LanguageDetectionMethod=uilanguage` / `ShowLanguageDialog=auto` / `UsePreviousLanguage=no`、文案全部搬进 `fushi/windows/installer/messages.iss`（`[Messages]` 一律带前缀，`[CustomMessages]` 英文兜底 + 每种语言一份）、官方安装包不带的 4 个 `.isl` 入库到 `fushi/windows/installer/languages/`；MD3 布局按钮宽度按当前语言文字量出（德语原先被裁）、Show 之后重排的路径行在 RTL（阿拉伯语）下自行镜像（原先「浏览」按钮跑到窗口外）。onboarding：补齐 15 种语言的译文，新 key `onboarding_anki_backend_ankiconnect` 把括号排版交给各语言
- **[x] ② 已加自动化测试** — `fushi/test/build/windows_installer_languages_guard_test.dart`（语言清单 ↔ `lib/i18n`、语言选择三条设置、语言文件来源、每种语言消息键齐全且非英文原文、`[Messages]` 必带前缀、`[Code]` 无 CJK 字面量，含合成语料自校验）；`fushi/test/i18n/onboarding_localization_guard_test.dart`（向导用到的 key 在每种语言里不得仍是英文原文、向导源码无可见位置写死文字与 CJK 字面量）
- **备注**：语言怎么选——Inno 调 `GetUserDefaultUILanguage`，先按 LanguageID 精确匹配，再按主语言匹配（列表中第一个主语言相同的项；所以繁体排在简体前面，zh-HK/zh-MO 走主语言命中繁体，代价是 zh-SG 也落到繁体），都匹配不上才弹语言选择框、默认 english。离屏预览（`fushi/tool/preview_installer.ps1 -Language <name>`）实测了本机 zh-CN 自动检测与 english / japanese / arabic / german / russian / chinesesimplified 强制指定；没在真实非中文 Windows 上跑过自动检测。阿拉伯语目录页的「所需磁盘空间」一行在 RTL 下不显示（修复前同样如此），未处理。

### 根因

1. `[Languages]` 只列 `chinesesimplified`，Inno 没有别的语言可选。
2. `[Messages]` 段的条目不带语言前缀，Inno 会把它们套到**所有**语言上——即使加了别的语言，页面标题仍是中文。
3. `[Code]` 里数据目录页、MD3 页眉、五个校验提示框、文件被占用提示全是中文字面量。
4. Inno 默认 `UsePreviousLanguage=yes`：在卸载注册表里记下上次的语言，下次（含静默升级）直接套用。旧版只可能记下简体中文，自动检测对存量用户永远不生效。

onboarding：i18n_sync `--add` 只写 en / zh，其余语言先填英文；`i18n_completeness_test` 只查 key 齐不齐，查不出「值就是英文」。
