## BUG-5200 · 新加的「听力」模板一打开就报「区块以外的代码被改过」，复习走 WebView 卡面
- **报告**：2026-11-22（用户：给内置 Fushi 卡片加「听力」模板后，可视化编辑的正面直接显示 `srs_fushi_layout_unrecognized` 警告，什么都没改过）
- **真实性**：✅ 真 bug（根因 `fushi/lib/src/srs/srs_template_presets.dart` 旧 `_fushiListeningFront`：手写一段不带区块标记、不是内置骨架的正面 HTML；`packages/fushi_anki/lib/src/fushi_card_blocks.dart` `_layoutProbe` 认不出 → 区块布局面板 `_recognized = false`、`srsFushiCardNative` 回退 `frontTemplate`）
- **[x] ① 已修复** — 听力预设改用 `fushiCardTemplateFor` 生成「单词音频字段区块」正面（与反向预设同一做法）；`_legacyListeningLayout` 把修复前加的听力正面读成同一字段区块（已有模板不用重置）；原生卡面计划把字段区块 / HTML 区块里画出来的 `[sound:]` 并进自动播放与重播（`srsFushiCustomItemSounds`，`SrsFushiCardMedia.custom`）
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_template_presets_test.dart`（听力正面认得出、是字段区块）、`packages/fushi_anki/test/fushi_card_back_layout_test.dart`（旧正面读成字段区块、改过的不认）、`fushi/test/srs/srs_fushi_card_items_test.dart`（自定义区块里的发音键进 `media.front` / `media.back`）
- **备注**：真机未复测（Windows 沙箱可复测：加听力模板 → 正面无警告、复习原生卡面、正面自动播放单词音频）。

### 根因

a5d5863e50（2026-11-07，「加卡片模板改为选『考什么』预设」）给内置 Fushi 卡片的听力预设手写了正面：

```html
<div class="fc fc-front" lang="ja">
  <div class="fc-front-audio">
    <div class="fc-audio fc-audio--large">{{TermAudio}}</div>
  </div>
</div>
```

区块布局只认内置骨架（或历史登记的旧骨架 / 自证骨架标记）里的 `data-fc-block` 区块。这段既没有骨架也没有标记，
`fushiCardLayoutProbe` 返回 null：编辑页一打开就显示「区块以外的代码被改过」，复习页整面回退 WebView。同一函数里的
反向预设用的是 `fushiCardTemplateFor`，没有这个问题。

连带问题：原生卡面的媒体计划（`srsFushiCardPlan`）只收内置区块的音频，字段区块 / HTML 区块里的 `[sound:]` 画成了
发音键却不进自动播放 / 底栏重播 / R 重播。听力正面改成字段区块后若不补这一处，正面就不会自动播放。

### 修复

- 预设：正面 = `fushiCardTemplateFor(front, [FushiCardFieldItem(field: <音频字段>)])`。
- 兼容：`_legacyListeningLayout` 认旧正面的规范形（只认正面、只认原样、字段名不含条件段 / 过滤器），读成同一字段区块；
  在区块布局里一改就写回标准骨架。
- 媒体：`srsFushiCustomItemSounds` 按 `srsFushiItemHtml` 同一口径取自定义区块的发音键（标签样式只画文字，不算），
  正面按布局顺序并进 `media.front`，背面进 `media.custom` → `media.back`。

### 已知限制

- 正面发音键现在是字段区块的普通尺寸，不再是旧模板的大号发音键（原生 HTML 片段不带卡片样式表）。
- 判重（`srsTemplateFrontKey`）按正面原文比较：已有旧格式听力模板的笔记类型再加新听力模板不会提示重复。
