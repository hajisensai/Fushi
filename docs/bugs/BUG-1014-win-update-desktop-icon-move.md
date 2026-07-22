## BUG-1014 · Windows 更新后桌面快捷方式移位
- **报告**：2026-07-22（用户：每次更新后桌面图标会移动位置）
- **真实性**：✅ 真 bug。Windows 应用内更新走 Inno Setup 覆盖安装（`hibiki/lib/src/utils/misc/platform_updater.dart:264` `WindowsInstaller.runAndExit` → `/VERYSILENT` 静默安装）。根因在安装脚本 `hibiki/windows/installer/hibiki.iss:43`（旧）：`[Icons]` 无条件创建 `Name: "{userdesktop}\Hibiki"`，每次更新都把桌面上已存在的 `Hibiki.lnk` 重写一遍。Explorer 把被重写的快捷方式当作变更/新项，丢弃 `HKCU\...\Shell\Bags` 里记住的图标坐标，把它重排回默认格子 → 用户观感「每次更新图标移位」。
- **[x] ① 已修复** — `hibiki/windows/installer/hibiki.iss`：桌面图标改为可选任务 `desktopicon`（默认勾选，保持首装即有图标的旧行为）+ `Check: ShouldCreateDesktopIcon`（`not FileExists({userdesktop}\Hibiki.lnk)`）——仅在快捷方式尚不存在时创建。首装照建；后续更新检测到 `.lnk` 已在即跳过、不重写、位置保留。提交：<pending>
- **[x] ② 已加自动化测试** — `hibiki/test/build/windows_installer_desktop_icon_guard_test.dart`（源码扫描守卫，3 用例）：桌面图标行必须挂 `Check: ShouldCreateDesktopIcon` + `Tasks: desktopicon`；`ShouldCreateDesktopIcon` 函数逻辑为 `not FileExists({userdesktop}\Hibiki.lnk)`；`desktopicon` 任务默认勾选（不带 `unchecked`）。提交：<pending>
- **备注**：真机验证（装旧版→在桌面把 Hibiki 图标摆到自定义位置→应用内触发一次更新→确认图标停在原位不回默认格子）尚待在 Windows 真机走一轮覆盖安装对照；本轮只做根因修复 + 源码守卫。若用户此前手动删过桌面图标，静默更新会因 `.lnk` 不存在而补建一个（放默认位置），符合直觉，非回归。
