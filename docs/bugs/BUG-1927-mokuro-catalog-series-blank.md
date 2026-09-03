## BUG-1927 · mokuro.moe 目录点进系列后一片空白

- **报告**：2026-08-29（用户：「漫画点击 mokuro 目录里面的漫画，会变空白」）
- **真实性**：✅ 真 bug，且是**恒发**（不是偶发、不挑系列）。
- **根因**：`fushi/lib/src/media/manga/online/mokuro_moe_catalog_view.dart:281`（修前）——
  `_openSeries()` 是纯 `setState`，把**浏览列表里那个 series 对象原样**存进 `_series` 就切阶段，
  **一次网络请求都不发**；`_buildSeries()` 随后 `ListView.builder(itemCount: series.volumes.length)`。

  而站点早已把卷清单从 library 接口里挪走。实测直连（2026-08-29）：
  - `GET /catalog/api/library` → HTTP 200 / 390402 字节，`"volumes"` 出现 **0 次**；
    字段只剩 `name / path / cover / volume_count / latest_volume_modified / total_pages /
    total_chars / titles / community`。
  - `GET /catalog/api/series?name=…` → HTTP 200，**有** `"volumes":[{name,cover,ocr_pending,
    ocr_active}…]`，逐字段对得上 `MokuroMoeVolume.fromJson`。

  取该端点的 `MokuroMoeClient.fetchSeries`（`mokuro_moe_client.dart:150`）在 lib 下**零调用**。
  `MokuroMoeSeries.fromJson` 对缺失 `volumes` 静默容错成 `const []`，`_buildSeries` 又只有
  `series == null` 一个守卫、没有加载/失败/空态 —— 三者叠起来就是「点进去什么都没有，也不说为什么」。

  **为什么测试全绿**：`mokuro_moe_catalog_dialog_test.dart` 的 fake client 只 override
  `fetchLibrary`，返回的常量里手写了内联 `volumes`；`mokuro_moe_client_test.dart` 同样。两处钉的
  都是**服务端已不再产出的响应形状**。

- **[x] ① 已修复** — 1d2053fdf4。`_openSeries` 改为真的 `await _client.fetchSeries(name)`，并补上
  加载 / 失败（可重试）/ 真的没有卷 三态；详情响应缺 `name/path/cover` 时用列表条目的值兜底
  （否则入库身份 `_volumeKey` 与封面 URL 会拿到空串）；加作废 token，用户返回或紧接着开另一个
  系列时丢弃 in-flight 的旧响应。列表条目自带 volumes（旧形状 / 注入的 fake）则直接用，不空跑网络。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/online/mokuro_moe_catalog_dialog_test.dart`
  新增 `_ServerShapedClient`（**按站点当前真实形状**：library 只回名字、不带 volumes）+ 3 条用例：
  点开系列必须调 `fetchSeries`、失败要给文案与重试、真的没有卷要给空态。
  变异实测：把 `_seriesLoading = series.volumes.isEmpty` 改成 `false`（退回旧行为，不发请求）→ 变红。
- **备注**：顺带发现两处死代码（BUG-1710 后「浏览」tab 并入「发现」的残留壳）：
  `online/mokuro_moe_catalog_page.dart` 全文与 `manga_module.dart:173` 的 `openOnlineCatalog`
  在 lib 下均零引用。本次未动，另开清理。
