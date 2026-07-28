## BUG-1208 · helper 打包脚本用 .NET Core-only 的 GetRelativePath，CI 的 PowerShell 5.1 直接崩
- **报告**：2026-07-28（用户：）
- **真实性**：✅ 真 bug。根因 `native/galgame_hook/tools/build_distribution.ps1:206`（合入前）——
  PR#528 加「递归打包 x64 Unity 提取运行时」时，用
  `[IO.Path]::GetRelativePath($stage, $_.FullName)` 把 staged 文件转成相对路径去比对
  `$expected` 清单。`GetRelativePath` 是 **.NET Core / netstandard2.1+ only** 的 API；
  `.github/workflows/build-multiplatform.yml:788` 与 `release-desktop.yml:344` 用的是
  `powershell -NoProfile -ExecutionPolicy Bypass -File ...`，即 **Windows PowerShell 5.1
  （.NET Framework 4.x）**，该方法根本不存在，运行时抛
  `Method invocation failed because [System.IO.Path] does not contain a method named 'GetRelativePath'`，
  `build_distribution.ps1 -RunTests failed (1)`。
  表现：develop `f81ed0d35` 的 `Build Desktop and Apple Release Artifacts`（run 30349973799）
  job `windows` 红。**C++ 侧全绿**（x64/x86 各 22/22 CTest 通过），挂的纯粹是打包阶段的
  PowerShell —— 单测和 CTest 都覆盖不到这一层。
  下游连带：job `publish` 的 `Publish mirror update manifest (desktop assets)` 报
  `No files matched hibiki-*-windows-setup.exe`，是 windows job 没产出安装包导致的次生失败，
  非独立缺陷。
- **[x] ① 已修复** — 用 5.1 也有的写法替代：新增 `Get-StageRelativePath` 辅助函数，
  以 `GetFullPath` 归一化后做前缀截断（与同文件 `Reset-StageDirectory` 已有写法同形），
  `OrdinalIgnoreCase` 对齐 `GetRelativePath` 在 Windows 上的比较语义，输出仍是 `/` 分隔，
  与 `$expected` 清单一致。比较前给前缀补上目录分隔符是关键：否则 `<root>extra\f` 会被
  误判成在 `<root>` 内。越界文件显式 throw，不再生成 `..\` 路径。
- **[x] ② 已加自动化测试** — `hibiki/test/tools/powershell_51_compat_guard_test.dart`：
  从 workflow 反推「被 `powershell -File`（真 5.1）执行」的脚本集合（`pwsh` 调用的是 PS7，
  不受限，仓库里绝大多数 .ps1 走 pwsh，一刀切会误伤），对这些脚本扫 PS7/.NET Core 专属
  API 黑名单；扫描前剥掉注释和引号内字面量，避免注释提到 API 名、或作为数据传给 bash 的
  `&&`/`||` 误报。含「解析不到任何 powershell -File 调用就判红」的自校验，防守卫扫空变摆设
  （BUG-1157 那类零执行伪装成通过）。变异实测：把 `::GetRelativePath(` 写回代码位，守卫
  转红并指出 `build_distribution.ps1:206`；改回后 2 tests PASSED。
- **备注**：本机 Windows PowerShell 5.1（5.1.26100.7462 / Desktop / CLR 4.0.30319）实测
  `[System.IO.Path]` 无 `GetRelativePath` 方法，并复现了与 CI 字节一致的报错。
  替代实现按 9 组边界用例验证（嵌套/顶层/base 带尾斜杠/正斜杠 base/大小写不一致/三层深/
  base 含 `..`/同级越界/`x64extra` 前缀陷阱），并用真实 x64+x86 清单（19+7 文件）跑通
  stage 列举与 `Compare-Object` 比对，含「删一个文件必须被发现」的反向对照。
  另核实：PR#528 同段新增的 `Join-Path` 内嵌正斜杠 → `Split-Path -Parent` → `Copy-Item`
  链路在 5.1 上实测正常（5.1 的 `Join-Path` 会自行归一化分隔符），非缺陷。
  已知遗留（非本 bug、未改）：5.1 的 `Compress-Archive` 写 zip 条目名用反斜杠
  （`unity_audio_runtime\x.dll`），不合 ZIP 规范（PS7 写正斜杠）。PR#528 之前 zip 里没有
  子目录，所以这条以前不可能显现。当前消费端安全：Dart 侧
  `hibiki/lib/src/mining/galgame_helper_installer.dart:1138` 解压时对 `/` 和 `\` 都做了
  归一化。**未验证**：`.github/workflows/av-selfscan.yml` 用 pwsh 的 `Expand-Archive`
  处理这种反斜杠条目的行为（本轮没跑该 workflow，本机也没有 pwsh 可复现）。
