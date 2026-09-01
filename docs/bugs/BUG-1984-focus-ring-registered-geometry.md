## BUG-1984 · 复合控件焦点环读取内部 Focus context 导致边界错位
- **报告**：2026-08-31（用户截图：下载资源页搜索框获得焦点时出现巨大且错位的焦点环）
- **真实性**：✅ 真 bug。`fushi/lib/src/utils/components/fushi_focus_ring.dart:228 与 :235` 直接读取 `FocusNode.context`；`SearchBar` 等复合控件的该 context 属于 Flutter 内部编辑区域，而 `FushiFocusRegistration` 已在外层登记了完整视觉锚点却未被焦点环消费。回归测试在修复前测得搜索框左边界为 `0`、焦点环左边界为 `38`。
- **[x] ① 已修复** — `FushiFocusController.geometryContextFor` 统一优先返回与主焦点节点精确匹配的已注册视觉锚点；全局焦点环绘制与自动滚动共同消费该边界，未注册控件仍回退原生 context。提交见本 PR。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_focus_ring_test.dart:518` 使用真实 `FushiSearchField` 验证四边均贴合完整搜索框；定向文件共 10 条用例通过。
- **审查补修**（同一 PR 内）：
  - **原改动在生产里基本永远不生效**。焦点环把控制器缓存在 `didChangeDependencies`
    里，而 `main.dart` 的 `runApp()` 在 `initialise()` 之前执行（先给用户看加载页
    而不是白屏），第一帧偏好还没加载完、`experimentalFocusNavigationEnabled` 恒读
    默认 false，于是缓存下来的是 `null`；`listen: false` 走
    `getInheritedWidgetOfExactType`、**不建立 inherited 依赖**，之后开关翻转只触发
    `didUpdateWidget`，缓存不刷新。冷启动（偏好已开）、运行时翻开关、以及**全部
    集成测试**（`focus_driver` 就是「app 起来后再翻开关」）三条路径全废——合进去
    用户看到的错位焦点环一点变化都不会有。而原新测试从第一帧起就 `enabled: true`，
    所以照样绿：它证明了算法对，完全证明不了接线对。
    改成不缓存的 `_focusGeometryContext()` 就地解析，绘制与 reveal 共用这一份；
    补「`enabled: false → true` 之后仍贴合」的冷启动时序回归测试。变异实测：改回
    缓存写法 → 新用例红、原用例仍绿。
  - **`geometryContextFor` 里那条 `!nativeContext.mounted → null` 是空转**：两个调用
    点都写着 `?? primaryFocus?.context`，返回 null 会被 `??` 把同一个 unmounted
    context 立刻递回去。未受管分支改成直接返回 `focusNode.context`，mounted 由消费
    侧各自把关（`globalRectOfContext` 与 `FushiFocusScroll` 都查）。
  - **匹配到 entry 但锚点不可用时改成 `return null`**，不再 `continue` 落到 native
    context 回退——那等于「锚点暂时不可用就悄悄退回**已知错位**的内框」，画一个
    确定错的框比不画更糟。顺带删掉冗余的 `entry.context.mounted`（`_isCurrentRoute`
    第一行已经查过）。
  - **几何刻意不看 `canFocus`**，与其余 4 处按节点身份找 entry 的地方（那些问的是
    「还能不能聚焦」，走 `_entryCanFocus`）判据不同是**有意**的，已在 doc comment
    里写明，防止下一个人顺手"统一"过来。
  - 测试里 `SizedBox(width: 900)` 改 600：测试面只有 800 宽，900 会被夹到 800，而
    `_computeFocusRect` 的近全屏早退门槛是 `sw * 0.92 = 736`——那时只靠高度
    56 < 552 才没触发，离静默返回 null（整条断言空转）只差一个条件。
  - build 号 1238 → 1239（develop 已占用 1238）。
- **已知欠账**：
  - `gamepad_service.dart` 仍是**第三种**几何解析（`controller.activeContext ??
    primaryFocus?.context`），在 primaryFocus 不受管时会回退到上一个 active entry
    的 context（即错误的控件），与 `geometryContextFor` 的回退真的会分叉。
    「统一几何」目前只做到 2/3。
  - `geometryContextFor` 被 `_armFrameTracker` **逐帧**调用，是 5 处同款扫描里唯一
    每帧的一处（其余 4 处事件驱动）。O(n) 线性扫描在几十到低百个 entry 上是亚微秒
    级、远小于同一回调里的 `localToGlobal`/`globalToLocal`，**没有实测数据就改数据
    结构属于过早优化**，故不做；真要做反查表须处理三个生命周期陷阱（`register` 是
    不经 `unregister` 的覆盖写、`unregister` 有 id+node+owner 三重身份闸、一个
    FocusNode 可对应多个 id 而现有仲裁是「取插入序第一个」）。
  - `_ensureVisibleIfHidden` 的行为变化比 PR 描述的更大：改锚点后
    `Scrollable.maybeOf` 第一次命中**页面**的滚动区（以前命中 `EditableText` 自带的
    内部横向滚动区，根本滚不动页面），所以「聚焦搜索框会让页面滚动」是新行为；
    锚点框更大也让 `fullyVisible` 判据变严。与 `_scheduleReveal`（本来就用锚点）
    对齐，属有意收敛，但未做真机复测。
- **备注**：首次测试在任何用例执行前被 `pdfium` 原生资产下载超时阻断；使用仓库本地代理重跑后 10 条全部通过。按用户要求未等待全量测试或 Windows 真机视觉验收。
