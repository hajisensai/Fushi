## BUG-1217 · 随主包发行精简版 Magpie，超分首次使用不再下载
- **报告**：2026-07-28（用户：「Magpie 内置会多大，能不能把功能内置过来」→ 权衡后「那就内置精简版的」。）
- **真实性**：✅ 真需求。超分首次使用要弹「下载约 10 MB」确认框再联网取包，弱网/被墙时直接用不上；而 galgame helper 已经走通了「随主包发行 + 零网络安装」的路子，Magpie 没理由还留着这道坎。
- **体积实测**（决策依据，全部实跑得出）：

  | | 完整包 | 精简包 |
  |---|---|---|
  | zip | 10.79 MB | **4.72 MB** |
  | 解压 | 29.39 MB（164 文件） | **13.35 MB（19 文件）** |

  裁掉的全是 `effects/`：完整包里 158 个 effect 占 16.41 MB，而 Magpie 默认 7 个 scalingMode 一共只引用 8 个 effect（`src/Magpie/AppSettings.cpp:1182-1252`），保留它们 + 全部共享 include（`*.hlsli`）只要 0.37 MB。安装包 63.7 → 68.4 MB，磁盘 335 → 348 MB。
- **为什么不自研超分**（同轮评估，结论记在这里免得反复）：Magpie 是 GPL-3.0，但**功能不受版权保护**，重新实现合法，FSR/Anime4K 着色器本身也是 MIT。真正劝退的是工程量分布——查证 Magpie **一行 hook 都没有**（全仓 0 处 `CreateNamedPipe`/`WM_COPYDATA`/共享内存/socket，纯外部覆盖 + WGC 捕获 + `WS_EX_NOACTIVATE` 缩放窗 + 2ms/50ms 轮询），难点全在 `CursorManager` 那类脏活（自绘光标、黑边阻挡、坐标映射、`adjustCursorSpeed`）而非放大算法。11 MB 不值得换这些。
- **[x] ① 已实现** —
  - 新增 `tools/build_magpie_slim.ps1`：下载 fork release 完整包 → **先校验上游 SHA-256** → 按默认 scalingMode 清单裁剪 → 重打包 → 生成侧车。校验必须早于重打包：裁剪等于重新签名，源包被掉包而不先验，我们的侧车就成了给污染产物背书的东西（守卫测试钉住这个顺序）。
  - `magpie_installer.dart`：新增 `kMagpieBundledDirectoryName = 'magpie_bundle'`（与安装落点 `magpie/` 刻意不同名）、`magpieBundledZipName`（带 `slim`）、`_installBundledMagpie`。随包归档仍做 SHA-256 校验：随包不等于可信，主包本身可能被改。最初暂留的网络兜底已由后续 [BUG-1292](BUG-1292-magpie-bundled-only.md) 删除。
  - 把 `_installCore` 的安装尾段抽成 `_installVerifiedZip`，网络与随包两条来源在此合流。
  - 🔴 **自更新熔断**：随包装完写 `installed.source = bundle`，`_updateSilently` 见到它立刻早退。不做这一步的话，精简包 sha ≠ release 完整包 sha → `magpieNeedsUpdate` 永远判「有新版」→ 每次开 app 都静默下载 10.79 MB 完整包覆盖掉 4.72 MB 的精简包，内置的意义当场归零。反向也堵了：网络装的会**删掉**该标记，否则它会伪装成随包版从此不再更新。
  - 两个 workflow（debug/release）加组包步骤，产物复制到 `magpie_bundle/`；Inno Setup 是 `{#SourceDir}\*` 递归收，无需改 iss。`dist/` 加进 `.gitignore`。
  - **只出 x64**：ARM64 Windows 通过系统 x64 模拟运行随包版，不再为另一个切片联网。
- **[x] ② 已加自动化测试** — `hibiki/test/mining/magpie_bundled_install_test.dart`（16 项全绿）：命名契约（随包目录 ≠ 落点、文件名带 slim、两个标记文件分开）、校验强度四条边界（无归档返回 false / 缺侧车 / 摘要不符 / 侧车非法一律硬失败）、源码守卫（自更新早退必须早于任何标记与网络判据、两条来源的 source 写入与清除、随包归档装完不得删除）、组包脚本契约（校验早于重打包、8 个默认 effect 一个不少、`*.hlsli` 保留）、以及 debug/release 两个 workflow 的随包资产契约。
- **备注**：
  - 组包脚本已在本机实跑通过：保留 19 个文件、裁掉 145 个、产物 4.72 MB + 侧车。
  - 脚本用 UTF-8 **带 BOM** 保存 —— PowerShell 5.1 按 ANSI 读无 BOM 脚本会把中文注释读成乱码，进而冲掉引号配对导致语法错误（本轮实际踩到）。
  - 改 Magpie 版本时必须重新核对 `_SetDefaultScalingModes()`：它多一个默认 mode，裁剪清单就要多留一个 effect，否则用户切过去拿到的是「effect 文件不存在」而不是降级。
  - 未真机验证：需要在 Windows 上装一次带 `magpie_bundle/` 的包，确认零网络装成、超分真的起得来。当前为 `implemented_unverified`。
