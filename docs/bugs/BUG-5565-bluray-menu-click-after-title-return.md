## BUG-5565 · 远端蓝光原盘：播完 NCOP 回到「映像特典」子菜单后点 NCED 没反应（Android）
- **报告**：2026-11-27（应用内反馈 S20XFQYC6g，Android 3.4.0+1003256302，OnePlus CPH2747 横屏，经互联播放远端《魔女の旅々 上巻》BD）
- **真实性**：⚠️ 未复现，根因未定。已排除与已确认的部分：
  1. **原生导航链路在 Windows 上正常**（随包 `libmpv-2.dll`，与 Android 制品同一份 `disc-navigation-state.patch`，sha256 `5edcd0de…`；
     同一张盘 `Majo no Tabitabi [BDMV]/Disc 1`）：Python ctypes 直接驱动 libmpv（`vo=null`），`discnav menu` → 等菜单可交互 →
     `discnav mouse-click 0.415 0.883`（映像特典）→ `mouse-click 0.415 0.729`（NCOP，title 2 起播）→ 播完回到 title 0、菜单可交互 →
     `mouse-click 0.415 0.767`（NCED）返回 0，随即 title 3 / playlist 3 起播。本地目录与「HTTP Range + manifest.json 的远端盘共享」
     （`bluray-device=http://…/`，走补丁里的 `bd_open_files` 远端读）两种打开方式结果相同。所以「标题结束回菜单后 IG 页状态没恢复」
     「激活被接收但 HDMV 命令没执行」在这台盘 + 这份补丁上都不成立。
  2. 用户日志里只有 3 条 `VideoDiscMenu.input`「input not consumed」，坐标都在按钮外（映像特典下沿、左侧空白、人物帽子），
     盘的拒收是对的。点 NCED 的那几下**没有任何记录**：要么盘「接收」了（见下面第 3 点），要么 Dart 侧根本没转发
     （`_onDiscSurfaceTap` → `resolveDiscSurfaceTap` 走了 `dismissOverlay` / `toggleBar` / `ignore`，这几条都不记日志）。
  3. **潜在缺陷（已从 libbluray 1.5.0 源码确认）**：`graphics_controller.c` 的 `_user_input` 在 `!gc->ig_drawn`
     （「menu not visible」）与 `gc->button_effect_running` 时返回 **0**（输入被忽略），而补丁的 `STREAM_NAV_MOUSE_CLICK`
     只把 `bd_user_input(...) < 0` 当失败（`stream_bluray.c`），于是一次被 libbluray 吞掉的点击在 mpv / Dart 两层都报「已接收」：
     页面不提示、不记日志——与「点了没反应、日志里也没有」的现场同形。单回路的按钮选中动画（`selected_repeat_flag == 0`）
     会在同一个 `mouse-click` 里先被 `_mouse_move` 触发、再让紧随的激活落进这个分支。本机这张盘上没触发（点击都返回 0 且生效），
     用户设备上是不是它，没有设备证据不能断言。
- **[ ] ① 未修复** — 没有可复现的根因，不做猜测性修改。要定根因需要：Android 真机 + 同一张盘经互联播放，记下点 NCED 时
  `_onDiscSurfaceTap` 的分流结果与 `discnav mouse-click` 返回值；若确认是第 3 点，正确修法是改补丁让 `bd_user_input == 0`
  的 `MOUSE_CLICK` 报未接收（并把「点中按钮但被动画吞掉」与「点在空白」分开透出），三端 libmpv 重编（Android / Darwin
  走 fork 镜像仓、Windows `tool/bluray/build_libmpv.ps1`，各自 provenance 钉值同步更新）。
- **[ ] ② 未加自动化测试** — 根因未定。
- **备注**：复现脚本思路（不入库）：`tool/bluray/probe_libmpv.py` 的 `Mpv` 封装 + `set bluray-device <盘根或共享 URL>` / `set disc-menu yes` /
  `loadfile bd://`，按 `disc-navigation-state-json` 的 `title` / `menu-active` 轮询推进；菜单刚变为可交互的一两秒内（IG 入场效果）
  点击会返回 -12，等效果结束再点。
