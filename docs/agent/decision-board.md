# 拍板台（待用户拍板事项的唯一入口）

所有需要用户拍板的事项（外部 PR 的取舍、PR 评论 / review 里的方向建议、issue、应用内反馈、审查发现里要用户定的、设计取舍），**一律写进拍板台**，不在对话里长篇列清单、不另开新的清单 artifact。

- 页面：<https://claude.ai/artifact/MJokFt6ZkHmtpZpJ129zKv>（只对用户本人可见）
- 读写方式：主会话用 `ArtifactData` 工具（`url` 填上面的地址）。子代理没有这个工具，由派它的主会话代写。
- 旧的「Fushi 待拍板清单」（`KF2W1fiXwwZKXWA2jZqhzA`）已冻结：2026-11-10 把其中未定的 27 条连同用户留言迁进拍板台，留言里能读出决定的已预填成对应决定。以后不再往旧清单写。

## 用户的六个决定

| verdict | 按钮 | Claude 要做的 |
|---|---|---|
| `do` / `choice`（带 `choice` 键） | 做 / 选某个方案 | 按建议（或选中的方案）实现，走正常 worktree → PR 流程 |
| `skip` | 不做 | 这次不做：外部 PR 礼貌关闭、反馈 / issue 回复不做的理由，然后结单 |
| `later` | 以后 | 不动，挂着；不要反复再问 |
| `never` | 永远不做 | 同 `skip` 处理，**并且**把它加进仓库 `CLAUDE.md`「功能黑名单」（一句话写清范围），以后同类建议直接不提 |
| `explain` | 没看懂 | 不实现。读用户在该条下的留言（问的是哪里），写一条 `from: "claude"` 的解释留言；必要时同时改写 `items` 里的 `ask` / `pros` / `cons`。解释写完后页面自动把这条放回「待拍」 |
| `delegate` | 你定 | 用户授权按 Claude 的判断「该怎么做就怎么做」。按根因与仓库规则选最好的方案直接做，在 `resolution` 里写清选了什么、为什么 |

用户还可能只留言不点按钮（例如「做」「不做，拉黑」「a」）。留言和按钮冲突时以**留言**为准，执行前把 verdict 改成与留言一致。

## 数据结构

三个集合，文档 id 一律用条目 id。

### `items/{id}`（只有 admin 可写，也就是用户本人和代用户写的 Claude）

```json
{
  "kind": "pr | feedback | issue | review | design | other",
  "title": "一句话标题",
  "ask": "要拍的问题本身 + Claude 的建议，用户只读这一段也能拍",
  "pros": "可选：好处",
  "cons": "可选：代价 / 风险",
  "choices": [{"key": "a", "label": "a 中键跳句"}],
  "source": "PR / issue 完整 URL 或反馈 id；多个用 ' · ' 连接",
  "rec": "do | skip | never | later | weigh",
  "order": 1794320000000,
  "state": "open | done | dropped",
  "resolution": "结单时写：做了什么 / 为什么不做，附 PR 链接或提交哈希",
  "createdAt": "ISO 时间"
}
```

- `id`：PR 用 `pr<号>`（同一 PR 多个取舍用 `pr3162a` / `pr3162b`），反馈用反馈 id，issue 用 `issue<号>`，其余用 `<kind>-<短 slug>`。写之前先 `get` 一次，已存在就别重复建。
- `order`：写入时的毫秒时间戳，页面按它倒序（新的在上）。
- `choices` 只在有两个以上互斥方案时给；给了就没有「做」按钮，改成每个方案一个按钮。
- `ask` 要自洽：说清现状、诉求、建议。用户点「没看懂」最常见的原因是缺上下文（例如「咱们不是自己有了吗」）——写之前先查清现有实现，把「已有什么、差什么」写进去。

### `verdicts/{id}`（用户在页面上点）

`{ "verdict": "...", "choice": "a"?, "by": "<user id>", "at": "ISO 时间" }`

Claude 一般只读不写；唯一例外是按上面「留言优先」规则校正。

### `notes/{自动 id}`（双方留言）

`{ "d": "<item id>", "text": "...", "from": "user | claude", "by": "<user id 或空>", "at": "ISO 时间" }`

Claude 写解释时 `from` 必须是 `"claude"`，`at` 用当前时间（页面靠它判断「已解释，回到待拍」）。

## Claude 的固定流程

1. **写入**：遇到需要拍板的事，`ArtifactData` `batch` 写 `items`（`state: "open"`）。写之前先查拍板台里 `verdict == "never"` 的条目和 `CLAUDE.md` 功能黑名单，命中就不写。
2. **巡检**（用户说「看拍板台」「按拍板结果做」时，或接手相关工作时）：`list` 三个集合，按条目归类：
   - 有 verdict 且 `state == "open"`，verdict 是 `do` / `choice` / `skip` / `never` / `delegate` → 执行；
   - verdict 是 `explain` 且没有比它新的 `from: "claude"` 留言 → 写解释；
   - `later` / 无 verdict → 不动。
3. **结单**：执行完 `update` 该条 `items`：`state: "done"`（不做的也是 `done`），写 `resolution`。撤回不再需要拍的条目用 `state: "dropped"` 并写原因。不要删条目，`never` 那一栏是长期黑名单的来源。
4. 多个会话可能同时巡检：开始执行某条前先在该条留一条 `from: "claude"` 的「开始处理（分支 xxx）」留言，看到别人已经留了就跳过。
