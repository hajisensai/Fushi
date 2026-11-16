# SRS 协议 4 换代：交接说明（2026-11-15）

> 本文是 W1ght 这边 agent 停手时的现场交接，接手方从这里继续。设计以
> [2026-11-11-srs-generation-break.md](2026-11-11-srs-generation-break.md)（已按定案改过，含 §11.5 D 号索引）为准；
> G7–G11 的实施规划见同目录 [2026-11-15-srs-gen4-g7-g11-plan.md](2026-11-15-srs-gen4-g7-g11-plan.md)
> （原在本机 scratchpad，原样拷入；文中「分规划 JSON」「scratchpad」路径只在原机器上有，结论已汇总进正文）。

## 1. 已定的事（不用再问）

- 2026-11-15 所有者对 G7–G11 规划 §4 的 D1–D34 回复「都按你推荐」，全部定案。要点：
  - **两段式合入**：没有调用方的新模块逐个合进 develop（不改线上行为）；接线、删旧代码、换同步格式在集成分支 `pr/srs-gen4-switch` 上做完，**一次推送**进 develop。断代只许一次。
  - **旧版本硬要求放宽**为「数据内容不变 + 旧版本明确拒绝并提示升级」。实测（`tool/srs_old_binary/` 装置，#3420）已发布的 Windows 版本拒开新库时会改 SQLite 头 24–27 / 92–95 两处计数字段，写成已知例外。
  - 封存原位、不改名；保留副本被删时放墓碑库。封存值 39999，新代文件 `srs4.db`，写 `application_id`。
  - d 项：已删卡的 revlog 保留，只进统计 / 日历，不参与排期（#3434 已实现）。
  - 旧 debug 安装包已存档到 prerelease `srs-old-binaries-2026-11`，装置从那里取包。
- 合并授权：W1ght 的 PR 审查后可直接合；其他作者照 CLAUDE.md 先问所有者。

## 2. 本轮已合进 develop

| PR | 内容 |
|---|---|
| #3284 | 写路径第 2～14 步（链底，收拢 #3289…#3385） |
| #3381 | profile 归属 |
| #3391 / #3392 | 写路径 15（内核修订号）/ 16（原始通道 cargo feature） |
| #3409 | windows appSmoke runner 基线修复 |
| #3411 #3413 #3418 #3420 | G 系列前置、gen4_ids、旧版本实测装置 |
| #3430 | 设计稿定案 + 旧包存档 |
| #3429 #3433 #3435 #3431 | G8-2 中继件、G10-1 远程复习版本协商、G8-1 位置命名、G11-1 导出格式 |
| #3434 | d 项：已删卡 revlog 只进统计（BUG-4657，修了 Fushi→Anki→Fushi 往返重复计数） |
| #3424 #3427 #3436 #3440 #3443 | 界面反馈修复、admin 路由遮蔽（BUG-4627）、浏览页 Enter 抢焦点（BUG-4628）、SRS 页面测试改等写入完成信号 |

## 3. 在途（按顺序接）

| 顺序 | PR / 分支 | 现状 | 下一步 |
|---|---|---|---|
| 1 | **#3395 G5a**（读站点改内核读命令、删 Drift 执行器），头 `25af71be856`，base develop | 与 develop **冲突**，所以主 CI 没跑（GitHub 上 dirty 的 PR 不触发 pull_request CI）。已含修复：#3434 新增代码还在用被删的 Drift 执行器，改为新 Rust 读命令 `native_logs_near`。本地 cargo check、fushi_engine / fushi_server analyze 过；要 DLL 的定向测试未跑 | 合 develop → `dart run tool/bug.dart settle --base upstream/develop` → 推 → CI 只剩基线红就合 |
| 2 | **#3396 G5b**（根上 ID 与同步目录名改向内核要，含 G3 #3374），头 `0fc2e458f5c`，**base 仍是 G5a 分支** | 已合入新的 G5a；已删卡派生按 #3434 口径（`uuidV5(defaultDeckId, 'anki-deleted-card/$cid')`，Rust `rules::deleted_anki_card(&Id, i64)`），`git merge-tree` 试合无冲突；4 处测试从 `SrsIds.builtinDefaultDeck` 改为 `SrsKernelIds(uid).defaultDeck`。Rust gen4_ids / golden / 删卡 revlog / ids 守卫的定向测试**跑到一半被停，无结论** | G5a 合后 `gh pr edit 3396 --base develop`，合 develop，重跑上述定向测试，CI 过就合 |
| 3 | **#3399 G4 / G4b**（真实库只读干跑 + 后台预演自检），头 `86300449212`，base develop | 已含最新 develop；本地 Rust 全量 784 passed / 0 failed / 38 ignored，全量 analyze 无问题；修了本 PR 的 file_picker 守卫真红（去掉 `FileType.custom`）。CI 停手时还在跑 | CI 只剩基线红就合 |
| — | **Flutter 3.50 升级 #3400** | 等 1～3 合完再进 develop，免得中途换工具链出伪红 | 1～3 合完后在 #3400 下评论「SRS 链已合完，可以进」 |
| 4 | **#3452 G7-1**（gen4 本机状态表、换代锁 GenLock、打开模式、封存与墓碑库），未合 | 实现已开 PR，**还没经过独立审查**（工作流停在审查前） | 对抗式审查 → 修 → 合（规划 §2.1） |
| 5 | **#3453 G9-1**（读侧按别名类判定，不接线），未合 | 同上未审查。**需所有者拍板**：样本库量出 144 个寄存器（笔记类型 css 1、字段 18、卡 newPos 125）换代后从「有冲突」变成「没冲突」，根因已隔离为写入者归回（设计 §5.3「三处一起换」的预期结果）。PR 建议接受；备选是 G9-2 把这 144 处列进迁移报告的已知差异 | 拍板 → 审查 → 合；与 #3399 只在 `store/gen4/mod.rs` 冲突一行 |
| 6 | **#3451**（BUG-4694：`tool/native_licenses.dart` 在 Windows 上把 git 符号链接许可文件读成别的文本、还删已入库文件），未合 | 未审查 | 审查 → 合 |
| 7 | 分支 **`pr/srs-ffi-op-meta`**（FFI 命令元数据由 Rust 声明），已推到 upstream，**无 PR** | 叠在旧 G5b 上；最后功能提交 `2b46d84b1e6` 标 wip，作者注明「11-13 未提交工作原样提交，未验证」 | 放到切 3.50 之后做。范围：命令性质（是否改投影、是否通道透明、可否不进独占区、回包是否带 `settled` / `localRevision`、输入项标记）由 `store/ops.rs` 声明并生成 Dart `SrsOp` 绑定；删 Dart 的 `kSrsSync2ProjectingOps` / `_kSync2CacheOps` / `kSrsSync2LockFreeOps` 和对应同文守卫；删 `ffsrs_memory_input`（ABI 7）。先 rebase 到合了 G5b 的 develop 再验证 |
| 末 | **#3344**（集成演练草稿） | 永不合 | 全部做完后关掉 |

## 4. 之后的路线（规划 §2）

1. 第一段剩余（无调用方模块，逐个合）：G7-1 → G7-3a（原生写入器 `Native` + `write_salts` + `ingest_settle`）→ G9-3（绑定 / join / adopt_foreign）与 G8-3（媒体清单 + `media_at`，D18 取 HLC 最大者）并行；G9-1 → G9-2（缓存层接规范 ID、按规范 ID 对拍）；再 G7-2、G8-4/5/6、G11-2、G7-3b、G7-4。依赖与文件热点排队见规划 §2.1、§2.3；凡要改 `store/ffi.rs` / `store/ops.rs` 的，等 op-meta 定了再做。
2. 第二段：`pr/srs-gen4-switch` 上接线、删旧、换格式，合并条件见规划 §6。
3. G12 与真机 / 大库 / 服务端真权重验证；旧版本拒开用 `tool/srs_old_binary/` 实测。

## 5. 还要所有者确认的

- **D21（只有协议 1 旧根的位置）**：规划没给推荐，设计稿按 §9 第 4 项写成继续支持，入口改为只读转译、不写 v3 meta，`srsMigrateV1Media` 移植到新库。
- **D16（加密数据跨钥匙转发）**：设计稿写成转发方解密后用目标位置钥匙重新加密、签名沿用作者的（由「签名覆盖明文哈希」推出），G8 实现时再核。
- 设计稿 §9 第 2、9 项及第 15、16 项里几个子项没有 D 号覆盖，写成「按推荐、已随实现落地」，不算所有者签字。
- #3453 的 144 个寄存器判定差异（见上表）。
- BUG-4500（#3424）的「不查词」范围没包含卡片里的链接 / 图片按钮，是否要扩。

## 6. 坑

- develop 上与 SRS 无关的已知红（停手时）：fushi_server `server_data_lock_test` 偶发超时；`guards` 里 reader 测试 `LateInitializationError`。#3372 带进来的那批 format / 单测红已由 #3442 修掉。
- BUG 号经常撞，合并前一律 `bug.dart settle --base upstream/develop`，别手改。
- 叠放 PR 的下层合掉后上层 base 不会自动变，要手动改 base 再合 develop。
- 本机重活走 heavy 租约；Rust 大批测试放 Mac（sccache）跑更快，本机内存紧时后台任务会被停。
- 旧版本实测装置用法：`docs/agent/srs-old-binary-harness.md`。
