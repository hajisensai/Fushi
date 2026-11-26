## BUG-5516 · Card field AI: field contents lose the target-word bold, gain spaces at tags, and mix furigana readings into the text
- **报告**：2026-11-24（用户：查看例句翻译默认提示词时发现）
- **真实性**：✅ 真 bug。`fushi/lib/src/ai/ai_srs_field_assistant.dart:197`（修前）把每个字段的内容交给 `aiSrsPlainText`（`ai_srs_template_assistant.dart:88`），它把**每个标签换成一个空格**：制卡写进例句的目标词加粗（`anki_models.dart` `_sentenceValue`）整个丢了，而翻译任务行要求「把目标词的译文包进 `<b>`」，模型只能猜是哪个词；`それに<b>気づいた</b>時` 变成 `それに 気づいた 時`，日文里平白多出空格；振假名 `<ruby>漢字<rt>かんじ</rt></ruby>` 变成 `漢字 かんじ`，读音混进正文；挖空 `{{c1::词}}` 被去掉花括号后成了 `c1::词`。
- **[x] ① 已修复** — 新增 `aiSrsFieldSample`（同文件）专给字段 AI 整理字段内容：只留 `<b>`（`<strong>` / 挖空也记成 `<b>`）与换行（`<br>` / 块结束），其余标签原地去掉不补空格，`<rt>` / `<rp>` 整段丢，脚本 / 样式 / 注释丢；截断不留半个标签、补上没闭合的 `</b>`；`&lt;` `&gt;` 保持转义，字段里的字面「<b>」伪造不了标记。系统提示补一句「字段内容里的 `<b>…</b>` 标的是目标词」。`aiSrsPlainText` 不动（模板助手还拿它清洗 AI 产出）。
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_note_editing_markup_test.dart`「交给 AI 的字段内容」组：加粗保留且不补空格、振假名与挖空、换行与实体、截断；外加用假 client 截下 `requestAiSrsField` 真正发出的消息，断言里面是 `それに<b>気づいた</b>時` 而不是带空格的旧形状。
- **备注**：字段内容仍截到 300 字（`kAiSrsFieldSampleMax`）；按字段名引用完整内容是后续「可编辑字段 AI 动作」的范围。
