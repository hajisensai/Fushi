## BUG-3148 · 互联下载/入站配置后配置管理列表不刷新，需重启才看到
- **报告**：2026-10-07（GitHub issue #1997 问题二：「从对端下载配置」显示成功，界面仍是旧配置，杀后台重进才出现新配置）
- **真实性**：✅ 真 bug。配置管理页的 `profileViewModelProvider` 是常驻的（非 autoDispose），列表只在构造时与本类自己发起的操作之后重读。互联下载（`interconnect.part.dart` 的 `_download`）与对端上传入站（`app_model.dart` 的 `importProfileJson`）都用另一份 `ProfileRepository` 直接写 profiles 表，视图模型无从得知，列表停在旧值直到进程重启。
- **[x] ① 已修复** — `ProfileRepository.watchProfilesChanged()` 暴露 profiles 表的 drift 表级变更流；`ProfileViewModel` 订阅它，任何写入方写了 profiles 表都重读列表（只刷新列表，不动激活 id 与绑定，`fushi/lib/src/profile/profile_view_model.dart:147`）。表级流是唯一真相，比在每个写入点记得通知可靠。
- **[x] ② 已加自动化测试** — `fushi/test/profile/profile_list_refresh_on_external_write_test.dart`：常驻视图模型加载后，用另一份仓库 createNew 导入一份配置，断言视图模型状态自己出现新配置、激活 id 不变。
- **备注**：下载的配置按设计作为**新**配置追加（不覆盖当前配置），用户仍要在「配置管理」里切过去才生效；要不要「下载后直接切换」属于产品取舍，未改（见 PR 待定）。
