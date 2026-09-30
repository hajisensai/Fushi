## BUG-2804 · 发布校验 fushi_p2p 是否进 APK 时 pipefail + grep -q 触发 SIGPIPE 假红
- **报告**：2026-09-30（CI 提速闭环中观测：develop 2f08d46 / 248238cf7 的 Build Release APK `build` job 连续红在「Verify fushi_p2p is packaged in every APK ABI」）
- **真实性**：✅ 真 bug（校验器自身，APK 其实没问题）。根因 `.github/workflows/release.yml:704`（修复前行号）：`if ! printf '%s\n' "$listing" | grep -qx "lib/$abi/libfushi_p2p.so"`。Actions 的 bash 带 `-o pipefail`；`$listing` 是整个 APK 的 `unzip -Z1` 条目（远超 64KB 管道缓冲），`grep -q` 一命中就退出，`printf` 随即 SIGPIPE（日志 `printf: write error: Broken pipe`），整条管道非零，`if !` 把「找到了」读成「没有」。两次失败的构建日志里 Gradle 都对三个 ABI 的 `libfushi_p2p.so` 做了 llvm-strip，说明它确实进了打包；成败只取决于 grep 退出与 printf 写完谁先，所以 c62c7888437（2026-09-28 引入该校验）之后连续 24 次碰巧全绿。
- **[x] ① 已修复** — 改为 here-string `grep -qx … <<< "$listing"`（无管道即无 SIGPIPE）。本地 1.2MB 合成清单、目标条目靠前：旧写法 200/200 误判「缺失」，新写法 0/200；负向对照（不存在的条目）仍判缺失。
- **[x] ② 已加自动化测试** — `fushi/test/build/workflow_pipefail_grep_q_guard_test.dart`：磁盘枚举全部 workflow（带规模哨兵），禁止 `printf … "$var" … | grep -q`；合成语料自校验 3 违规 / 4 合规。变异实测：把 release.yml 改回旧写法，守卫在真实文件上红（`release.yml:708`，exit 1），恢复后绿。
- **备注**：其余 `| grep -q` 写端都是极短输出（`file` / `ldd` / 小段 JSON），写端总能在 grep 退出前写完，守卫刻意只抓「变量经 printf 喂给 grep -q」这一形态。
