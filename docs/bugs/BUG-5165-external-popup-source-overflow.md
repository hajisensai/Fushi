## BUG-5165 · 应用内外查词长原文无法完整浏览并挤占释义
- **报告**：2026-11-22（用户反馈：Android 系统文本选择菜单传入长原文后，顶部原文占满窗口且无法独立滚动；应用内也应能向下浏览完整原文，不限制原文高度。）
- **真实性**：✅ 真 bug。原 `fushi/lib/src/pages/implementations/popup_dictionary_page.dart:866` 在卡片 Column 中放置非 flex 的 SourceLookupTextPanel；组件内部 `clipboard_lookup_text_panel.dart:308` 使用按内容自然增长的 Wrap，缺少有界 viewport，导致下方 Expanded 释义无剩余空间。
- **[x] ① 根因修复** — 外部窗口在工具栏下的实际剩余空间中约束原文最多占三分之一，短文自然收缩，独立滚动条和滚动容器不共享释义的滚动状态；初始点击字和新匹配字在最近原文 viewport 内显现。应用内 `home_dictionary_page.dart` 的结果卡存在同样的 Column 布局根因，改为完整自然高度的原文 sliver 与剩余空间释义 sliver，由页面向下滚动，结果 Stack 明确撑满释义视口；嵌入式词典同样处理。保留逐字点选与高亮，折叠只改变展示，不截断或清空查询与制卡上下文。
- **[x] ② 自动化测试** — `fushi/test/widgets/source_lookup_scroll_test.dart` 覆盖限高、短文自然高度、滚动不误查词、初始点击字可见、滚动后索引与坐标、外层滚动位置不变；`popup_dictionary_source_line_test.dart` 覆盖长文释义空间、窗口缩小、真实制卡句子保留及嵌入式词典自然滚动；`home_dictionary_source_scan_test.dart` 覆盖应用内长原文自然高度、滚到末字后点选和释义可达；`popup_source_visibility_channel_test.dart` 与 Android 契约守卫覆盖冷启动、同文本热复用、缺参默认展开和剪贴板透传。
- **备注**：尚无连接的 Android 设备或模拟器，未声称实机复测通过。新增调用级 Boolean extra `sourceTextCollapsed`，默认 false；不新增全局偏好或深链参数。
