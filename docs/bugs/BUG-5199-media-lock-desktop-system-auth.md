## BUG-5199 · 上锁作品：Windows / Linux 没有系统验证（只有口令）
- **报告**：2026-11-22（PR #4144 审查）
- **真实性**：✅ 真缺口。`fushi/lib/src/media/privacy/media_lock_auth.dart` 的 `ChannelDeviceOwnerAuth` 走 `fushi/device_owner_auth` 通道，只有 Android（`DeviceOwnerAuthChannel.java`）与 Apple（`FushiDeviceOwnerAuth.swift`）实现；Windows / Linux 上 `isAvailable()` 为 false，只能用口令。后果：桌面端没口令时不能「忘了口令用系统验证重设」，也不能在同步来锁、口令还没到时自助解锁（按设计拒绝，见 `MediaLockVerifyPlan.blocked`）。
- **[ ] ① 未修复** — Windows 接 Windows Hello（`Windows.Security.Credentials.UI.UserConsentVerifier`，Runner 里 C++/WinRT 实现同名通道）；Linux 可评估 polkit `pkcheck` / fprintd，拿不准就保持只用口令。
- **[ ] ② 未加自动化测试** — 通道契约测试 + Windows 集成测试。
- **备注**：Android / Apple 的系统验证也未在真机上验过。
