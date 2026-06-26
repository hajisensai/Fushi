## BUG-433 · 外挂ASS毫秒精度时间码加载失败误报不支持
- **报告**：2026-06-27（用户：）
- **真实性**：✅ 真 bug，根因 `packages/hibiki_audio/lib/src/parsers/ass_parser.dart:229`（旧行）`_parseAssTime` 正则 `^(\d+):(\d{2}):(\d{2})\.(\d{2})$` 硬性只认 2 位厘秒。内封轨经 ffmpeg 抽取规范化成 2 位故正常；外挂 .ass 若时间码为 3 位毫秒（`0:00:01.000`，常见于 SRT→ASS 转换工具）或 1 位十分之一秒 → `startMs=null` → `if (startMs == null) continue` 跳过 → 0 cue → 上层 `cues.isEmpty` → 报 `video_subtitle_load_failed`（文案含「不支持」，误导）。
- **[x] ① 已修复** — 正则小数秒 `(\d{2})` → `(\d{1,3})`，归一到毫秒改用与 `srt_parser.dart:210` 同构的 `padRight(3, '0')` 写法（1 位.1→100ms / 2 位.67→670ms / 3 位.000→0ms），消除 ASS 孤立特例。保留 `am>=60 || as_>=60` 越界守卫。修复提交：e3243f95f（`ass_parser.dart`）。
- **[x] ② 已加自动化测试** — `hibiki/test/media/audiobook/ass_parser_test.dart` 新增两用例：3 位毫秒 `0:00:01.000` → startMs==1000、1 位 `.1` → +100ms；撤掉修复（旧 2 位正则）两用例转红（Expected 1, Actual 0），加修复后转绿（13/13 全绿）。同文件现有 `.67→670ms` 厘秒用例继续守护。测试提交：e3243f95f。
- **备注**：与 SRT/VTT 解析器对齐，不手写 ×100/×10/×1 三分支。ASS 字段已按逗号拆分，`_parseAssTime` 收到的不含逗号，无需 replaceAll(',','.')。
