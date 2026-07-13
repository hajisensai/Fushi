## BUG-789 · 底栏 inset 后分页终点过期导致章尾不可读

- **报告**：2026-07-13（复验用户「翻页漂移问题」的固定 420 标记章节时发现）。
- **真实性**：✅ 真 bug。真实 macOS WKWebView 在 reader chrome 落地后，列距由
  `635` 变为 `582.490967`，但扫描仍只到 413/420；即使强制重建 metrics 后，末点也被
  截在 `61 × pitch = 35531.948987`，m420 仅在视口底部露出约 40px。
- **根因**：
  1. `hibiki/lib/src/reader/reader_pagination_scripts.dart` 的分页
     `setChromeInsets` 写入 `--chrome-top-inset/--chrome-bottom-inset` 后，没有使
     `paginationMetrics` 失效；快速切换分支还会在重锚进行中直接 return，于是用旧 pitch
     建成的 `maxScroll` 长期缓存，提前约两页返回 `limit`。
  2. 重建后的 `buildPaginationMetrics` 只保留完整的 `N × pitch` 终点。chrome inset 使
     `pageStep` 小于 scrolling element 的 client extent，浏览器真实物理终点
     `scrollHeight-clientHeight=36041` 落在第 61、62 条网格之间；继续截在第 61 条网格会
     隐藏末段，直接请求第 62 条网格又会被浏览器 clamp，并可能让 `paginate` 重复报告
     `scrolled`。
- **[x] ① 已修复** — inset CSS 写入后、任何 early return 前立即清空 metrics；
  `getScrollContext` 另暴露只用于末页的 `physicalMaxScroll`。中间页仍严格走绝对
  `N × pitch` 网格；当末内容跨过最后一条可达整页网格时，仅增加一次真实物理终点页，
  forward 下一次稳定返回 `limit`，backward 回到上一条整页网格。`pageInfo` 同步把这张
  非网格 terminal clamp 计为一页。
- **[x] ② 已加自动化与真机测试** — 纯函数锁定本机 RED 数值、尾随空白反例与负 pageStep；
  JS 源码守卫锁定 inset 失效和物理终点；integration harness 固定期望 420、按正文裁剪盒
  统计 text-range 可见面积、拒绝任意 `minScroll` 新原点和只露缝的末标记。2026-07-13
  macOS 真机复跑为 63 页、raw `pitch=582.490967`、420/420、I1-I7/I9/I10 全通过；末页
  `scroll=metricsMax=browserMax=36041`，m420 从 `top=85` 到 `bottom=623.5`，不再提前停翻。
- **备注**：逻辑 `maxScroll=totalSize-pageStep` 仍保持 TODO-729 单一翻页量纲；新增物理值
  不是第二套 pageStep，只是浏览器不可再滚动时的一次性章尾钳位。
