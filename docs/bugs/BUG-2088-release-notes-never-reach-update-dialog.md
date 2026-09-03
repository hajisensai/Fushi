## BUG-2088 · 正式版更新公告进不了应用内更新弹窗，用户看到的是一行占位符
- **报告**：2026-09-03（准备 2.2.4 正式版公告时发现，不是用户报告）
- **真实性**：✅ 真 bug（**已发布数据实测**，非静态推理）。`update-manifest` 分支上 `latest-stable.json` 里 v2.1.1 的 `notes` 字段是

  ```
  Manual formal release from bridge/auto-migrate-download @ 4d1c8f4.
  ```

  而同一版在 GitHub Release 页面上的正文有 **3613 字**（`gh release view v2.1.1 --json body`）。应用内更新弹窗读的是前者（`tool/publish_update_manifest.sh` 的 `NOTES` ← workflow 的 `steps.channel.outputs.body`），**所以上一次正式版的用户在弹窗里看到的是这行占位符，不是更新公告**。
- **根因**：`.github/workflows/release.yml` 与 `release-desktop.yml` 的 `Resolve … release channel` 步骤里，`BODY` 只有一行模板：
  - `workflow_dispatch` 的 `formal` / `beta` 分支 → `BODY="Manual formal release from ${GITHUB_REF_NAME} @ ${SHORT_SHA}."`
  - `release` 事件（手动发 GitHub Release）分支 → **从头到尾没有给 `BODY` 赋值**，停在初始化的空串。

  两条通道都不去读作者真正写的公告。弹窗渲染侧没有问题（`MarkdownBody` 正常渲染它拿到的字符串），问题在于喂给它的字符串一直是占位符。
- **[x] ① 已修复** — 约定公告写在 `docs/release-notes/<语义版本>.md`：`formal` / `beta` 通道自动取用；`release` 事件优先用作者当场写的 Release 正文，留空时回落到该文件。`debug` 通道**有意不取**——滚动开发构建挂完整 changelog 会误导。两个 workflow 共 5 个 channel step（release.yml 1 个 + release-desktop.yml 4 个：windows/macos/ios/publish）全部改到。
- **[x] ② 已加自动化测试** — `fushi/test/build/release_workflow_diagnostics_guard_test.dart` 新增守卫：五个 channel step 各自都必须读 `docs/release-notes/${VERSION}.md`，且 `release` 事件分支必须先取 `RELEASE_BODY`。
- **验证方式**：把两个 workflow 的 channel step 的 `run:` 脚本抽出来在本地真跑（`bash`，喂不同的 `GITHUB_EVENT_NAME` / `INPUT_CHANNEL` / `RELEASE_BODY`），断言写进 `$GITHUB_OUTPUT` 的 `body` 段：

  | 事件 | 期望 | 实测 |
  |---|---|---|
  | `workflow_dispatch` formal | 公告全文 | 93 行，首行 `## Fushi 2.2.4` ✅ |
  | `release` + 作者写了正文 | 作者正文 | 作者正文 ✅ |
  | `release` + 正文留空 | 回落公告文件 | 93 行 ✅ |
  | `push`（自动 debug） | 原占位行不变 | 不变 ✅ |
  | `workflow_dispatch` debug | 原占位行不变 | 不变 ✅ |
  | `workflow_dispatch` beta | 公告全文 | 93 行 ✅ |

  `release-desktop.yml` 的 windows step 单独复验 formal / debug 两档，行为一致。
- **备注**：`body<<EOF … EOF` 的多行 output 写法本来就在，所以喂多行公告不需要改 output 机制。本条只改「`BODY` 从哪来」，不碰发布通道、不碰 `PRERELEASE`/`MAKE_LATEST` 判据。
