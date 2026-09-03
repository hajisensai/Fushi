## BUG-1845 · 在线字幕落盘直接拼远端文件名，可路径穿越写出目标目录
- **报告**：2026-08-25（代码审计，非用户报告）
- **真实性**：✅ 真 bug（安全） — 根因
  `fushi/lib/src/pages/implementations/jimaku_subtitle_dialog.dart` 的 `_downloadSource`：
  `final String dest = p.join(dir.path, download.fileName);`
- **[x] ① 已修复** — 见本轮提交
- **[x] ② 已加自动化测试** — `fushi/test/pages/subtitle_download_path_traversal_test.dart`
  （4 例纯函数 + 1 例端到端）
- **备注**：与 [BUG-1842] / [BUG-1843] / [BUG-1844] 同一个对话框，但这条不是用户报的。

### 根因

`VideoSubtitleDownload.fileName` **完全由远端 provider 决定**（Jimaku 用条目里的 `file.name`，
OpenSubtitles 用下载响应给的名字）。`p.join(dir.path, '../../evil.srt')` 归一后指向保存目录
之外，`File(dest).writeAsBytes(...)` 就会把内容写到那里——一个在线字幕源可以改写用户磁盘上的
任意文件（用户点一次「下载」即触发，无需任何额外交互）。

Windows 上还多一种逃逸形态：`C:evil.srt` 是「盘符相对路径」，`p.join` 会把它当根、直接丢掉
目标目录。

### 修复

新增纯函数 `safeSubtitleFileName(String)`，落盘前只取安全叶名：

- **同时按 `/` 和 `\` 切**——`p.basename` 只认**当前平台**的分隔符，Linux/macOS 上
  `..\evil.srt` 会被原样当成一个合法文件名放行，而字幕来自远端，攻击面与运行平台无关
  （这也是 CI 在 Linux 上跑、开发机在 Windows 上跑时最容易漏掉的一类假绿）；
- 剥掉 Windows 盘符段（冒号在 Windows 文件名里本来就非法）；
- 结果为空 / `.` / `..` 时退回确定的兜底名 `subtitle.srt`，不写出空路径。

### 测试怎么写的

纯函数层喂 8 个敌对文件名（`../`、`..\`、`/etc/passwd`、`C:\Windows\...`、`C:evil.srt`、
`sub/../../evil.srt` …），断言输出不含任何分隔符与冒号，并**用 `p.posix` 与 `p.windows`
两套 Context 各拼一次**，断言 `ctx.isWithin(root, dest)` 恒真——只用当前平台的 `p` 会在另一端
假绿。

端到端层用一个 provider 桩回 `../../evil.srt`，真下载真落盘，断言：pop 回来的路径仍在保存目录
内、逃逸目标文件不存在、落盘文件确实存在。变异实测（把 `safeSubtitleFileName` 从调用点拿掉）
时这一例直接打印出
`...\video_subtitles\../../evil.srt 逃出了 ...\video_subtitles` —— 拦得住，也证明得了。

### 变异实测

调用点改回 `p.join(dir.path, download.fileName)` → 端到端例转红；还原后文件 sha256 与变异前
一致。
