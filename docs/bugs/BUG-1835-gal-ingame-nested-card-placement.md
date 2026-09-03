## BUG-1835 · 游戏内嵌套查词子卡未按选词正上正下布局
- **报告**：2026-08-24（用户运行时报告，已脱敏）
- **真实性**：✅ 真 bug。这里混用了两个不同约束：SGRE 的 1592×1020 物理 px
  （DPR=2 时为 796×510 CSS px）只应是**单张卡片**的位图/排版上限，级联布局工作区则应是
  **完整游戏 viewport**。旧链路却把同一 `_physicalCap` 继续作为 `showAt(capW/capH)` 的
  工作区，并把根卡在工作区内的原点强制写成 `(0,0)`，所以所有 child 都只能落在截图红框
  那块单卡范围内。`global_lookup_render.dart` 又令 nested frame 使用
  `fitHeightToAnchorSide: false`，近全高 child 会被 clamp 到 parent 上，与
  `dictionary_popup_layer.dart` 的“选词正上/正下、按该侧空间限高”契约不一致。现有运行日志
  还记录到旧离屏 resize + 双 rAF 路径额外等待 408–565 ms；这只证明原失败路径的时延，
  不等于下述实现已经通过真机复测。
- **[ ] ① 实现已落地、最终真机门待确认** — 单卡 cap 与完整 viewport 已拆开；`capW/capH`
  传完整游戏 viewport，`capX/capY` 传冻结的根卡原点。galCard 保留 anchor-side fitting，
  但不使用桌面 HWND 的 `originFloor`：否则非零根原点会把透明 union 预留到 viewport 左上角。
  child 现在可使用根卡外的 viewport 空间；direct-active 时 `ResizeStackForGal` 围绕固定根卡
  原点原位扩缩已贴在游戏上的 HWND，只有尚未进入 direct mode 或 direct 不可用时才保留离屏
  resize/captureReady 位图回退。Windows Debug 构建已经完成并在原 SGRE 会话启动；用户随后
  要求提交上游 PR，但位置、闪动与时延尚无单独的最终显式通过回报，因此本项仍不勾选。
- **[x] ② 已加自动化测试** — 已补“完整 viewport + 较小单卡 cap + 非零根原点”的纯布局
  断言，以及 capW/H/X/Y、galCard-only anchor-side fitting、galCard 禁用 originFloor 和
  direct/fallback 接线守卫；这些离线守卫不替代 SGRE 真机验收。
- **备注**：不改变桌面全局查词的工作区与 originFloor 行为，不触碰 hook 文本、hook 音频或
  游戏原生转义链。字体静态载荷的重复注入与缓存属于 BUG-1833，不是本条红框几何的根因。
