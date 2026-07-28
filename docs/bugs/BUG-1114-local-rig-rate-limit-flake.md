## BUG-1114 · 内置引擎本地 rig 测试：限速对 loopback peer 不生效导致 peer 观察窗口消失（flaky）

- **报告**：2026-07-26（agent 在 TODO-1961-a 改动中跑既有测试时发现）
- **真实性**：✅ 真 bug（既有缺陷，**不是** TODO-1961-a 引入）

### 现象

`packages/hibiki_torrent/test/embedded_pipeline_test.dart` 的
`ip_filter blocks the seeder, then clearing it lets the download start` 用例
本地约 **1/5 通过**，失败在最后一句：

```
Expected: a value greater than <0>
  Actual: <0>
seeder peer must surface in peer_info with bytes fed to us
```

### 验真过程（对照实验）

用同一份测试分别对 develop 基线 DLL 与 TODO-1961-a 改动后 DLL 各跑 5 次：

| DLL | 通过 |
|---|---|
| 基线（`git checkout -- native/`后重建） | 1/5 |
| TODO-1961-a 改动后 | 1/5 |

flaky 率一致 → 与本轮 native 改动无关，是既有缺陷。

### 根因

`packages/hibiki_torrent/test/embedded_pipeline_test.dart:237` 用
`leecher.setRateLimits(downloadBps: 64 * 1024)` 把 1 MiB 传输拉长到约 16 秒，
好让后面的轮询有窗口观察到「做种者出现在 peer_info 里且喂过字节」
（`embedded_pipeline_test.dart:270-289`）。

但 libtorrent 把**本地网络 peer 归进独立的 local peer class**，该 peer class
默认不受 session 全局速率上限约束 —— 127.0.0.1 上的传输根本没被限速。1 MiB
在 loopback 上几十毫秒就传完，轮询循环的第一次迭代就已经
`progress >= 0.5` 而退出，`maxSeenDownload` 还是 0。断言因此挂在一个纯粹的
调度竞态上。

### 为什么本轮不修

根因修复需要给 C ABI 加「设置 local peer class 速率上限」的能力
（`ht_apply_limits` 目前只设 session 全局限速），属于新 native 能力，与
TODO-1961-a（resume 持久化）无关，硬塞进同一个 PR 会把审查面摊开。

**顺带发现的产品侧问题**（比测试更值得跟进）：既然 local peer class 不受全局
限速约束，那么用户在设置里配的上传/下载限速对**局域网 peer 同样不生效**。
对局域网互传场景这可能是想要的，但它从未被声明过，也没有开关。

### 产品侧定案 v1：这是有意行为，不是缺陷（2026-07-28，**已被 v2 取代**）

> ⚠️ **本节是历史记录，不再是现行决策。** 现行决策见下面的「产品侧定案 v2」。
> 保留它是为了让后来者看懂 `download_rate_limit_lan_exempt` 这条文案的来历。

上一段那个「产品侧问题」由用户拍板结案。给出的三个选项是
①保持现状 + 文档说明 / ②给个默认关的开关 / ③改成默认受限，**当时用户选 ①**，
理由：**局域网满速通常是用户想要的 —— 家里两台机器互传不该被限速。**

当时落地的唯一改动是把它讲给用户听：`torrent_settings_section.dart` 的下载/上传
限速输入框各挂了一条常驻 `helperText`（i18n key `download_rate_limit_lan_exempt`，
17 语言齐），文案「不作用于局域网；局域网内的传输始终全速进行。」

### 产品侧定案 v2：加一个默认关的开关（2026-07-28 晚，**现行**）

用户在同一天改判，从 ① 换成 **②：给一个开关「限速也作用于局域网」，默认关**。
理由：默认行为不变（局域网仍满速，v1 的判断依然成立），但**想限的人能限**。

因此 v1 里「不给 C ABI 加能力 / 不加任何开关」三条**全部作废**。现状：

- **C ABI 加了能力**：新增 `ht_apply_limits_ex(session, download_bps, upload_bps,
  connections_limit, limit_local_peers)`（`native/hibiki_torrent/hibiki_torrent_ffi.cpp`）。
  `limit_local_peers` 非 0 时把同一组上限写进 libtorrent 的 **local peer class**
  （内置 class id 2）——这是 libtorrent 官方文档指定的唯一正规入口（`settings_pack`
  里的 `local_*_rate_limit` / `ignore_limits_on_local_network` 在 2.x 已废弃）。
  旧入口 `ht_apply_limits` **签名与语义完全不变**，等价于 `..._ex(..., 0)`。
- **加了开关**：`QbConnectionConfig.limitLocalPeers`（默认 `false`，老配置缺字段
  也读成 `false`）；UI 在「设置 → 下载」限速输入框下方，
  i18n key `video_setting_torrent_limit_lan(_hint)`。
- **默认行为一字未改**：开关关着时 native 把 local peer class 的上下行上限写回
  0（= 不限），正是 libtorrent 出厂默认，与 v1 时代的实际表现一致。
- **文案随开关走**：`download_rate_limit_lan_exempt`（「不作用于局域网…」）现在
  只在开关**关闭**时显示；打开时显示新 key `download_rate_limit_lan_included`
  （「同时作用于局域网内的传输。」）。v1 那条无条件断言在开关打开后是**假话**，
  必须条件化，界面不能出现与实际行为相反的说明。

> 结论要点：「限速对局域网不生效」**默认仍然成立且是有意的**，但现在**有开关**。
> 再有人报这个，先问他知不知道那个开关，而不是去改默认。

### 影响面

- ~~CI **不受影响**：`packages/hibiki_torrent` 的测试要 `HIBIKI_TORRENT_LIB`
  指向已构建的 DLL，CI 没有该 DLL → 整组 skip。纯本地噪声。~~
  **2026-07-27 更正：这条已过期。** `.github/workflows/build-multiplatform.yml`
  的 windows job 现在先用 vcpkg 编出 DLL，再跑
  `Run hibiki_torrent FFI tests against the freshly built DLL`（该步骤无
  `continue-on-error`）—— 本 flaky 从此**也能把 CI 判红**，优先级要按 CI flaky
  重估，不再是纯本地噪声。（发现于 BUG-1162 的验证：本地连跑 10 次整包套件，
  这条挂了 1 次。）
- 本地跑 `packages/hibiki_torrent` 测试时会看到这条偶发红，**不要**误判成自己
  改动引入的回归；先按上面的对照实验法验一次。

### 跟进

- **[ ] ① 本条 flaky 仍未修复** — 注意：原先「不会去加那个 native 能力」的理由
  已随「产品侧定案 v2」作废，`ht_apply_limits_ex` 现在**已经存在**。但这条
  `ip_filter` 用例本身**没有**改用它，行为维持原样，flaky 照旧。
  （真要修，见下面「正确方向」；那是独立任务，不该塞进加开关的 PR。）
  - 本地实测通过率：基线 DLL 与 TODO-1961-a 改动后 DLL **同为 1/5**（见上面的
    对照实验），说明它是**既有**调度竞态，不是谁新引入的回归。
  - ⚠️ **残留风险，别当成「已无影响」**：上面「影响面」一节的 2026-07-27 更正
    仍然成立 —— `.github/workflows/build-multiplatform.yml` 的 windows job 会先
    用 vcpkg 编出 DLL 再跑 `Run hibiki_torrent FFI tests against the freshly
    built DLL`（无 `continue-on-error`），所以这条 flaky **能把 CI 判红**。
    「不受 CI 影响」的旧说法已过期，别再引用。
  - 真要消掉这条噪声，正确方向是**改测试**（不要依赖限速来撑开观察窗口，改成
    用更大的载荷或直接对 peer_info 做事件式断言），而不是去改产品行为。
- **[ ] ② 未加自动化测试** — 同上，随「改测试」方向一起落地。
- **备注**：产品侧「全局限速默认不约束局域网 peer」仍是**有意行为**，但
  2026-07-28 晚已按「产品侧定案 v2」加了一个**默认关**的开关
  （`QbConnectionConfig.limitLocalPeers` → `ht_apply_limits_ex`）。默认体验未变。
