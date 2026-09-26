# 在线视频制卡：播放器缓冲副本 + 后台制卡 + 看完再制卡

2026-09-26。用户：「emby 和 aniyomi 这种在线看的视频制卡慢，要做成跟浏览器一样的看完再制卡，本地制卡是秒出的，想个好的交互。」

## 慢在哪（改动前，沿代码路径）

视频页点制卡 → `ImmersionMiningEngine`：句子音频与封面动图是**两个独立 ffmpeg 进程，各自对远端 URL `-ss` 开流、探测、seek、下载**（媒体服务器直出 remux / 转码 HLS；在线源 HLS 经本机中继串行转发）。muxed 流连抽音频也要拉整段视频码率；移动端 AVIF 必败再开一次流；全局串行队列让连点排队。弹窗的制卡按钮 `await` 到卡写进 Anki 才恢复。与此同时，这句话刚播完，**数据就在 mpv 的 demuxer 缓冲里**（桌面后向 64 MiB / 移动 16 MiB），制卡却完全没用它。

## 一：播放器缓冲副本（性能）

libmpv `dump-cache <start> <end> <file>` 把缓冲里的包原样写成 mkv。实测（mpv 0.41 = app 随包 `libmpv-2.dll`；本地 HTTP 服务器分别供 Range 可 seek 的 mkv 与 6 秒分片 HLS；音轨按秒阶跃 300+20n Hz，用频谱反推任意片段的绝对起点；GOP 5 秒）：

| 事实 | 数据 |
|---|---|
| 命令同步完成 | 7～109 ms 返回，文件已完整（0.5 s 后大小不变） |
| mkv 与 HLS 都可用 | 两种形态各 5 组全部成功 |
| 输出时间戳被归零 | 0 点 = 请求起点**之前的视频关键帧**（请求 30.0 → 24.987；请求 31.3 → 30.0） |
| 从缓冲段起点落盘 | 0 点 = `seekable-ranges[i].start`，扣除检测器自身 −18 ms 偏差后误差 ≤ 5 ms（段起点 15.000 / 15.021 / 0.0 三组） |
| 只含当前选中的轨 | 副本里只有一条音轨 |
| 属性读取 | `demuxer-cache-state` 整份读得到（JSON），子路径 `…/seekable-ranges/0/start` 读不到（NULL） |

所以：点击当下读 `demuxer-cache-state`，找到包含这句的缓冲段，**从段起点**落到句尾 + 0.5 s，文件 0 点 = 段起点（`planMpvCacheDump`）。句尾还没下载到时最多等 8 秒（前向缓冲在读）；这段不在缓冲里就放弃。引擎拿到副本后把抽取时刻减去 0 点（`ImmersionMiningRequest.mediaTimeOffsetMs`），两路都本地 seek；卡面 `{clip-timestamp}` 仍写播放器轴原值；副本抽取中止再用远端源试一次；副本用完即删。分离音轨（YouTube）不在播放的流里，不落副本。

## 二：交互（`VideoOnlineMiningMode`，Anki 设置 › 在线视频制卡）

只对网络流生效；本地视频、覆盖已有卡、回看会话恒等待（= 改动前）。

- **后台制卡（默认）**：弹窗立刻回 `queued`，按钮变「已加入 ✓」（popup.js 早有此态，网页播放器队列在用），视频照常播放；右上角角标「正在制卡 N」转圈；落地后 OSD 报结果（成功 / 降级 / 失败原因）。统计与制卡历史用点击时冻结的库与归属写，页面关了也记得上。代价：没有「最新可改」——卡在点击时还不存在。
- **看完再制卡**：同样立刻返回；引擎照常备好媒体，但交给 `stageNote` 暂存：媒体拷进 `<support>/video_mine_queue/<id>/`，行落进 `web_mine_queue`（与网页播放器队列同表同语义，按 `bookUid` 分开），`meta.json` 存卡面文本 / 标签 / 统计与历史归属。角标「待制卡 N」，点开列表可删点错的、「全部写入 Anki」；**离开播放页时自动全部写入**，结果用全局 toast 报（页面在场时一律 OSD，BUG-931 守卫不变）。写入失败（Anki 没开 / 重复）留在列表里，下次写入重试；暂存媒体丢了标失败，不建空壳卡。
- **等待完成**：改动前的行为。

不升 schema：`web_mine_queue` 已有 pending/done/failed、冻结字段 JSON、cue 窗；表里没有的只跟那份媒体同生共死，放在同一目录。

## 没做 / 未验证

- 字幕列表行「＋制卡」：没有「不查词、整句成卡」的现成入口（卡需要词典字段），要先定整句卡的字段形态，另开。
- 未在真 Emby / Aniyomi 上端到端计时；`dump-cache` 只在 Windows 随包 libmpv 上实测，Android / iOS / macOS 的 media_kit libmpv 未验（失败会自动回远端抽取，不会制不出卡）。
- media_kit 默认 `PlayerConfiguration.async = true`，命令走 `mpv_command_async`，落盘不占 UI 线程；但它在 mpv 核心上执行，大缓冲段落盘的几十到一百多毫秒里核心的其它命令会排在后面（对播放流畅度的影响未在真 app 里测）。
