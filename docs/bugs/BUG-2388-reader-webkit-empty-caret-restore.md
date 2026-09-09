## BUG-2388 · WebKit竖排字符锚矩形为空导致重开回章首
- **报告**：2026-09-09（用户：现在基本都会只回到章首）
- **真实性**：✅ 已在真实 WebKit 26.0 渲染中复现。完整生产引擎、竖排分页、390×844 视口：保存 charOffset=851，重开后=0；对应 collapsed Range 的矩形是 (0,0,0,0)，展开到目标字符却是 (358,3376,25,22)。`fushi/lib/src/reader/reader_pagination_scripts.dart` 的分页 `scrollToCharOffset` 与连续 `scrollToCharOffset` 直接将空矩形当作有效坐标，造成错误滚动后仍正常发送恢复完成。纯文字 uid/字符锚存取未发现归零；无需音频即可复现。
- **[x] ① 已修复** — `d0627011b7`：共享 `characterAnchorRect` 保留有效光标矩形，空矩形时逐个展开目标 Unicode 码点并跳过折叠空白，取有面积的字符矩形；无法取得几何时不使用伪原点。连续竖排按字符右边缘对齐正文右沿，防止目标字被推到视口之外；句尾矩形为空时回退单点对齐。恢复、字号/边距重锚共用同一修复。
- **[x] ② 已加自动化测试** — `reader_character_anchor_rect_test.dart` 执行真实生成 JS，覆盖正常矩形、WebKit 空矩形、代理对、不修改原 range、无可见字符与两模式接线。`cold_restore_probe.mjs` 加载完整压缩生产引擎，真实翻四页→取进度→新页面恢复，支持 Chrome 与 Playwright WebKit。WebKit 修复后分页 851→851、连续 780→780；去掉字符测量的变异版恢复 851→0 并以断言失败退出 1，恢复原脚本后通过。Dart 两组定向检查共 130 项通过。
- **备注**：WebKit Windows 是真实渲染引擎验证，不等同原始 iPhone App E2E；未构建/发布 iOS 包，未使用用户原书。Chrome 竖排恢复通过；探针还暴露已有横排页边界可能回退一页，本 BUG 不将该不同问题宣称已修复。证据在 `.codex-test/cold-restore-webkit-negative.log` 与正向日志。
