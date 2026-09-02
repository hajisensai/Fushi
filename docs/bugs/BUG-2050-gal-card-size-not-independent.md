## BUG-2050 · 游戏内查词卡尺寸不可独立配置，且上界用画布像素夹屏幕像素被系统性压小
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
    用同样的默认值故不跳尺寸；设置项在 `settings_schema_lookup.dart` 与覆盖窗那组同构。
    控制器新增 `_effectiveLookupSizeForCurrentRoute`，按 `currentRoute.source == 'galCard'`
    分流，5 处取用点全部改走它。
  - 上界改按客户区算：runner 在 direct present 时回报游戏客户区物理尺寸
    （`RevealOverProcessClient` 出参 → `LookupDirectPresenter` → present 结果的
    `clientWidth`/`clientHeight`），Dart 缓存后用于 cap。**anchor 仍按画布口径单独计算**
    （`anchorCapW/anchorCapH`），因为位图回退路径要用它，两个单位不混。
- **[x] ② 已加自动化测试** — `fushi/test/lookup/gal_ingame_lookup_contract_test.dart`
  新增断言：字形矩形四个字段必须原样过 `galLookupPresent` 通道（丢了就退回按画布尺寸排的
  anchor）。形态解析本身由既有的 `effective_lookup_size` 纯函数与
  `test/lookup/` 全套（715 项）覆盖，合并后连同 mining/i18n 共 1945 项全过。
- **备注**：修复后第一版仍然没生效，原因是客户区尺寸的缓存被写进了 `_cancelRecapture()`
  ——那是**每次查词结束**都跑的函数，于是 runner 回报的值每次都被清零、下一次查词又退回
  画布口径。客户区是**会话级**事实，已改为只在 `setSessionEpoch` 换局时清除，并在原处留下
  注释说明不能在此清。这一步是真机复测才暴露的（用户报「好像控制不了大小」），
  仅靠单测发现不了，属分层测试的已知盲区。

  已知残留：客户区尺寸依赖上一次 present 回报，因此**每局游戏的第一次查词**仍按画布口径
  出卡（偏小），第二次起正确。消除它需要在会话建立时（geometry admission）就把客户区尺寸
  捎回来，尚未做。
