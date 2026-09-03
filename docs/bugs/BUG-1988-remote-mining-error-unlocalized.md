## BUG-1988 · 互联远端制卡不可达错误未本地化
- **报告**：2026-08-31（用户：制卡失败日志仍显示英文，追问“翻译呢”）
- **真实性**：✅ 真 bug。`fushi/lib/src/anki/remote_mining_anki_repository.dart:226` 把互联对端不可达复用为 `ANKI_CONNECTION_UNKNOWN`；`fushi/lib/src/utils/misc/error_log_service.dart:574-575` 会优先把该码映射为通用 AnkiConnect 连接文案并忽略英文 `errorDetail`，此前又没有互联制卡专用 i18n 键，因而无法显示针对配对设备的中文恢复建议。
- **[x] ① 已修复** — 新增稳定码 `ANKI_PAIRED_DEVICE_UNREACHABLE`，远端仓库按真实失败边界返回该码，并在制卡失败的本地化映射中使用专用文案；通过 `i18n_sync.dart` 补齐语言键并由 slang 重新生成。提交：`d9d6df21eb`。
- **[x] ② 已加自动化测试** — `fushi/test/anki/remote_mining_anki_repository_test.dart` 验证不可达响应的专用错误码；`fushi/test/anki/mine_failure_surfacing_test.dart` 切换到 `zh-CN`，验证中文文案同时包含启动配对设备 Fushi 与关闭「制卡到已配对设备」两条恢复路径。
- **备注**：纯错误分类与本地化映射变更，无需设备视觉验证；英文 `errorDetail` 继续保留为诊断日志和未知 locale 的安全回退。
