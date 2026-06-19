## BUG-341 · develop 倍速菜单守卫陈旧致预存红 (TODO-601)
- **报告**：2026-06-19（CI 实证：Build Release APK 步骤 `dart run tool/flutter_test_failures.dart --exclude-tags golden` 红）
- **真实性**：✅ 真 bug（陈旧守卫，非功能回归）。根因 = 两个源码扫描守卫硬编码的 `_showSpeedMenu` 精确签名串过时：
  - `hibiki/test/pages/video_controls_cleanup_guard_test.dart:111`（旧）断言 `src.contains('void _showSpeedMenu({LayerLink? popoverLink})')` → false
  - `hibiki/test/pages/video_menu_guard_test.dart:77`（旧）同样断言该精确串 → false
  - 真实源码 `hibiki/lib/src/pages/implementations/video_hibiki_page.dart:6012` 签名已是
    `void _showSpeedMenu({LayerLink? popoverLink, VideoControlSlot? sourceSlot})`（多了 `sourceSlot` 形参）。
  - 引入提交 `471602782 fix(video): speed popover follows button slot (TODO-560/BUG-325)`：给倍速浮层加「跟随触发按钮 slot」能力，扩了签名，但没同步更新这两个守卫的字符串模式。
  - 功能完整无回归：6013 `if (popoverLink == null)` fallback、6014 `_showVideoSidePanel(_VideoSidePanelKind.speed)`、6017 `_toggleControlPopover(_VideoControlPopoverKind.speed)`、调用点 5223、右键菜单引用 7352 全在。
- **[x] ① 已修复** — commit `fb477fea3`。把两处硬编码闭合签名串改为「方法头前缀」匹配（`void _showSpeedMenu({LayerLink? popoverLink`，不含闭合括号），对未来追加形参鲁棒；不削弱守卫意图。`sourceMember(src, ...)` 的起点也改用同一前缀（前缀真实存在，`indexOf` 命中，方法体提取不变）。
- **[x] ② 已加自动化测试** — 复用并加强这两个守卫本身：
  - `hibiki/test/pages/video_controls_cleanup_guard_test.dart` 在保留前缀断言基础上，**新增正向反向锁**：正则 `void _showSpeedMenu\(\{LayerLink\? popoverLink, VideoControlSlot\? sourceSlot\}\)` 必须命中（撤掉 BUG-325 的 `sourceSlot` 真功能会重新转红，已离线验证 reverted 源码该正则 → false）。
  - `hibiki/test/pages/video_menu_guard_test.dart` 前缀断言同步更新。
  - 两守卫单跑 +8 全绿；CI 精确命令 `dart run tool/flutter_test_failures.dart --exclude-tags golden` 全量后两条不再失败。
- **备注**：纯守卫测试更新，不动 `video_hibiki_page.dart`（高冲突文件，仅只读确认签名）。全量跑中另有 3 个 Windows 临时目录删除竞态（`video_book_tags_test` / `video_shader_manager_test` / `backup_service_test` 的 `PathNotFoundException` / 目录非空 errno=2/145），单独重跑 +61 全绿 → 与本改动无关的本机文件系统 flaky，CI 跑在 Linux 不出现。守卫为纯源码扫描，无需设备复测。
