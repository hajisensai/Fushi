## BUG-5531 · AI 库管家默认开、书架每次重载就跑一趟，额度用完还逐个单元问 AI、下一趟再问一遍
- **报告**：2026-11-26（用户：「别默认开这个 ai 管家并且修好这个 ai 管家」「不要一直跑，不要自动开，要问了用户才开」「并且改为默认手动触发」；安装版错误日志里每趟 `libraryCurate.scrapeBooks.ai` 报 `AiChatFailure: quota_exhausted` 7 次，阅读时每 2～3 分钟一趟）
- **真实性**：✅ 真 bug，四个根因：
  1. **默认开**：`library_curate_auto` / `library_agent_review_auto` 默认 true（`fushi/lib/src/models/preferences_repository.dart`）。
  2. **没有新内容也跑**：书架 `_loadShelfMaps`（`reader_fushi_history_page.dart`）每次重载都 `scheduleAutomaticLibraryOrganize` → `scheduleAutomaticLibraryCurate`，书架连阅读进度、合集变化都会重载；30 秒去抖后整条流水线照跑（全库审计、待确认列表、⑤ 全库补填关系、TMDB 补成员表）。
  3. **致命失败不停**：`_scrapeBooks` / `_scrape` / `_scrapeGames` / `_videoStructure`（`packages/fushi_engine/lib/media/library_curate/library_curator.dart`）的 AI 调用 catch 后只 `incomplete = true; continue;`，额度用完 / 鉴权失败也逐个单元继续问。
  4. **失败单元每趟重问**：失败单元不进 `seen`、阶段 partial 不推进水位，下一趟原样捞回再问。
- **[x] ① 已修复** —
  - 两个开关默认关（设置项 defaultValue 同步），用户自己打开后才自动跑；重新打开库管家开关时解除 AI 停用与退避（`LibraryCurateState.resume`）。
  - `AiChatFailure.stopsBatch` / `aiFailureStopsBatch`（`packages/fushi_engine/lib/ai/ai_chat_client.dart`）定义配置类致命失败（额度、鉴权、未配置、端点 / 协议 / 互联主机配置）。编排器碰到它本趟立刻停掉后续全部 AI 调用（各阶段只跑规则部分），`LibraryCurateRun.aiStopped` 带失败短码，手动结果对话框如实说明；持久化成 `LibraryCurateState.aiBlocked`，之后的自动路径整趟不发 AI，手动跑一趟才重试。整理（`library.organize.run` 的 `error`）、关系推断 / 音乐（新增 `aiError`）里的 AI 失败同样判。
  - 失败单元进退避 `LibraryCurateState.deferred`（6 小时起、翻倍、封顶 7 天）：自动路径退避期内不碰，到期后随下一趟重试（水位越过它也能从全库捞回），手动照样重试；停在 AI 上的单元不当「认不出」留进待确认。
  - `LibraryCurator.runAuto`：比库变化戳（`LibraryCurateFacts.changeStamp`：各库行数 + 最近入库 / 更新时刻，加 AI 指派），没变且上一趟没碰到单趟上限就什么都不做。触发点不收窄：库页重载覆盖了全部入库入口（含同步拉取），收窄要在每条导入路径各挂一次、容易漏；变化判断放在编排器里，服务端 / CLI 也受益。
  - ⑤ 系列关系补填在自动路径上只在 `video_metadata_works` 自上一趟以来变过（或这一趟有改动）时跑。
- **[x] ② 已加自动化测试** — `packages/fushi_engine/test/media/library_curate/library_curator_test.dart`：配置类失败停掉后续 AI / 结论带原因 / 自动路径不再问 / 手动重试；非致命失败退避、手动照样重试；退避到期从水位之外捞回重试；没有新内容不跑、不记运行；碰到单趟上限接着跑；⑤ 补填门；关系推断 `aiError` 停 AI；退避与状态往返。`fushi/test/ops/ctl_library_curate_routes_test.dart`：两开关默认关、开了才接管触发点。
- **合并时补修（2026-11-27，PR #4516 审查）**：① 库变化戳漏了 `srt_books`（自动整理的书域读它的 `local_added_at`），只新入库字幕书 / 有声书时门不开，已补列；② 阶段失败（`internal_error`）不推进水位，但戳不变时门不开，这一阶段永远不会被自动重跑；退避到期的失败单元同样要等库有变化。现在失败阶段按同一套退避记成 `stage:<wire>`，`runAuto` 的门多一个条件：有退避在「上一趟自动跑开始之后、此刻之前」到期就放行。只看这个窗口，陈旧退避不会让门常开；③ 设置开关直接读、改、写 `library_curate_state`，会被正在跑的那一趟整份写回盖掉。改成调 `LibraryCurator.resumeAuto()`，有一趟在跑时由它收尾合并。测试在 `library_curator_test.dart`「自动路径「没有新内容」不跑」组。AI 停用后的自动恢复与界面提示登记为 BUG-5538，v182 合并侧孤儿登记为 BUG-5539。
- **备注**：spec `docs/specs/2026-11-18-ai-library-curator-design.md` §9、`docs/specs/2026-11-22-ai-library-agent-design.md` §7 同步改成默认关。
