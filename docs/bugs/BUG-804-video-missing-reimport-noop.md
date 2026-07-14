## BUG-804 · 视频缺失态重新导入空操作没反应
- **报告**：2026-07-14（用户：）
- **真实性**：✅ 真 bug。用户报「视频无法访问，点重新导入没反应」。沿真实代码路径验真：
  本地视频文件被移动/删除/盘未挂载时，`_applyLoad` 前置短路进「资源缺失」态
  （`hibiki/lib/src/media/video/video_resource_check.dart` `isLocalVideoResourceMissing` +
  `video_hibiki_page.dart:2329`），弹缺失对话框 / 正文。其中「重新导入」按钮的 handler
  **只是空操作**：
  - 弹窗版 `_promptMissingResource`：`_MissingResourceChoice.reimport → nav.pop()`
    （`video_hibiki_page.dart:2632-2633`，原注释「M1：退回视频库…」）。
  - 正文版 `_buildMissingResourceBody`：`onPressed: () => Navigator.of(context).pop()`
    （`video_hibiki_page.dart:5394-5397`）。
  页面经 `adaptivePageRoute`（Navigator.push）推入（`home_video_page.dart:1002/1004`），
  pop 能弹回视频库——但**不触发任何导入**，破卡仍在库里，用户看着就是「没反应」。
  真正能修复的「重新选择文件」重链动作（`_relinkMissingResource`）却藏在独立按钮里，
  且只对单视频显示，用户没意识到那才是修复入口。
- **[x] ① 已修复** — commit `<pending>`。根因修复（消除「两个近乎重复、其中一个空操作」的
  坏设计）：缺失态收敛成用户预期的两个真按钮 **[重新导入] [删除]**。
  - 「重新导入」改为真动作 `_reimportMissingResource`（`video_hibiki_page.dart`）：
    单个本地视频 → 走既有 `_relinkMissingResource`（选新文件 → 重写 `videoPath` → 原地
    重载，保留进度/字幕/音轨/倍速）；播放列表/其它 → 打开与库共用的 `VideoImportDialog`
    真导入。删除旧的空操作 `nav.pop()` 与多余的独立「重新选择文件」按钮（合并进「重新导入」）。
  - 「删除」保留（单视频，二次确认）。
  - 移除枚举项 `_MissingResourceChoice.relink`，移除未用 i18n key `video_resource_missing_relink`。
- **[x] ② 已加自动化测试** — `hibiki/test/pages/video_missing_resource_test.dart`（扩展）：
  单视频缺失态正文断言 **只有 [重新导入]+[删除] 两按钮、不再出现旧的「重新选择文件」**，
  锁住两按钮契约 + 消除空操作按钮。真机验收（真实选文件重链 / 打开导入对话框走完导入）
  见备注。
- **备注**：文件选择器 / 导入对话框走完整流程需真机（file_picker / libmpv），widget 测试
  只锁 UI 契约与按钮集，不驱动原生选择器。待真机复测：单视频缺失 → 点重新导入 → 选回文件
  → 原地续播且进度保留；删除 → 二次确认 → 退回库。
