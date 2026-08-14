## BUG-1635 · 游戏内嵌套查词卡被父弹窗锚点空间裁短
- **报告**：2026-08-13（用户附真机截图：子卡只剩父卡内锚点一侧的高度；预期仅在游戏
  视口顶部/底部空间不足时限高，同时右侧底角被横切成方口。）
- **真实性**：✅ 真 bug。`global_lookup_layout.dart` 的横排 `computeFrameRect` 原本对所有有锚点
  卡使用 `max(spaceAbove, spaceBelow)` 作为高度；`global_lookup_render.dart` 又把父卡内被点击词
  的 rect 作为 nested anchor，因此子卡被“锚点某一侧”二次收高。随后
  `global_lookup_host.js::measureAndReport` 只把实测短高度用于 union bbox / shellRects，未同步
  写回 shell；CapturePreview 在 iframe 实际 planned 底圆角之前横切，形成方形底口与命中区错位。
- **[x] ① 已修复** — `computeFrameRect` 新增默认保持旧语义的
  `fitHeightToAnchorSide`；仅 nested `depth > 0` 关闭锚点侧限高，改为在完整工作区顶部/底部
  收敛。host 每轮都从 descriptor planned height 重新计算
  `min(plannedHeight, measuredHeight)`，把同一值写回 shell 并用于 union/region；iframe 合成面
  自身也使用继承半径的 `clip-path`，每张级联卡独立圆角。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/global_lookup_layout_test.dart` 锁定 nested
  高度只受屏幕边界；`fushi/test/lookup/global_lookup_host_test.mjs` 锁定 planned/measured 单一
  高度真值、异步内容可回扩和 iframe 独立圆角。按用户要求本轮只做 format / 语法与 diff
  静态检查，不运行测试套件。
- **备注**：仅影响 Windows app-out / galCard 复用的 host cascade；app 内 popup 不加载
  `global_lookup_host.js`。PNG/WIC/straight-BGRA/`ltAlpha` 链路未改，也不对整张 union 位图套
  统一圆角 mask，避免误裁卡片重叠区。
