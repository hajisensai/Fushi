## BUG-5219 · 有声书歌词视图里整句扫词键 / 鼠标侧键失效（键桥漏动作、非 Windows 鼠标回调只认跳句）
- **报告**：2026-11-22（2026-11-22 合并审查 HBK-AUDIT-221，PR #4130）
- **真实性**：✅ 真 bug。#4130 声明「正文三种视图与有声书歌词视图共用」扫词、「键盘 / 手柄 / 鼠标三条通道都落到本执行体」，但歌词文档两条输入通道都没接上：
  - 键盘：`fushi/lib/src/pages/implementations/reader_fushi/lyrics.part.dart:18` `kLyricsBridgedActions` 漏了 `readerLookupNextWord` / `readerLookupPrevWord`。歌词 WebView 一拿到 OS 焦点（点过词 / 行之后），扫词键只到 DOM，`onLyricsKey` 键桥不导出也不反解析它们。
  - 鼠标（非 Windows，指针归 WebView 的平台）：`fushi/lib/src/media/audiobook/lyrics_mode_html.dart:1859` 非左键 `mousedown` 只在 `.cue` 行上回传，`lyrics.part.dart:1823` `onLyricsPointerSeek` 只做「seek 到点击句」，且入口就因 `_audiobookController == null` 早退。绑到侧键的扫词 / 关词典等动作在歌词视图里全是死项（正文 `onPointerSeek` 早已是「位置型 → 宿主让位 → 通用执行体」三级阶梯，BUG-2031）。
- **[x] ① 已修复** — 键桥动作表加上两个扫词动作（reader scope，排在 audiobook 之前）；歌词 JS 非左键按下一律回传（行外行号 -1），`onLyricsPointerSeek` 改成与正文同一条阶梯：入口先收回焦点 → 位置型 seek（controller 门控只在这一支）→ `hostOwnsWebViewPointerInput` 让给页面根 Listener → `resolveMouseBindingActionForButton` + `_executeShortcutAction`（扫词经唯一派发点分流）。
- **[x] ② 已加自动化测试** — `fushi/test/pages/reader_lyrics_key_bridge_test.dart`：扫词键经歌词键桥导出并反解析到扫词动作；生成 HTML 的 mousedown 在行外也回传；`onLyricsPointerSeek` 三级阶梯顺序与 controller 门控位置的接线守卫。
- **备注**：WebView 内真实焦点 / macOS 侧键逐词行为未在设备上复测（需 Windows 原生 WebView 焦点与 macOS 侧键），待补。
- **后续**：2026-11-23 按拍板台 pr4141a 删除阅读器整句扫词，键桥里的两个扫词动作与对应测试随之去掉；歌词非左键回传与 `onLyricsPointerSeek` 三级阶梯是通用鼠标绑定通道（关词典等），保留。
