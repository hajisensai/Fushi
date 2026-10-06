# 2026-10 UI / 动效 / 交互重做

分支：`claude/fushi-ui-animation-redesign-76lngq`　效果图：[`docs/design/2026-10-ui-motion-redesign/`](../design/2026-10-ui-motion-redesign/README.md)

## 目标与边界

- **在现有设计系统上改，不从零重写**（仓库规则）。颜色阶梯、字号阶梯、圆角、组件形状维持
  `FushiDesignTokens` / `FushiTypeScale` / `applyFushiSurfaceLadder` 的既有决定；这一轮补的是
  此前缺位的三块：**统一的动效体系**、**触屏按压反馈**、**过渡与浮层的一致性**。
- 所有装饰性动效有两档降级，且只在一处判定：墨水屏（连续重绘 = 残影）与系统「减弱动态效果」
  （`MediaQuery.disableAnimations`）。判据 `fushiMotionEnabled(context)`，时长出口
  `fushiMotionDuration(context, d)`。承载语义的状态（选中色、最终几何）照常到位，只是瞬间完成。
- 不新增偏好键、不新增 i18n key：减弱动态效果跟随系统无障碍开关。

## 动效体系 `FushiMotion`（`lib/src/utils/components/fushi_motion_tokens.dart`）

| token | 值 | 用途 |
|---|---|---|
| `micro` | 90 ms | 按压下沉 |
| `short` | 180 ms | 小组件状态（导航药丸、图标交叉淡化、按压回弹） |
| `medium` | 280 ms | 列表 / 网格项进场 |
| `long` / `longReverse` | 360 / 240 ms | 跨页转场（退出约为进入的 2/3） |
| `enter` / `exit` / `standard` | M3 emphasizedDecelerate / emphasizedAccelerate / standard | 进入 / 退出 / 原地变化 |
| `release` | 自定义减速曲线，≈1.25% 过冲 | 松手回弹 |
| `staggerStep` × `staggerMaxItems` | 35 ms × 8 | 错峰进场，第 8 项之后不再加延迟 |

原则：快进慢出、距离决定时长、500 ms 以上的动画视为设计错误。

## 变更清单

1. **桌面页面转场**：Windows / Linux / Fuchsia 由 `ZoomPageTransitionsBuilder` 换成
   `FushiSharedAxisPageTransitionsBuilder`（`lib/src/utils/adaptive/fushi_page_transitions.dart`）。
   Zoom 是为手机「卡片放大成整页」设计的，整窗缩放的位移随窗口尺寸线性增长，4K 全屏下一次 push
   等于把几百像素整体推拉一遍，并且两页同时缩放要两层离屏合成。新转场只让进入页从下方 24 px 上滑
   并淡入；被覆盖页**不位移**，只原地压暗 6%（早先版本让它同时上移 6 px，用户实测觉得「整个页面往上跳」，已去掉）。Android 预测性返回、iOS / macOS Cupertino、墨水屏零转场
   矩阵不变（守卫 `test/models/theme_page_transitions_guard_test.dart` 新增桌面断言）。
2. **导航药丸展开**：`_FushiNavTile` 选中指示器从 32 横向展开到 64 并渐入填充色，图标线框 ↔ 实心
   轻缩放交叉淡化，标签字重过渡。settle 后的几何与配色与改造前逐值相同（eink 守卫不变）。
3. **触感反馈**：`fushiSelectionHaptic`（`fushi_haptics.dart`）——仅 Android / iOS，仅「选择变化」
   （切换底栏目的地）；普通点击仍由 `InkWell` 的 `Feedback.forTap` 负责。
4. **按压下沉** `FushiPressScale`：按下 90 ms 缩到 0.97，松手 180 ms 带轻过冲回弹；只挂 `Listener`
   旁观指针事件、不进手势竞技场，内层点击 / 长按 / 拖拽语义不变；移动超过 touch slop 视为滚动起手
   立即放回。接入点：`FushiCard`（可点时）与 `FushiHoverLift`（书架 / 视频 / 游戏 / 首页所有库页卡片
   共用的悬停壳，因此一处接入覆盖全部库页）。
5. **错峰进场** `FushiEntranceScope` + `FushiStaggeredEntrance`：只在「进场窗口」（scope 挂载后
   600 ms）内首次挂载的项播放淡入 + 上移 16 px，窗口外（滚动带出、懒加载补入）瞬间出现，避免滚动
   拖影；延迟折进 controller 的 Interval，不挂计时器；只改 opacity / transform，不改布局。接入点：
   书架散书网格。
6. **主题切换过渡**：`MaterialApp.themeAnimationStyle` = 280 ms standard（墨水屏 `noAnimation`）。
7. **组件主题**：tooltip 改反色小浮层（悬停 400 ms 才出、离开 100 ms 收起）；snackbar 加底部
   inset 与反色强调色；进度条启用 M3 2024 样式（圆头、留缝、停止点；墨水屏保留 2023 样式）。

## 效果图怎么生成

```bash
fushi/tool/design_preview/render_previews.sh            # Linux / macOS
powershell -File fushi/tool/design_preview/render_previews.ps1   # Windows
```

渲染器 `fushi/test/design_preview/redesign_preview_test.dart` 用**真实主题工厂与生产组件**在
flutter test 离屏光栅里出图（不是手绘稿），未设 `FUSHI_DESIGN_PREVIEW_OUT` 时自身 skip，CI 不受影响。
动效胶片逐帧采样真实动画（转场是真 `Navigator.push`），GIF 由 ffmpeg / ImageMagick 慢放合成（6 fps）。

## 已知限制 / 待真机验证

- 效果图是离屏光栅：阴影、字体 hinting 与真机略有差异；封面是程序生成的渐变。
- 未在真机 / 模拟器上复测（本环境无设备）。合入前建议：Android 真机验按压 + 触感 + 底栏动画，
  Windows 验 push / pop 转场与悬停 + 按压叠乘，墨水屏模式与系统「移除动画」下确认全部降级为瞬时。
- 错峰进场接入面（2026-10-04 补齐视频与设置）：书架散书网格；视频库系列墙 / 全部视频网格 / 首页横滚行
  （`home_video_page.dart`，scope 的 `replayKey` 为当前分区，切分区重播）；设置分类列表与详情分组
  （`material_settings_renderer.dart`，宽屏主从切分类时详情按 destination 重建、重播一次）。游戏库待接。
- 发现页头部（2026-10-04）：窄屏（缩放折算后 < 600）书 / 漫画 / 视频三域统一为两行——搜索框独占整行，
  来源下拉（视频域无）与入口按钮在第二行；宽屏维持单行（`discovery_header.dart` / `video_discovery_page.dart`）。
