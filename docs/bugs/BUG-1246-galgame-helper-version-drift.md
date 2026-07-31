## BUG-1246 · 随包 helper 已更新但完整旧安装被直接放行，native 修复永远不生效
- **报告**：2026-07-29（用户：「启动游戏总是没反应，是不是卡住什么了」）
- **真实性**：✅ 真 bug。用户机当前包 `1.3.1-debug.9445` 的
  `galgame_helper/voice_hook_x86.zip.sha256` 为 `4d6d2b2e…`，实际被启动路径读取的
  `voice_hook/x86/installed.sha256` 却仍为 `b72b437a…`，两份 injector SHA-256 也不同；
  `hibiki/lib/src/mining/galgame_helper_installer.dart:339`（修前）在必需文件齐全时直接 `return true`，
  从未读取自己在安装尾段写下、注释明确称作「自动更新比对基线」的 `installed.sha256`。
  因而 app 更新随附了 native 修复也不会换入，只要旧目录文件齐全就永久漂移。
- **[x] ① 已修复** — 启动前先以当前随包侧车摘要对账完整安装：摘要一致才直接放行；
  标记缺失、损坏或不同均走既有「校验 zip → staging 解压 → 清单复检 → 原子换入」路径。
  正式包的 zip/侧车残缺或校验失败时保留旧目录但拒绝拿它启动；两份随包资产都不存在的
  旧包/开发构建仍可继续使用完整现有安装。
- **[x] ② 已加自动化测试** —
  `hibiki/test/mining/galgame_helper_installer_test.dart` 增加真实文件行为测试：完整旧安装
  即使文件一个不少，只要 marker 与随包版本不同，就必须换入新 injector 并重写 marker；
  另锁定无随包资产的开发构建不得误删或拒绝完整旧安装。
- **备注**：
  - 本修复解决的是「当前 app 随附 helper 无法抵达实际启动路径」；本次现场游戏 PID 63196
    的主线程确实处于 `Suspended`、无窗口，属于 BUG-1092 的原始失败形态，但仅凭该现场不能
    反推新版随包 helper 已彻底消除所有挂起来源，仍需之后从游戏库原始路径补真机 E2E。
  - 用户明确本轮不用等待 native 双架构编译与真机验收；PR 必须如实保留这一验证缺口。
