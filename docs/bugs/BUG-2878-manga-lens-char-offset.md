## BUG-2878 · 漫画 Lens OCR 逐字命中区相对原图字形漂移（竖排高亮压前字、切后字）
- **报告**：2026-10-02（用户：漫画查词截图「有点偏移」——竖排「決して交わることのない…」查「交わる」，高亮上沿压到「て」、下沿切掉半个「る」，开框调试可见逐字格子整体比原图字形偏上）
- **真实性**：✅ 真 bug。`fushi/lib/src/media/manga/ocr/google_lens_protocol.dart` 的 `_characterRegions` 只拿 `TextLayout.Line.geometry`，把整行框按字数均分成逐字格子；而 Lens 行框带首尾留白、字距不均（省略号几个点挤在一个短 Word 里），均分后格子相对真实字形累积漂移。Lens 其实给了每个 `TextLayout.Word.geometry`（字段 4，对照 dimdenGD/chrome-lens-ocr `lens_overlay_text_pb.cjs` 的 `Word.getGeometry` → 4），一直没读。真机取证：对《君が一等星に光るまで 01》第 20 页实打 Lens，「アトリは･･･」旧格子与新格子最大相差 35.6 px（原图像素），旧格子里「は」被切开、三个点各占一个大格，与用户截图同形。
- **[x] ① 已修复** — 解码时读每个 Word 的几何，逐字格子在所属 Word 框内沿阅读方向均分；任一 Word 缺几何或 Word 文字拼不回行文字时整行退回旧的均分。只影响新识别：已识别过的卷要在卷上「重新识别」（整卷重跑会先清 Lens 逐页缓存）才会换上新格子。本地 ONNX / mokuro 走 `mangaEffectiveTextRegions` 的列内均分，不在本条范围。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/ocr/google_lens_protocol_test.dart`「BUG-2878 逐字区按 Word 几何切分」两条（照真实响应建模的 Word 几何切分 + 缺几何回退均分）；`google_lens_wire_contract_test.dart` 补 `TextLayout.Word.geometry` = 4 的外部来源核对；fixture 支持逐 Word 框。
- **备注**：真实 Lens 探针（临时 flutter test，不入库）：第 12 / 20 页分别有 3 / 6 个块的逐字格子不再等高，说明真实响应带 Word 几何、新路径生效。
