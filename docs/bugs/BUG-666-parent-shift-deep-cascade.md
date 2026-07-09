## BUG-666 · app 外查词深层级联父弹窗残留 1 帧位移

- **报告**：2026-07-09（用户：TODO-1231 第六轮复诉「父卡还是会动一下，查词的时候」；续 BUG-583 五轮修复后残留）
- **真实性**：✅ 真 bug（沿真实代码路径定位；Windows app 外全局查词覆盖窗 = WebView2 裸窗；BUG-583 前几轮报告自陈「深层级联罕见 1 帧残留·非本轮目标」，本轮根治）
  - 根因（**深层级联父卡残留 1 帧位移**）：`hibiki/lib/src/lookup/global_lookup_layout.dart` 的 `computeCascadeHeadroomSeed` / `_cascadeHeadroom`（旧 :315）把根卡首帧预留的「级联余量地板」定为**一张卡**（`headroom = min(card, 光标到边距离, 工作区维度 - card)`）。BUG-583 第五轮（TODO-1345·`d2c57193a`）用这个地板让向左/上子卡落在已提交窗口原点内、origin 首帧冻结、父卡零位移——但**只覆盖一层、一张卡以内的级联**。当级联更深（**孙卡**=第 3 层·或**单张子卡高/宽过一张卡**）时，子卡 shell 最外边越过一张卡地板：host `global_lookup_host.js` `measureAndReport`（:1090-1114）在该子卡 content-ready 那刻把 union bbox 最小角（origin）外拉过地板 → Dart `global_lookup_controller.dart` `_applyOverlayBox`（:1549）棘轮 origin 外移 → C++ `global_lookup_window.cpp` `RevealStack`（:384 `SetWindowPos`）移窗 + `commitLayerShift`（:402 经 `ExecuteScript`）慢约 1 帧补偿，钉住的父卡先跳后弹 = 用户看见的残留 1 帧位移。前几轮把它当「跨 DWM/WebView2 平台残留·不可消除」，实为**地板预留不足**（只留一张卡）。
  - 几何根因：`computeFrameRect`（同文件）把**任意层级**级联子卡的中心 clamp 进 `[w/2(+边距), screenW-w/2(-边距)]`，故子/孙/曾孙卡最外边最远只能触到**工作区该侧边缘**（window-local ≈ `-cursorWork`）。预留「一张卡」（`-card`）在 `cursorWork > card` 时被越过；预留**到工作区边**（`-cursorWork`）则覆盖所有层级级联极值，origin 从首帧就冻结、任意深度零位移。
- **[x] ① 已修复** — commit `ca799ef70`
  - `global_lookup_layout.dart` `_cascadeHeadroom` 改为 `headroom = cursorWork`（reserve to the work-area edge，兜底夹 `<= screenWork`），删掉「一张卡」`card` 项与 `screenWork - card` 夹紧；`computeCascadeHeadroomSeed` 去掉 `cardW`/`cardH` 参数（不再用）。控制器 `global_lookup_controller.dart` `_lookupExternal` 调用点同步去掉 `cardW`/`cardH`。host（`measureAndReport` 的 `if (originFloorLeft < minLeft) minLeft = originFloorLeft`）与 C++ `RevealStack`/`commitLayerShift` **不动**——地板值由 Dart 推入，只是从「一张卡」扩到「到边」。
  - 为何预留到边**安全**（不触发 C++ 工作区 clamp 的 origin/layer 失配）：地板把窗口原点恰好定在工作区该侧边（on-screen origin == `rcWork.left/top`），正是 C++ 左/上 clamp（`global_lookup_window.cpp:381-382`）的目标值；即便远端内容让窗口比屏还宽、C++ 右/下+左/上双向 clamp，最终原点仍落在工作区边 == `commitLayerShift` 用的 bbox 值 → **绝无失配位移**（反而是旧「一张卡」地板在窗口过宽的退化场景才会失配）。光标贴左/上边时该侧余量趋 0（退化为修前几何·Never break userspace）。
  - 代价：向左/上侧透明预留区从「一张卡」扩到「到工作区边」（仅上/左方向）。该区点击经 host 命中 gap → dismiss（与 BUG-583 棘轮既有透明区同性质·点弹窗外本就 dismiss·功能无碍），会话结束复位。
- **[x] ② 已加自动化测试** — `hibiki/test/lookup/global_lookup_layout_test.dart`
  - `computeCascadeHeadroomSeed` 组 6 例改为「预留到边」语义（deep-inside 取 `-cursorWork`·edge 取 0·夹到光标距离·脏数据夹 `<= screenWork`·无工作区退化 0·恒非正）。
  - **核心几何守卫**新组「floor covers every cascade card」：对横排/竖排、多组光标位置，遍历工作区内所有 anchor 跑 `computeFrameRect`，断言每张级联卡的 window-local 原点 `>= 地板`（即 host `min(shellLeft, floor) == floor`·origin 恒不外移·父卡零位移）。旧「一张卡」地板在 `cursorWork > card` 时**必红**（正是残留根因）。
  - 既有守卫 `hibiki/test/lookup/global_lookup_inapp_isolation_guard_test.dart` 与 node harness `#46/#47`（host 按注入 floor 冻结 origin）**不受影响**（改的是 Dart 如何算 floor·非 host 契约）。
- **备注**：WebView2 覆盖窗渲染无法离屏自动化，最终视觉验收是**真机**。真机口径：Windows 让被查词靠近屏幕**右/下边** → app 外划词根卡出现 → 卡内**逐层嵌套查词**（父→子→孙·使子/孙卡向左/上**深层**级联超出一张卡） → **父卡任意层级打开子/孙卡时绝对不动**（对比修前：深层那次父卡向右下跳 1 帧）。向右/下常见级联、单层浅级联照旧零位移（回归）。
