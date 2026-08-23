## BUG-1691 · 转区静默生效解坏多语言版游戏文字，用户无从发现
- **报告**：2026-08-16（用户：wrds）
- **真实性**：✅ 真 bug（转区静默生效 + 不可见）。根因 `fushi/lib/src/mining/galgame_japanese_locale.dart:104`（`auto` 判据 = 系统 ACP≠932 且目标 32 位）+ `fushi/lib/src/mining/galgame_audio_source.dart:1279`（结果只喂给 injector，从不向上暴露）。
- **[x] ① 已修复** — 让「本局是否转区」成为会话事实并显示出来：`EngineHookGalAudioSource.japaneseLocaleApplied` 在算出判据的同一处记账；`GalHookSessionController.launchGame` 写入 `GalHookSessionState.japaneseLocaleApplied` 并记 `launch.japanese_locale_applied` 事件（注入失败降级也照写——游戏进程已经在 CP932 下跑着了）；捕获工作台状态卡窄屏显示短标记、宽屏追加可执行处置（提示去把该游戏的日语区域改成「永不转区」）。提交见下。
- **[x] ② 已加自动化测试** — `fushi/test/mining/gal_japanese_locale_visibility_test.dart`（8 例）：锁定 `auto` 判据四格（中文系统+32 位⇒转区 / 日文系统⇒不转 / off 兜底 / attach 短路）、转区会话置位并记事件、未转区不置位不记事件、会话停止后复位、`copyWith(clearLaunchExe:)` 复位。**变异实测**：把 `japaneseLocaleApplied: engine.japaneseLocaleApplied` 改成恒 `false` → 2 例转红（exit 1）；反向替换还原后 sha256 与变异前逐字节一致（`87bf5a80…6595`）。

### 现场证据（2026-08-16，TenShiSouZou_R18 / KiriKiri ver1.12 / 本机 ACP=936、游戏 x86）

Fushi 启动该游戏时 injector 命令行实际带着 `--japanese-locale`：

```
fushi_voice_injector.exe --launch ...\tenshi_sz.exe --hold --wait-ms 30000 --japanese-locale --workdir ... --luna-hook-profile ...
```

单变量对照（同一条命令，只增删 `--japanese-locale`），差异出现在窗口标题：

| | 窗口标题 | 中文 UI | 切日文 UI |
|---|---|---|---|
| 带 `--japanese-locale` | `天使☆騒**器** RE-BOOT!` | 标题栏乱码 | 恢复正常 |
| 不带 | `天使☆騒**々** RE-BOOT!` | 正常 | 正常 |

「々」被解成「器」= 拿 CP932 解 GBK 字节的典型症状。这是**多国語版**（中/英/日，`plugin/getLangName.dll`），本来就不需要转区，而 `auto` 在中文系统 + 32 位目标上必然给它转区。

### 边界：没有改判据本身

`resolveJapaneseLocale` 的注释已经论证过 `auto` 不可能总判对（exe 位数与文本编码之间没有因果关系），真正兜底的是用户手动选 `off`。本次修的是「兜底够不着」——判错之后用户在任何界面都看不到 Fushi 改了区域，也就无从想到去关它。

收紧判据（例如把 KiriKiri 的 `getLangName.dll` 当作「内建多语言 ⇒ 不转区」的负向信号）**没有做**：手头样本只有 3 个（天使☆騒々 两个版本都有该 DLL；日文原版「屋上の百合霊さん」没有 plugin 目录），不足以排除误伤日文原版的风险。要做需要先补样本。

### 未复现的部分（不要当成本条已覆盖）

同日用户报了一个 KiriKiri 致命错误，**未能复现**，因此没有归因给转区：

```
{{Script}} load.ks(21)
{{Exception}} Cannot convert the variable type ((void) to Object)
{{Trace}} uiloader.tjs(1)[uiloadWithFuncTable] <-- uiload <-- system.tjs <-- conductor.tjs[onTag] <-- timerCallback
```

用户路径：切界面语言 → 调整左上角文本语言 → 点继续游戏。转区状态下按该路径尝试：语言切换 6 轮、UI 画面遍历 18 次（载入/流程图/鉴赏/系统设定）、切换后 0.3s 内立刻点继续 6 轮、双语（主要=日语 + 字幕=简体中文，已确认生效）路径 6 轮，均未触发。留待带更精确时序/存档状态的复现。
