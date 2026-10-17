## BUG-3495 · 视频遥控：开关类按钮放进主控制行时没有着色
- **报告**：2026-10-17（应用内反馈 SS9coDLqrd，iOS；所有者澄清：与上一句 / 播放 / 下一句同一行的其它按钮要和主控键一样用 M3E 着色）
- **真实性**：✅ 真 bug。用户截图里收藏（☆）被拖进主控制行，只剩裸图标。主控制行非播放键本就统一走 `FushiIconButtonControl.filledTonal`（M size，`fushi/lib/src/pages/implementations/video_remote/video_remote_control_card.dart:203`），倍速 / 音量 / 选集等非开关键已铺 secondaryContainer；但收藏 / 字幕显隐带 `isSelected`（toggle），M3E tonal toggle 未选态退成 `surfaceContainer`（`fushi/lib/src/utils/components/glass/fushi_glass_buttons.dart:1559-1562`），而遥控卡自身底色正是 `surfaceContainer`（`fushi/lib/src/utils/components/fushi_floating_toolbar.dart:156`），于是关着的开关键容器与卡片同色、看不见。
- **[x] ① 已修复** — `video_remote_control_card.dart` 新增 `videoRemotePrimaryToggleStyle`：主控制行的开关键（MD3、非墨水屏）无论开关都铺与前后句同一个 secondaryContainer / onSecondaryContainer，开关由图标（实心 / 空心）与 M3E 选中形状（圆 → 方圆角）区分，`isSelected` 语义保留；次组行、非开关键、Apple 设计系统（tonal = 中性灰底圆钮，本就与前后句同色）与墨水屏不变。按压沿用按钮组挤压 + 按钮自身形变，与前后句一致。
- **[x] ② 已加自动化测试** — `fushi/test/pages/video_remote/video_remote_primary_row_tint_test.dart`（明 / 暗主题下开关键关着与开着的容器色 = 上一句；次组行不变；Apple 不覆盖；非开关键沿用默认）。
- **备注**：
