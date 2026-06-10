## BUG-177 · 已禁用的词频辞典查词时仍出现 + 声调与词频间距太小遮挡
- **报告**：2026-06-11（用户：win 端查词，TODO-098）
- **真实性**：✅ 真 bug（两个独立症状，同一次报告）

### 症状①：已关闭的词频(frequency)辞典查词时仍显示词频数据
词典管理里把某词频辞典「关闭」后，查词弹窗里仍出现它的词频。

**根因**：词典「禁用/启用」没有独立 enabled 字段，走的是
`Dictionary.hiddenLanguages` / `isHidden(language)`
（`packages/hibiki_dictionary/lib/src/engine/dictionary.dart:43`，
开关在 `hibiki/lib/src/pages/implementations/dictionary_dialog_page.dart:1037,1110`）。
但词频/声调数据来源是 C++ FFI 引擎（`lookupPopupJson`），引擎按
`AppModel._rebuildDictPathsCache` / `_rebuildDictPathsCacheAsync`
（`hibiki/lib/src/models/app_model.dart:593,622`）收集的 `freqPaths`/`pitchPaths`
加载。这两处遍历 `dictRepo.dictionaries` 时**只看 `d.type` 分桶、从不检查
`isHidden`**，所以被禁用的词频/声调辞典照样 `addFreqDict`/`addPitchDict` 进引擎，
词频值照样出现在 popupJson 里。
对比：term 释义走 Flutter 端 `dictionary_term_page.dart:63-66` 的
`dictionaryNamesByHidden` 渲染期过滤，所以 term 禁用生效；而 freq/pitch
从无任何 hidden 过滤（引擎层、popupJson 层、popup 注入层都没有，
`dictionary_popup_webview.dart:456` 只注入了 collapsedDictionaryNames）。
第二缺口：`AppModel.toggleDictionaryHidden`（原 `app_model.dart:1844`）切开关后
不清查词结果缓存，缓存里旧的 popupJson（启用时生成、含该词频）下次命中缓存
仍会复现，与删除路径（`deleteDictionary` 清缓存）不对称。

### 症状②：声调(pitch accent)与词频(frequency)间距太小、互相遮挡
**根因**：`buildEntryElement`（`hibiki/assets/popup/popup.js:1701-1709`）把
frequency section、pitch section 作为两个相邻 `.category-section` 纵向堆叠，
两者间距只有 `.category-section { margin-top: 2px }`
（`hibiki/assets/popup/popup.css:497`）。pitch 第一拍的高低线
`.pronunciation-mora-line { top: -2px }`（`popup.css:544`）会往行盒上方伸出，
在仅 2px 的间距下贴住/盖住上方 frequency 标签。

### 修复
- **[x] ① 根因修复** —
  - `app_model.dart` `_rebuildDictPathsCache` / `_rebuildDictPathsCacheAsync`：
    收集 freq/pitch 路径时 `if (!d.isHidden(targetLanguage))` 才加入，禁用的
    词频/声调辞典从源头不进引擎（term 仍全量加载，保持渲染期过滤行为不变）。
  - `app_model.dart` `toggleDictionaryHidden`：切开关后 `clearDictionaryResultsCache()`，
    让启用态缓存的 popupJson 失效（对齐删除路径，BUG-171 范式）。
  - `popup.css`：新增 `.frequency-section + .pitch-section { margin-top: 8px }`，
    仅在 freq→pitch 相邻堆叠时加大间距（pitch-only 仍保持紧凑 2px）。
  - 提交：a0ed4d35c（档内哈希指向上一提交,本行回填提交另有哈希）
- **[x] ② 增加自动化测试** —
  - `hibiki/test/models/disabled_freq_dict_engine_filter_guard_test.dart`
    （源码扫描守卫：两个 rebuild 方法须 consult `isHidden`，toggle 须清缓存；
    FFI 引擎/AppModel 无法 headless 链接）。
  - `hibiki/test/pages/popup_pitch_frequency_spacing_guard_test.dart`
    （CSS 守卫：`.frequency-section + .pitch-section` 的 margin-top 须 > 2px）。
  - 撤修复后三条引擎守卫红、间距守卫红，已实测 TDD 红→绿。
- **备注**：popup/查词渲染类修复需真机复测——禁用某词频辞典后查词确认其词频不再
  出现、且不需重启；声调与词频间距足够不再遮挡。本轮仅 host 守卫 + analyze + format。
