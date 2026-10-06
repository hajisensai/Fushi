## BUG-2997 · 查词只命中已隐藏词典时弹窗画页面自己的 emoji「未找到」并铺满最大尺寸
- **报告**：2026-10-06（用户：阅读器查词弹窗「这个很丑」——约 1000×700 的大面板里只有一枚彩色 emoji 放大镜 +「未找到搜索结果。」靠上偏左，下面大片空白）
- **真实性**：✅ 真 bug（沿真实代码路径验证；用户截图那一次查的具体词未取到，所以「截图正是这条路径」是推断，见备注）。根因：被用户关掉的词典只在 popupJson 一条出口上过滤，`entries` 一条不过滤——
  - `packages/fushi_dictionary/lib/src/language/language.dart` `buildPopupJsonFromLookup`：`if (hiddenDictionaries.contains(g.dictName)) continue;`（只命中隐藏词典的词 → `[]`）；
  - 同文件 `buildResultFromLookup`：不认识隐藏集合，`entries` 照样带上隐藏词典的释义；
  - `fushi/lib/src/models/app_model.dart` `searchDictionary` 两处调用都把同一批 `ffiResults` 分别喂给上面两个函数；
  - 宿主按 `entries.isNotEmpty` 判「有结果」（`base_source_page.dart` `_itemNeedsWebViewRender`、`dictionary_popup_layer.dart` `_hasRenderableResults`），于是不走 Flutter 的紧凑空态，而是等 WebView 渲染；页面拿到 `window.lookupEntries = []`，走进 `fushi/assets/popup/popup.js` `renderPopup` 的无结果分支，画出页面自己的「No results」（旧版是 `&#x1F50D;` emoji）；阅读器宿主当时也不接 `onContentMetrics`，弹窗按最大宽高铺开。
- **[x] ① 已修复** — `buildResultFromLookup` 新增 `hiddenDictionaries`（与 popupJson 同一口径：先剔除隐藏词典的释义，剩不下释义的词头直接跳过，不占 `maximumTerms` 预算、不贡献高亮长度），`AppModel.searchDictionary` 两处调用传入 `hiddenDictionaryNames`。同批顺带：阅读器宿主接上内容高度自适应、真实空结果收成 `kLookupPopupEmptyHeight`、页面空态换成 M3E（search_off 矢量 + 标题 + 建议），见同一提交。
- **[x] ② 已加自动化测试** — `fushi/test/models/lookup_hidden_dictionary_entries_test.dart`（只命中隐藏词典 ⇒ entries 与 popupJson 同为空；隐藏词典的词头不占预算；不传隐藏集合时行为不变）。
- **备注**：用户报的另一处「弹窗左侧外面孤立的 ×」本轮没能在真机复现、来源未确认（flutter run 已断开，没有 VM service 可用）；源码排查已排除 popup.js 的语法说明关闭钮（WebView 内容画不到弹窗外）、阅读器音频行、加载占位层。最可疑的是下层查词卡被上层裁掉后剩下的一条带状残片（`PopupOccluderClip`，`dictionary_popup_layer.dart`），需要在真机上复现后再定。
