## BUG-1419 · Windows 阅读器右键后左键点击只出蓝色选区、查词失效（WebView2 鼠标键状态粘滞）

- **报告**：2026-08-02（用户：书籍里面，右键复制以后，点击查词只会出现原生蓝色的高亮，查不了词。平台 Windows 桌面，「点击查词」= 鼠标左键单击一个词）
- **真实性**：✅ 真 bug（架构缺陷已静态确证；真机复现待用户在 Windows 验证，见备注）。与 BUG-927 同症状不同层：927 修的是阅读器 JS 手势层（早退条件 + 复制后清选区，修复仍在、守卫仍绿），本条在其**下游的平台层**——fork 的 WebView2 鼠标键状态同步。
  - 根因：`packages/flutter_inappwebview_windows/windows/in_app_webview/in_app_webview.h:71` 的 `VirtualKeyState::set()` 是**粘滞增量位集**——只有 `setPointerButton` 的 down/up 会翻转 `MK_*` 位，没有任何自愈路径；而 `custom_platform_view.dart` 旧实现（`onPointerDown`）把 `ev.buttons` **整个位掩码**喂给只接受单个位的 `_getButton`，结果存进 `_downButtons[ev.pointer]` 的是**单值** `PointerButton`。
  - 触发：`ev.buttons` 在多键并按时是复合值（左|右 = `kPrimaryMouseButton | kSecondaryMouseButton` = 3），`_getButton(3)` 落进 `default → PointerButton.none`，**覆盖掉**该 pointer 已记的按钮；抬起时 `_downButtons.remove` 取回 `none` → 对应的 button-up **永远发不到 WebView2**。同族触发还有：模态路由（阅读器右键走 `_showReaderTextContextMenu` → `showMenu` 的 `PopupRoute`）期间指针序列被打断、指针在 WebView 之外抬起。
  - 后果：`MK_*` 位永久卡死。此后每个 `SendMouseInput(MOVE, virtualKeys_.state(), ...)`（`in_app_webview.cpp:1893`）都带着「某键仍按住」进 Blink，被判成**拖拽**：鼠标一动就把正文刷成**原生蓝色选区**，而 click 不成立 → 阅读器 `_gestureEnd` 的 tap 分支（`webview.part.dart:1093`）拿不到干净的点击，`selectText` → `onTextSelected` → 查词弹窗整条链永久失效。旧实现按 pointer id 分桶，而 hover 是**另一个 pointer id**，所以残留位连「移动鼠标」都无法自愈，只能重启 app。
  - 为什么是 Windows 独有：Android/iOS/macOS 的 WebView 是真平台视图，指针由系统直送；只有 Windows 合成模式经 fork 手工转发鼠标状态，才存在这份可漂移的副本。
- **[x] ① 已修复** — 状态所有权归一：按钮真值唯一来源是 Flutter 每个指针事件自带的 `ev.buttons` 掩码，fork 不再维护可漂移的副本。
  - `custom_platform_view.dart`：删除 `_downButtons` 单值记账，改为单个全局 `_mouseButtons` 掩码（鼠标是单一设备，状态天然全局——按 pointer id 分桶正是 hover 无法自愈的原因）。
  - 新增纯函数 `diffMouseButtonMasks(previous, next)`：逐位比对，只对**变化**的位产出一次 down/up 翻转，掩码未变返回空表（按住不动时重发 down 会污染 Blink 拖拽判定）。
  - `onPointerHover / Down / Up / Cancel / Move` 五个非触摸入口统一调 `_syncMouseButtons(ev.buttons)`。hover 的掩码恒为 0，成为**残留位的自愈点**：任何原因漏发的 up 都会在用户下一次移动鼠标时补上，不再需要重启 app。触摸路径（`_setPointerUpdate`）不受影响。
  - 提交：（见 PR）
- **[x] ② 已加自动化测试** — 两层：
  - 行为层 `packages/flutter_inappwebview_windows/test/mouse_button_mask_diff_test.dart`（7 例）：单键成对、右键不再被当成 none、**多键并按各自成对**（根因用例）、掩码归 0 时补齐所有残留位、未变化不下发。
  - 结构层 `hibiki/test/reader/webview2_mouse_button_sync_guard_test.dart`（4 例，进 CI 单测门）：钉死 `_downButtons` 不得复活、`_getButton` 不得再吃整个掩码、五个入口都接线、差分必须走纯函数且跳过未变化位。fork 包自己的 test 目录不进 CI（真门只跑 `hibiki/test`），故结构守卫放 hibiki 侧。
  - 变异实测：删掉一处 `_syncMouseButtons(ev.buttons)` → 守卫报「实际只有 4 处」变红；把 `if (wasDown == isDown) continue;` 改成恒假 → 守卫与行为单测同时变红。两次均反向替换还原并逐字节核对。
- **备注**：
  - 与 BUG-927 的关系：927 的三处修复（pointerup 早退只认 `nativeMoved`、两处 copy 后 `_clearReaderAppSelection`、右键 eval try/catch）**全部仍在且守卫全绿**，本条不是它的回退。927 修好了「JS 侧残留选区吞点击」，但当平台层把 MOVE 标成拖拽时，蓝色选区是 Blink **持续重建**的，JS 侧 `clearSelection` 清完立刻又被画回来——所以症状复现而根因在下游。
  - 真机验证缺口：本机未复现原始失败路径（需 Windows 真实鼠标序列 + WebView2 合成渲染，离屏 itest 的既有冒烟目标长期红、且合成鼠标绕不过 fork 转发层）。架构缺陷本身由源码确证并有行为单测覆盖；**是否根治用户症状需在 Windows 构建后按原路径复测**：拖选 → 右键 → 复制 → 左键单击一个词 → 应正常弹词典。
