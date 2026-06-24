# reader_pitch_headless — 竖排阅读器分页列周期真实渲染探针

仓库的分页几何守卫 `hibiki/test/reader/reader_vertical_pitch_invariant_test.dart` 是**纯
代数影子**：它把「真实列周期」直接定义成 `columnWidth + gap`（名义值），所以结构上**测不出**
浏览器 multicol 实际渲染的列周期是否真等于这个名义值。这个盲点让一个**不存在**的「竖排翻页
累积偏移」问题拿到了 P0（见 `docs/bugs/BUG-405-pagination-cumulative-offset.md`）。

本目录用 headless Chrome 复刻竖排 reader 的真实 CSS（`reader_content_styles.dart` 的
`column-width: max(F, V−mt·vh−mb·vh−F)` + `column-gap:22px` + padding），逐字符量
`getBoundingClientRect().top` 拼出真实列带顶序列，从而验证真实渲染层的两个不变量。

## 用法（本机，CI 跑不到真 WebView）

```bash
cd tool/reader_pitch_headless
npm install                 # 装 puppeteer-core（不下载 Chromium，用系统 Chrome）
node band_period_probe.js   # 默认 5 组字号×视口；退出码 0=PASS 1=FAIL
```

- 默认系统 Chrome 路径 `C:/Program Files/Google/Chrome/Application/chrome.exe`，
  可用环境变量 `CHROME_PATH` 覆盖。
- 本机直连 GitHub 不稳，`npm install` 前可 `export HTTPS_PROXY=http://127.0.0.1:34151`。

## 断言的不变量

- **I1**：全程所有列带的**平均列周期 ≈ 名义 pageStep**（`|Δ| ≤ 1px`）。实测各字号差 <0.2px，
  证明名义 `contentBox+gap` 就是正确的累积步进单位。
- **I2**：真实滚动到 `scrollTop=k*pageStep` 后，视口顶列相对 padding-top 的偏移在 30+ 页内
  **有界振荡**（锯齿幅度 ≈ 一个列内步进），且**净漂移不随 N 增长**（终点落在振荡带内）。

## 关键发现（为什么不是 bug）

列带顶相邻差不是单一稳态值，而是**有界锯齿**（亚像素列宽布局：多为 ~731.94，每 ~4 列回吐一个
~761.94）。**全程平均 == 名义 pageStep**。`paginate()`（`reader_pagination_scripts.dart`）每步把
目标 snap 到绝对网格 `(floor(stepScroll/pitch)±1)*pitch`（非增量 `+=pitch`），结构上误差不可累积。
原 P0 的「+185px/30 页」来自旧调查脚本用 `(bt[13]-bt[3])/10` 10 带窗口估周期撞锯齿相位偏置，
再当「每页漂移率」×30 凑出来——是**测量伪影**，不是真渲染漂移。

> 若哪天 I1/I2 真的 FAIL，那才是出现了真的列周期偏离，再按 BUG-405 备注里列的候选方向沿真实路径定位。
