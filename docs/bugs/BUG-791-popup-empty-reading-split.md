## BUG-791 · 查词弹窗同词因空读音拆成两张卡
- **报告**：2026-07-14（用户）
- **真实性**：✅ 真 bug — 根因 `packages/hibiki_dictionary/lib/src/language/language.dart:522` 与 `hibiki/lib/src/pages/implementations/dictionary_popup_webview.dart:1749`
- **[x] ① 已修复** — 见下「根因 / 修复」，提交 <PENDING>
- **[x] ② 已加自动化测试** — `hibiki/test/pages/dictionary_popup_empty_reading_group_test.dart`
- **备注**：

### 现象
查同一个假名词（如「それだけ」）时，弹窗把它拆成上下两张 headword 卡：一张含明鏡日汉双解 / アクセント辞典 / Pixiv，另一张只含小学館日中辞典 v3。卡头表记、注音看着完全一样，用户以为是重复。

### 根因
弹窗按 `表记 + "\n" + 读音` 拼 key 分组，key 相同才并进同一张卡：

```dart
final key = '${r.term.expression}\n${r.term.reading}';   // language.dart:522
final key = '${entry.word}\n${entry.reading}';            // dictionary_popup_webview.dart:1749
```

「それだけ」本身是假名词。按 Yomitan/Yomichan 数据约定，**当读音与表记相同时词条库常把 reading 字段留空**（"空读音 = 读音同表记"的隐含语义）。小学館日中辞典转来的这条 reading 为空，而明鏡等给了显式读音 `それだけ`：

- 显式：key = `それだけ\nそれだけ`
- 空读音：key = `それだけ\n`

两个 key 不等 → 同一个词被判成两组，画成上下两张卡。界面上看不出差异是因为卡头显示的是**表记**，读音的「有 vs 空」不可见。

### 修复
按"空读音 = 读音同表记"的正确语义，分组前把空读音归一到表记再拼 key（**只归一 key，不改存储的 display reading**，空读音仍无注音、符合现状）：

```dart
final effectiveReading = reading.isEmpty ? expression : reading;
final key = '$expression\n$effectiveReading';
```

改动两条 Dart 分组路径：
- `buildPopupJsonFromLookup`（当前运行主路径，BUG-712 P4 后走 Dart 侧）
- `buildLookupEntriesJson`（fallback / popup_settings_injection 路径）

原生 C++ `lookupPopupJson` 已非弹窗主路径，本次不动。

### 边界（多读音 + 空读音）
- **假名词**（それだけ）：本就不可能有 2 个不同读音，空读音归一后与显式读音同 key，合成一张。✓
- **汉字多读音词**（辛い＝つらい／からい）+ 空读音：`つらい`、`からい` 各自成组；空读音归一到表记 → `辛い\n辛い` **自成第三组**，绝不会被硬塞进 つらい 或 からい。汉字词空读音本身是歧义数据，无法判定属于哪个读音，宁可单独显示也不乱认（乱合会把释义挂到错误读音下，才是真 bug）。✓
