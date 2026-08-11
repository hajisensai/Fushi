## BUG-1557 · TOFU 指纹比对顺序倒置 + 编辑地址留旧指纹且无清除入口
- **报告**：2026-08-12（互联配对与安全链路审计）
- **真实性**：✅ 真 bug，两处：
  1. **比对顺序倒置**：`fushi/lib/src/sync/sync_settings_schema/interconnect.part.dart` 的
     `_runPairingV2` 拿**本次握手看到的新指纹**把整套跑完（确认身份 → 输 PIN → pair/v2 把本机设备名 +
     deviceId 送给对方 → host 把 peer 行都落了库），最后才在 `_onPairSuccess` →
     `SyncRepository.addFushiClientUrl` 里撞上 MITM 守卫发现指纹不符。那时中止已经晚了：冒充已知
     host 的对端拿到了我的设备标识。
  2. **编辑地址留旧指纹**：同文件编辑分支无条件 `copyWith(url: ...)`，把旧机器的钉扎指纹原封不动
     钉到新地址上；https 握手次次失败，而 UI 里**没有任何清指纹的入口**（MITM 守卫故意不覆盖已存
     值）——那条 URL 就此永久连不上，用户只能删了重加，且不会知道要这么做。
- **[x] ① 已修复** —
  ① `_runPairingV2` 最先过一道 TOFU 闸 `_ensurePinnedFingerprintTrusted`（`interconnect.part.dart:604`）：
  已存指纹与本次所见不符就**当场中止**（设备标识一字未发出），走 `sync_pair_fingerprint_changed`
  路径；同时给出唯一的「清除已存指纹重新信任」出口（`_confirmFingerprintRetrust` 弹窗并列新旧两个
  指纹供核对，默认动作是取消）。
  ② 编辑保存时用 `isSameInterconnectEndpoint`（`fushi/lib/src/sync/interconnect_url.dart`）判断：
  scheme+host+port 未变才保留指纹，改指另一台机器就清掉该行指纹（`interconnect.part.dart:215`）；
  令牌 / 启用态 / 展示名不动。新增仓储层 API `SyncRepository.getFushiClientFingerprint` /
  `clearFushiClientFingerprint`，指纹归一化比对收敛到钉扎层同一份 `fingerprintEquals`。
  **兼容性**：首连（本地无存指纹）与明文 http 路径行为零变化；MITM 守卫不覆盖已存指纹这条不变量
  一字未动，只是多了一个用户显式授权的清除动作。
- **[x] ② 已加自动化测试** — `fushi/test/sync/interconnect_fingerprint_trust_test.dart`：仓储层行为
  （读/清指纹、只清指纹不动其它字段、清后可重新 TOFU）+ `isSameInterconnectEndpoint` 真值表 +
  配对编排的**顺序**源码守卫（切片前先抓掉注释行，把调用注释掉也骗不过）。已变异实测：注释掉闸 +
  把端点判断换成 `true` → 两条守卫各自变红。
- **备注**：本轮互联配对安全链路六修之三（BUG-1555~1559）。
