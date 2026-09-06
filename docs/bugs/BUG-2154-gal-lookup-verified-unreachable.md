## BUG-2154 · 内嵌查词对每个游戏都恒需手动「确认点击风险」：shield 的 Verified 状态在 hook 里无任何生产者、结构上不可达
- **报告**：2026-09-05（用户：「这个フタマタ恋愛 根本没有显示」）
- **真实性**：✅ 真 bug（结构性），真机 フタマタ恋愛 Ver1.00（KiriKiri Z，pid 49200/78904）实测。

### 根因链（每一步都有代码位置）

1. **通用覆盖恒 Partial 是有意设计，不是 bug。** `hook/generic_input_shield.inc:115-119`
   把这条写死在注释里：
   > Generic public-API coverage is always Partial (or a stricter KnownUncovered/Faulted
   > conclusion), **never Verified**; this micro-window is part of the **explicit risk
   > acceptance**.

   `ClassifyGenericShieldCoverage`（`include/generic_input_shield.h:95-104`）因此根本没有
   Verified 这个返回值，只有 Faulted / KnownUncovered / Partial / Unknown。**这一层没错。**
2. **但 `Verified` 在全仓没有任何生产者，所以它对谁都不可达——包括有精确 profile 的游戏。**
   `lookup_shield_status_flags` 全仓只有三个赋值点，全在通用层：
   `generic_input_shield.inc:1119`（Faulted）、`:1122`（KnownUncovered）、`:1128`（Partial）。
   `kLookupShieldStatusVerified` 只在 `include/voice_hook_ipc.h:1591-1597` 被**消费**，
   从未被**请求**过 ⇒ 那段消费逻辑（`fully_ready && !risk_allowed → Verified`）是死代码。
   精确 profile 的 `ReadExactSampledShieldState`（`:1090-1100`）只贡献 required/ready，
   结论仍然由通用判定给出。**这一条是真缺陷**：设计上「精确 profile 可免确认」的那条路
   在代码里断了。
3. **`:1128` 的注释引用了一个不存在的机制。**
   > Keep generic coverage partial until the **per-build 1,000-transaction evidence gate**
   > is recorded.

   该 evidence gate 全仓查无此物。「暂时 partial」于是永远是 partial，而读代码的人会以为
   存在一条自动升级路径。
3. **Fushi 侧的门因此恒成立。** `fushi/lib/src/lookup/gal_attached_text_controller.dart:672-681`：
   ```dart
   if (!riskAccepted && _shieldStatus.conclusion != verified) {
     _setStatus(needsRiskAcceptance, reason: 'evaluate_profile_risk_not_accepted');
     return;   // 面板根本不创建
   }
   ```
   `conclusion` 永远不可能是 `verified` ⇒ 对**每一个**游戏、每一次，都只能靠
   `riskAccepted` 这一条路。
4. **唯一解锁入口埋在一个 44px 工具条里。** `GalAttachedLookupWorkbench`
   （`fushi/lib/src/pages/implementations/gal_attached_lookup_workbench.dart:60-70`，
   挂在 `texthooker_page.dart:2115`）里一个 `TextButton.icon`，黄色警告三角 +
   `game_lookup_attached_risk_accept` =「确认点击风险」。**游戏里没有任何提示指向它**，
   用户在游戏里点半天只会看到"什么都没发生"。
5. **同意按 exe SHA-256 存。** `needsUnsafeRiskAcceptance`（`gal_attached_text_controller.dart:355-366`）
   要求 `_exeSha256 != null`。换游戏要重来，同一游戏换版本也要重来——与 BUG-2153 是同一个
   「exe 级绑定」病。

### 实测证据

- フタマタ恋愛 Ver1.00：`shield=req:2 applied:2 owner:1 required:0x7C ready:0x64
  observed:0x04 fault:0x00 status:0x02`（`0x02` = Partial）。
- `lookup_diag=0xB0000541`：`sensor_installed | expression_ready |
  classic_patch_installed | classic_processch_fired` 全亮 —— **hook 侧一切正常**，
  是 host 侧不放行。
- 同一份 `%TEMP%\fushi_galhook.log` 里，能采到几何的进程（pid 98668 / 106308）都是
  `wrapper.identity: state=0`（有 KAGEX `TextRender`），フタマタ 是 `state=1`（经典 KAG3）。

### 附带发现（真实但**不是**本条根因，勿混淆）

`required` 的 DirectInput 两位由「dinput.dll 或 dinput8.dll 是否已加载」点亮
（`generic_input_shield.inc:1103`，纯模块存在判据、必然成立），而 `ready` 那两位要走完
「钩到工厂调用 → 撞见 `CreateDevice(GUID_SysMouse)` → 钩住设备 vtable 四槽」整条链才亮
（`:594`）。フタマタ 实测 `required=0x7C ready=0x64`，差的正是这两位。

这是真的不对称，但**补齐它不会改变结论**——`ready == required` 之后
`ClassifyGenericShieldCoverage` 仍然只能返回 Partial。所以它是独立缺陷，另计。

其中一半**已在本条修掉**：`DirectInputCreateEx` 原来全仓没钩（只钩了 `DirectInputCreateA/W`
和 `DirectInput8Create`），而 A/W 在 dinput.dll 内部只是 Ex 的包装——游戏直接
`GetProcAddress("DirectInputCreateEx")` 就完全绕过遮罩层，设备建出来了我们一无所知，
左键照样穿到游戏里推进对话。这是一条**静默漏路**：没有任何断言会红，只有真机上"点了没反应"。
- 修复：`hook/generic_input_shield.inc` 增 `Detour_GenericDirectInputCreateEx`（签名与
  `DirectInput8Create` 同形、带 REFIID，不是 A/W 的四参数形状）+ 独立的 original 指针与
  hooked 闩。
- 守卫：`tests/direct_input_factory_coverage_guard_test.py`。判据**不是**手写名单——那正是
  「漏一个」的同一个失效模式——而是在 Windows 上读系统 `dinput.dll`/`dinput8.dll` 的导出表，
  取所有 `DirectInput*Create*` 当作必须覆盖集（实测推导出 `DirectInput8Create`/
  `DirectInputCreateA`/`DirectInputCreateEx`/`DirectInputCreateW` 四个）；系统 DLL 不可读时
  退回文档集合，绝不静默跳过。另有一条断言禁止两个入口共用同一个 detour 或 original 指针
  （会串台）。变异实测：抹掉 Ex 那段安装块后守卫报
  `DirectInputCreateEx: 没有 detour + original 指针的安装块`。

**剩下那一半没修**：`required` 由「dinput 模块在不在」点亮而 `ready` 要靠抓到一次工厂调用，
这条不对称仍在。正确修法是让 `ready` 也能只靠「模块在」达成——直接给 dinput 设备的**共享
vtable** 打补丁（`HookFnWithOriginalRegistry` 钩的是槽位里那个函数，一个设备等于全进程），
再在 detour 里对未注册设备惰性分类（vtable 槽 3 = `GetCapabilities`，`dwDevType` 低字节 == 2
即鼠标）。没做是因为它不影响本条结论，且需要真机验证「游戏到底建不建 DirectInput 鼠标设备」。

### 与 BUG-2121 第④段的关系

即使接受了风险，フタマタ 仍然点不出卡片：经典 KAG3 的 `classic_geometry`(0x200) 灭，
registry 恒空 ⇒ `lookup.coord.v1 ... N=0` ⇒ 永远没有命中。**两道坎是叠着的**，本条只解开
第一道。第二道的判别实验（类级 `Layer.drawText` 计数 vs 类级 `MessageLayer.processCh`
计数）所需的可读性已在 BUG-2153 的两条提交里补上。

- **[x] ① 已修复** — 取的是三个候选之外的第四条：**把这道门整个去掉**（用户
  2026-09-05 拍板）。`GalAttachedTextController._unsafeLeftClickAlwaysAccepted`
  恒 true，`needsUnsafeRiskAcceptance` 由它派生而非硬编码 false，于是
  `unsafeRiskAcceptanceRequest` 恒 null、工具条上那个按钮不再出现。

  为什么不是「删掉这个概念」：`riskAccepted` 不只是 UI，它作为 `allow_risk` 一路
  传到 hook 的遮罩层契约（`kLookupShieldStatusRiskAllowed`）。恒定接受等价于
  「用户每次都点了那个按钮」，IPC 两侧契约不变，而用户看得见的那道门消失。
  持久化字段 `unsafeLeftClickAccepted` 保留不动（存量 profile 缺字段会整条解析失败）。

  连带清掉一条随之不可达的分支：`gal_capture_setup_dialog.dart` 里「风险确认要来
  了，捕获设置弹窗自动让位」那条 else-if —— 它的触发者恒为假，留着只会让「弹窗
  会不会自己关」多一个永远不成立的答案。`yieldingToRiskConsent` 参数本身保留，
  门若哪天按引擎重开，接回来只是一个 else-if。

  三条原候选没有被否定，只是不再是这条 bug 的前置：(a) per-build evidence gate、
  (b) 把状态呈现挪到游戏窗边、(c) 同意粒度改引擎级，都属于「风险提示要不要以别的
  形态回来」，与「当前这道门把每个游戏每次启动都卡住」是两件事。

- **[x] ② 已加自动化测试** —
  `fushi/test/pages/gal_capture_setup_lookup_priority_test.dart`：原来三条守的是
  「风险请求把捕获设置弹窗顶掉、并暴露确认按钮」，现在反向守新契约——会话活跃后
  `needsUnsafeRiskAcceptance` 恒 false、request 恒 null、**用户打开的弹窗留在原地**、
  确认按钮不出现。这两条正是用户实际抱怨的症状，反向之后就是那道门不许悄悄回来的锚。
  另两条（排队的自动关闭不得弹掉下层工作台路由）改由**选中文本线程**触发同一条
  路径，回归覆盖没有随门一起丢。
  `fushi/test/pages/gal_capture_setup_dialog_lifecycle_guard_test.dart` 的源码守卫
  同步反向：弹窗 build 里**不许**再引用 `needsUnsafeRiskAcceptance`，
  `yieldingToRiskConsent: true` 的调用点数从 1 改成 0 —— 否则会出现「守卫还在、
  被守的行为已经没了」。
- **备注**：本条**不是** hook 坏了。hook 侧 `lookup_diag` 四位全亮，是 host 侧的准入
  语义把它挡在门外，而挡的理由（"等待一个不存在的 evidence gate"）已经不成立。
