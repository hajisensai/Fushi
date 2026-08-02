## BUG-1437 · renumber 自校验与替换共用同一扫描器，漏改文件被谎报零残留
- **报告**：2026-08-02（用户：）
- **真实性**：✅ 真 bug。两个根因，第二个才是要害。
  **根因①（口径太窄）**：`tool/bug.dart:946-950`（改造前的 `looksTextual`）用**白名单**判文本
  ——「有点号 **且** 扩展名在 `textExtensions` 里」。实测：
  ```
  looksTextual(.gitattributes) = false
  looksTextual(third_party/m_extension_server/UPSTREAM) = false
  looksTextual(LICENSE) = false
  looksTextual(Makefile) = false
  ```
  文本文件的扩展名是开放集合，枚举不完；而没扩展名的纯文本（`UPSTREAM` / `LICENSE` /
  `Makefile`）和前导点文件（`.gitattributes`）在本仓真实存在并真的承载 BUG 引用。
  **根因②（守卫与被守对象同盲）**：`repoScanPaths()`（`:994`，过滤在 `:1014`）套这个判据，
  而**替换**（`buildRenumberPlan:1216-1217`）与**自校验**（`findResidualRefs:1188-1189`）
  **吃的是同一个 `repoScanPaths()`**——守卫和被守对象共用同一副瞎眼镜，扫描器漏掉的文件在
  自校验里同样看不见，于是「零残留」是假的。实测一次改号 9 处引用只落了 7 处，漏掉
  `.gitattributes` 与 `third_party/m_extension_server/UPSTREAM`，工具仍打印「自校验零残留」。
  这比取号撞号危险：撞号人能发现，自校验骗人则没人会去复查。
  **现场 A/B（真 git fixture，`renumber 9246 → 9250`）**：
  ```
  改前：[out] renumber 完成：…（2 处引用 / 1 个文件改名，自校验零残留）   ← 退出码 0
        UPSTREAM       => 🔴 仍是 BUG-9246
        .gitattributes => 🔴 仍是 BUG-9246
        notes.bin      => 🔴 仍是 BUG-9246
  改后：工具结论：报错 -> 改号后仍有 BUG-9246 残留，请人工处理：docs/notes.bin:1
        UPSTREAM       => ✅ 已改   .gitattributes => ✅ 已改
  ```
  次要盲区一处：两侧读文件都用 `readAsStringSync()`，非 UTF-8 文本（GBK 等）抛
  `FormatException` 后直接 `continue`——里面的 ASCII `BUG-NNN` 同样看不见。
- **[x] ① 已修复** — `tool/bug.dart`：
  ① `looksTextual` 判据由白名单改成**黑名单 + NUL 嗅探**（`binaryExtensions` 只是省一次
  开文件的快路径，真正判据是读头 8KB 看有没有 NUL，`fileLooksBinary` / `bytesLookBinary`；
  `excludedScanPrefixes` 挡住 `build/`、`.dart_tool/` 等生成物目录；前导点不再当扩展名分隔符）。
  ② **自校验走独立遍历**：新增 `residualScanPaths()`，自己跑 `git ls-files`（tracked +
  untracked）、**一个扩展名判据都不用**，二进制在 `findResidualRefs` 里按字节现场判；
  撞号态下的自校验范围也从 `effectivePaths`（＝ `repoScanPaths ∩ scope`，会继承扫描器盲区）
  改成直接取 `git diff` 出来的 `scope.paths`。这样 `looksTextual` 再退化一次，自校验仍看得见残留。
  ③ 残留扫描改用 `utf8.decode(..., allowMalformed: true)`，GBK 等非 UTF-8 文本里的 ASCII
  引用也算残留。
- **[x] ② 已加自动化测试** — `hibiki/test/tools/bug_tool_renumber_scope_test.dart`
  新增 group「BUG-1437：扫描口径 + 自校验独立遍历」共 6 个用例：无扩展名/前导点文件的引用
  必须被真正改到；**替换扫描器漏掉一类文件时自校验必须报红、不许打印「零残留」**；非撞号态
  全量口径同样看得见；`findResidualRefs` 的枚举不复用 `repoScanPaths`（直接盯独立性）；
  真二进制既不被改也不被误报；非 UTF-8 文本里的 ASCII 引用算残留。
  **反向变异实测**：把撞号态自校验范围改回 `effectivePaths` → 用例 2 转红；把
  `findResidualRefs` 默认改回 `repoScanPaths()` → 用例 3、4 转红（均为断言失败，非编译失败）。
- **备注**：性能实测（本仓 11880 个 tracked 文件 / 394MB）：`repoScanPaths` 8370→9706 个文件、
  1477ms→3077ms；全量 `findResidualRefs` 3461ms→1922ms；真仓库 `renumber --dry-run`
  端到端 8.3s→7.9s（噪声内，耗时由 1857 个 ref 的跨分支扫描主导，不由文件扫描主导）。
  没碰 `new` / `check` 的取号逻辑（PR#730 刚改完那块），也没碰 `reindex`。
