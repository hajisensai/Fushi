## BUG-2066 · 游戏内查词卡尺寸不可独立配置，且上界用画布像素夹屏幕像素被系统性压小
- **报告**：2026-09-02（用户：「游戏内查词过小，浮窗查词过大。做到设置里可以独立配置」）
- **真实性**：✅ 真 bug，两个独立缺陷叠在一起。

  **① 形态未拆分**：游戏内查词卡与 app 外覆盖查词窗共读同一组尺寸键。
  `fushi/lib/src/lookup/global_lookup_controller.dart` 有 5 处直接读
  `model.overlayLookupEffectiveSize`，而游戏内卡片（route `galCard`）也走同一条
  `GlobalLookupController`。于是两个形态只能二选一——卡片贴在游戏客户区里、要避开正文，
  浮窗浮在整块桌面上，合适尺寸本就不同，调大一个必然让另一个不合适。
  仓库里本来就有「跟随共享值 / 解锁独立尺寸」的形态模型
  （`fushi/lib/src/lookup/effective_lookup_size.dart`，覆盖窗与浏览器扩展各有一组键），
  游戏内卡片只是从未被建成第三个形态。

  **② 上界单位混用**（这条使 ① 的设置在纵向完全失效）：
  `fushi/lib/src/lookup/gal_ingame_lookup_controller.dart` 的 `_applyCardSizeCap` 取
  `hit.viewW/viewH * 0.6` 作 cap，即**游戏画布像素**；而
  `global_lookup_controller.dart` 的 `_clampToPhysicalCap` 把逻辑尺寸乘
  `appUiScale * dpr` 换算成 **App 屏幕物理像素**后直接与该 cap 比大小。两个坐标系没有
  任何换算就相互夹取。

  真机数据（9-nine Episode 1）：画布 1280×720、客户区 1902×1069。cap 因此是 768×432
  物理像素，日志里卡片恒为 `card=563x432` / `card=542x432`——纵向正好被钉死在
  `0.6×720=432`。用户把「最大高度」调到 510 逻辑像素（物理约 1020）也毫无变化。
  正确上界应按客户区算，即 `0.6×1069≈641`。
- **[x] ① 已修复** — `09cf2a93ca`。
  - 新增第三个尺寸形态：`gal_card_lookup_independent_size` / `gal_card_lookup_max_width` /
    `gal_card_lookup_max_height`（`preferences_repository.dart` + `app_model.dart` 的
    `galCardLookupEffectiveSize`），默认 `independent=false` 跟随 app 内共享值，解锁瞬间
    用同样的默认值故不跳尺寸。

    **更正（审查发现）**：三个设置项最初放在 `settings_schema_lookup.dart`，且**没有任何
    平台门**（该文件全文 `Platform.` 出现 0 次），于是 Android/iOS/macOS/Linux 用户在
    「查词 → 弹窗窗口」分区和设置搜索里都看得到一个 galgame 专属设置项——撞死
    「禁止宣称支持其它平台的 galgame 实现」这条硬规则。已按 #938 的先例
    （它当年正是把整个 `gal_hook_overlay` section 从 `settings_schema_lookup.dart` 搬进
    `settings_schema_game.dart` 以取得双重 Windows 门）搬进 `settings_schema_game.dart`
    的「游戏内查词」section，destination 级 + item 级双重 `Platform.isWindows`。
    三个偏好键同时补进 `preference_keys.dart` 的 `kKnownPreferenceKeys`（此前
    `preference_keys_guard_test` 直接判红），开关登记进
    `settings_schema_coverage_test` 的 `kCoveredElsewhere`（两个滑杆带 `visible:` 门、
    不进清单，无需登记）。
    控制器新增 `_effectiveLookupSizeForCurrentRoute`，按 `currentRoute.source == 'galCard'`
    分流，5 处取用点全部改走它。
  - 上界改按客户区算。**第一版**是：runner 在 direct present 时回报客户区物理尺寸
    （`RevealOverProcessClient` 出参 → present 结果的 `clientWidth`/`clientHeight`），Dart
    缓存进 `_gameClientWidth/_gameClientHeight` 后用于 cap。这一版有两个失效面（见下面的
    「更正」），已整个换掉。
    **现在**：客户区是**每一刻的事实**，不是会话级常量，所以由 runner 随**每一条 hit** 用
    `GetClientRect` 现量现报（`GalLookupHit.clientW/clientH`，新增
    `fushi/windows/runner/game_client_extent.h` 把进程客户区查询收成唯一原语，
    `global_lookup_window.cpp` 与 `voice_hook_reader.cpp` 共用）。缓存字段及其失效规则整个
    删除。这**不是**跨进程 IPC 契约变更：注入侧不知道也不该知道窗口尺寸，这一对是 runner
    在本进程量的。
  - cap 同时受**画布**约束（取下界）：卡片可能落到位图回退路径被 1:1 画进 primaryLayer，
    比画布还大的位图会被 `WriteLookupPresent` 按字节预算静默裁掉下半截。取下界之后就不
    需要预先知道本次走哪条路——那个知识要等 present 回执才有，而 cap 必须在 present 之前
    定死。真机形态 scale≈1.486 < 1/0.6，画布约束不咬到，641 的收益完整保留。
  - **坐标域混用（审查发现）**：第一版把 `setPhysicalCap` 的 `workWidth/workHeight` 也换成
    了客户区尺寸，而同一次调用的 `workOriginX/Y` 是 `_resolveAnchor` 在**画布**坐标系里解出
    来的根卡原点。这两对下游被当作同一坐标系用（`_screenWorkW/H` + `_cursorWorkX/Y` →
    `computeFrameRect` 的 `spaceRight`/`spaceBelow`），放大时工作区变 1902×1069 而原点上界
    仍 ≤1280×720，级联子卡的 above/below 与右/下边界判定系统性偏乐观；这也与
    `flutter_window.cpp` 里「capW/H 表示**完整游戏 viewport**、capX/Y 是根卡在该 viewport
    内的原点」的既有契约注释不符。已把工作区换回 `hit.viewW/viewH`。
    卡片尺寸上界（`width`/`height`，屏幕物理像素）与布局工作区（画布像素）是**两件事**，
    不要因为改动前它们碰巧同源就再合到一起。
    `anchorCapW/anchorCapH` 同时删除：位图是 1:1 贴进画布的，卡片在画布域的占位就是
    `capW/capH` 本身，用另一份更小的尺寸解 anchor 会让卡片右/下边溢出画布。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/gal_card_size_cap_test.dart`（新增，10 条）。

  **此前这一条是过度声称**：原文写的「形态解析由既有 `effective_lookup_size` 纯函数与
  `test/lookup/` 全套覆盖」只覆盖了纯函数和 wire 透传，**分流接线本身**没有任何咬合点。
  实测：把 `_applyCardSizeCap` 里按客户区算上界那段撤销（= 撤销本条整个 cap 修复），
  `test/lookup` 719 条**一条都不红**；把 `_effectiveLookupSizeForCurrentRoute` 的 galCard
  分支改回共读 overlay 键（= 撤销 ① 的形态分流），同样 719 条全绿。
  `grep -r 'galCardLookupEffectiveSize\|_gameClientWidth' fushi/test/` 当时是 0 命中。

  新测试钉三条不变式，四条变异逐条实测为红、还原后 sha256 回基线：
  - 本局**第一次**查词就按客户区口径出卡（真机形态 1280×720 画布 / 1902×1069 客户区 →
    cap 高 641，而不是画布口径的 432）；客户区变化在**下一条 hit** 立刻跟上；量不到时
    退回画布口径而不是拿 0 当尺寸。
  - cap 同时受画布约束（3 倍放大时不会算出比画布还大的位图），且该约束不会反过来压掉
    真机那一档的收益。
  - `workWidth/workHeight` 是画布尺寸、与画布域的 `workOriginX/Y` 同域；根卡整张留在
    工作区内；view 非法时 cap 与工作区一并清空。
  - galCard route 读 gal 那组键、桌面 route 继续读 overlay 那组，两组非对称值不互串；
    关掉开关时跟随 app 内共享值。
- **备注**：修复后第一版仍然没生效，原因是客户区尺寸的缓存被写进了 `_cancelRecapture()`
  ——那是**每次查词结束**都跑的函数，于是 runner 回报的值每次都被清零、下一次查词又退回
  画布口径。客户区是**会话级**事实，已改为只在 `setSessionEpoch` 换局时清除，并在原处留下
  注释说明不能在此清。这一步是真机复测才暴露的（用户报「好像控制不了大小」），
  仅靠单测发现不了，属分层测试的已知盲区。

  **原「已知残留」已消除**（审查指出它就是本 bug 的用户症状本身，不该当残留放过）：
  第一版依赖上一次 present 的回执，于是**每局第一次查词**按画布口径出卡（真机上与修复前
  逐像素相同，本次查词内不自愈）；且缓存只随换局失效、**不随窗口尺寸变化失效**，玩家中途
  全屏↔窗口化后下一次查词读旧客户区，旧值更大时 cap > 当前客户区，`ClampDirectCardOrigin`
  把原点钉到 0、整张卡盖住画面。
  根因是「客户区」被建模成了**会话级缓存**，而它其实是**每一刻的事实**。改成随每条 hit
  现量现报之后，缓存和它的失效规则一起消失，两个失效面同时没了——这也是为什么修法不是
  「present 回执到了再重跑一次 cap」（那仍然晚一次查词）。
