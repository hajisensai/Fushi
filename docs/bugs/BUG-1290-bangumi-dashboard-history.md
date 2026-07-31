## BUG-1290 · Bangumi 首页卡把映射误当观看历史且不列待手动关联条目
- **报告**：2026-07-29（用户：右上角 Bangumi 点击应展示全部看过；删掉“还没有任何条目关联……”泛化说明；明确写出哪些需要手动关联；以前看过的内容没有显示。）
- **真实性**：✅ 真 bug。首页卡的数据源只有 `MediaTrackingStatus.mappings`（`hibiki/lib/src/pages/implementations/home_dashboard_page.dart:2247`），而映射表只含 Hibiki 建立过的本地→Bangumi 关联，既不是账号收藏历史，也不会包含尚未关联的旧本地观看/阅读记录。因此“以前看过”必然缺失；零映射文案只能给出泛化说明，无法回答“哪些需要手动关联”。Bangumi 官方收藏列表接口与本地历史表两套真相源都没有接进卡片。
- **[x] ① 已修复** — 本提交。账号行改为可点击入口，直接分页读取当前 Bangumi 账号所有 `subject_type=2&type=2` 的“看过”动画（`media_tracking_service.dart:433`），不再从映射反推。仓储新增本地旧历史反查（`media_tracking_repository.dart:232`）：已完成视频/有阅读位置的书/已设置游玩状态的游戏减去现有映射，视频 playlist 折叠成合集后输出“需要手动关联”清单；首页显示前 5 项，设置页显示全量并可直接带目标进入添加映射。用户指定的旧泛化文案及 17 语言 key 已移除。
- **[x] ② 已加自动化测试** — `hibiki/test/media/tracking/bangumi_api_client_test.dart`（官方收藏分页与筛选参数）、`media_tracking_repository_test.dart`（旧完成视频进入待关联、映射后消失）、`media_tracking_service_test.dart`（远端历史不依赖本地映射）、`home_dashboard_page_test.dart`（旧历史条目与明确手动关联提示）。
- **备注**：`flutter analyze --no-pub` 通过。定向 Flutter 测试在执行 0 个用例前被 `pdfium_dart` 原生资产从 GitHub 下载超时阻断，按用户要求不等待完整编译验收；不是断言失败。
