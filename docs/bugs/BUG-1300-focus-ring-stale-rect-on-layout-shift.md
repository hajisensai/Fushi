## BUG-1300 · 焦点环矩形不随布局位移过期悬空
- **报告**：2026-08-01（用户截图：首页 dashboard 上焦点环悬在「继续」与「最近添加」两个区块之间的空白处，与任何卡片几何都对不上；与 BUG-1301 同一轮「焦点高亮错误」反馈）
- **真实性**：✅ 真 bug。`HibikiFocusRing` 的矩形重算是**事件枚举式**（`hibiki/lib/src/utils/components/hibiki_focus_ring.dart`：焦点变化 `_onFocusManagerChange`、高亮模式 `_onHighlight`、窗口尺寸 `didChangeMetrics`、UI 缩放/主题 `didChangeDependencies`、滚动 `NotificationListener<ScrollNotification>`）——**纯布局位移没有事件**：dashboard 的异步区块（热力图/继续/最近添加）加载后整页 reflow 把焦点卡片推走，没有任何触发器命中，环钉死在旧矩形上悬空。旧代码里 UI-scale 的 `didChangeDependencies` 特例正是同类病灶的单点补丁（注释自述「invisible to every other recompute trigger」）。
- **[x] ① 已修复** — 根因修复：消除事件枚举——traditional（键盘/手柄）高亮模式期间用自续臂 post-frame 回调**逐帧**跟踪焦点控件几何（`_armFrameTracker`），「矩形 = 焦点控件实时几何」成为持续成立的导出状态；滚动通知特例一并删除（滚动帧就是帧）。post-frame 回调不催帧：无帧渲染零成本，矩形无变化不 setState、不产生新帧，天然收敛。
- **[x] ② 已加自动化测试** — `hibiki/test/widgets/hibiki_focus_ring_test.dart`：「ring follows the focused control after a plain layout shift (BUG-1300)」——上方区块无事件长高 120px 推走焦点控件，环必须跟随（变异实测：截断 `_armFrameTracker` 起臂即红）；既有 8 例（缩放跟随/缩放尺寸/主题不回拉滚动等）全绿证明旧契约不破。
- **备注**：与 BUG-1301（视频页隐形 chrome 可聚焦）同轮报告但根因独立：1301 是「焦点落在不可见控件上」（焦点所有权问题），本条是「矩形过期」（几何派生状态问题）。两修复叠加后：环只会画在可聚焦的可见控件上、且始终贴住其实时几何。
