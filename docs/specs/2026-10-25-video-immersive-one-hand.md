# 视频沉浸模式：点画面显字幕 + 单手拇指栏（设计案）

> 状态：草案，待所有者拍板（见文末「待决策」）。
> 来源：2026-10-25 用户群讨论（手机看视频查词难受、没法单手操作；有人靠沉浸模式 + 开字幕看，提议「沉浸模式点一下出字幕」「右手放前后句 + 收藏按钮」）。

## 1. 用户在说什么

| 原话（摘要） | 背后的诉求 |
|---|---|
| 手机看视频查词难受 / 没法单手操作 | 手机横屏握持时，两只拇指都被占着；现有学习动作（跳句、收藏）要么在底栏（得先点出控制条），要么只有键盘 / 手柄能按 |
| 用沉浸模式开字幕看，不然查词太麻烦 | 沉浸锁把触摸误触挡掉，点字幕只会查词，不会弹控制条——这已经是「手机学习模式」的事实用法 |
| 沉浸模式点一下出字幕 | 想先听、听不懂再看：字幕平时不显示，点一下画面就出这一句 |
| 听不懂的那句就收藏 / 只用收藏按钮还行 | 收藏是最高频动作，必须一个拇指够得着 |
| 右手那边放前后句 + 收藏，单手就能操作 | 一列固定在拇指可达区的大按钮 |

## 2. 现状（代码事实）

1. **沉浸锁**：`_immersiveLocked`（`video_fushi_page.dart` `_toggleImmersiveLock`）。按 `VideoImmersiveMode`（`lib/src/media/video/video_immersive_mode.dart`）四档放行：`full` / `shortcutAndLookup`（默认）/ `lookupOnly` / `unlockOnly`。门控是四个 getter：`_immersiveAllowsFullControls` / `_immersiveAllowsShortcuts` / `_immersiveAllowsDoubleTapSeek` / `_immersiveAllowsLookup`。
2. **沉浸态侧栏只剩锁按钮**：`layout.part.dart` `_buildVideoSideRailFor(immersiveOnly: true)` 把左右侧栏过滤成只渲染 `VideoControlItem.immersiveLock`。也就是说用户哪怕把「上一句 / 下一句 / 收藏」拖到了 `screenRight` 槽，一锁就全没了。
3. **按钮本身都有**：`VideoControlItem.previousCue` / `nextCue` / `replayCue` / `favoriteSentence` 早就存在；动作实现 `_replayPreviousCueAndKeepControls` / `_replayCurrentCueAndKeepControls` / `_toggleFavoriteCurrentCue`（已遵守 BUG-2030 / BUG-931：不唤起控制条）。
4. **字幕遮蔽**：`VideoSubtitleObscureMode{none, blur, hide}`（`video_subtitle_obscure_mode.dart`）+ `VideoSubtitleOverlay` 的 `blurEnabled` / `subtitleHidden`。暂停 / 查词浮层开着时自动显示（BUG-2198 / BUG-2235）。
5. **移动端显形通道只有一条**：`video_subtitle_overlay.dart` 里遮蔽态盖了一层 `Key('video-subtitle-reveal')` 热区，**只覆盖字幕盒本身**。隐藏态下字幕盒是透明的——用户得去点一块看不见的区域；点中后 `_tapRevealed` 一直保持到 cue 换轮。
6. **沉浸态点画面目前几乎什么都不做**：`_handleVideoPointerUp` 只 `_pokeLockButton()` 唤回解锁按钮；非 `full` 档下双击 seek 也被挡掉。整个画面在沉浸态是一块闲置的大触控区。

结论：两条诉求都**不需要新的底层能力**，缺的是「沉浸态把画面点击交给字幕显形」和「沉浸态允许一列学习按钮」这两处接线 + 一个门控分类。

## 3. 方案

### 3.1 沉浸点画面显字幕（P1）

**新设置**「沉浸时字幕」（视频设置 › 沉浸模式分组，`adaptiveSegmentedButton` 三段）：

| 值 | 行为 |
|---|---|
| 跟随字幕遮蔽设置（默认，零行为变化） | 沉浸态与非沉浸态一样用全局 `VideoSubtitleObscureMode` |
| 隐藏，点画面显示 | 进入沉浸锁时有效遮蔽模式 = `hide` |
| 模糊，点画面看清 | 进入沉浸锁时有效遮蔽模式 = `blur` |

- **有效遮蔽模式是纯函数**：`effectiveVideoSubtitleObscureMode({required VideoSubtitleObscureMode global, required VideoImmersiveSubtitleMode immersive, required bool locked})`，页面只消费结论传给 overlay。不改全局偏好值——解锁即回到用户原来的遮蔽设置。
- **点画面 = 显形当前句**：沉浸锁定且有效遮蔽 ≠ `none` 时，`_handleVideoPointerUp` 在现有 chrome / 侧栏 / 选集横轨三道早返回之后、双击判定之前，调用 overlay 新增的显式显形入口（`VideoSubtitleRevealController.toggle()`，与 `hitTester` 同一种「页面持有、overlay 绑定」的句柄），复用现有 `_setRevealed(..., byTap: true)` 状态机：
  - 显形持续到 cue 换轮（与现有点击热区同语义，换句自动遮回）；
  - 已显形时再点画面 = 遮回去（toggle，给「误点了」一个撤销）；
  - 只显形主字幕；副字幕（翻译）照旧遵守自己的遮蔽与 `secondaryObscureRevealOnInteraction`——常见用法是「点一下看原文，翻译仍然盖着」；
  - 全局「遮蔽态允许临时显形」(`obscureRevealOnInteraction`) 关掉时，点画面也不显形（BUG-2256 的「显形全部来源一起门控」）。
- **显形后点字 = 查词**：显形态字符才登记命中（现有逻辑），所以手势链天然是「点画面看一眼 → 点那个字查词」，两步都是单指点按。
- **与双击的关系**：单击立即显形、不等双击窗口（不加延迟）。`full` 档下双击左右区 seek 照旧，第一次点击顺带显形无害；其余档位双击本来就被挡。
- **解锁按钮唤回照旧**：`_pokeLockButton()` 不动，点画面仍会把解锁口亮出来。

### 3.2 单手拇指栏（P2）

沉浸锁定态下，在**拇指侧**屏幕边缘画一列竖排大按钮（默认右手）：

```
            ┌───┐
            │ ⏮ │  上一句（重播上一句）
            ├───┤
            │ ★ │  收藏本句（实心 = 已收藏），垂直居中、拇指自然落点
            ├───┤
            │ ⏭ │  下一句
            └───┘
```

- **内容走现有控件布局体系**：新增槽位 `VideoControlSlot.immersiveRail`，默认 `[previousCue, favoriteSentence, nextCue]`，用户可在控件布局编辑器里换成 / 加上 `replayCue`、`speed`、`ocrFrame`、自定义快捷键按钮等任何 chip 可渲染项。老布局回填：该槽位不存在时写入默认三项（与 `customAction*` 的兜底 assignment 同范式）。
- **门控新分一类「学习动作」**：新 getter `_immersiveAllowsLearningActions`，`full` / `shortcutAndLookup` / `lookupOnly` 放行，仅 `unlockOnly` 挡。理由：拇指栏是固定位置的显式按钮，不是落在画面上的误触，挡它没有意义；而 `unlockOnly` 的语义就是「什么都别动」。栏内若放了非学习类按钮（倍速等），仍按原 `_immersiveAllowsFullControls` 门控——判据写成纯函数 `videoImmersiveAllowsItem(VideoImmersiveMode, VideoControlItem)`，不在渲染处散写。
- **左右手**：设置「拇指栏位置：右 / 左」（同一分段控件）。锁按钮默认在左侧居中，栏在右侧不冲突；用户把栏切到左侧或把锁按钮放进 `screenLeft` 时，锁按钮让到栏的上方（同一 Column），不叠放。
- **可见性**：常驻，不随 2s 自动淡出消失（淡出就又要先点一下才能按，单手链断了）；空闲 2s 后降到低不透明度，仍可点；按下即恢复全不透明。时长取 `fushiMotionDuration` / `FushiMotion`，墨水屏与「减弱动态效果」归零。
- **视觉与命中**：纯图标、无文字（文字进 tooltip 与 Semantics label，用 `video_control_*` 现有文案）；单键命中区 ≥ 56dp（横屏握持，比 48dp 底线再大一档）；按压 `FushiPressScale`；不画组间分隔线。MD3 与 Apple 两套设计系统都接（Apple 用 `fushiAppleSolidFloatingDecoration`）。
- **反馈**：
  - 收藏：触感反馈（与本仓 video haptics 同一入口）+ 星标实心切换 + 现有 OSD；不唤起控制条（BUG-931）。
  - 跳句：走 `_keepControlsAliveIfVisible` 语义（BUG-2030），沉浸态本来控制条就被压着。
  - **跳上一句 / 重播时自动显形目标句**（3.1 开着时）：往回跳的意图就是「刚才那句没听懂」，再让用户点一下画面是多余一步；下一句不自动显形。
- **哪些平台出**：移动端默认出；桌面端只在触屏 / 触控笔握持（Surface）时出——判据复用 `isTouchLikePointerKind` 的「最近一次指针类型」，桌面鼠标用户有键盘快捷键，栏默认不画（可在布局编辑器手动加回）。小窗（`mini` 密度）一律不画。
- **字幕避让**：拇指栏占右侧边缘约 72dp，字幕盒水平居中且最大宽度本就留边，正常不重叠；`compact` 密度下字幕最大宽度额外让出栏宽（在字幕避让那一处乘，不另立常量）。

### 3.3 不做什么

- 不加「右半屏竖滑 = 上 / 下一句」这类隐形手势：发现性差，且和系统边缘手势 / 未来亮度音量手势抢区域。按钮能做到的不靠手势。
- 不改沉浸锁的进入 / 退出方式。
- 不动全局 `VideoSubtitleObscureMode` 的持久化（3.1 是派生，不是改写）。

## 4. 落地拆分

| 阶段 | 内容 | 主要文件 |
|---|---|---|
| P1 | 3.1 点画面显形：新偏好 + `effectiveVideoSubtitleObscureMode` 纯函数 + overlay 显形句柄 + `_handleVideoPointerUp` 接线 + 设置行 + i18n | `video_subtitle_obscure_mode.dart`、`video_subtitle_overlay.dart`、`video_fushi_page.dart`、`layout.part.dart`、`settings_schema_video.dart`、`preferences_repository.dart` |
| P2 | 3.2 拇指栏：`immersiveRail` 槽位 + 老布局回填 + `videoImmersiveAllowsItem` 纯函数 + 栏渲染 / 淡出 / 左右手 + 跳句自动显形 | `video_control_customization.dart`、`layout.part.dart`、`video_fushi_page.dart`、控件布局编辑器 |

i18n 一律 `fushi/tool/i18n_sync.dart --add`，key 形如 `video_setting_immersive_subtitle_*` / `video_setting_immersive_rail_side_*`。

## 5. 测试

- 纯函数单测：`effectiveVideoSubtitleObscureMode` 全组合；`videoImmersiveAllowsItem` 四档 × 学习 / 非学习按钮。
- overlay widget 测试：显形句柄 toggle、cue 换轮自动遮回、`obscureRevealOnInteraction=false` 时句柄无效、副字幕不受主字幕句柄影响。
- 页面 widget 测试：沉浸锁 + 「隐藏，点画面显示」下点画面中心 → 主字幕可见且字符可点查词；`unlockOnly` 下拇指栏按钮不响应；`shortcutAndLookup` 下点收藏写穿收藏表。
- 布局回填测试：老布局（无 `immersiveRail`）读出后得到默认三项；已有自定义的不被覆盖。
- 集成测试按焦点驱动规则补一条：进入沉浸锁 → 焦点到拇指栏收藏键 → Enter → 断言 DB 收藏行。

## 6. 待决策

1. **「沉浸时字幕」默认值**：建议「跟随字幕遮蔽设置」（老用户零变化），群里那种用法自己切到「隐藏，点画面显示」。若想直接推广成默认学习形态，可默认「隐藏」——但会让现在「沉浸 + 开字幕看」的用户一升级字幕就没了。
2. **`lookupOnly` 档是否放行拇指栏**：建议放行（栏是显式按钮）；若认为「仅查词」应字面意义上只能查词，就只在 `full` / `shortcutAndLookup` 放行。
3. **栏内容固定还是进布局编辑器**：建议进布局编辑器（新槽位），代价是控件布局多一个槽位要维护回填。
4. **上一句 / 重播是否自动显形**：建议是。
