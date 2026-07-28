## BUG-1227 · 大 GIF 上传超时被吞后仍创建无图卡并留下孤儿媒体
- **报告**：2026-07-29（用户反馈 Anki 制卡时未响应，且卡片经常缺少图片、GIF）
- **真实性**：✅ 真 bug。默认 GIF + 最高质量配置会产生数 MiB 到十余 MiB 的文件；旧实现把本地媒体编码成 Base64 后通过 JSON 上传，并在上传超时或失败时吞掉异常、返回空媒体，随后仍继续 `addNote`，因此既可能阻塞 Anki，也会创建无图卡并留下已落盘但未引用的媒体。根因位于 `packages/hibiki_anki/lib/src/ankiconnect/ankiconnect_repository.dart:1186` 与 `hibiki/lib/src/mining/immersion_mining_engine.dart:141`。
- **[x] ① 已修复** — `adbb79476`：本机 AnkiConnect 改用文件路径上传，远端端点保留 Base64 回退；封面、GIF、句子音频与词典媒体全部成功后才调用 `addNote`，必需媒体失败则整次制卡失败。媒体保持用户所选质量，不按文件体积擅自降质。
- **[x] ② 已加自动化测试** — 覆盖本机路径上传、远端 Base64 回退及媒体超时禁止 `addNote`。
- **备注**：媒体上传链路 68 个定向测试、当前队列与媒体质量链路 36 个定向测试通过，两个受影响模块的定向 analyzer 均为 0 issues。按用户要求未等待 Windows 整包编译验收；也未向用户个人 Anki 写入测试媒体。
