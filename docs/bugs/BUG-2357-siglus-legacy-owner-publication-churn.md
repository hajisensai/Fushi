## BUG-2357 · 旧版Siglus重复发布正文对象导致查词弹窗闪退
- **报告**：2026-09-08（用户：点完后查词框好像会立马消失）
- **真实性**：✅ 真 bug。`native/galgame_hook/hook/adapters/siglus_lookup_legacy.inc:66` 每轮重新发布已验证且完全相同的正文对象快照；字形回调持有共享 SRW 锁时，独占锁失败返回 false。`siglus_lookup.inc:1301` 将其当作正文失效，撤销 provider，消费端随即关闭弹窗。
- **[x] ① 已修复** — 本文件同提交：`siglus_legacy_owner.h:136` 的生产 `PublishSnapshot` 在 fresh live snapshot 完全一致时免去重复写入；快照改变或无效仍需独占锁，发布失败仍拒绝查词。单 worker 写入、回调只读的所有权不变，没有延时、重试或放宽活体验证。
- **[x] ② 已加自动化测试** — `473a766403` 的 `native/galgame_hook/tests/siglus_legacy_owner_publication_test.cpp` 直接测试生产函数，使用真实 SRW 共享锁制造争用，覆盖相同、改变、无效快照，以及全部身份字段和容量变化。删除免写分支的负对照退出 1。CMake 注册在本文件同提交。
- **备注**：旧 Rewrite PID 51284 在稳定正文上复现两次：03:25:33.485 showAt 后约 112 ms dismiss；03:25:49.672 needsCalibration 后 2 ms dismiss。独立只读检查中 owner/view 各 1000 次均有效且不变，但 provider 持续撤销和恢复。

2026-09-08 新 Rewrite PID 48540 从原始 Start.exe 经转区启动，实际加载修正 DLL SHA-256 `C38766F11E53DABB35D53A2489112108F5307B3D97A1A98B5017A7C2B0CFAFFB`。Fushi 本体在游戏出现前另有 BUG-2231 崩溃，恢复 Fushi 后经正常附着和线程选择验证，不能将此会话写成无中断启动全程通过。

原生正文点击得到稳定词典弹窗；同句第二个词也能查询且正文未推进。独立 1000 次只读采样共 15.312 秒，owner/view 全部有效，provider 始终 2/3 status 2、变化 0 次，已发布 hit 保留。Save、Log、Close 均撤销正文 provider，Save 返回后的第三次正文点击恢复弹窗，generation 从 239/20 更新为 239/21。游戏图片、正文和探针载荷不入库。

Windows native 完整构建通过，CTest x86 96/96、x64 92/92，结构守卫 49/49；manifest/profile 检查及生产 workflow replay 退出 0。此记录证明旧版正文发布和查词弹窗回归，未升级引擎支持状态；逐句原音、配对及真卡尚未验收。
