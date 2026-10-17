## BUG-3295 · iOS 查词框没有上 M3E 着色（未复现）
- **报告**：2026-10-11（反馈 #LZDKhmJFpM，iOS 27.2 / iPhone18,3，正文只有「rt」；附一张截图）
- **真实性**：❌ 着色部分未复现。iOS 在 `auto` 设计系统下走 MD3（非 Apple）；书内弹窗主题由 `resolveDictionaryPopupTheme`（`fushi/lib/src/pages/implementations/dictionary_popup_theme.dart`）统一取 app ColorScheme，没有 iOS 分支。截图里弹窗外壳是 scheme surface、顶栏按钮组是 surfaceContainerHigh 胶囊（`dictionaryPopupToolGroupColor`），与同期 Android 截图（#7NmMDZKs2f）的弹窗外观一致，看不出哪一处偏离 M3E 配色。截图同时显示两件别的事：① 迷你播放条与悬浮工具栏压在弹窗下半截——这是 BUG-3292，已修；② 弹窗正文区完全空白（无词条），原因无法从截图 / 日志判断（日志无查词相关记录）。
- **[ ] ① 未修复** — 需要用户说明「M3E 着色」具体指哪块（词条卡片底色？顶栏？与哪个界面对比），以及空白弹窗能否稳定复现。
- **[ ] ② 未加自动化测试** —
- **备注**：未复现记一条。
