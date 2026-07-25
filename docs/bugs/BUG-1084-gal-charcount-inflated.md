## BUG-1084 · galgame 字数统计虚高：标点全算/重复行重计/递增重发重计/外部通道双计
- **报告**：2026-07-25（用户：gal 的字数统计不准，参照 Luna/ReinaManager 的统计方式）
- **真实性**：✅ 真 bug。根因 `hibiki/lib/src/mining/gal_hook_session_controller.dart:1647`（修复前）——`_recordActivityLine` 直接用裸 `text.length`（UTF-16 code unit）累计进 `activity_events.charsDelta`，计数前没有任何口径处理：
  1. 标点/括号/空白/排版符号全算字数（「」。、…♪ 等）；
  2. 无相邻重复行去重——引擎重绘/回想/自动模式重发同句全额重计（`_pollHookedText` 只有 seq 序号去重，防不了同文本换 seq 重发；`texthooker_service.dart appendLine` 只 trim）；
  3. 无打字机递增行处理——Kirikiri 类引擎"あ→ああ→あありがとう"逐次重发按整行反复计；
  4. 外部通道双计——引擎 hook 会话激活时，外部 WS/剪贴板行（`gal_hook_session_controller.dart` `_onTextBufferChanged` 外部分支）也走 `_recordActivityLine`，同游戏并行开 LunaTranslator 时每句从两条通道各计一次；
  5. 无超长垃圾行门——脚本 dump 整块文本一次进账数千"字"；
  6. UTF-16 code unit 口径使增补面汉字（𠮟 等）计 2。
  参照口径（源码核实）：LunaTranslator `count_words_mixed`（textsourcebase.py，2026-04 起）= 文本处理后计数、标点不计、CJK 每字 1、西文每词 1、相邻两道去重、min/max 长度门；exSTATic `charsInLine`（calculations.ts）= 剔日文排版符号后计长、相邻去重。非相邻重复（回想/二周目）两家都照计，不做高水位。ReinaManager 无字数统计（仅前台计时），不构成参照。
- **[x] ① 已修复** — 新增 `hibiki/lib/src/mining/galgame_char_count.dart`：`countGalgameChars`（标点/空白不计 + CJK 按 code point 每字 1 + 西文连续串每串 1）+ `GalgameLineCharCounter`（相邻重复计 0、前缀递增只计增量、清洗后超 500 字视为垃圾 dump 计 0）。`gal_hook_session_controller.dart` `_recordActivityLine` 改走该计数器并加 `fromEngineHook` 单计数源门（引擎已计数则外部 WS/剪贴板行不再计；引擎无文本时外部通道照常计数），会话开始/关闭复位计数器。历史已落库的 `charsDelta` 不重算（Never break userspace）。提交：见本分支 fix commit。
- **[x] ② 已加自动化测试** — `hibiki/test/mining/galgame_char_count_test.dart`（纯口径 + 会话态计数器 15 用例：标点/西文串/增补面/半角片假名/相邻去重/递增增量/长度门/reset）；`hibiki/test/mining/gal_hook_session_controller_test.dart` 新增 2 个集成用例（重复台词+标点+外部通道门 charsDelta=10；引擎无文本时外部唯一计数源 charsDelta=7），原有「5+6=11」用例在新口径下继续成立（纯假名无标点）。
- **备注**：口径变更只影响新会话；WS 纯外部流（无游戏会话绑定）依旧不计入「游戏」活动，行为不变。
