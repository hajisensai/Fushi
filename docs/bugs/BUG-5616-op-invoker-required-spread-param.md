## BUG-5616 · AI / ops-call 调 video.subtitle.glossary.set 必定 400（必填的 spread 参数永远判缺失）
- **报告**：2026-11-28（来源：PR #4625 独立审查，核对新旧调用器差异时发现）
- **真实性**：✅ 真 bug。`video.subtitle.glossary.set` 的 `glossary` 参数是 `required` + `spread`（`fushi/lib/src/ops/op_descriptions_video.dart:1116-1123`）。迁移前的进程内调用器 `OpInvoker.buildCall`（develop 上 `packages/fushi_cli/lib/src/ops/op_catalog.dart`）先把 spread 对象的键值铺进 body 顶层（不留 `glossary` 这个键），再用 `body.containsKey('glossary')` 判必填，于是只要按 schema 传参就回 400 `glossary 缺失`；模型改传 `glossary.glossary` 又撞「与参数重名」。AI 助手、`/api/admin/ops/call`、MCP 三条进程内路径都调不通这个操作，只有 `fushi_cli video subtitle glossary set`（HTTP 直连）能用。全目录只有这一个 spread 参数。
- **[x] ① 已修复** — 必填判据改成跟着参数的取值来源走：`OpArgs.parse` 把 body 顶层的未声明键收回 spread 参数，spread 参数「有没有给」看收回来的键值是否为空（`packages/fushi_cli/lib/src/ops/op_spec.dart` 的 `OpArgs.parse` / `_coercedValue`），不再对铺开之后的 body 查原参数名。提交 617c606a8e（PR #4625 引入统一解析时一并改掉），本条补登记与测试。
- **[x] ② 已加自动化测试** — `packages/fushi_cli/test/ops/op_spec_test.dart`「必填的 spread 参数」：经 `OpInvoker` 传对象 → 键值铺进 body 顶层并执行；不传 → 400 `缺失`；对象里的键与别的参数重名 → 400。
- **备注**：这是 PR #4625 相对 develop 的一处对外行为变化（进程内路径从必定失败变成能执行），方向是修复。HTTP 直连路径行为不变。
