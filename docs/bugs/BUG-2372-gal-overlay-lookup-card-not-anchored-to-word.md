## BUG-2372 · 悬浮字幕查词弹窗没锚在被点的词上
- **报告**：2026-09-09（用户：「galgame 的这个悬浮字幕的辞典弹窗位置也不对」→ 追加「悬浮字幕的查词弹窗位置 应该是对应单词的位置」）
- **真实性**：⏳ **未定位**。已排除三条最像的假根因（见下），锚点接线本身是通的；
  缺的是真实落点数值，已加诊断日志待一次复现。

### 已排除（都有实测依据，不是读代码读出来的印象）

1. **不是**「根卡按最大高钳位、渲染却更矮 → 留出空档」（[[BUG-2082]] 在桌面 route 的同形缺陷）。
   `hibiki_glookup.log` 的 `reveal(box)` 行里 `root=773`，而 `cardH*dpr = h0/2.0 = 773`
   —— **根卡渲染高度恒等于最大高度**，钳位没有多余量可留。
2. **不是**游戏内查词的画布 cap 污染桌面 route。`setPhysicalCap()` 在 gal route hide 时会清；
   且日志显示这台机上 gal 内查词全程 `geometryAdmission=disabled`。
3. **不是**锚点没接线。`gal_hook_text_overlay_channel.dart:1168` 确实传了 `_wordRect(args)`，
   一路到 `GlobalLookupController.lookupText(anchorScreenRect:)` → `showAt(atCursor:false)`。
   native 侧 `DispatchLookupAt` 的换算（client 物理 px + `GetWindowRect` → `/scale`）也自洽，
   `showAt` 选显示器用的是**锚点**而不是光标。

### 按用户真实设置算出来的期望落点（读生产库）

- 浮窗 rect：`left=555 top=152 width=2618 height=219`（物理 px）→ CSS `370,101,1745x146`，
  **在屏幕顶部**。
- 卡片：`overlay_lookup_max_*` = `641x368` CSS × `appUiScale 1.4` = `897x515` CSS。
- 工作区 CSS `2560x1440`（4K@150%）。

词在 y≈101..247 CSS，下方余量 1193 > 515 → `computeRootShellOffset` 纵向偏移应为 **0**，
卡片应当正好贴在词的下方。横向仅当词的 x > 1663 CSS 时才左移（贴屏幕右缘，仍紧邻词）。
**也就是说按现有模型算，卡片本该就在词下面——与用户观察矛盾，说明模型里有一个我还没找到的输入是错的。**

### 待办

- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** —

已在 `global_lookup_controller.dart` 加一条诊断 glog（本 PR）：一次记全
`anchor`（逻辑 px）/ `dpr` / `appUiScale` / 真正投给 native 的**物理** `showAt` 坐标 /
`cardCss` / `cap` / native 回报的 `work`+`origin`+`monitorDpr`。配合随后的 `reveal(box)`
即可把卡片最终屏幕位置反算到像素，定位「模型里哪个输入是错的」。

复现方法：跑本分支构建的 `fushi.exe`，在悬浮字幕上点一次词，然后取
`%TEMP%\hibiki_glookup.log` 里最后的 `lookup: anchor=...` 与 `reveal(box):` 两行。
