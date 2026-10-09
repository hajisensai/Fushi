## BUG-2960 · 整套下载资料源不可用时联网补全拿单部剧场版标题搜维基列不出系列
- **报告**：2026-10-06（本机 fushi_server 试「一口气下载全部哆啦A梦剧场版」：服务端没有 TMDB key、Jikan 停摆，系列清单只能靠联网补全，结果 `franchiseUnavailable`；修了第一层后实测清单只有 8 部、名字是《のび太の月面探査記》、且不含用户选的那一部）
- **真实性**：✅ 真 bug，三处连环：
  1. `expandVideoFranchiseFromWeb`（`packages/fushi_engine/lib/ai/ai_video_franchise_assistant.dart`）的查询词只有 `known?.name ?? 锚点标题` + 原名。用户说「全部哆啦A梦剧场版」时锚点是单部剧场版，探针实测三站都只回那一部的条目；而用户口中的系列名（AI 补的 `workQueries`）根本没传到这一层——`loadFranchise` 端口只收 `VideoDiscoveryItem`。同一探针：`Doraemon` 命中 ANN 条目，正文同时列着《月面探査記》《宇宙小戦争》。
  2. MAL 关联链走不动时 `resolveMalFranchise` 交回一个以锚点标题命名、0 部作品的系列；联网补全把这个「系列名」当最可信的查询词排第一，又回到了用锚点标题搜。
  3. 同一情形下锚点不在 `known` 里，联网补全又把锚点当「已知」跳过——两头都不收，清单里没有用户选的那一部。
- **[x] ① 已修复** — `c950f77fec`：新增 `VideoFranchiseQuery(item, seriesNames)`，reducer 把 `slots.workQueries` 随 `VideoAcquisitionLoadFranchiseEffect` 带下去；`aiFranchiseWebQueries` 按「资料源系列名 > 用户系列名 > 锚点标题 > 原名」排序、归一化去重、最多 3 个，首个交给 AI 当系列名。`bbc0a40806`：与锚点同名的「系列名」不算系列名、排到最后；联网结果恒含锚点，并排在合并首位（清单名取最像系列名的查询词）。
- **[x] ② 已加自动化测试** — `fushi/test/ai/ai_video_franchise_assistant_test.dart`（BUG-2960：按系列名搜并交给 AI、0 部资料源下锚点仍在且按系列名命名；`aiFranchiseWebQueries` 四条：排序 / 锚点同名降级 / 无系列名退回旧行为 / 去重；变异实测：去掉锚点补入即红）；`video_acquisition_franchise_test.dart`「所有剧场版」断言 effect 带 `seriesNames`（变异实测：不传即红）。
- **备注**：TMDB collection 仍是哆啦A梦这类长寿系列最全的来源；服务端没配 `tmdb_api_key` 时清单只能做到联网补全能核对上的那部分，并如实提示「可能不全」。
