## BUG-5459 · 更新后网页制卡写到 Anki，制卡去向疑似改变

- **报告**：应用内反馈 5-8sfIbHd1（Windows 3.4.0+32563）。补充说明称，更新完 Fushi 后先在网页制卡，查询时看到新卡落在 Anki，随后发现复习设置变了。认为当时旧卡已消失是反馈人的推测，截图只证实当前配置的默认牌组为 0 张。
- **真实性**：网页写入 Anki 是反馈人的观察，自动改写设置仍未复现。原日志证实目标复习库已经绑定给本机另一份配置，详见 [同步修复 PR #4442](https://github.com/hajisensai/Fushi/pull/4442)。没有网页制卡请求使用的配置、更新前后的「保存到」值，也没有原始数据库。
- **[ ] ① 未修复** — `fushi/lib/src/profile/extension_profile_adapter.dart` 的 `resolveScope` 按扩展选择、浏览器绑定、App 激活配置的顺序决定制卡使用的设置。`fushi/lib/src/models/app_model.dart` 的 `hostMiningRepositoryForView` 按该设置选后端。选定 Fushi 复习的请求若遇到迁移阻塞，`fushi/lib/src/srs/srs_mining.dart` 的 `_minerForWrite` 返回代际错误，不改投 Anki；迁移入口也不写制卡去向。
- **[ ] ② 未加自动化测试** — 既有 `fushi/test/srs/srs_install_default_test.dart` 22 项实跑通过。覆盖显式 Fushi 目标重启后保留，以及切入缺少该项的旧配置时可能回落到 Anki。
- **复现所需**：网页制卡前后扩展所选配置、App 激活配置及「设置 → 制卡 → 保存到」的值。若用其他网页制卡工具，补工具名称和实际写入端点类型。

- **追加确认**：反馈人确认更新后切到了另一份配置方案。当前配置的牌组数与网页制卡去向因此可以同时变化。仍缺升级前后的配置名与版本，无法区分 App 启动时更换了激活配置，还是网页入口命中了不同的配置。
- **启动路径核查**：`ProfileRepository._ensureDefaultProfile` 在保存的激活配置无效时才回到第一份。`ProfileViewModel._restoreLegacyBindingFallback` 会在首次加载时消耗旧版作品绑定的 `profile_fallback_id` 并切回记录的配置。两条路径在 3.3.0 和 3.4.0 都已存在。3.4.0 作品绑定优先级调整只改变会话的生效配置，浏览器扩展的配置信息解析与 3.3.0 相同。
- **复测**：`fushi/test/profile/work_profile_session_test.dart` 11 项通过，包括绑定不改全局激活配置，以及有旧回退点时启动确实切换并清除回退点。
