## BUG-1229 · 自定义 CSS 遮罩退出丢失草稿且关闭即保存
- **报告**：2026-07-29（用户反馈）
- **真实性**：✅ 真 bug。`hibiki/lib/src/pages/implementations/dictionary_settings_dialog_page.dart:568`
  的范围切换会调用持久化 setter，旧 footer 的“关闭”也会直接保存；对话框被遮罩关闭时
  state/controller 随路由销毁，没有任何跨实例草稿。
- **[x] ① 已修复** — `hibiki/lib/src/pages/implementations/dictionary_settings_dialog_page.dart:498`
  增加与当前 `AppModel` 绑定的会话草稿，范围切换和非按钮退出只暂存；footer 改为
  “取消 / 保存”，取消清空草稿，保存一次性提交所有已编辑范围并清空草稿。
- **[x] ② 已加自动化测试** —
  `hibiki/test/pages/dictionary_css_editor_dialog_test.dart:178` 覆盖遮罩退出不持久化、
  重开恢复、取消丢弃；`:214` 覆盖切换范围不写入以及保存统一提交。
- **备注**：两个改动文件的定向 `dart analyze` 通过。widget 测试已启动，但在执行
  测试前被 `sqlite3` native asset 从 GitHub Release 下载超时阻塞，未进入测试用例；
  按用户要求不等待完整编译验收。
