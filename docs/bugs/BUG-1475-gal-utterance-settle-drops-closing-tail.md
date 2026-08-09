## BUG-1475 · 切句时收敛裸 return，最后 250ms 已进环的 PCM 从未被读走
- **报告**：2026-08-09（用户：哈吉千歳）
  - 原话：上一句音频没播完就切下一句，会打断上一句已捕获的音频。
- **真实性**：✅ 真 bug，但**不是**用户直觉的那个机制。先把两件事分开：
  - **「播放被停掉」不存在**。`texthooker_page.dart` 里所有 `DesktopAudioPlayback.stop()`
    都是用户手动触发；用户说的「上一句语音没播完」指的是**游戏自己的语音**，
    App 从不控制它。
  - **「捕获缓冲被清掉」也不存在**。hook DLL 往共享环写
    （`native/galgame_hook/hook/dll_main.cpp`），`clip_write_count` 单调递增无处 reset，
    唯一 memset 只在首次创建映射。数据一直在环里。
  - **真正丢的是「没人去读」**：`fushi/lib/src/mining/gal_hook_session_controller.dart`
    的 `_settleLineUtterance` 收敛循环里有**三个裸 `return`**（存活判据
    `_canSettleLine` 不成立时），都不做最后一次 grab。从最后一次成功 grab 到下一句
    到达之间，最多有一个 `_utteranceSettleInterval`（250ms）的 PCM 已经进环、
    却从未被读出来。
  - 这段数据的时间戳**严格早于**下一句的 ts，根本不属于 [[BUG-1109]] 要防的东西
    （那条防的是把**下一句**的段拼进上一句），纯属误伤。BUG-1109 当年刻意把
    「下一句到达」定为收敛终点是对的，代价是这条尾巴——之前没人把这个代价单独记下来。
- **[x] ① 已修复** — 新增 `_closingUtteranceGrab`，三个终止点各调一次。三条纪律：
  - **只在「下一句到达」这一种终止原因下补**。会话/音源换走、用户裁决、补录窗口开着、
    资源升格这几种终止意味着这行的所有权已经不在收敛手上，此时再写缓存就是越权。
  - 前向窗口用**下一句的 ts** 收口：native `VoiceHookReader::GrabUtterance` 新增可选
    `end_ts_ms`，把 `[ts-200, ts+6000]` 的右界收到 `min(6000, end_ts - ts)`
    （`fushi/windows/runner/voice_hook_reader.cpp`）；通道新增 `endTsMs`
    （`flutter_window.cpp`）；Dart `grabUtterance` 新增 `endTsMs` 具名参数，
    缺省 null/0 ⇒ **旧行为逐字等价**。BUG-1109 的不变量由上界保住，而不是由「不抓」保住。
  - 上界取「seq **紧接**本行之后那一行」的 ts（`_nextLineTimestampAfter`），不是「最新一行」——
    一次轮询可能一口气交付好几行，拿最新那行当上界会把中间那些行的语音一起圈进来。
  - 仍然只在**更长**时才写回，缓存单调变长的性质不变；写回前再核一次所有权。
- **[x] ② 已加自动化测试** — `fushi/test/mining/gal_utterance_settle_test.dart`：
  - 桩引擎 `_GrowingEngine` 新增 `boundedBytesByTs`，**真的按 `endTsMs` 返回更少的数据**
    ——不这么做的话「上界真的起作用」测不出来（只按调用序号返回会让带界的封口 grab
    拿到和无界一样多的数据，是假绿）；并记录每次 grab 的上界供断言核对。
  - BUG-1109 的两条既有断言从「不许再抓」改成「只许**带界**再抓一次」，这处修改本身
    就是契约变更的证据点；另加正面断言：封口 grab 必须发生、音频补回 500ms，
    且**不得**长到 1000ms（那个数才是混进下一句的证据）。
  - 已做两轮变异实测：拿掉封口 grab → 「收手时必须补一次封口 grab」红；
    封口 grab 不带上界 → 「必须以下一句的 ts 为前向上界」红。
  - `flutter test test/mining/` 全量 975 tests PASSED。
- **备注**：⚠️ **代码之外的边界（推测，需真机验证）**：若游戏引擎在玩家跳过时**真的停止**
  向混音器提交，剩余 PCM 从未产生，任何改法都拿不回来。本修复只能救回「已提交给
  混音器、App 还没来得及读」的那 ≤250ms。区分两者需真机对比「跳过时刻的
  `clip_write_count`」与「已 grab 字节数」。
