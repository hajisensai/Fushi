## BUG-3366 · iOS 竖排歌词扫过高亮不按阅读顺序跨列
- **报告**：2026-10-14（用户：iOS 竖排歌词模式截图，「ios歌词模式高亮顺序有问题」——当前句「その音に耳を澄ませてみると、扉の向こうでくすくす笑うようなざわめきが起こっている。」三列里每列上半段已亮、下半段仍暗：第一列「扉の向」暗、第二列「なざわめきが」暗、第三列「起こっている。」已亮，屏上是一条横带）
- **真实性**：✅ 真 bug，是 BUG-3346 修复时明确接受的代价。WebKit 回退（`fushi/lib/src/media/audiobook/lyrics_mode_html.dart:458` 的 `@supports not (box-decoration-break: slice)`）为了让长句不消失把 `.tx` 变成 `inline-block`，于是 BUG-3105 的竖排规则 `linear-gradient(to bottom, … var(--ly-p) …)` 铺在整块原子盒上：渐变只按纵坐标走，所有列在同一高度同时被点亮，跟阅读顺序（右列自上而下扫满再进左列）无关。Blink 走行内盒 + `box-decoration-break: slice`，渐变沿各列接续，不受影响。
- **[x] ① 已修复** — 仍保留 inline-block（BUG-3346：WebKit 画不出多列行内盒上的 text 裁剪背景），改为按列铺渐变：`_lyLayoutSweepColumns`（`lyrics_mode_html.dart:914`）量出当前句每列的布局几何（跳过 rt / rp 注音、除掉当前句放大 transform），右列在前排序，第 i 列占全句累计长度 `[s, s+len)`，铺一层 `linear-gradient(to bottom, current calc((p - s - 4%) * total/len), upcoming calc((p - s + 4%) * total/len))`，与 Blink slice 的跨列接续逐像素等价（软边同为全长 ±4%）；三个变量 `--ly-cols-bg/-pos/-size` 交给回退规则，未量到时退回整块渐变，末层兜底未读色、文字绝不透明。几何只在换句、起播、重新适配字号时量；进度推进仍只靠 `--ly-p` 的一次 CSS transition，不逐帧回传。
- **[x] ② 已加自动化测试** — `fushi/test/media/audiobook/lyrics_vertical_sweep_columns_js_test.dart`：node 跑生成文档里真实的 `_lyLayoutSweepColumns`（三列 + 注音节点 + 1.15 放大的 DOM 桩），解析写出的 calc 断言全局进度 20% / 50% / 95% 时右列 → 中列 → 左列依次推进、注音不成列、几何换回布局像素；Blink（认 slice）与暂停态（行内盒）不铺列层；回退规则读列层变量。修前代码没有列层，该文件红。
- **备注**：
  - iOS 模拟器 Safari 真 WebKit 探针（iOS 26.5 / FushiProbe，页面 = 本修复的生产 `LyricsModeHtml.generate`：竖排、MD3 覆盖层主题、`platform: iOS`、截图里同几句 cue，URL 参数驱动 `__lyricsSetPlaying` / `__lyricsSetCue` / `__lyricsSetProgress`）：进度 20% 只有右列上段亮、往下渐暗，左两列未读；50% 右列整列亮、左两列未读；80% 右两列亮到第二列中段、末列未读；暂停整句点亮；短句正常。修前同一状态是截图里的横带。
  - node 测试在 Mac 上跑不了（Mac 没装 node，三条 node 用例因此红），本机与 CI 有 node；已用 Mac 生成的真文档在本机 node 下跑通三条用例。
  - 未在 Fushi app 本体的 iOS 真机上复测，等用户确认。
