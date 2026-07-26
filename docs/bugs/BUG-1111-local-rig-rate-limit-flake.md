## BUG-1111 · 内置引擎本地 rig 测试：限速对 loopback peer 不生效导致 peer 观察窗口消失（flaky）

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

### 影响面

- CI **不受影响**：`packages/hibiki_torrent` 的测试要 `HIBIKI_TORRENT_LIB`
  指向已构建的 DLL，CI 没有该 DLL → 整组 skip。纯本地噪声。
- 本地跑 `packages/hibiki_torrent` 测试时会看到这条偶发红，**不要**误判成自己
  改动引入的回归；先按上面的对照实验法验一次。

### 跟进

- **[ ] ① 未修复** — 需先给 C ABI 加 local peer class 限速开关（新 TODO），
  再把测试的观察窗口建立在真实限速上。
- **[ ] ② 未加自动化测试** — 同上，修复落地时随附。
- **备注**：产品侧「全局限速不约束局域网 peer」是否要给用户开关，需单独立项。
