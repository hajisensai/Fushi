## BUG-1924 · 下载页展开下拉框时左上角误显返回键
- **报告**：2026-08-28（用户：「点击下拉框会导致左上角多了返回按钮」）
- **真实性**：✅ 真 bug。`fushi/lib/src/pages/implementations/downloads_page.dart`
  的旧页头在 build 期读 `Navigator.of(context).canPop()` 决定是否显示返回键。
  Material 下拉框展开时会向同一 Navigator push 临时 `PopupRoute`，因此即使
  下载页仍是根页，`canPop()` 也会在弹层存在期间变为 true，触发页头重建后
  左上角误显返回键。
- **[x] ① 已修复** — 下载页改为读
  `ModalRoute.of(context)?.isFirst == false`：页内 context 所属的 PageRoute 身份不会被
  栈顶 PopupRoute 改写；顶层 tab 稳定不出箭头，被设置 push 时仍会显示。
  同样的双身份页面 `browser_extension_page.dart` 一并收口到相同判定。
- **[x] ② 已加自动化测试** —
  `fushi/test/pages/downloads_center_contract_guard_test.dart` 钉死下载页只能使用
  `ModalRoute.isFirst` 判定返回键；浏览器扩展页既有守卫同步覆盖同构路径。
- **备注**：按用户要求本轮跳过所有测试，仅做 Windows 增量构建验证。
