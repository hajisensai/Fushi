## BUG-1984 · 复合控件焦点环读取内部 Focus context 导致边界错位
- **报告**：2026-08-31（用户截图：下载资源页搜索框获得焦点时出现巨大且错位的焦点环）
- **真实性**：✅ 真 bug。`fushi/lib/src/utils/components/fushi_focus_ring.dart:239` 直接读取 `FocusNode.context`；`SearchBar` 等复合控件的该 context 属于 Flutter 内部编辑区域，而 `FushiFocusRegistration` 已在外层登记了完整视觉锚点却未被焦点环消费。回归测试在修复前测得搜索框左边界为 `0`、焦点环左边界为 `38`。
- **[x] ① 已修复** — `FushiFocusController.geometryContextFor` 统一优先返回与主焦点节点精确匹配的已注册视觉锚点；全局焦点环绘制与自动滚动共同消费该边界，未注册控件仍回退原生 context。提交见本 PR。
- **[x] ② 已加自动化测试** — `fushi/test/widgets/fushi_focus_ring_test.dart:518` 使用真实 `FushiSearchField` 验证四边均贴合完整搜索框；定向文件共 10 条用例通过。
- **备注**：首次测试在任何用例执行前被 `pdfium` 原生资产下载超时阻断；使用仓库本地代理重跑后 10 条全部通过。按用户要求未等待全量测试或 Windows 真机视觉验收。
