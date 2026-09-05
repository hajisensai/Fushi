## BUG-2116 · 经典 KAG3 游戏内查词传感器给 TJS 类对象打补丁对实例永远不可见
- **报告**：2026-09-04（ceshi 批量适配 · 下一款排到 Fate/stay night[Realta Nua]（KiriKiri2/BCB，无 textrender.dll）与 フタマタ恋愛/恋爱成双（KiriKiri Z + KAGParser.dll，无 textrender.dll）。既有真机记录（2026-08-14，`engine-support.yaml` notes）：Fate RN 传感器装上、查词开、连推 7 句，`classic_geometry_captured` 与 `classic_processch_fired` 全灭，同期 LunaHook 正常收到 7 行——游戏内查词在所有经典 KAG3 游戏上整个缺席）
- **真实性**：✅ 真 bug。`native/galgame_hook/hook/adapters/kirikiri_adapter.inc` KAGEX 缺席门 else 分支（原 4425 行 `global.Layer.drawText = function(...)`、4440 行 `global.MessageLayer.processCh = function(...)`）给**类对象**赋成员。TJS2 的类不是原型链：`tTJSNativeClass::CreateNew`（krkrz `tjs2/tjsNative.cpp`）把原生成员逐个注册到每个新实例上（`FuncCall(0, NULL, …, dsp) // add member to dsp`），脚本类 `tTJSInterCodeContext::CreateNew`（`tjs2/tjsInterCodeExec.cpp`）把类体在新实例上执行一遍——类对象上的成员赋值既改不了已存在的实例，也不进入以后的实例化，对实例**永远**不可见。原注释把它当成「时序/自证探针」并推测要走原生 TVPDrawText detour，方向错了：正确位置是实例自己的成员表。
- **[x] ① 已修复** — `kirikiri_adapter.inc`：新增 `fushiLookupPatchClassicLayer(layer)`（给单个消息层实例赋 `layer.drawText` / `layer.processCh` 包装，`incontextof layer` 钉死，幂等标记）与 `fushiLookupSweepClassicLayers()`（扫 `kag.fore/back.messages`，以 classic 位 0 为门，KAGEX 游戏零开销）；else 分支改为置位 + sweep；`fushiLookupRefreshCaptureBridges` 在 KAG stable 边沿补扫新建的消息层；`fushiLookupCaptureDrawText` 加影/边重绘去重（同字 ±4px 内再画一次 = 同一个字，钉到最小 x/y），否则本体落在影的左上会被「回到左上 = 换屏」判据误判成清屏。真机门未跑（用户桌面占用中），状态仍 implemented_unverified，见台账 `docs/plans/2026-09-04-gal-ceshi-batch-classic-kag3.md`。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/kirikiri_lookup_source_guard_test.py`：规则 3 取消 KAGEX 缺席门 else 的全局补丁豁免（`find_global_monkey_patches` 只认探测分支）；新增正向规则 `find_classic_sweep_missing`（门存在 + else 里调用 sweep + 存在逐实例 `<layer>.drawText = function` 形状）；`RealAdapterTest` 加真文件断言；`MutationSelfTest` 加 5 条变异（门恒真 / else 变无条件块 / else 换回类补丁 / sweep 从 else 删除 / 逐实例补丁退化为类补丁 / 只定义不调用）全部红。
- **备注**：用户原始报告是「验收要求 2-4（单击/Shift 查词、整词高亮、点外不推进）」在经典 KAG3 上不可能满足；本条只修传感器采集面，MessageLayer 每字是否真走 `this.drawText`（而非 TYPE-MOON 定制路径）要真机 `classic_geometry_captured` 位来判，那是下一个边界。

- **审查补修（2026-09-05 集成时）**：`fushiLookupPatchClassicLayer` 的幂等标记
  `layer.fushiLookupClassicPatched = 1;` 原本写在 drawText、processCh **两次包装都成功之后**。
  第二步在定制 MessageLayer 上可能抛（只读成员），而调用方 `fushiLookupSweepClassicLayers`
  把异常吞进 `catch(e) { fushiLookupFault(); }`——于是 drawText 已被包装、标记却没落下，此后
  每个 KAG stable 边沿重扫都把「上一层包装」当成 original 再包一层，N 次推进后一次 drawText
  调用递归 N 层，主线程在画字时栈溢出。标记提到第一次赋值之前：半途失败只是保持半装，
  drawText 采集仍然有效。守卫 `find_late_classic_patch_marker` + 变异自测。详见 [[BUG-2121]]。

- **真机答案（2026-09-05，フタマタ恋愛 Ver1.00 / KiriKiri Z，注入器直驱、探测分支打开）**：
  上面备注留的那个「下一个边界」——MessageLayer 每字是否真走 `this.drawText`——**答案是否定的**。

  **实测到的（不是推断）**：
  - 一段产生 15 条 LunaHook 文本事件的对白里，**实例级** `drawText` 包装一次都没触发
    （`classic_geometry` 恒灭），**类级** `global.Layer.drawText` 包装也一次都没触发
    （`probe.drawText` 零行、`classDrawText` 在该会话里没到过 1）。同一实例的 `processCh`
    包装**会**触发（`classic_processch_fired` 亮）。
  - 类级 `global.MessageLayer.processCh` 包装恒不触发（`classProcessCh=0`）。原因是顺序：
    实例补丁（`fushiLookupSweepClassicLayers`，KAGEX 缺席门 else 分支）装在探测分支
    （installStage 39）**之前**，实例包装保存的 `fushiLookupOriginalProcessCh` 是**未被类补丁
    包过**的类方法，调用链因此绕过类级探针。**这一位灭不代表「类补丁无效」**，别再据此推断。
  - 游戏 exe 静态导入 `gdi32!GetGlyphOutlineW` / `GetTextExtentPoint32W` /
    `CreateFontIndirectW` / `CreateDIBSection` / `GetFontData`；进程加载 19 个 `plugin\*.dll`，
    含 `layerExDraw.dll`（GDI+ 绘图插件）、`KAGParser.dll` / `ExtKAGParser.dll`。
  - 输入侧没有问题：`kagSeams=30`（`0x1E` = onPrimaryClick|onMouseMove|onMouseWheel|onKeyDown）
    四个接缝全装上；鼠标移动时 `lookup.coord.v1` 正常流动，只是 `N=0`（registry 空）。

  **推断（标注为推断）**：对白正文由引擎 native 层逐字形光栅化后直接合成，不经过 TJS 的
  `Layer.drawText` 成员查找。`Layer.drawText` 是 native 成员，TJS 层给类或给实例赋值都不在
  它的内部调用路径上——所以几何采不到**不是补丁装错了对象**，是这条路上根本没有可拦截的
  TJS 调用。BUG-2116 的修复（逐实例补丁）本身是对的，只是对这一类游戏拿不到 drawText。

- **踩坑记录：不要整体枚举活的引擎对象成员（2026-09-05，真机把游戏弄崩了一次）**：
  为了不猜字段名，我试过在 `processCh` 实例包装里用
  `var dic = %[]; dic.assign(layer);` 整体枚举图层的数值成员，想靠「调原始实现前后谁前进了
  `font.getTextWidth(ch)`」自校准出 x 光标。**结果游戏弹出 KiriKiri 全局脚本异常框
  `Script exception raised / Member "enabled" does not exist`，一条数据都没采到。**
  `Dictionary.assign` 会逐个**读取**源对象的所有成员，踩到任何一个读取即抛的属性就炸，
  而那是 native 侧抛的、**TJS 的 `try/catch` 拦不住**（我已经把 assign 包在 catch 里了，
  照样弹框）。已回退，未进任何提交。
  后续要做自校准发现，只能**逐个候选名各自 try/catch 单独读**，绝不能整体 assign。

- **下一个边界**：几何来源。processCh 拦得到、每字符一次、能拿到字符本身和
  `font.getTextWidth(ch)`，缺的只是屏幕坐标锚点。候选方向（都未验证，别当结论）：
  ① 逐个候选名安全读取 KAG3 标准字段推出光标；② 从已被 `text_render_adapter` 钩住的
  `gdi32!GetGlyphOutlineW` 侧取字形度量并与 processCh 关联；③ 自己维护光标（累加字宽 +
  按层宽推断换行）。三条都要真机验证，不要在没有实测前写进采集路径。

- **失败的修复尝试与回退（2026-09-05，三次真机崩溃，已全部回退）**：
  「对白层可能不在 `kag.fore/back.messages` 里」这个方向我试了三版，全部让游戏崩，已回退
  （commit `9db5a83578`，三个文件回到 `f3e644f42a`）。留档是为了让后来者别再走一遍：

  | 版本 | 做法 | 真机结果 |
  |---|---|---|
  | ① | 从 `kag.primaryLayer` / `fore.base` / `back.base` 走整棵窗口树，深度 12 / 预算 512 | `Script exception raised / Member "enabled" does not exist`，窗口丢失 |
  | ② | 收窄到**消息层子树**，深度 4 / 预算 64 | 同样的 `enabled` |
  | ③ | 退回 `fushiLookupProbeMode` 后面、**默认关**（`decdiag` 实测 `0x80` 不亮，树遍历不执行） | **仍然崩**，这次是 `Member "CS_Timer" does not exist` |

  **③ 是关键**：树遍历已经不执行了却照样崩，说明我对症结的判断（"给 messages 之外的层
  注入成员会和 KAG3 的页交换/状态存恢复冲突"）**没有得到证实**，而我还在往同一个方向改。
  用户用**完全不注入**的干净实例验证游戏本身正常（无错误框）；而本轮早些时候**带注入且
  不含这批改动**的构建（pid 78904 / 28584）被用户正常推进过对白。所以嫌疑落在本轮对
  `kirikiri_adapter.inc` 的改动上，**但具体哪一处未定位**——`CS_Timer` 与 `enabled` 是
  不同符号，两者的因果可能也不同。

  因此没有保留任何一部分，连"默认关的死代码"也没留：第三次崩溃恰恰发生在默认关的构建上，
  无法证明它无害。

  **仍然有效的知识**（不依赖被回退的实现）：
  - `kDiagKirikiriClassicTreePatched` 亮过 ⇒ **消息层确实有子层**，扫描面扩得到，
    「对白层不在 messages 里」这个假设本身没有被证伪，只是不能靠常驻注入去验证。
  - 下次要走这条路，必须先有一个**不修改游戏对象**的观测手段（例如从 native 侧看
    `gdi32!GetGlyphOutlineW` 的调用者栈，或只读不写地比对层的位图内容），
    确认对白层身份之后再谈补挂。**不要再用"先注入再看"的办法**。
