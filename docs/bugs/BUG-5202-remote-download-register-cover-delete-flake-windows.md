## BUG-5202 · remote-download-register-cover-delete-flake-windows
- **报告**：2026-11-22（BUG-5197 跑相关测试时发现）
- **真实性**：✅ 间歇红（存量，非 BUG-5197 引入）。`fushi/test/pages/home_video_remote_download_register_test.dart` 「fake 区后台任务持封面锁时，下载登记仍拿到 host 封面」在 Windows（dist self-win）上 5 次红 2 次，同批在 self-mac 重跑全绿。失败形态：登记链落封面时删旧文件报 `PathAccessException: Cannot delete file … remote_videos\remote-clip.cover.jpg`（文件被另一句柄占用），`row.coverPath` 为 null（测试 :366）。Windows 不允许删除被打开的文件，疑为同一封面路径上还有读句柄（卡片解码 / 回填任务）与 `MediaCoverService.applyCoverBytes`（`fushi/lib/src/media/media_cover_service.dart:68`）的「删旧 + rename」竞争。BUG-5197 的改动没有触及这条路径的任何文件 IO（`home_video_page.dart` 的 diff 不含 File / readAs / coverPath / exists）。
- **[ ] ① 未修复** — 待查：谁在删除时持有该封面文件的句柄；Windows 上落稳应改为「写临时文件 + 原子替换（MoveFileEx REPLACE_EXISTING）」而不是先删后改名。
- **[ ] ② 未加自动化测试** — 现有用例已能间歇复现（Windows）。
- **备注**：
