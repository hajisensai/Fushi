## BUG-1333 · 漫画 Lens 同一气泡被拆成多列导致制卡句子残缺
- **报告**：2026-07-29（用户：制卡没有把漫画气泡整句算进去，怀疑 OCR）
- **真实性**：✅ 真 bug。用户当次 Google Lens 缓存的
  `page-000003.jpg` 把同一句竖排对白拆成四个块：
  `だいじょうぶ`（注音）、`大丈夫`、`だよな`、`?`。原
  `hibiki/lib/src/media/manga/manga_overlay_html.dart:27` 按“一个 OCR
  block = 一个 `<p>`”渲染，而
  `hibiki/lib/src/reader/reader_selection_scripts.dart:1082` 的句子上下文
  只在当前段落内取值，因此点击任一列时制卡句子必然只有该列；问题不在 Anki
  字段映射。
- **[x] ① 已修复** — `0599fa97b`：覆盖层按横/竖排阅读轴把相邻 OCR
  行/列合成标点封口的句子，并将完整句子回填到组内每个 block；窄假名注音仍可
  点击，但不重复写进正文。选区 payload 优先读取这份几何重建句子，现有 Lens
  缓存无需重跑 OCR 即可生效。
- **[x] ② 已加自动化测试** — `0599fa97b`：
  `hibiki/test/media/manga/manga_overlay_html_test.dart:147` 使用用户真实页面的
  block 坐标稳定复现四段拆句，断言四块均得到 `大丈夫だよな?`、注音被排除，
  并覆盖横排多行合句与强句末停止；selection payload、数据解析和制卡分发链路
  一并纳入定向测试。
- **备注**：相关 81 项 Flutter 测试全部通过，Windows debug 构建成功。
  修复版在用户原漫画第 2–3 页实机点击了该气泡，查词链路正常；未额外写入一张
  Anki 卡，避免污染用户牌组。`flutter analyze --no-pub` 未产生代码诊断，
  Flutter 3.44 analysis server 因 LSP JSON 响应截断崩溃。
