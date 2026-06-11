# Hibiki 快捷键清单（TODO-048a 统计）

> 生成：2026-06-11，base develop@d94197419。本文件是「当前实际生效的快捷键 + 手柄
> + 鼠标绑定」的盘点，供 TODO-048（统计并优化快捷键）使用。**本清单只统计，不改任何
> 绑定行为**；发现的冲突/重复/缺失列在末尾「待优化」，改绑定属行为变更，须用户确认。
>
> 快捷键分两类来源：
> 1. **可配置注册表**（`ShortcutAction` + `ShortcutDefaults` + `HibikiShortcutRegistry`，
>    用户可在「快捷键设置」页改键）—— reader / home / global / audiobook 四个 scope。
> 2. **硬编码**（视频播放器、全局 Esc/方向键焦点、有声书 Space 覆写、阅读方向翻页覆写）
>    —— 不进注册表，用户改不了。

---

## 1. 可配置注册表（桌面默认，`shortcut_defaults.dart` `_desktop`）

> macOS 把所有 `Ctrl` 自动换成 `Cmd`（`_macOS`）；移动端只保留手柄/鼠标绑定，去键盘
> （`_mobile`）。下表是桌面键盘 + 手柄默认值。

### reader scope（阅读器页面解析 reader + audiobook）

| Action | 键盘默认 | 手柄默认 | 功能 |
|---|---|---|---|
| readerPageForward | PageDown / → / ↓ / Space | RB, D-pad右 | 下一页 |
| readerPageBackward | PageUp / ← / ↑ / Shift+Space | LB, D-pad左 | 上一页 |
| readerToggleChrome | M | Y | 切换底栏 |
| readerDismissDict | Esc | B | 有弹窗关弹窗，否则退出书 |
| readerToggleBookmark | Ctrl+D | X | 切换书签 |
| readerToggleFurigana | （无键盘默认） | R3 | 切换振假名 |

### home scope（首页解析 home + global）

| Action | 键盘默认 | 手柄默认 | 功能 |
|---|---|---|---|
| homeTabBooks | Ctrl+1 | — | 跳「书架」tab |
| homeTabDict | Ctrl+2 | — | 跳「查词」tab |
| homeTabSettings | Ctrl+3 | — | 跳「设置」tab |
| homeTabPrev | （无键盘默认） | LT | 上一个 tab |
| homeTabNext | （无键盘默认） | RT | 下一个 tab |
| homeFocusSearch | Ctrl+F | Y | 聚焦搜索框 |

### global scope（非阅读器页通用）

| Action | 键盘默认 | 手柄默认 | 功能 |
|---|---|---|---|
| globalBack | Alt+← | —（手柄留空，避免被 reader B 遮蔽） | 返回上一级 |
| globalScrollPageDown | （无键盘默认） | RB | 整页下滚 |
| globalScrollPageUp | （无键盘默认） | LB | 整页上滚 |

### audiobook scope（有声书激活时，在 reader scope 之后解析）

| Action | 键盘默认 | 手柄/鼠标默认 | 功能 |
|---|---|---|---|
| audiobookPlayPause | Ctrl+Space | L3（手柄） | 播放/暂停 |
| audiobookNextSentence | Ctrl+→ | —（RB/LB 已被 reader 翻页占用会被遮蔽） | 下一句 |
| audiobookPrevSentence | Ctrl+← | — | 上一句 |
| audiobookSeekToClickedSentence | — | 鼠标中键（位置型，走 onPointerSeek） | 点句跳转并播放 |

> scope 解析顺序的关键约束（`shortcut_action.dart` coactiveScopes）：reader 页按
> `[reader, audiobook]` 顺序解析，home 页按 `[home, global]`。同一物理键在共活 scope
> 里只会触发一个，后面的 scope 会被静默遮蔽——所以默认值刻意给被遮蔽位置留空（注释
> 已说明，如 audiobookNextSentence 不绑 RB/LB、globalBack 不绑手柄）。

---

## 2. 硬编码快捷键（不进注册表，用户改不了）

### 2a. 视频播放器（`video_player_shortcuts.dart` `buildVideoPlayerShortcuts`）

> **这一节属 TODO-048b（视频组）的优化对象，本任务只统计不改。** 当前是 asbplayer 风格
> 硬编码键，CallbackShortcuts 安装在 video 页（`video_hibiki_page.dart:1697`）。

| 键 | 功能 |
|---|---|
| Space / P / MediaPlayPause | 播放暂停切换 |
| MediaPlay / MediaPause | 播放 / 暂停 |
| ← / A / J | 时间后退（seekBackward） |
| → / D / I | 时间前进（seekForward） |
| Ctrl+← / Ctrl+→ | 上一句 / 下一句字幕 |
| Shift+F | seekForward（**与 F=全屏冲突，见待优化**） |
| C | 切换着色器对比 |
| ↑ / 0 | 音量+ |
| ↓ / 9 | 音量- |
| M | 静音切换 |
| [ / - | 减速 |
| ] / = | 加速 |
| Backspace | 速度复位 |
| , / . | 上一帧 / 下一帧 |
| S | 截图 |
| F | 切换全屏 |
| Esc | 退出（退全屏或退页） |
| B | 切换字幕模糊（`video_hibiki_page.dart:3305`，内层 CallbackShortcuts，asbplayer 同款） |

### 2b. 全局焦点/导航（`global_navigation.dart`，仅实验性焦点导航开启时）

| 键 | 功能 |
|---|---|
| Esc（在 Navigator 之上） | 退出全页路由层级（`_handleGlobalEscape`，只 pop PageRoute，不动 popup） |
| 方向键（单行文本框聚焦时按上/下，press 边） | 逃出文本框焦点（框架把方向键全吞成 caret intent 的补救） |
| 方向键（无文本框聚焦，OS 自动重复 KeyRepeat） | 持续移动焦点（带面板几何 + 阅读顺序回退） |
| 裸 Space | 中和为 DoNothingIntent（不触发激活，焦点确认统一走 Enter / 手柄 A） |

### 2c. 有声书 Space 覆写（`reader_space_override.dart`）

| 条件 | 覆写 |
|---|---|
| 有声书激活 + 无修饰 + Space | 翻页 → 改为 audiobookPlayPause（媒体播放器惯例） |

### 2d. 阅读方向翻页覆写（`reader_space_override.dart` resolveReaderArrowPageTurn，BUG-098）

| 条件 | 覆写 |
|---|---|
| 竖排 RTL（日文默认）+ 无修饰 ← | readerPageForward（下一页在左） |
| 竖排 RTL + 无修饰 → | readerPageBackward |
| 横排 LTR + 无修饰 ←/→ | 后退 / 前进（默认方向） |

### 2e. 查词弹窗

弹窗自身（`assets/popup/popup.js`）无键盘快捷键；关闭走 Flutter 层（reader 的 Esc→
readerDismissDict 关栈顶弹窗 / 全局 Navigator pop / 手柄 B）。

---

## 3. 待优化（发现的冲突/重复/缺失，报 PM，不擅自改）

### 冲突（需 048b 视频组确认后改）

- **视频 `F` 双绑**：`F` = 切换全屏（line 88），`Shift+F` = seekForward（line 69-71）。
  Shift+F 与裸 F 不是同一 activator 故不会硬撞，但 `F`/`Shift+F` 语义割裂（一个全屏一个
  快进）容易误触，建议 048b 统一。
- **视频 seek 键重复**：`←`/`A`/`J` 三键都是 seekBackward，`→`/`D`/`I` 三键都是
  seekForward。功能正确但键位冗余，asbplayer 兼容性保留可，048b 决定是否精简。

### 重复（同 scope 多键绑同一动作，属设计，非 bug）

- reader 翻页：PageDown/→/↓/Space 四键都前进、PageUp/←/↑/Shift+Space 四键都后退——
  这是注册表里的设计冗余（覆盖多种习惯），非冲突。

### 缺失（注册表里手柄默认刻意留空，因 scope 遮蔽）

- audiobookNextSentence / audiobookPrevSentence 无手柄默认（RB/LB 被 reader 翻页占用，
  绑了也会被遮蔽，注释已说明）。这是正确的「不绑被遮蔽位」，非缺陷。
- globalBack 无手柄默认（reader B 已是 readerDismissDict）。同上。

### 注册表外无统一入口

- 视频播放器快捷键（2a）整套硬编码，**不进「快捷键设置」页**，用户无法自定义。把视频
  键纳入可配置注册表是 048b 的潜在工作（本任务不做）。
