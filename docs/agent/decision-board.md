# 拍板台（待维护者拍板事项的唯一入口）

所有需要维护者拍板的事项（外部 PR 的取舍、PR 评论 / review 里的方向建议、issue、应用内反馈、审查发现里要人定的、设计取舍），**一律写进拍板台**，不在对话里长篇列清单、不另做清单页面。

- 网页：<https://rank.fushi.moe/dev/decisions>，开发者处理台（`/dev`）顶栏的「拍板」。开发者账户邮箱验证码登录，只有 `role = dev` 的账户能进。
- 代理读写：`services/leaderboard/scripts/decisions.mjs`，两种后端、命令完全一样：
  - **HTTP（没有 Cloudflare 凭据的开发者用这个）**：开发者登录处理台，在顶栏「密钥」（<https://rank.fushi.moe/dev/keys>）给自己签发个人密钥（明文只显示一次，每人最多 5 把，可单把吊销；账户被撤开发者后全部失效），在代理那台机器上设环境变量 `FUSHI_DECISIONS_TOKEN=fdk_…`，脚本就走 HTTPS 调 `/v1/decisions/**`。密钥只能读写拍板台，碰不到反馈和账户数据。HTTP 模式的 `add` 不收迁移字段 `verdict` / `notes`。
  - **wrangler**（没设密钥，或带 `--wrangler` / `--local`）：本机 wrangler 直连线上 D1，与 `feedback.mjs` 同一套 Cloudflare 凭据。
- 命令在 `services/leaderboard/` 下执行，`node scripts/decisions.mjs` 不带参数打印用法。新 worktree 没有 `node_modules`（`setup_worktree.ps1` 不装 npm 依赖），首次使用前先在 `services/leaderboard/` 下跑一次 `npm ci` 装上 wrangler；缺了脚本会直接报「缺 wrangler：先 npm ci」。
- 代码：`services/leaderboard/src/decisions.js`（SQL、校验、页面）、`src/decisions_client.js`（网页的无刷新提交 / 撤销 / 快捷键 / 自动同步），`src/decisions_api.js`（个人密钥与 `/v1/decisions/**` JSON API），迁移 `0020_decisions.sql` / `0024_decision_api_keys.sql`，测试 `test/decisions.test.js` / `test/decisions_api.test.js`。

## 维护者的七个决定

| 决定 | Claude 要做的 |
|---|---|
| 做 / 选某个方案（`do` / `choice:<key>`） | 按建议（或选中的方案）实现，走正常 worktree → PR 流程 |
| 不做（`skip`） | 外部 PR 礼貌关闭、反馈 / issue 回复不做的理由，然后结单 |
| 以后（`later`） | 不动，挂着；不要反复再问 |
| 永远不做（`never`） | 同「不做」处理，**并且**在 [feature-blacklist.md](feature-blacklist.md) 加一行（一句话写清范围；不要写进 `CLAUDE.md`，那里每轮都读），以后同类建议直接不提 |
| 没看懂（`explain`） | 不实现。读维护者在该条下的留言（问的是哪里），先查清现状再用 `note` 写解释。解释写完后这条自动回到「待拍」 |
| 要设计图（`mockup`） | 不实现。维护者想象不出交互 / 界面长什么样。读该条留言（想看哪部分），画自包含的 html 设计图（有几个方案就每个方案一张，文件名带方案名，和 `choices` 对应），`attach <id> …` 附上，再 `note` 一句说明每张图看什么。留言写完后这条自动回到「待拍」 |
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
  "original": "可选：来源原文摘录（PR 正文 / issue / 评论 / 第三方意见原话），≤8000 字",
  "rec": "do | skip | never | later | weigh"
}
```

- `id`：PR 用 `pr<号>`（同一 PR 多个取舍用 `pr3162a` / `pr3162b`），反馈用反馈 id，issue 用 `issue<号>`，其余用 `<kind>-<短 slug>`；只允许字母数字 `_` `-`，最长 40。**同 id 已存在的跳过、不覆盖**，可以放心重复跑。
- `original`：页面在卡片里默认展开显示（可收起），让维护者直接对照原话。反馈类事项不用填，页面按 id / source 联表取用户的标题与正文；PR / issue / 评论类尽量贴原话（外文照贴，不必翻译）。图片：反馈截图自动显示；`original` 里的 `![](url)` / `<img src>` 若是 GitHub 附件（`github.com/user-attachments/assets/…`、`*.githubusercontent.com`）会直接显示在原文下方，所以贴 PR / issue 原文时保留图片标记；其他图床不显示。
- `choices` 只在有两个以上互斥方案时给；给了就没有「做」按钮，改成每个方案一个按钮。
- `ask` 要自洽：说清现状、诉求、建议。维护者点「没看懂」最常见的原因是缺上下文（例如「咱们不是自己有了吗」），写之前先查清现有实现，把「已有什么、差什么」写进去。
- **降低决策负担**：凡是涉及交互 / 界面 / 布局的取舍（新按钮放哪、手势怎么触发、几种布局选哪个），写入时就先画好设计图 `attach` 上去，别让维护者对着文字想象；不确定画不画就画。纯后端 / 策略类的不用画。
- 写之前先查 [feature-blacklist.md](feature-blacklist.md)，命中就不写。

### 附设计图

```bash
node scripts/decisions.mjs attach <id> design-a.html design-b.html spec.md shot.png
node scripts/decisions.mjs detach <id> <序号>   # 序号从 0 数，show 里能看到
```

- 收 html / htm / md / markdown / txt / png / jpg / jpeg / webp / gif / svg，单个 ≤ 10 MB，每条最多 10 个；文件传到 R2，卡片里直接预览：html 默认展开 iframe 预览（sandbox，页面脚本能跑、拿不到处理台会话），图片出缩略图，md / txt 给打开链接（纯文本显示）。
- 要维护者在几个设计里挑一个时，每个方案一个文件 + `choices` 一一对应，标题写进文件名（如 `a-卡片式.html`）。
- 维护者也会在网页上把设计图 / 截图拖进卡片（或粘贴、点「上传附件」），这类附件标「开发者上传」，并自动留一条「上传了附件：…」。巡检看到后用 `node scripts/decisions.mjs files <id> [--out <目录>]` 下到本地再看（默认 `./decision-files/<id>/`）；开发者上传的是可信的维护者输入。
- html 要自包含（CSS / 图片内联，外部脚本只用 CDN）；同目录的相对路径资源不会跟着上传。

## 巡检与执行

维护者说「看拍板台」「按拍板结果做」，或接手相关工作时：

```bash
node scripts/decisions.mjs list               # 默认 = 等解释 + 待执行（代理该动手的）
node scripts/decisions.mjs list --stage todo  # 还没拍的；其余：explain / exec / later / never / closed / all；--raw 出 JSON
node scripts/decisions.mjs show <id>
```

1. **开工先留言**：多个会话可能同时巡检。开始处理某条前 `note <id> --text "开始处理（分支 xxx）"`，看到别人已经留了就跳过。
2. **没看懂**：`note <id> --text "<解释>"`（或 `--file`）。
3. **要设计图**：画 html 设计图 → `attach <id> a-xxx.html b-yyy.html` → `note <id> --text "<每张图看什么>"`；附件要先于留言（留言一写这条就回到待拍）。
4. **结单**：做完（含「不做」已回复）`close <id> --text "<做了什么 / 为什么不做，附 PR 链接或提交哈希>"`；不再需要拍的 `close <id> --dropped --text "<原因>"`。不要删条目，「永远不做」那一栏是长期黑名单的来源。

## 历史

- 2026-11-10 之前用过两个 claude.ai artifact 清单（「Fushi 待拍板清单」`KF2W1fiXwwZKXWA2jZqhzA`、「Fushi 拍板台」`MJokFt6ZkHmtpZpJ129zKv`），都已冻结；未定条目连同维护者留言迁进了这里，留言里能读出决定的已预填。
