# 拍板台（待维护者拍板事项的唯一入口）

所有需要维护者拍板的事项（外部 PR 的取舍、PR 评论 / review 里的方向建议、issue、应用内反馈、审查发现里要人定的、设计取舍），**一律写进拍板台**，不在对话里长篇列清单、不另做清单页面。

- 网页：<https://rank.fushi.moe/dev/decisions>，开发者处理台（`/dev`）顶栏的「拍板」。开发者账户邮箱验证码登录，只有 `role = dev` 的账户能进。
- 代理读写：`services/leaderboard/scripts/decisions.mjs`（本机 wrangler 直连线上 D1，与 `feedback.mjs` 同一套 Cloudflare 凭据；要走代理先 `export HTTPS_PROXY=http://127.0.0.1:34151`）。命令在 `services/leaderboard/` 下执行，`node scripts/decisions.mjs` 不带参数打印用法。
- 代码：`services/leaderboard/src/decisions.js`（SQL、校验、页面），迁移 `0020_decisions.sql`，测试 `test/decisions.test.js`。

## 维护者的六个决定

| 决定 | Claude 要做的 |
|---|---|
| 做 / 选某个方案（`do` / `choice:<key>`） | 按建议（或选中的方案）实现，走正常 worktree → PR 流程 |
| 不做（`skip`） | 外部 PR 礼貌关闭、反馈 / issue 回复不做的理由，然后结单 |
| 以后（`later`） | 不动，挂着；不要反复再问 |
| 永远不做（`never`） | 同「不做」处理，**并且**在 [feature-blacklist.md](feature-blacklist.md) 加一行（一句话写清范围；不要写进 `CLAUDE.md`，那里每轮都读），以后同类建议直接不提 |
| 没看懂（`explain`） | 不实现。读维护者在该条下的留言（问的是哪里），先查清现状再用 `note` 写解释。解释写完后这条自动回到「待拍」 |
| 你定（`delegate`） | 维护者授权「该怎么做就怎么做」。按根因与仓库规则选最好的方案直接做，结单时写清选了什么、为什么 |

维护者常常只留言不点按钮（「做」「a」「不做，拉黑」）。留言和按钮冲突、或只留言没点按钮时，**以留言为准**：执行前先 `verdict <id> <决定>` 把决定改成与留言一致。

## 写入事项

```bash
node scripts/decisions.mjs add --json items.json
```

`items.json` 是数组，每条：

```json
{
  "id": "pr3162a",
  "kind": "pr | feedback | issue | review | design | other",
  "title": "一句话标题",
  "ask": "要拍的问题本身 + Claude 的建议，维护者只读这一段也能拍",
  "pros": "可选：好处",
  "cons": "可选：代价 / 风险",
  "choices": [{"key": "a", "label": "a 中键跳句"}, {"key": "b", "label": "b 做成开关"}],
  "source": "PR / issue 完整 URL 或反馈 id；多个用 ' · ' 连接",
  "rec": "do | skip | never | later | weigh"
}
```

- `id`：PR 用 `pr<号>`（同一 PR 多个取舍用 `pr3162a` / `pr3162b`），反馈用反馈 id，issue 用 `issue<号>`，其余用 `<kind>-<短 slug>`；只允许字母数字 `_` `-`，最长 40。**同 id 已存在的跳过、不覆盖**，可以放心重复跑。
- `choices` 只在有两个以上互斥方案时给；给了就没有「做」按钮，改成每个方案一个按钮。
- `ask` 要自洽：说清现状、诉求、建议。维护者点「没看懂」最常见的原因是缺上下文（例如「咱们不是自己有了吗」），写之前先查清现有实现，把「已有什么、差什么」写进去。
- 写之前先查 [feature-blacklist.md](feature-blacklist.md) 和 `CLAUDE.md` 功能黑名单，命中就不写。

## 巡检与执行

维护者说「看拍板台」「按拍板结果做」，或接手相关工作时：

```bash
node scripts/decisions.mjs list               # 默认 = 等解释 + 待执行（代理该动手的）
node scripts/decisions.mjs list --stage todo  # 还没拍的；其余：explain / exec / later / never / closed / all；--raw 出 JSON
node scripts/decisions.mjs show <id>
```

1. **开工先留言**：多个会话可能同时巡检。开始处理某条前 `note <id> --text "开始处理（分支 xxx）"`，看到别人已经留了就跳过。
2. **没看懂**：`note <id> --text "<解释>"`（或 `--file`）。
3. **结单**：做完（含「不做」已回复）`close <id> --text "<做了什么 / 为什么不做，附 PR 链接或提交哈希>"`；不再需要拍的 `close <id> --dropped --text "<原因>"`。不要删条目，「永远不做」那一栏是长期黑名单的来源。

## 历史

- 2026-11-10 之前用过两个 claude.ai artifact 清单（「Fushi 待拍板清单」`KF2W1fiXwwZKXWA2jZqhzA`、「Fushi 拍板台」`MJokFt6ZkHmtpZpJ129zKv`），都已冻结；未定条目连同维护者留言迁进了这里，留言里能读出决定的已预填。
