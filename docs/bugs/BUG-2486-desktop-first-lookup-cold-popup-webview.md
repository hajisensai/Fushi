## BUG-2486 · 桌面首次点击查词慢一拍：热槽只预热空卡，首次真实渲染冷
- **报告**：2026-09-12（用户：「电脑点击查词第一次总是慢一拍，你查查为什么，都是本地数据库」）
- **真实性**：✅ 真 bug。用户猜的「本地数据库慢」不成立——引擎侧只占几十 ms；慢的是**每个新查词弹窗 WebView 的第一次真实词条渲染**，热槽预热只渲染了「未找到结果」空卡，V8 JIT / 各词典 CSS 选择器匹配 / `constructDictCss` memo / 字形栅格化全冷。
  - 热槽 seed 用空结果：`fushi/lib/src/pages/base_source_page.dart:99-104`（`seedWarmSlot(seedResult: kPopupSearchingPlaceholderResult)`，`kPopupSearchingPlaceholderResult = DictionarySearchResult(searchTerm: '')`，`dictionary_popup_controller.dart:21`）→ popup.js 走 `renderPopup` 的 no-results 早退（`fushi/assets/popup/popup.js:5306-5316`），`buildEntryElement` / 词典 CSS / masonry 这条真实渲染路径一行都没跑。
  - 次因（量级小）：引擎 mmap 冷页——`native/fushidicts/fushidicts_src/memory/memory.cpp` 的 `map_rd` 纯 `MapViewOfFile` 不预触页，启动预热 `app_model.dart:1947` 只查 `こんにちは世界` 三次；新词落到没进 OS 页缓存的页就是磁盘缺页。
- **[ ] ① 未修复** —
- **[ ] ② 未加自动化测试** —
- **备注**：
### 实测（2026-09-12，Windows 离屏 itest，隔离根，用户同款 Klee One 词典字体 + 用户 6 本真实词典：大辞林/三省堂/明鏡 term、NHK/大辞林 pitch、JPDB freq）
| 次序 | 词 | 端到端到 `isDictionaryShown` | push→首次 `popupRendered`（露出） | JS `renderPopup` 全量 | push→末次 `popupRendered`（长满） |
|---|---|---|---|---|---|
| 1 首查 | 猫 | **49ms** | **96ms** | **170ms** | **409ms** |
| 2 换词 | 本 | 22ms | 50ms | 195ms | 257ms |
| 3 复查 | 猫 | 10ms | 30ms | 42ms | 82ms |
| 4 复查 | 本 | 12ms | 56ms | 141ms | 236ms |

首查的 JS `first-entry-dom` 12.1ms vs 之后 3.6~7.5ms；`renderPopup` 全量 170ms vs 同词复查 42ms。第 2 次换新词就已经与它自己的复查（第 4 次）同量级，说明多付的是**每个新弹窗 WebView 一次性**的成本，正对应「每次开书/开视频后第一次点词慢一拍」（阅读器/视频/首页三个表面共用同一个 `DictionaryPopupWebView` 热槽机制）。

### 已排除的嫌疑（都有实测证据）
- **词典字体首拉**：首查前探针 `document.fonts` 显示 `Klee One:loaded`——seed 那次空卡渲染已经把 8.7MB 字体经拦截器拉完（push→rendered 528~565ms，在开书后台付掉）。只有用户开书 <1s 就点词才会撞上。
- **静态段重发（BUG-1868 形态）**：首查 `staticChanged=false`，没重发。
- **引擎待办同步重建（BUG-2110 形态）**：启动 `loadPendingAsync` 已结算，稳态无待办；只在改过词典设置后才命中一次。
- **Profile 切换整体重载**：用户只有 1 个 Profile，`autoApplyBinding` 同 id 不切。
- **引擎本身**：`flutter test` 直接映射用户 26 本词典（2.6GB）：装载 29ms；OS 页缓存冷时新句 16~48ms，热后 2~5ms，同句复查 1~3ms。到不了「一拍」。

### 修复方向（未实施，待拍板）
热槽 seed 改用一份**真实渲染过的结果**预热（例如启动预热 `_warmUpSearchAfterFirstFrame` 已经查过的 `こんにちは世界` 结果，或任一本地命中词），让 JIT / 词典 CSS / 字形缓存在用户第一次点击前就热；seed 完成后再换回空卡或直接停在屏外。要注意：seed 结果不得进查词历史 / 统计 / `onLookupStarted` 计数（`base_source_page.dart:102` 的 `_recordLookupCounter`），也不能让 `_lastSearchTerm` 去重把用户真查同一个词判成 load-more。引擎冷页可在启动预热里对每本词典各触一次 hash 桶（收益 ~30ms，次要）。

探针脚本（含 `[popup-perf]` push/rendered 打点与 `document.fonts` 探针）备份在本次会话 tmp，修复时可直接回灌成 perf itest。
