# 手机经互联让电脑的 AI 办事：AI 下视频远端会话（2026-09-28）

## 需求

「手机互联电脑 AI，给电脑下指令」：在手机上跟 AI 说「下 xxx」，由**电脑**的 AI 解析、
电脑的资源搜索挑版本、电脑的下载管线下到电脑的库里。手机不需要配置 AI 提供商，也不需要
下载后端。

此前两块都已经在：「AI 下视频」对话（`2026-09-22-ai-video-acquisition.md`）与「下载执行
设备」（`2026-09-21-remote-download-execution.md`）。缺口是两者没接上——AI 下视频永远在
本机跑，而 `2026-09-22` 文档 §5 把「互联 host 远端走 AI 流程」列为不做。

## 决策

**整场对话在电脑上跑，手机只当对话前端。** 不是「手机的 AI 解析 + 电脑下载」：

- AI 配置是设备本地的（不进同步），手机多半没配；电脑配了。
- 资源搜索的索引器、落地源、画质 / 字幕偏好都在电脑上。
- 状态机（`reduceVideoAcquisition`）本来就是无 Flutter 的纯函数 + 端口注入，搬到 host
  上跑零改动；助手发言本来就是 i18n 键 + 参数，过线后手机按**自己的**界面语言渲染。

**入口不加开关**：沿用「下载执行设备」偏好。它指向一台已配对电脑时，AI 下视频整场交给那
台电脑；连不上 / 电脑不支持时如实报，**不**退回本机（与四个下载入口同一口径）。

**不用 `/api/jobs`**：任务是「算完取回产物」的一次性调用；对话会停在问题上等手机点选，
一场可能跨几分钟——是会话，不是任务。

## 协议（`packages/fushi_engine/lib/sync/assistant/`）

```
能力位   /api/capabilities → assistant: {supported, features: ['videoAcquire'], reason?}
POST    /api/assistant/sessions                  {feature, locale} → {id, revision, view}
GET     /api/assistant/sessions/<id>?after=&wait=  长轮询（≤25 秒）  → {id, revision, view}
POST    /api/assistant/sessions/<id>/actions     {type, ...}      → {id, revision, view}
DELETE  /api/assistant/sessions/<id>
```

- `reason` 短码：`no_provider`（电脑没给 AI 下视频指派提供商）/ `not_ready`（下载后端没起
  或没有受管视频来源）/ `disabled`（iOS 合规门或浏览模块被关）。开会话时同样的门不过 →
  409 `{reason}`。老 host 没有 `assistant` 字段 → 手机报「请更新那台设备上的 Fushi」。
- 动作：`text` / `choose{slot, optionId, remember?}` / `confirm` / `cancel` / `restart` /
  `toggleFranchise{index}`。只校验形状（400），「此刻能不能点」交给 reducer，与本机页面同
  一口径。动作返回时事件已归约进快照，效果链（搜作品 / 搜资源 / 找系列）在后台跑，靠长轮询
  推给手机。
- 会话表在引擎里：24 位随机 hex id、闲置 30 分钟回收、并发上限 8（超了先关最久没碰的）、
  server 停机全部关闭。鉴权走既有 middleware。

## 分层

| 层 | 文件 | 职责 |
|---|---|---|
| 引擎 | `sync/assistant/host_assistant.dart` | `HostAssistantProvider` / `HostAssistantSession` 接口 + `HostAssistantSessions` 会话表 |
| 引擎 | `sync/assistant/host_assistant_routes.dart` | shelf 路由 |
| 引擎视图 | `fushi_engine/lib/media/video/acquisition/video_acquisition_view.dart` | `VideoAcquisitionView`（与语言无关、JSON 往返）+ `VideoAcquisitionSession` 接口 + `projectVideoAcquisitionView` |
| 引擎装配 | `fushi_engine/lib/media/video/acquisition/host_video_acquisition_assembly.dart` | 与宿主无关的端口装配（`createHostVideoAcquisitionService`），app 与无头服务端共用 |
| app 装配 | `media/video/acquisition/app_video_acquisition_assembly.dart` | 接本机偏好 / 后端；首页入口与 host 共用；`createVideoAcquisitionAssistantHost(AppModel)` |
| host | `fushi_engine/lib/sync/assistant/video_acquisition_assistant_host.dart` | 能力 / 前置短码 + 把 `VideoAcquisitionService` 包成引擎会话（app 与服务端共用） |
| 服务端 | `fushi_server/lib/src/assistant_host.dart` | 服务端装配：AI 读 yaml `ai:` 段，发现 / 资源 / 管线用服务端自己的（2026-09-30） |
| 手机 | `sync/interconnect_assistant_client.dart` | 探能力、开会话、长轮询、发动作（https 钉扎同下载客户端） |
| 手机 | `media/video/acquisition/remote_video_acquisition_session.dart` | 长轮询循环；断线时在记录里**固定位置**插一条「连接中断」并放开输入 |

对话页只认 `VideoAcquisitionSession`；本机 `VideoAcquisitionService` 直接实现它，所以既有
测试与探针的构造方式不变。远端时标题下写「在 <设备> 上执行」，「去配置下载后端」按钮不渲染
（那是电脑的后端）。「以后默认」勾选框按问题的结构签名判断换题——远端每次更新都是新解码
的对象，按对象身份比会把用户刚改的勾选冲掉。

## 有意不做

- 手机本机没有 AI、也没设「下载执行设备」时，不自动去找一台有 AI 的电脑——「在哪台设备上
  办」只有一个开关，就是「下载执行设备」。
- 远端会话不跨手机重启恢复（手机退出页面即 DELETE；断线遗孤由闲置回收）。
- 其它 AI 功能（galgame 清洗 / 样式生成…）不走这个通道；`features` 列表为此预留。

## 验证

- `fushi_server/test/assistant_host_test.dart`：服务端没配 AI → `no_provider` 且假 AI 端点零请求；
  配了 → 一句话打到服务端配置的假 AI 端点 → 确认 → `video_download_jobs` 真有行。
- `test/sync/app_assistant_host_test.dart`：真 `FushiSyncServer` + `VideoAcquisitionAssistantHost`（真
  状态机、假外部端口）+ 真 `InterconnectAssistantClient` / `RemoteVideoAcquisitionSession`：
  能力位三态、409 短码、一句话 → 电脑端搜索 → 手机收到摘要问句 → 点「就这个」→ 入队发生在
  电脑的端口上、退出页面 host 释放发现服务；电脑停机 → 连接中断提示只插一次；会话表的非法
  动作、长轮询超时 / 立即返回、关闭后 404、闲置回收与并发上限。
- `test/media/video/acquisition/video_acquisition_view_test.dart`：投影 + JSON 往返、未知
  字段宽容、非 JSON 参数兜底。
- `test/pages/ai_video_acquisition_remote_page_test.dart`：执行设备标注、过线的版本标签、
  勾选不被新对象冲掉、断线文案与不渲染「去配置」。
- `test/sync/app_host_downloads_wiring_guard_test.dart`：AppModel → 控制器 → server 的
  接线，以及端口装配只在装配文件里写一次。
- **未真机验证**手机 ↔ Windows 电脑真实配对后的端到端（本机只有一台设备）。
