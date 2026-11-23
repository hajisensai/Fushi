## BUG-5297 · 新加的「听力」模板一打开就报「区块以外的代码被改过」，复习走 WebView 卡面
- **报告**：2026-11-22（用户：给内置 Fushi 卡片加「听力」模板后，可视化编辑的正面直接显示 `srs_fushi_layout_unrecognized` 警告，什么都没改过）
- **真实性**：✅ 真 bug（根因 `fushi/lib/src/srs/srs_template_presets.dart` 旧 `_fushiListeningFront`：手写一段不带区块标记、不是内置骨架的正面 HTML；`packages/fushi_anki/lib/src/fushi_card_blocks.dart` `_layoutProbe` 认不出 → 区块布局面板 `_recognized = false`、`srsFushiCardNative` 回退 `frontTemplate`）
- **[x] ① 已修复** — 听力预设改用 `fushiCardTemplateFor` 生成「单词音频大号发音键字段区块」正面（与反向预设同一做法）；`_legacyListeningLayout` 把修复前加的听力正面读成同一大号发音键字段区块（已有模板不用重置）；原生卡面计划把字段区块 / HTML 区块里画出来的 `[sound:]` 并进自动播放与重播（`srsFushiCustomItemSounds`，`SrsFushiCardMedia.custom`）
- **[x] ② 已加自动化测试** — `fushi/test/srs/srs_template_presets_test.dart`（听力正面认得出、是大号发音键字段区块；旧格式听力模板与新预设判为重复）、`packages/fushi_anki/test/fushi_card_back_layout_test.dart`（旧正面读成字段区块、改过的不认）、`fushi/test/srs/srs_fushi_card_items_test.dart`（自定义区块里的发音键进 `media.front` / `media.back`）
- **备注**：Windows 离屏真 app 探针 `fushi/integration_test/srs_listening_preset_layout_itest.dart` 已复测：新旧听力模板可视化页签无警告、原生卡面、正面自动播放单词音频、复习页正面大号发音键、新旧两份判为重复。

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

- 预设：正面 = `fushiCardTemplateFor(front, [FushiCardFieldItem(field: <音频字段>, style: audio)])`。
- 兼容：`_legacyListeningLayout` 认旧正面的规范形（只认正面、只认原样、字段名不含条件段 / 过滤器），读成同一大号发音键字段区块；
  在区块布局里一改就写回标准骨架。
- 媒体：`srsFushiCustomItemSounds` 按 `srsFushiItemHtml` 同一口径取自定义区块的发音键（标签样式只画文字，不算），
  正面按布局顺序并进 `media.front`，背面进 `media.custom` → `media.back`。

### 与修复前一致的两处（同一 PR 补上）

- **大号发音键**：字段区块新增样式 `audio`（编辑器里「发音键」）。模板沿用 `fc-audio fc-audio--large`，Anki / WebView
  与修复前同样 60px；原生卡面画听力卡题面同款大号 `_AudioButton`，不经 HTML 子集渲染器。听力预设与旧正面兼容都用它。
  旧版本 app 读到 `audio` 样式时按 HTML 区块原生画（小号按钮），布局项 JSON 未知样式回落 `body`。
- **判重**：`srsTemplateFrontKeyIn` 对内置 Fushi 卡片按区块布局比较（认不出布局的、其它笔记类型仍按原文），旧格式听力模板
  与新听力预设判为重复，笔记类型页的「修复重复」也能把两者归成一组。
