# 中键点击 seek 音频到对应位置（书籍 + 歌词模式）设计

日期：2026-06-06
分支：`worktree-mid-click-seek`

## 需求

有声书阅读时，用**鼠标中键**点击正文/歌词里的某句，让音频播放头**跳到该句对应的播放点并从该句开始播放**。左键已被划词查词占用，故用中键。同时支持**普通阅读器（Sasayaki 原生 EPUB + 合成书）**和**歌词模式**。触发键进入可配置快捷键体系（但编辑页继续保持隐藏）。

### 已确认决策

1. **Seek 行为**：跳转并从该句开始播放（复用 `playCueAndContinue(cue)`，无论之前播放/暂停）。
2. **可配置粒度**：扩展快捷键体系新增鼠标按键绑定（默认中键），进注册表持久化；`ShortcutSettingsPage` 入口**维持注释隐藏**，配置仅经默认值 + JSON。
3. **歌词定位单位**：整句（cue 起点）。

## 现状（复用基础）

- 有声书 seek 收口：`packages/hibiki_audio/lib/src/audiobook/audiobook_controller.dart` — `skipToCue(cue)`:604 / `playCueAndContinue(cue)`:673（skipToCue + 播放，正是需求行为）。
- 合成书已有「点击句子从本句播放」：`[data-cue-id]` → `onCueTap`（`reader_hibiki_page.dart:1945`）→ `playCueAndContinue`。仅合成书生效。
- Sasayaki cue↔DOM 映射已建：`reader_pagination_scripts.dart` 的 `cueRangesMap`（cueId→Range[]，:433）/ `cueWrappers`（cueId→span[]，:452）。
- 歌词模式 cue 标记现成：`.cue` 元素带 `data-cue-index`（`lyrics_mode_html.dart:30`），`__lyricsCueContext`/`__lyricsScrollToCue` 可用。
- 中键当前完全空闲：正文 `pointerdown` 硬过滤 `e.button!==0`（`reader_hibiki_page.dart:1661-1668`）；歌词用标准 `click`（中键不触发）。中键必须在 JS 层拿（WebView 吞掉 Flutter 指针）。
- 快捷键体系：`lib/src/shortcuts/`（`shortcut_action.dart` / `input_binding.dart` / `shortcut_defaults.dart` / `shortcut_registry.dart`），键盘+手柄，per-profile JSON 持久化（`shortcut_bindings_json`）。**当前无鼠标按钮概念**。设置入口在 `settings_schema.dart:758-764` 被注释隐藏。

## 核心选型：Sasayaki「点击位置 → cue」反查

唯一真缺口（合成书/歌词已有 cue 标记）。

**方案 A（采用）— 复用已有 cue↔DOM 映射做包含判定。** 新增 JS 原语 `hoshiReader.cueIdAtPoint(x,y)`：
1. `getCaretRange(x,y)`（`reader_selection_scripts.dart:139`）拿折叠 Range（textNode + offset）。
2. 优先 `closest('[data-cue-id]')` —— 命中合成书 cue，直接回传其 cueId（sentenceIndex）。
3. CSS Highlight 路径：遍历 `cueRangesMap`，用 `range.compareBoundaryPoints` 判定 caret 点落在哪个 cue 的 Range 区间内 → 回传 cueId。
4. Wrapper 路径：`caret.node` 向上 `closest('.hoshi-sasayaki-cue')`，取 span 上记录的 cueId → 回传（应用 cue 时把 cueId 写到 wrapper 的 `data-cue-id` 属性，供反查）。
5. 都不命中回 null。

回传的 cueId 用「下发 cue 时已有的 cueId↔AudioCue 映射」（与 `highlightSasayakiCue(cueId)` 同一套）在 Dart 反查得到 `AudioCue`。**新代码只有一个 JS 函数 + 一个 Dart handler，不碰归一化码点偏移数学**（规避 BUG-060 类码点代理对错位）。

方案 B（弃用）：重建 normChar 反查（点击偏移 → 归一化全局码点 → `cueForNormOffset` 解码 `ns/ne` 命中），更多新代码、易错、无收益。

## 设计分模块

### 1. 按键绑定建模（进体系，编辑页仍隐藏）

- `input_binding.dart`：新增 `MouseBinding`（`final int button` + modifiers），不可变值类型 + `==`/`hashCode` + `toJson`/`fromJson`（沿用现有 label 序列化范式，鼠标按钮序列化为 `Mouse1`/`Mouse2`/... 之类稳定 label）。给 `ShortcutBindingSet` 加 `List<MouseBinding> mouse`（默认空），并入 `toJson`/`fromJson`（旧 JSON 无该字段时默认空，向后兼容）。
- `shortcut_action.dart`：`ShortcutAction` 枚举新增 `audiobookSeekToClickedSentence`（scope=`audiobook`，稳定 key 字符串）。
- `shortcut_defaults.dart`：桌面 + 移动默认 map 给该动作 `mouse: [MouseBinding(button:1)]`（中键）；键盘/手柄留空。
- `shortcut_registry.dart`：新增 `ShortcutAction? resolveMouse(int button, Set<modifiers>)`，镜像 `resolveKeyboard`。
- `shortcut_settings_page.dart`：`_actionLabel`（:13）补 case；新增 i18n key `shortcut_action_audiobook_seek_clicked`（经 `tool/i18n_sync.dart` 加 17 语言 → `dart run slang`）。**设置入口（`settings_schema.dart:758-764`）维持注释隐藏。**

### 2. 运行时（鼠标键是位置型，不走位置无关的 `_executeShortcutAction`）

- **正文 JS**（`reader_hibiki_page.dart:1661` 旁）：新增对非左键（button 1/2）的 `pointerdown`/`auxclick` 监听 → `preventDefault()`（压中键自动滚动）+ `callHandler('onPointerSeek', button, x, y)`。
- **正文 JS 原语**（`reader_pagination_scripts.dart`）：实现 `hoshiReader.cueIdAtPoint(x,y)`（见上）。应用 Sasayaki cue 时给 wrapper 写 `data-cue-id` 以便反查。
- **正文 Dart**（`reader_hibiki_page.dart` JS handler 注册区 :1821-1879 一带）：新增 `onPointerSeek` handler → `registry.resolveMouse(button, mods)`；命中 `audiobookSeekToClickedSentence` 才 `evaluateJavascript(cueIdAtPoint(x,y))` → cueId → 反查 `AudioCue` → `controller.playCueAndContinue(cue)`。未命中绑定或未命中 cue 直接忽略。
- **歌词模式**（`lyrics_mode_html.dart:195`）：标准 `click` 不触发中键，新增 `auxclick`（或 `pointerup` 判 `e.button===1`）监听 → `e.target.closest('.cue')` 取 `data-cue-index` → 复用 `onPointerSeek` 桥（带 cueIndex 而非坐标，或单独 `onLyricsPointerSeek`）→ Dart 侧 `playCueAndContinue(_lyricsCueList[idx])`。

### 3. 数据流

```
中键 down (button=1) ──JS──▶ preventDefault + callHandler('onPointerSeek', 1, x, y)
                                    │
                              Dart onPointerSeek
                                    │ resolveMouse(1) == audiobookSeekToClickedSentence ?
                                    │ 否 → ignore
                                    │ 是
                          ┌─────────┴──────────┐
                     正文(reader)          歌词(lyrics)
                          │                    │
              evaluateJS cueIdAtPoint(x,y)   data-cue-index(已在JS取)
                          │                    │
                       cueId               cueIndex
                          │                    │
              Dart: cueId↔AudioCue 反查    _lyricsCueList[idx]
                          └─────────┬──────────┘
                                    ▼
                      controller.playCueAndContinue(cue)
```

### 4. 错误处理 / 边界

- 无有声书激活（`controller == null` 或未加载）：handler 直接 return，不报错。
- `cueIdAtPoint` 返回 null（点到空白/非 cue 区域）：忽略，不 seek。
- cueId 在 Dart 侧反查不到（DOM 与快照不一致的瞬态）：忽略。
- 中键 `preventDefault` 仅对绑定按钮生效，避免误伤右键上下文菜单（若绑定为右键由配置决定）。
- 旧持久化 JSON 无 `mouse` 字段：`fromJson` 默认空列表，注册表回退默认值，向后兼容。

## 测试

- **单元**（最强可落地层）：
  - `MouseBinding` toJson/fromJson round-trip + `==`/`hashCode`。
  - `ShortcutBindingSet`（含 mouse）round-trip；旧 JSON（无 mouse）解析为空列表。
  - `HibikiShortcutRegistry.resolveMouse` 命中/未命中。
  - `ShortcutDefaults.forPlatform` 桌面含 `audiobookSeekToClickedSentence` 默认中键。
- **Dart 行为**：mock 注册表 + 控制器，`onPointerSeek(button=1)` 命中绑定时调 `playCueAndContinue`；非绑定按钮（如 button=2 未绑定）不调；无控制器时不报错。
- **源码扫描守卫**：正文 JS 中键监听 + `cueIdAtPoint` + 歌词 `auxclick` 接线存在（防回归被改回 `button!==0` 过滤）。
- **真机三表面**（Sasayaki / 合成书 / 歌词）中键 seek+播放 —— 留待用户设备复测。

## 向后兼容

- 中键当前完全空闲；左键查词不受影响；歌词标准 `click` 查词不受影响。
- 设置编辑页维持隐藏，不新增可见 UI。
- 旧 shortcut JSON 向后兼容（mouse 字段缺省空）。
- 零破坏现有功能。

## 影响文件清单

| 文件 | 改动 |
|---|---|
| `lib/src/shortcuts/input_binding.dart` | 新增 `MouseBinding` + `ShortcutBindingSet.mouse` |
| `lib/src/shortcuts/shortcut_action.dart` | 新增 `audiobookSeekToClickedSentence` |
| `lib/src/shortcuts/shortcut_defaults.dart` | 默认中键绑定 |
| `lib/src/shortcuts/shortcut_registry.dart` | `resolveMouse` |
| `lib/src/pages/implementations/shortcut_settings_page.dart` | `_actionLabel` case |
| `lib/src/reader/reader_pagination_scripts.dart` | `cueIdAtPoint` + wrapper 写 cueId |
| `lib/src/pages/implementations/reader_hibiki_page.dart` | JS 中键监听 + `onPointerSeek` handler |
| `lib/src/media/audiobook/lyrics_mode_html.dart` | `auxclick` 中键监听 |
| `lib/i18n/*.i18n.json` + `strings.g.dart` | `shortcut_action_audiobook_seek_clicked`（经 i18n_sync + slang） |
| 测试文件 | 单元 + 行为 + 源码扫描守卫 |
