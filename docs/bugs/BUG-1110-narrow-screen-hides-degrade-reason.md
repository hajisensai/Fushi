## BUG-1110 · 捕获工作台窄屏时藏掉降级原因，只留一个「已降级」徽章

- 报告：用户 2026-07-26。原文「为什么不够宽就不显示，修复」。
  起因是上一轮验收清单里把「窗口须拉宽到 ≥840px 否则看不到降级原因」写成了操作前置——
  用户指出这本身就是 bug，不该要求用户迁就 UI。
- 真实性：真 bug。`texthooker_page.dart` 的 `_SessionOverviewCard` 里，降级原因行的
  渲染条件是 `if (!compact && state.fallbackReason != null)`，而 `compact` 在窗口
  宽度 < 840px 时为 true（布局分支 `box.maxWidth >= 840` 的 else 路径）。
  → 窄屏下降级原因**整行不渲染**。

  更糟的是**不对称**：同一张卡右侧的 `_StatusPill` 完全不看 `compact`，降级时照常亮
  「已降级」。于是窄屏用户看到的是「出事了 + 不告诉你出了什么事」，比两个都不显示更难
  排查——用户知道降级了，却拿不到任何可执行处置（「以管理员身份启动」这类）。

  这是优先级搞反：compact 该省的是次要信息（采样率/声道/位深，即 `format`），不是唯一
  的诊断线索。

- [x] ① 根因修复：渲染条件去掉 `!compact`，改为只看 `state.fallbackReason != null`；
      窄屏只把 `maxLines` 从 3 收窄到 2，不整行丢弃。`format` 仍按原样在 compact 下省掉
      （那是 compact 的正当用途）。
      `hibiki/lib/src/pages/implementations/texthooker_page.dart` `_SessionOverviewCard`
- [x] ② 自动化测试：`hibiki/test/pages/texthooker_narrow_degrade_reason_guard_test.dart`
      （5 条，抽取 `_SessionOverviewCard` 类体后断言，避免整文件命中蒙混）：
      条件不含 `!compact`、`maxLines: compact ? 2 : 3`、format 仍在 compact 下省、
      以及**徽章与原因的显示条件必须对称**（`_StatusPill` 不得出现 `compact`）。
      捕获工作台整页依赖真实 WebView 平台视图、widget test 起不来，故守住源码接线——
      与该页既有守卫（`texthooker_lookup_popup_overlay_test.dart` 等）同范式。

- 备注：仍未真机验证「窄屏下确实能看到那行字」。窄屏渲染需要真机改窗口宽度肉眼看，
  已并入批次 11 验收清单。相关：BUG-1100 修的是同一行字的**内容**（别把内部代码
  `engine_pcm_unavailable` 甩给用户），本条修的是它的**可见性**。
