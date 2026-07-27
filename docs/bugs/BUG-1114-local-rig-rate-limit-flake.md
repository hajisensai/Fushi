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

### 产品侧定案：这是有意行为，不是缺陷（2026-07-28）

上一段那个「产品侧问题」已由用户拍板结案。给出的三个选项是
①保持现状 + 文档说明 / ②给个默认关的开关 / ③改成默认受限，**用户选 ①**，
理由：**局域网满速通常是用户想要的 —— 家里两台机器互传不该被限速。**

因此「设置 → 下载」里的上传/下载限速**只约束广域网 peer，不约束局域网 peer**，
这是 libtorrent local peer class 的既定行为，Hibiki **有意保持**：

- **不给 C ABI 加** local peer class 限速能力（`ht_apply_limits` 继续只设 session
  全局限速）；
- **不加任何开关**；
- **不改限速的实际行为**。

已落地的唯一改动是把它讲给用户听：`hibiki/lib/src/pages/implementations/torrent_settings_section.dart`
的下载/上传限速输入框各挂了一条常驻 `helperText`（i18n key
`download_rate_limit_lan_exempt`，17 语言齐），文案「不作用于局域网；局域网内的
传输始终全速进行。」

> 结论要点：**以后再有人把「限速对局域网不生效」当 bug 报上来，先回到这一节** ——
> 它是有意行为 + 已决策，不要重新立项去加开关或改默认。

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

- **[ ] ① 未修复，且 2026-07-28 起明确「保持现状不修」** — 原计划的修法（给
  C ABI 加 local peer class 限速开关）已被上面的产品决策否掉：既然限速对局域网
  不生效是**有意行为**，就不会为了这条测试去加那个 native 能力。这条 `ip_filter`
  用例的 flaky 因此维持原样。
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
- **备注**：产品侧「全局限速不约束局域网 peer」**已结案为有意行为**（见上面的
  「产品侧定案」一节），不再需要单独立项加开关。
