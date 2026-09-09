## BUG-2379 · CI 的 Run package tests 循环写死五个包名，新包的测试在 CI 里一次都不会跑

- **报告**：2026-09-09（用户：审 PR #1316 时发现）
- **真实性**：✅ 真 bug。根因 `.github/workflows/release.yml:953` 与 `.github/workflows/main.yml:142`
  （旧版 `for pkg in packages/fushi_core packages/fushi_dictionary packages/fushi_anki packages/fushi_audio packages/fushi_platform`）。

  这个循环是 `packages/*/test` 的**唯一** runner——`fushi/` 那两步 `flutter analyze` / 单测门都不覆盖
  path 依赖包的 test 目录。包名写成字面量，于是任何新加的自有包连同它的全部测试**在 CI 里一次都不会跑**，
  而 job 照常绿（循环跑完五个已知包就退出 0，没有任何东西声明「本该跑几个」）。

  PR #1316 新增的 6 个 `packages/fushi_server/test/*.dart` 就落在这个盲区里：作者写了测试、
  CI 显示全绿，但那 6 个文件从未被执行过。

  注意这是**两处**，不是审查评论里说的一处：`main.yml` 和 `release.yml` 各有一份同样的字面量循环。

- **[x] ① 已修复** — commit `d402a3ca6b`。两处循环都改成 `for pkg in packages/*/` **磁盘枚举**，
  清单方向翻成**排除**制，排除项只有两类且都有明确归属：
  * vendored / fork / stub（`flutter_inappwebview_windows`、`gamepads_windows`、`gamepads_android_stub`）——上游产物，不归本仓测；
  * `fushi_torrent`——其测试要 dlopen 真 DLL，Linux 上整组 skip，由 `build-multiplatform.yml`
    里那个带 `FUSHI_TORRENT_LIB` 的 job 专门跑（该 job 的注释原本就写明「main.yml / release.yml 的
    包测试清单里也没收录这个包」，这次把这个事实写进了排除项的理由里）。

- **[x] ② 已加自动化测试** — 循环内计数 `ran`，跑完断言 `ran >= 3`（实测 4 个：core/anki/audio/platform；
  dictionary 无 `test/` 目录，torrent 走专用 job），低于下界就 `::error` 并 `exit 1`。

  这条哨兵是必须的，理由和 BUG-2378 那两条同源：**「零个包跑过」和「所有包都绿」在退出码上完全一样**。
  枚举写错、`packages/` 布局变动、路径前缀改名，都会让循环一个包都不跑而 job 依然绿。

  **干跑实测**：新循环在当前仓库布局下命中 `fushi_anki` / `fushi_audio` / `fushi_core` / `fushi_platform` 四个包，
  跳过四个（三个 vendored + torrent），`fushi_dictionary` 报「无 test 目录」warning，哨兵通过。

- **备注**：与 BUG-2378 同一根因模式（写死的扫描面 = 静默变瞎的门），一并在同一分支修。
  改 workflow 的爆炸半径不是「按目录挑」而是**所有读该文件的测试**——本次用
  `dart tool/tests_for_changes.dart` 推导出 40 条，全跑绿（282 条用例真执行）。
