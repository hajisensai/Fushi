# 视频沉浸模式：点画面显字幕 + 沉浸布局（设计案）

> 状态：草案 v2（2026-10-25 与所有者讨论后修订：去掉「沉浸时字幕」三档覆盖设置与常驻拇指栏，改为「点画面显形」开关 + 独立的沉浸布局）。
> 来源：2026-10-25 用户群讨论（手机看视频查词难受、没法单手操作；有人靠沉浸模式 + 开字幕看，提议「沉浸模式点一下出字幕」「右手放前后句 + 收藏按钮」）。

## 1. 用户在说什么

| 原话（摘要） | 背后的诉求 |
|---|---|
| 手机看视频查词难受 / 没法单手操作 | 横屏握持时学习动作（跳句、收藏）要么在底栏（得先点出控制条），要么只有键盘 / 手柄能按 |
| 用沉浸模式开字幕看，不然查词太麻烦 | 沉浸锁把触摸误触挡掉，点字幕只会查词——这已经是「手机学习模式」的事实用法 |
| 沉浸模式点一下出字幕 | 先听、听不懂再看：字幕平时遮住，点一下画面出这一句 |
| 听不懂的那句就收藏 / 右手那边放前后句加收藏 | 沉浸态下也要有一两个拇指够得着的学习按钮 |

## 2. 现状（代码事实）

1. **沉浸锁**：`_immersiveLocked`（`video_fushi_page.dart` `_toggleImmersiveLock`），按 `VideoImmersiveMode`（`full` / `shortcutAndLookup`（默认）/ `lookupOnly` / `unlockOnly`）放行，门控 getter `_immersiveAllowsFullControls` / `_immersiveAllowsShortcuts` / `_immersiveAllowsDoubleTapSeek` / `_immersiveAllowsLookup`。
2. **沉浸态屏幕上只剩锁按钮**：`layout.part.dart` `_buildVideoSideRailFor(immersiveOnly: true)` 把左右侧栏过滤成只渲染 `immersiveLock`；锁按钮在顶 / 底栏时（沉浸态顶底栏整个被压掉），退回 `_buildSideLockButton` 画在左侧居中。两条路径都由 `_withImmersiveLockAutoHide` / `_lockButtonVisible` 管显隐：点画面唤出、2s 淡出。
3. **按钮与动作都已存在**：`VideoControlItem.previousCue` / `nextCue` / `replayCue` / `favoriteSentence`，动作 `_replayPreviousCueAndKeepControls` / `_replayCurrentCueAndKeepControls` / `_toggleFavoriteCurrentCue`（已遵守 BUG-2030 / BUG-931：不唤起控制条）。
4. **字幕遮蔽**：`VideoSubtitleObscureMode{none, blur, hide}` + `VideoSubtitleOverlay` 的 `blurEnabled` / `subtitleHidden`；暂停 / 查词浮层开着时自动显示（BUG-2198 / BUG-2235）；全局「遮蔽态允许临时显形」`obscureRevealOnInteraction`（BUG-2256）。
5. **移动端显形只能点字幕盒本身**：遮蔽态热区 `Key('video-subtitle-reveal')` 只盖字幕盒；隐藏态字幕盒是透明的，等于让用户盲点。点中后 `_tapRevealed` 保持到 cue 换轮。
6. **沉浸态点画面几乎无事可做**：`_handleVideoPointerUp` 只 `_pokeLockButton()`；非 `full` 档双击 seek 也被挡。

## 3. 方案

### 3.1 沉浸态点画面显字幕（P1）

**新设置**「沉浸时点画面显示字幕」（视频设置 › 沉浸模式分组，开关，**默认开**，偏好键 `video_immersive_tap_reveal`）。

生效条件（全部成立）：沉浸锁定 ∧ 本开关开 ∧ 主字幕当前处于遮蔽态（`blur` / `hide`）∧ 全局「遮蔽态允许临时显形」开。最后一条沿用 BUG-2256「显形的全部来源一起门控」：用户关掉临时显形，就是不想被任何方式唤出来。

行为：
- 点画面任意位置（不含落在按钮 / chrome 上的点击）= 显形当前主字幕。接线点在 `_handleVideoPointerUp` 现有 chrome / 侧栏 / 选集横轨三道早返回之后、双击判定之前；`_pokeLockButton()` 照旧（锁按钮同时亮出来）。
- overlay 新增页面持有的显形句柄（与 `hitTester` 同范式，`VideoSubtitleRevealController`），内部复用 `_setRevealed(..., byTap: true)`：显形保持到 cue 换轮，换句自动遮回；已显形时再点 = 遮回（误点可撤销）。
- 只显形主字幕；副字幕（翻译）照旧按自己的遮蔽与 `secondaryObscureRevealOnInteraction`。
- 显形后字符才登记查词命中（现有逻辑），手势链是「点画面看一眼 → 点那个字查词」。
- 单击立即显形，不为等双击加延迟；`full` 档双击左右区 seek 照旧，首击顺带显形无害。
- 判据写成纯函数 `videoImmersiveTapRevealsSubtitle({locked, enabled, obscured, revealOnInteraction})`，页面只消费结论。

### 3.2 沉浸布局（P2）

**沉浸态屏幕上剩什么，由一套独立于普通布局的「沉浸布局」决定**，在控件布局编辑器里加一个「沉浸」页签编辑。

- **只有两个位置**：屏幕左侧栏、屏幕右侧栏（各自是一列，可调上下顺序）+ 隐藏托盘。不提供顶 / 底栏——沉浸态顶底栏本来就不画，给了也是摆设。
- **锁按钮必选**：沉浸布局里锁按钮不能拖进隐藏托盘（它是唯一退出口），但左 / 右、在一列里的上下位置随意。
- **默认 = 只有锁按钮，零行为变化**。老用户 / 新用户都没有沉浸布局的持久化值时，按普通布局派生锁按钮位置：普通布局里锁在 `screenLeft` / `screenRight` 就放同侧；在顶 / 底栏或隐藏就放左侧（= 现在 `_buildSideLockButton` 的位置）。**不往任何栏里预塞按钮**，普通布局也一个不动。
- **可拖入的项**：学习类 `previousCue` / `nextCue` / `replayCue` / `favoriteSentence`，以及 `speed`、`ocrFrame`、`customAction1-4` 等 chip 可渲染项。想单手的用户自己把「上一句 / 收藏 / 下一句」拖到锁按钮同侧或另一侧。
- **显隐与锁按钮同一套**：整层（两条侧栏）跟 `_lockButtonVisible` 走——点画面唤出、2s 淡出、桌面 hover 续命、按下续命。不常驻，沉浸态平时画面是干净的。与 3.1 叠加时点一下画面，字幕和按钮一起出来。
- **门控：沉浸布局管按钮，沉浸档位管画面与按键，两者正交**（2026-10-25 所有者拍板）：
  - 沉浸布局里的按钮在**任何** `VideoImmersiveMode` 档位下都渲染、都响应，包括 `unlockOnly`——用户亲手放进来的显式按钮不是误触；不想要就不放（默认布局只有锁按钮，`unlockOnly` 的「只能解锁」靠默认布局成立）。
  - `VideoImmersiveMode` 只继续门控画面与输入：点字查词、双击 seek、滚轮、右键菜单、键盘 / 手柄快捷键（现有四个 getter 不变）。
  - 因此沉浸布局按钮的点击**不走** `_immersiveAllowsFullControls`；渲染处不再按档位过滤，避免「放了按钮点不动」。
- **持久化**：与普通布局分开存一份 slot assignment（新偏好键，进 Profile / 备份同普通布局）；只存用户改过的值，未改时始终按上面规则派生，避免普通布局里锁按钮挪了位置、沉浸布局还停在旧位置。
- **渲染**：`_buildVideoSideActionRail` 的 `immersiveOnly` 过滤改为读沉浸布局；`_buildSideLockButton` 退化路径并入同一渲染（锁按钮总在沉浸布局里有确定位置），删掉 `lockOnSideRail` 两条分支。视觉沿用侧栏现有按钮（纯图标、tooltip + Semantics、≥48dp、`FushiPressScale`），MD3 / Apple 两套都走现有侧栏实现。
- **收藏反馈**：触感反馈 + 星标实心切换 + 现有 OSD，不唤起控制条（BUG-931）。

### 3.3 不做什么

- 不加「沉浸时字幕」覆盖全局遮蔽的设置：要「沉浸时字幕遮住」把全局遮蔽设成隐藏 / 模糊即可，3.1 补的是缺失的显形入口。
- 不做常驻拇指栏、不改普通布局的出厂默认。
- 不加「右半屏竖滑 = 跳句」这类隐形手势。

## 4. 落地拆分

| 阶段 | 内容 | 主要文件 |
|---|---|---|
| P1 | 3.1：偏好 + 设置行 + 纯函数 + overlay 显形句柄 + `_handleVideoPointerUp` 接线 + i18n | `preferences_repository.dart`、`settings_schema_video.dart`、`video_subtitle_overlay.dart`、`video_fushi_page.dart`、`layout.part.dart` |
| P2 | 3.2：沉浸布局模型 + 派生默认 + 持久化 + 编辑器「沉浸」页签 + 渲染并路 | `video_control_customization.dart`、控件布局编辑器、`layout.part.dart`、`video_fushi_page.dart` |

i18n 一律 `fushi/tool/i18n_sync.dart --add`（如 `video_setting_immersive_tap_reveal` / `_hint`、编辑器页签名）。

## 5. 测试

- 纯函数单测：`videoImmersiveTapRevealsSubtitle` 全组合；沉浸布局默认派生（锁在左栏 / 右栏 / 顶栏 / 底栏 / 隐藏五种普通布局）。
- overlay widget 测试：显形句柄 toggle、cue 换轮遮回、`obscureRevealOnInteraction=false` 时无效、副字幕不受影响。
- 页面 widget 测试：沉浸锁 + 隐藏遮蔽下点画面中心 → 主字幕可见且字符可点查词；开关关掉后点画面不显形；沉浸布局放了收藏 → 四个档位（含 `lookupOnly` / `unlockOnly`）都可点且写穿收藏表；同时 `lookupOnly` 档点画面双击仍不 seek（档位门控画面输入不受沉浸布局影响）。
- 编辑器测试：锁按钮拖不进隐藏托盘。
- 集成测试按焦点驱动规则补一条：沉浸锁 → 焦点到沉浸布局里的收藏键 → Enter → 断言 DB 收藏行。

## 6. 已拍板 / 待决策

- 已拍板（2026-10-25）：点画面显形做成开关、默认开；不往任何布局预塞按钮；沉浸态单独一套排列；沉浸布局里的按钮在所有档位都有效，档位只管画面与按键。
- 无待决策项。
