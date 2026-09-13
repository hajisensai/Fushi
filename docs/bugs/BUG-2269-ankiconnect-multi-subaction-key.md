## BUG-2269 · AnkiConnect multi 子 action 缺 key：配置 apiKey 时所有批量写被整批拒绝
- **报告**：2026-09-08（agent 在本机 Anki 上跑「卡组新卡按词频重排」真实探针时发现；用户未报）
- **真实性**：✅ 真 bug。根因 `packages/fushi_anki/lib/src/ankiconnect/ankiconnect_service.dart:331`（修前）——
  `requestMulti` 只在**外层** `multi` 请求上带 `key`，打包进 `params.actions` 的每条子 action 只有
  `action / version / params`。而 AnkiConnect 插件的 `multi` 就是 `list(map(self.handler, actions))`
  （`__init__.py:515`），`handler` 对**每条请求**独立比对 `request.get('key') != apiKey`
  （`__init__.py:112-116`）。于是配置了 apiKey 的 Anki 上，外层通过、每条子 action 各自被判
  `valid api key must be provided`——`multi` 本身返回 200 + `error: null`，失败全落在逐条结果里。
  受影响的是**所有走 `_requestMultiChunked` 的批量路径**：媒体去重的批量改写 / 删除
  （`updateNoteFieldsMany` / `deleteMediaFilesMany` 等）、`findNotesByQueries`、以及新加的
  `setCardsDueMany`。本机实测（apiKey 已配置）：重排写回 3 张全部返回该错误，`written=0`；
  补 key 后 `written=3`、位置 1/2/3 与计划一致、撤销恢复 3 张。
- **[x] ① 已修复** — `requestMulti` 给每条子 action 加 `if (apiKey.isNotEmpty) 'key': apiKey`
  （与外层 `_request` 同一条件，未配置 key 时不多发字段）。提交见本 PR。
- **[x] ② 已加自动化测试** — `packages/fushi_anki/test/ankiconnect_deck_reposition_test.dart`
  「配置了 apiKey 时 multi 的每条子 action 都带 key」：用 MockClient 抓请求体，断言外层与每条
  子 action 的 `key` 都等于配置值。
- **备注**：同一探针还纠正了 `setSpecificValueOfCard` 的结果解读——插件把失败写在 `result`
  （成功 `[true]`、异常 `[[false, msg]]`、形状错 `false`）而不是 `error`，仓储层改用
  `ankiSetSpecificValueFailure` 判定，`isError` 不再是成功判据（同文件同 PR，测试同上）。
