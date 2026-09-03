## BUG-1694 · Jimaku 搜索永不传 anime 参数，真人剧/日剧字幕永远 0 结果
- **报告**：2026-08-17（用户：字幕自动下载准确率优化）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/media/video/jimaku_client.dart:_searchEntries`——全仓从未拼过 `anime` query 参数（`grep -c anime jimaku_client.dart` = 0）。Jimaku `/entries/search` 把 `anime` 当**硬相等过滤**且**缺省 `true`**，于是每一次搜索都只在动画子集里进行，Jimaku 上数千条真人日剧/日影条目在任何入口（播放页对话框 / 合集批量 / 番剧下载 / 下载流水线）都搜不到。
  第二道锁在 `fushi/lib/src/media/video/download/video_subtitle_registry.dart:18-25`：非 anime 分类只放 OpenSubtitles，Jimaku 连被调用的机会都没有——而日语字幕恰恰是 OpenSubtitles 最缺、Jimaku 最强的一档。
- **[x] ① 已修复** — `JimakuAnimeFilter` 三态（anime / liveAction / either），`either` = 先 `anime=true` 空结果再 `anime=false`，动画命中即停所以动画用例请求数不变；`JimakuVideoSubtitleProvider` 按 `discoveryCategory` 直接给出确定档；registry 不再按分类把 Jimaku 挡在门外。
- **[x] ② 已加自动化测试** — `fushi/test/media/video/jimaku_client_test.dart` 的 `BUG-1694 anime 硬过滤` 组：三条分别钉住「缺省 either 会真的发出 `anime=false` 那一发」「liveAction 只发一次」「动画命中不多打」。
- **备注**：`anime` 是硬过滤不是排序权重，所以「不传参数 = 搜全部」这个直觉是错的——这也是它藏了这么久的原因。
