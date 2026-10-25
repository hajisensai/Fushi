# Fushi SRS 同步 v2 实现计划

> 设计：[2026-10-25-srs-sync-v2-design.md](2026-10-25-srs-sync-v2-design.md)（下称「设计」，§ 号指它）。
> 分支：`claude/srs-sync-redesign-1882cf` 上做总集成；每个阶段一条 PR 合进该分支，全部完成、审查确认后再合 `develop`（大型、长周期，按 CLAUDE.md 保留独立分支）。
> 规则：Rust 胖核心 + 粗 FFI；搬了就删，不留回退；推送前跑全量 `flutter analyze`；新页面带动效、走设计系统组件；i18n 一律 `i18n_sync`。

## 0. 现状与边界（只为划定替换范围，不沿用其同步设计）

- SRS 已在 `develop` 上（`packages/fushi_srs`、`native/fushi_fsrs`、srs.db），已有用户数据和旧同步文件，所以 v2 必须带**一次性迁移**（用户已拍板：首次 v2 同步弹窗确认）。
- 现有主键全是 UUID 文本（v7 / v5）。迁移只做「文本 → 16 字节」的无损转换，**存量 ID 一个不换**（包括按牌组名派生出的旧 ID，迁移后它们只是普通的不透明 ID）；新规则（设计 §3.1）只管今后新建的实体。
- 要被 v2 整体替换并删除的旧同步层（P7 删）：`packages/fushi_srs/lib/src/sync/`（`sync_engine.dart` / `sync_files.dart` / `memory_replica.dart`）、`fushi/lib/src/srs/srs_sync_scheduler.dart`、`fushi/lib/src/pages/implementations/srs/srs_sync_settings.dart`、srs.db 的 `srs_sent_batches` / `srs_event_local` 及相关读写。
- **不在本计划内**：备份（设计里的备份节已删，待重新设计；现有 `srs_backup.dart` / 备份页本计划不碰）、Anki 互通（AnkiConnect / AnkiDroid）、ASR、调度算法本身。

## 1. 阶段总览

| 阶段 | 内容 | 产出 | 依赖 |
|---|---|---|---|
| P0 | 风险探针：FSRS 跨平台确定性、编解码 / 压缩选型 | 结论 + 固定向量 | — |
| P1 | Rust 基础件：ID、HLC、版本向量、操作编解码、段 | `sync2` 模块 + 性质测试 | P0 |
| P2 | Rust 合并内核：寄存器、OR-Set、墓碑 / 冲突项、别名、复习重放、快照、Merkle | 收敛性质测试全绿 | P1 |
| P3 | srs.db 新 schema + 旧库迁移 + 所有本地写入改为「追加操作」 | 本地单机全功能跑在操作日志上 | P2 |
| P4 | 存储位置传输层（哑存储）+ 同步轮次 + 分叉 / GC | 两台设备经网盘 / 本地文件夹收敛 | P3 |
| P5 | 互联 / fushiServer 快速通道（反熵 + 实时推送） | 在线秒级同步 | P4 |
| P6 | UI：存储位置、冲突中心、重复合并建议、同步状态、迁移弹窗 | 用户可用 | P4（P5 可并行） |
| P7 | 删除旧同步层与旧表、更新守卫与文档 | 无双份实现 | P4–P6 |
| P8 | 故障注入、规模基准、五平台确定性 CI | 验收报告 | 全部 |

P5 与 P6 可并行（不碰同一批文件）；其余按序。

## 2. 各阶段细节

### P0 风险探针（先做，结论决定 P2 的实现方式）

1. **FSRS 确定性**：用 `fsrs` crate（当前钉的 rev）对一组固定复习序列（≥1 万张卡、含各种评分 / 间隔 / 参数）算调度状态，输出逐卡位级哈希；在 Windows x64、Android arm64、iOS arm64、macOS arm64、Linux x64 各跑一次比对。
   - 一致 → 直接用。
   - 不一致 → 调度路径换成纯 Rust `libm` 的确定性 `exp/ln/powf`（只替换重放用到的函数，必要时以补丁形式进 `ci/patches/`），重测到一致为止。
2. **编解码与压缩**：postcard vs 手写 varint 的体积 / 速度；ruzstd 编码器（纯 Rust，五平台免 C 工具链）在 100 万条复习上的压缩率与耗时。不达标时评估 `zstd`（C）交叉编译成本。
3. **密码学依赖**：`blake3`（哈希链 / 内容寻址）、`ed25519-dalek`（签名）、`chacha20poly1305`（XChaCha AEAD）、`argon2`（口令派生）在五平台交叉编译与体积（release 已开 `opt-level = "z"`）。

退出条件：确定性结论 + 固定向量落进 `native/fushi_fsrs/tests/vectors/`；依赖清单定稿。

### P1 Rust 基础件（`native/fushi_fsrs/src/sync2/`）

与现有 store 同一个 crate（状态归同一个 Rust 持有者，避免两个原生库互相传数据）。

| 文件 | 内容 |
|---|---|
| `id.rs` | `Id([u8;16])`：v7 生成、v5 派生（来源身份白名单 API，设计 §3.1 规则 2），文本 ↔ 二进制仅在 FFI 边界 |
| `hlc.rs` | HLC：本地推进、接收合并、wall 上限与「超前 > 24h」告警标记 |
| `vv.rs` | 版本向量、dot、偏序比较、合并、紧凑编码 |
| `op.rs` | 操作信封 `{op_id, hlc, kind, schema_ver, payload}` + 设计 §3.3 全部 kind；未知 kind 保留原字节 |
| `segment.rs` | 段打包 / 解析：zstd → 可选 AEAD → 前段哈希链 → Ed25519 签名；head 编解码；校验失败分型（不完整 / 损坏 / 签名不符） |
| `keys.rs` | 设备密钥对、集合密钥（Argon2id 派生或配对下发） |

测试：编解码往返、未知 kind 透传、哈希链断裂检测、截断 / 篡改检测（proptest）。

**ID 规则落地**（设计 §3.1）：
- `fushi_srs` 的 `SrsIds.deck` / `deckAlternate` 改为新建时随机 v7；`fieldByName` / `templateByName` 只留在导入路径（无来源 id 的旧格式），本地新建字段 / 模板改随机 v7。
- 加守卫测试：本地新建路径不得调用名字派生函数（扫描调用点白名单）。

### P2 Rust 合并内核（`sync2/merge/`、`sync2/replay.rs`、`sync2/snapshot.rs`、`sync2/merkle.rs`）

1. **多值寄存器**（笔记字段）：因果覆盖替换、并发保留多值，「选定」= 新写入覆盖全部并发值。
2. **LWW 寄存器**（牌组名 / 父牌组 / 配置键 / FSRS 参数）：HLC 决胜，被覆盖值留历史。
3. **加胜 OR-Set**（标签）。
4. **墓碑 + 冲突项**（设计 §5.3 表格六种组合）：检测并发破坏性操作 → 生成 `Conflict{kind, entity, ops}`；未决前保守可见；`ResolveConflict` 操作关闭它。
5. **别名**：存活牌组全名相同 → 自动合并（保留 ID 较小者），后续操作按别名重定向；`MergeNotes`（重复笔记合并）同一机制。
6. **复习重放**：每卡事件流（Review − Retract + 调度干预）按 `(时刻, hlc)` 排序；尾部插入前推、中间插入只重放该卡尾部、参数变更全量重放；fuzz 种子 = `hash(card_id, review_op_id)`；每日计数从合并日志推出。
7. **快照**：内容寄存器 + 标签 + 墓碑 + 冲突项 + 别名 + 复习列式表，以覆盖的版本向量命名；加载 = 快照 + 尾段。
8. **Merkle 摘要**：按卡 ID 前缀分桶的派生状态摘要。

测试（本阶段的核心交付）：
- 收敛性质测试：随机 2–6 台设备操作序列，任意顺序 / 重复 / 分批投递，断言最终派生状态与 Merkle 根逐比特一致。
- 重放等价：一次性顺序喂入 ≡ 乱序分批增量重放。
- 冲突六种组合各一组确定用例；别名「改名 + 新建旧名」不误合用例（设计 §3.1 反例）。

### P3 srs.db 新 schema、旧库迁移、本地写入改走操作

1. **schema**（srs.db 版本 +1，ID 列一律 `BLOB(16)`）：
   - `ops`（`device BLOB, seq INT, hlc, kind, payload BLOB`，PK `(device, seq)`）——唯一事实表。
   - 派生缓存：notes / cards / decks / notetypes / presets / tags / review 列式投影 / conflicts / aliases（全部可由 `rebuild_all()` 重建）。
   - 同步元数据：`devices`（DeviceId、公钥、最新 head、ack）、`self`（本机 DeviceId、下一个 seq、分叉检测用的末段哈希）、`locations`（存储位置配置与每位置上传进度）。
2. **旧库迁移**（Rust 内一次性命令，后台 isolate，带进度）：旧事件 / 字段修改 / 复习日志 → v2 操作（ID 文本转 16 字节、不换值）；旧 writerId 不复用，本机生成新 DeviceId；迁移后 `rebuild_all()` 与迁移前的派生状态逐卡比对，不一致则中止并保留旧库。迁移前用旧实现生成固定输入 → 输出向量做回归测试（CLAUDE.md 重写规则）。
3. **本地写入**：先由 scout 盘出现有全部写命令清单（新建 / 编辑 / 复习 / 撤销 / 挂起 / 埋卡 / 重置 / 改笔记类型 / 移动 / 删除 / 导入 / 优化参数…），逐个改成「组装操作 → 一次 FFI `apply_local(ops)`」；Dart 侧不再直接写 srs.db 业务表。
4. **FFI**（粗粒度，设计 §11）：`apply_local(ops_bytes)`、`pending_segments(location)`、`ingest_segments(bytes[])`、`ingest_snapshot(bytes)`、`make_snapshot()`、`sync_status()`、`list_conflicts()` / `resolve_conflict()`、`migrate_v1(progress_cb)`；查询仍走现有的 Rust 直读命令。

退出条件：单机下所有 SRS 功能跑在操作日志上，现有 SRS 测试全部迁移通过；迁移回归向量全绿。

### P4 存储位置传输层与同步轮次（Dart，`packages/fushi_engine/lib/srs/sync2/`，纯 Dart）

1. **`SrsLocationStore` 接口**：`list(prefix)` / `get(path)` / `put(path, bytes)` / `delete(path)`（设计 §11）。实现：
   - 现有云后端：薄封装现有 `SyncAssetStore` / `SyncBackend`（复用已登录账号；兼容现有「防扫盘混淆」包装）。
   - 本地文件夹：桌面直接路径；Android SAF tree URI；iOS security-scoped bookmark（平台通道在 app 侧，经全局装配点注入引擎，守 `fushi_engine` 纯度）。
2. **同步轮次编排**（设计 §6.2）：对每个勾了「同步」的位置并发执行「上传本地段 → 写 head → 读各设备 head → 拉缺段 / 快照 → `ingest_segments`」；位置间互为副本，按 OpId 幂等。
3. **触发**：本地新操作防抖 10 s、回前台、前台 5 min 定时、手动；复习落盘不等网络。
4. **媒体**：内容寻址上传（先于引用段）、按需拉取 + Wi-Fi 预取今日 / 明日队列、多位置镜像。
5. **分叉检测**（设计 §7.3）、**段 / 快照 GC**（§7.1，以全部同步位置可见的 ack 为准）、**休眠设备**（§7.2）。
6. **哑存储容错**：GDrive 最终一致与同名重复文件、写入中断、head 先于段可见。

退出条件：两个模拟设备分别经 本地文件夹 / WebDAV（测试服务）/ 内存假网盘 收敛；故障注入测试全绿。

### P5 互联 / fushiServer 快速通道

- 互联：host 新增 SRS 反熵路由（交换版本向量 → 互发缺失操作段）与实时推送；P2P 隧道下同协议。
- fushiServer：按设备分目录存段 + WebSocket 新段通知；服务端不解析操作内容。
- 与网盘通道并存，按 OpId 幂等。

### P6 UI（MD3 / Apple 两套设计系统，带动效）

| 页面 / 组件 | 要点 |
|---|---|
| 存储位置列表 | 「＋」添加（复用已登录账号 / 新后端 / 本地文件夹）；每卡显示后端、用途标签（同步 / 媒体）、加密开关、已用空间、最近成功时间、落后条数；首个位置默认全勾；取消用途不删文件，「清理此位置」二次确认 |
| 冲突中心 | 六种冲突的列表与详情、通知入口、处理后同步；卡片上的「待确认」标记 |
| 重复笔记合并建议 | 首字段 + 读音判重，确认后发 `MergeNotes` |
| 同步状态 | 每台设备最后可见时间、落后多少、冲突数、Merkle 一致性 |
| 迁移弹窗 | 首次 v2 同步时确认一次，说明「并入、不覆盖」 |
| 同步历史 | 被 LWW 覆盖的低价值标量可查 |

动效：列表 `FushiEntranceScope` + 错峰进场，按压 `FushiPressScale`，时长取 `FushiMotion`；分段选择用 `adaptiveSegmentedButton`；顶栏动作走 `FushiFloatingTopBar` 自适应溢出。新增文案全部 `i18n_sync --add`，`dart run slang` 重新生成。

### P7 删除旧同步层

删除 §0 列出的旧文件与旧表的读写、旧设置项入口；旧网盘目录不自动删（用户在位置管理里手动清理）。更新 `docs/agent/` 相关段落与 CLAUDE.md 仓库地图里的 SRS 同步条目；补守卫：禁止重新引用旧同步符号。

### P8 验证与验收

- 故障注入矩阵（设计 §12.3）、分叉（§12.4）。
- 规模基准（§12.6）：100 万复习 / 5 万卡的迁移耗时、冷启动、全量重放、单轮增量的端到端耗时（含 FFI 与拷贝），写进合入 PR。
- 五平台确定性 CI：P0 的固定向量进 CI 矩阵，任一平台哈希不一致即红。
- 真机多设备联调不设为门槛；未覆盖的路径在 PR 里写明缺口。

## 3. 风险

| 风险 | 影响 | 对策 |
|---|---|---|
| FSRS 浮点跨平台不一致 | 各设备调度不同，Merkle 报警 | P0 先测，必要时换确定性 libm |
| 迁移重度用户库耗时 | 首次升级卡顿 | 后台 isolate + 进度 + 可中断续跑；失败保留旧库 |
| 本地写入改造面大（P3） | 漏改的写路径绕过操作日志 → 不同步 | scout 先出清单；加守卫：业务表只允许 Rust 写 |
| 哑存储各家行为差异 | 某后端读到不一致前缀 | 读者只认「head 引用段都可读」的前缀；故障注入覆盖 |
| iOS / Android 后台限制 | 后台同步不及时 | 只依赖前台 + 回前台触发，后台属尽力而为 |
| Argon2id 在低端机慢 | 开启加密时首次派生慢 | 参数按设备基准自适应并记入 `meta.json`，仅在开加密时触发 |

## 4. 每阶段完成判据（统一）

- 本阶段新增 / 改动的定向测试通过（判绿看退出码 + 实际执行数）。
- 全量 `flutter analyze` 通过后推送；PR CI 结论看完再进下一阶段。
- Rust 改动：`cargo test` + 性质测试；FFI 签名变化同步 Dart 绑定。
- 提交只 stage 本阶段文件。
