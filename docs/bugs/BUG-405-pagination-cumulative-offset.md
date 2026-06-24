## BUG-405 · 竖排翻页累积偏移(pageStep名义值≠真实渲染列周期)
- **报告**：2026-06-23（用户：「竖排翻页页面和实际文字偏移，越翻页偏移越大」）
- **真实性**：❌ 未复现（headless Chrome 真实渲染实测**证伪**累积说）。沿真实代码路径 +
  真机引擎几何实测后结论：**不存在「越翻页偏移越大」的累积漂移**，名义
  `pageStep = contentBox + gap`（`hibiki/lib/src/reader/reader_pagination_scripts.dart`
  getScrollContext :1320-1359）已是正确的列周期。
  - **铁证**：用 `tool/reader_pitch_headless/` 的 headless Chrome harness 复刻竖排 reader CSS，
    逐字符 `getBoundingClientRect().top` 归列带、量真实列带顶序列：
    - 列带顶相邻差是**有界锯齿**（亚像素列宽布局：多为 731.94，每 ~4 列回吐一个 761.94），
      不是单一稳态值。**全程 161 带的平均周期 == 名义 pageStep**（F18 815.23 vs 815.28 /
      F22 766.96 vs 767.12 / F26 873.35 vs 873.52 / F30 739.95 vs 739.92，逐字号差 <0.2px）。
    - 真实滚动到 `scrollTop=k*pageStep` 后探视口顶列偏移，30+ 页**有界振荡**（F30 在
      ±~12px 内，p10=-1.6 p20=+8.8 p30=-11.8），**不随 N 增长**。
    - `paginate`（:1622-1660）每步算 `target=(floor(stepScroll/pitch)±1)*pitch` 绝对网格对齐
      （非增量 +=pitch），结构上**误差不可累积**。
  - **原 P0 误判根因**：之前的调查脚本 `realpitch_from_scroll.js` 用 `(bt[13]-bt[3])/10`
    10 带窗口估列周期，撞锯齿相位偏置得 733.74（≠真实均值 739.95），再把它当「每页漂移率」
    ×30 凑出「+185px」。`fix_verify.js` 自己的 `alignErrNominal` 输出其实是 16→38→60→82→32→24
    →16… 的**有界锯齿**（注释写「应递增累积」但数据并不递增），只看前 4 个值误判成线性累积。
  - 若按原 P0 方案把 pitch 换成「列带顶中位数/窗口拟合」，因中位数取的是锯齿众数(731.94 偏低)
    **反而引入真漂移**（F30 实测 fitted 30 页 +228px）——把没病的引擎治出病。已实现该方案后用
    同一 harness 自验为「更差」，遂**整段回退**，零代码改动。
- **[x] ① 无需修复（证伪）** — 引擎几何正确，未改任何运行代码。若用户仍在真机看到偏移，应是
  *别的*症状（候选：① 切字号/章节后 reanchor 落相邻页 ② 真机 EPUB 非均匀内容/ruby 的列内
  抖动被误读 ③ 底栏遮挡几何），需用户提供具体书 + 字号 + 复现步骤重新沿真实路径定位，
  不要再按「名义 pitch 错」这条假设动 getScrollContext。
- **[x] ② 已加自动化测试（盲点工具入库）** — 仓库无内置 headless 是「非 bug 拿到 P0」的根因。
  把 headless Chrome harness 入库 `tool/reader_pitch_headless/`（puppeteer-core + 系统 Chrome +
  README，本机运行：`node band_period_probe.js`）作为竖排分页几何的**真实渲染回归手段**：
  断言「全程平均列周期 ≈ 名义 pageStep（差 <1px）」「真实滚动后视口顶偏移有界不随 N 增长」。
  CI 跑不到真 WebView（main.yml 走 Linux 无 WebView2），故文档化为本机/真机回归。纯代数守卫
  `reader_vertical_pitch_invariant_test` 结构上测不出列周期真伪（它把 realPitch 定义成
  columnWidth+gap），这次正是 harness 才证伪了 P0。
- **备注**：四类原「绝不回归」项均未触碰（零代码改动）：① 翻一半跳章(729) ② 漏到底栏(734)
  ③ 坍塌叠印(743) ④ 双页 spread——全部保持 develop f9dada776 原状。
