## BUG-1281 · 词典自动更新检查成功但无新版时永远显示从未并重复检查
- **报告**：2026-07-29（用户：）
- **真实性**：✅ 真 bug。`hibiki/lib/src/models/app_model.dart:3630-3664`
  的启动自动更新循环原来用 `successCount` 只统计“发现新版且下载重导成功”的词典，
  并仅在 `successCount > 0` 时写 `last_dictionary_update_at`。因此联网检查全部成功但
  所有词典已是最新版时，`lastDictionaryUpdateAt` 永远为 null，设置页一直显示“从未”，
  `shouldAutoUpdateDictionaries(lastUpdate: null)` 又让每次启动都重复联网检查。另一个
  契约缺口是 `DictionaryUpdateService.fetchRemoteIndex` 把网络/解析失败和“无新版”都
  压成 nullable revision，调用方无法安全地把成功检查计入完成数。
- **[x] ① 已修复** — `0bacb5e99`：自动更新改用结构化远端 index 结果；已是
  最新版也计为成功完成，只有整批检查/必要重导全部成功才写上次检查时间。
- **[x] ② 已加自动化测试** — `0bacb5e99`：
  `hibiki/test/dictionary/dictionary_auto_update_test.dart` 覆盖整批完成判据与
  AppModel 接线；`dictionary_update_service_test.dart` 覆盖远端成功、网络失败及
  坏 index 的结果区分。
- **备注**：修复保留既有 `last_dictionary_update_at` 偏好键兼容旧数据，但明确其语义
  为“上次完整成功检查”。所有可更新词典都成功读到远端 revision，且发现新版时也成功
  重导，才推进时间；任一本检查/重导失败都不推进，以便下次启动重试。设置页文案同步
  改为“上次成功检查”，避免把“检查过但无新版”误解成“更新器没运行”。
  `flutter analyze --no-pub` 已通过；定向测试在执行用例前被 `pdfium_dart` 从 GitHub
  下载原生资产超时阻断，按用户要求未等待编译/下载验收，留 CI 执行。
