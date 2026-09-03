## BUG-2089 · 应用内制卡全部失败：「导出卡片失败: Invalid card data (payload parse failed): type 'String' is not a subtype of type 'bool?' in type cast」
- **报告**：2026-09-03（用户截图，视频页字幕列表 + 查词弹窗制卡「三文芝居」时报错）
- **真实性**：✅ 真 bug，**已本地复现**（不是静态推理）。构造两条桥的真实拍平方式喂 `AnkiMiningPayload.fromJson`，`true` 与 `false` **两个取值都抛**同一异常。
- **影响面**：**应用内每一次制卡都失败**（不是偶发、不分取值）。浏览器扩展 / 远端 `/api/mine` 那条线不受影响。
- **根因**：`packages/fushi_anki/lib/src/anki_models.dart` 的 `AnkiMiningPayload.fromJson` 里

  ```dart
  glossarySelectionHighlighted: json['glossarySelectionHighlighted'] as bool? ?? false,
  ```

  而该 payload 走**两条编码不同的线**：

  1. **保类型 JSON**——浏览器扩展 / 远端 API，布尔就是布尔；
  2. **全字符串**——应用内 WebView 桥。`fushi/lib/src/pages/implementations/dictionary_popup_webview.dart:1981` 与 `fushi/lib/src/lookup/overlay_bridge_handlers.dart` 都逐值 `.toString()` 拍平成 `Map<String, String>`，因为下游 `ImmersionMiningRequest.fields`、`miningHandler(fields:)`、互联转发**全都是** `Map<String, String>`（Anki 的字段渲染本来就是「字段名 → 字符串」）。这条线上布尔到达时是 `"true"` / `"false"`。

  裸 `as bool?` 只对第 1 条线成立。`"false".toString()` 同样是非 null 的 String，所以**两个取值都炸**，不存在「只有勾选时才失败」。

  **这不是新约定**：同一个 `fromJson` 里 `singleGlossaries` 与 `dictionaryMedia` 早就各自按「String 或原生类型」两分支处理。引入者（`5aaeda80ca`，2026-09-03 07:42，「SelectionText 让位的判据下沉到知道字段映射的那一层」）新加的布尔字段没跟上这个既有约定。`AnkiMiningPayload` 的其余字段全是 String / `Map<String,String>` / List，**这个 bool 是唯一的异类**。
- **[x] ① 已修复** — 抽出 `_boolFromPayloadWire`（`anki_models.dart`），与 `singleGlossaries` / `dictionaryMedia` 的双线处理同源：`bool` 原样、`String` 只认 `'true'`。**不做「非空即真」的宽松解析**——那会把拼写错误静默变成 true。
- **[x] ② 已加自动化测试** — `packages/fushi_anki/test/mining_payload_wire_contract_test.dart`（4 条）：应用内桥两个取值都还原正确、保类型 JSON 照旧、缺失/空串/垃圾值一律 false，外加一条**结构性防复发守卫**——`fromJson` 函数体里禁止再出现 `as bool` / `as int` / `as num` / `as double`（含 `?` 形态）的裸强转，带函数体窗口自校验。
- **备注**：修的是解析边界，不动两条桥的拍平（它是下游 `Map<String, String>` 契约的必然结果，不是缺陷），也不动布尔在 Dart 模型里的类型（消费方 `base_anki_repository.dart` 确实按布尔用）。
