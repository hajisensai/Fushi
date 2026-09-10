## BUG-2443 · 设置页导航窗格与详情窗格之间那条分隔线两侧读不出窗格
- **报告**：2026-09-11（用户：截图圈出设置页中间那条竖线，「总觉得这条线还是有点怪」）
- **真实性**：✅ 真 bug（观感缺陷，可像素判定）。对用户截图（2940×1734，DPR 1.92）逐行采样，
  接缝一行的实际色块是：
  `[导航分组卡 #ECECF3] … [窗格底 #F4F4FB ×20dp] [线 #C4C6D0 1px] [详情底 #FFFDFF ×28dp] [详情卡 #ECECF3]`
  两处根因：
  - `fushi/lib/src/settings/settings_home_page.dart:348` 导航窗格底色取 `tokens.surfaces.group`
    （surfaceContainerLow）。它与详情窗格所在的 `surfaces.page`（surface）在浅色主题下只差
    约 2%（#F4F4FB vs #FFFDFF，11/255），**线两侧几乎同色**——人眼预期一条线两边是两个不同
    的面，这里看不到面，线就只能读成一条凭空的竖线。同一屏里 `surfaces.card` 的分组卡又铺在
    `surfaces.group` 的窗格上（差同样约 2%），等于窗格里再套一层看不见的卡，窗格自己反而没有
    一整块可辨的实色面。
  - `fushi/lib/src/settings/material_settings_renderer.dart:19-24` 详情正文左内边距是
    `page + gap`(28)、右边 `page`(20)。正文在自己的窗格里左右不等宽；落到接缝上就是线左边
    20dp、右边 28dp，**一条线两侧呼吸不一样宽**，线看着偏向左侧。
  左边「图标侧栏 | 导航窗格」那条缝本来就没有分隔线（`home_page.dart:1315-1331` 是裸 `Row`，
  rail 与内容同为 `surface`），于是同一屏里两条同类接缝一条隐形、一条画硬线，左右不对称。
- **[x] ① 已修复** — 导航窗格底色提一档到 `tokens.surfaces.card`（surfaceContainer，与详情底
  面差约 4.3%，线两侧真有两个面）；宽屏主从的分类分组不再铺同色卡片（`surfaceColor:
  Colors.transparent`），窗格本身就是那块 tonal 面，窄屏 push 列表没有窗格底、分组卡是它唯一
  的容器，保持不变；窗格里的搜索框相应提到 `surfaces.overlay`，在更深的窗格底上保持原有的
  4.7% 对比；详情正文左右内边距都取 `page`，正文左右对称、分隔线居中于 20+20 的缝里。
  分隔线本身（`surfaces.outline` / 1px）不动——实测这个浅色主题相邻 tonal 档只差 2~4%，
  单靠面差撑不住窗格边界，线仍是必要的，问题从来不是它存在，而是它两侧没有面。
- **[x] ② 已加自动化测试** — `fushi/test/settings/settings_pane_seam_test.dart`（行为层：宽屏
  导航窗格必须画在 `surfaces.card` 档、且该档与 `page`/`group` 不同色；详情正文左右内边距必须
  相等。两条都做过反向验证：改回旧值确实变红）。源码层对应守卫在
  `fushi/test/settings/settings_redesign_static_test.dart`（窗格底色档位 + 宽窄两侧分组卡策略）。
- **备注**：改前/改后真实像素对照见 `.codex-test/settings-seam/seam_before_zh.png` /
  `seam_after_zh.png`（widget 预览，1200×750 逻辑、DPR 2，中文真字体）。暗色主题同法采样：
  窗格 #1B2023 / 详情底 #0F1417（面差 4.7%）、搜索框 #303638，均正常。
