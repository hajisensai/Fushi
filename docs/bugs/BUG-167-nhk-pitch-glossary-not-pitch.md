## BUG-167 · NHK发音辞典被读成释义词典（实为glossary格式·无pitch数据·非bug）
- **报告**：2026-06-11（用户：导入 `[Pitch] NHK日本語発音アクセント新辞典.zip` 期望识别为音高/发音词典，却被读成释义词典）
- **真实性**：❌ 非 bug（经独立核实）。词典本身就是 glossary 释义格式，不带任何机器可读的 pitch accent 数据；Hibiki 把它分类为「释义词典」是**正确行为**，符合 Yomitan 生态契约。
- **[ ] ① 不需修复** — Hibiki 行为正确，无需改 importer/query。硬把它标成「音高词典」反而是错的（它没有 pitch position 数据，`query_pitch` 也查不到任何东西）。
- **[ ] ② 不需加测试** — `detect_type()` 现有逻辑即正确分类此词典；无回归可守。
- **备注**：见下方证据。

---

### 用户诉求
用户导入 `C:\Users\wrds\Downloads\QQ\[Pitch] NHK日本語発音アクセント新辞典.zip`，期望它是「音高/发音词典」（pitch accent），结果被读成「释义词典」（glossary）。

### 一、词典实物证据（解压该 zip）

`index.json`（完整内容）：
```json
{"title":"NHK日本語発音アクセント新辞典","format":3,"revision":"1.0","sequenced":true}
```
- `format: 3` = Yomitan term dictionary v3，**没有任何标识自己是 pitch 词典的字段**（Yomitan pitch 数据靠 `term_meta_bank` 承载，不靠 index 字段）。

文件清单：
- `term_bank_1.json` … `term_bank_8.json`（8 个）
- **`term_meta_bank_*.json`：0 个**（这是关键——Yomitan pitch accent 数据必须放在 term_meta_bank）

全 8 个 bank 审计（python 遍历 75992 条）：
```
total entries (all 8 banks): 75992
glossary items that are dict/list (structured content): 0
glossary items that are plain string: 75992
term_meta_bank files present: 0
```

`term_bank_1.json` 前几条原文（标准 Yomitan term 8 元组 `[expression, reading, defTags, deinflect, popularity, [glossary...], seq, termTags]`）：
```json
["帯広","おびひろ","名詞 地名","",0,["おびひろ【帯広】（北海道）\n ・［0］オビヒロ"],0,""]
["お姫様","おひめさま","名詞","",0,["おひめさま【お姫様】\n ・［2］オヒ＼メサマ"],2,""]
["脅かす","おびやかす","動詞 五段・サ行","v5",0,["おびやかす【脅かす】\n ・［4］オビヤカ＼ス"],4,""]
```
音高调号（`［0］`/`［2］` 及降符 `＼`）只是**释义字符串里的纯文本**，不是 Yomitan 结构化 pitch accent 数据。
真正的 pitch accent 条目形如 `["term","pitch",{"reading":"…","pitches":[{"position":N}]}]`，存在于 `term_meta_bank`——本词典完全没有。

### 二、Hibiki 代码契约（确认分类正确）

`packages/hibiki_dictionary/native/hoshidicts/hoshidicts_src/importer.cpp:88-106` `detect_type()`：
```cpp
std::string detect_type(const Files& files, const Zip& zip) {
  if (!files.kanji_banks.empty()) return "kanji";
  if (!files.term_banks.empty()) return "term";           // 有 term_bank 即释义词典
  if (!files.meta_banks.empty()) {                         // 仅当只有 meta_bank 才看 mode
    ...
    if (metas[0].mode == "pitch") return "pitch";
  }
  return "term";
}
```
本 zip 有 8 个 `term_bank_*`、0 个 `term_meta_bank_*` → 第 92-93 行直接返回 `"term"`（释义词典）。**完全正确。**

`yomitan_parser.cpp:84-90` 的 pitch 解析契约 `{reading, pitches:[{position}]}` 只从 `term_meta_bank` 取（`parse_meta_bank`）；`query.cpp` 的 `query_pitch` 要求 `mode=="pitch"`。本词典没有任何符合此结构的数据，即便强行标成 pitch 也查不到 position。

### 三、结论与给用户的建议

- **这不是 Hibiki 的 bug。** 这个名为「[Pitch]」的 NHK 词典，实质是一个把音高调号当释义文本展示的 **glossary 释义词典**，不携带机器可读的音高数据。Hibiki 读成「释义词典」是对的；它会在查词弹窗里正常显示 `［2］オヒ＼メサマ` 这类释义文本（含音高标注），但不会进入音高/发音渲染管线。
- **若用户要的是真正能驱动音高曲线/着色的「音高词典」**，需导入带 `term_meta_bank`、type=="pitch" 的 Yomitan pitch accent 词典（例如社区常见的带 term_meta_bank 的「NHK 日本語発音アクセント辞書（pitch accent 版）」「Kanjium / 大辞泉 pitch accent」等版本）。带音高数据的词典导入后 Hibiki 会自动 `detect_type` 为 "pitch"。
