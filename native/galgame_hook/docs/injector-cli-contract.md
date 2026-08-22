# injector 命令行契约（Hibiki ↔ hibiki-hook）

Hibiki 与 `hibiki_voice_injector.exe` 之间是**进程边界 + 命令行 + stdout 文本握手**，
没有共享代码。任何一侧改这组 flag 都必须先改本文件，否则两仓会各自漂移。

- Hibiki 侧生产者：`fushi/lib/src/mining/galgame_audio_source.dart` 的
  `buildEngineHookInjectorArguments`（唯一构造点）。
- hibiki-hook 侧消费者：`injector/injector_main.cpp` 的 `main()` 参数循环。

## launch 模式：把参数透传给游戏 exe

| flag | 值 | 语义 |
|---|---|---|
| `--launch <exe>` | 单个路径 | 目标游戏 exe（与 `--pid` 二选一） |
| `--workdir <dir>` | 单个路径 | 游戏工作目录。**省略 = injector 缺省取 exe 所在目录**（历史行为） |
| `--arg <value>` | 单个参数，**可重复** | 追加一个传给游戏的命令行参数；一个 `--arg` = 游戏侧一个 argv |
| `--native-loopback-policy allow\|deny` | 单个枚举；可用于 attach/launch | 是否允许**注入 DLL 内**创建 WASAPI loopback。省略=`deny`；非法/缺值立即非零退出 |

## Native loopback policy v1（隐私边界）

`cleanOnly` / `resourceOnly` 不只要停止 Hibiki 宿主进程里的 loopback，还必须从 T+0 阻止
游戏内 hook DLL 创建 `AUDCLNT_STREAMFLAGS_LOOPBACK`。因此生产调用必须先做无目标能力预检：

```text
fushi_voice_injector.exe --capabilities
```

成功时 stdout **只能**是下列单 token（换行可忽略），退出码为 0：

```text
native_loopback_policy_v1
```

该命令不得打开/创建/注入目标进程。`--capabilities` 与 `--pid` / `--launch` 同时出现为错误。
旧 injector 会忽略不认识的 flag，随后因没有目标而非零退出，故不会误降级成“已支持”。

实际启动/附着时必须显式传：

```text
--native-loopback-policy allow
--native-loopback-policy deny
```

缺省和任何非法值都 fail closed；非法值不是可忽略的未知 flag。injector 在 `InjectDll` 前把
策略写进 v16 `SharedHeader` 并发布首个 `request_seq=1`。DLL 只有看到 exact `allow` 才能创建
loopback worker；`deny` 不创建该线程，也不进入 COM。运行期切换通过同一组四字段：

- `native_loopback_requested`: `0=deny`, `1=allow`；其它值按 deny。
- `native_loopback_request_seq`: producer 的请求代际；最高位只在极短写入临界区使用，稳定值
  非零且最高位为 0。
- `native_loopback_state`: `0=stopped`, `1=starting`, `2=running`, `3=stopping`, `4=failed`。
- `native_loopback_applied_seq`: DLL 最后发布的确认代际。

只有 `requested=0 && request_seq==applied_seq && state=stopped` 才证明动态 deny 已完成
`IAudioClient::Stop`、反序 `Release`、线程退出与 handle reap。`starting/stopping` 都仍是未完成；
allow 的 `failed` 表示已清理且该代启动失败。每个真实 allow/deny 边沿推进 generation，旧 worker
绑定自己的 generation；即使 `allow→deny→allow` 全发生在两个 DLL poll 之间，旧 worker 也必须
先退出/reap，不能直接确认最后一个 allow 或产生双 worker。

injector 一旦发布 allow，后续任何注入、ready、guard 或 resume 失败都必须先发布 deny；若 DLL
可能已进入 loopback 生命周期，还要等到对应 `stopped/applied` 才释放控制映射。对仍处挂起态的
launch，停止无法确认时禁止 degraded resume（结束尚未启动完成的进程），避免失败路径遗留一个
无人持有控制面的系统混音录音 worker。

### 为什么是 `--arg <value>` 重复，而不是 `--` 之后全部尾随

`--` 尾随写法要求 host 把「参数列表」压成一段文本再让 injector 重新切分，
中间必然引入一次**由 injector 决定的**切分规则；host 和游戏对同一段文本的理解就有了
两次翻译机会。`--arg` 每次只搬运一个**已经切好**的 token：Windows 的
`CommandLineToArgvW` 在 injector 启动时已经帮我们切好了 `argv`，token 边界全程零歧义，
参数里含空格、引号、`--`、路径统统不需要特例。

另外 `--` 尾随会和现有 flag 顺序耦合（必须永远排在最后），而 `--arg` 与其它 flag 顺序无关。

### 转义规则（唯一真相源）

两侧共用一套 Windows argv 规则，互为逆变换：

1. **用户输入 → token**（Hibiki 侧，`parseGameLaunchArguments`，
   `fushi/lib/src/mining/galgame_library.dart`）：用户在设置里写的是**一整行命令行**
   （形如 `-windowed --save="D:\My Saves"`），按 `CommandLineToArgvW` 规则拆成 token。
2. **token → 一个 `--arg`**（Hibiki 侧）：token 原样作为进程参数交给 `Process.start`，
   由 Dart/Windows 负责这一跳的转义。
3. **token → 游戏的 `lpCommandLine`**（hook 侧，`BuildLaunchCommandLine`，
   `include/launch_command_line.h`）：`CreateProcessW` 只收**一个字符串**，所以每个
   token 必须按官方 `ArgvQuote` 规则重新转义后再拼接：
   - 含空格 / 制表 / 换行 / 垂直制表 / 引号，或为空串 → 整体加双引号；
   - 引号前的连续反斜杠数量翻倍再补一个反斜杠转义该引号；
   - 右引号前的连续反斜杠数量翻倍（否则会转义掉右引号，吞掉后面所有参数）；
   - 其余位置的反斜杠是普通字符，原样输出。

首 token 永远是 exe 自身（`CreateProcessW` 约定），强制加引号。

回归测试：`tests/launch_command_line_test.cpp` 除了逐字节断言，还真的把组装结果喂给
`CommandLineToArgvW` 反解、逐 token 比对——这才是游戏进程实际看到的东西。

## 版本兼容

**新 Hibiki + 老 injector**（用户尚未更新 helper）：native loopback 策略先用上面的
`--capabilities` 无目标预检；缺少精确 capability 就不得开始会话。不能只把新 flag 发给旧
injector，因为它会静默忽略未知 flag。`--arg` / `--workdir` 自 helper 引入
launch 模式起就已存在，不是本次新增；即便遇到完全不认识的 flag，injector 的参数循环是
一条没有 `else` 分支的 if-else 链，**未知 flag 被静默忽略，不报错、不退出**。
再加上 Hibiki 侧「用户没配置就一个 `--arg` 都不发」，未配置参数的用户命令行与旧版逐字节
相同。

**老 Hibiki + 新 injector**：未发送 native policy 时新 injector 默认 deny，因此不会创建注入侧
系统混音录音；老 Hibiki 从不发 `--arg`，`extra_args` 为空，
`BuildLaunchCommandLine` 的输出与历史实现逐字节相同（`launch_command_line_test.cpp`
里有专门的兼容锁断言）。

**本次 hook 侧的真实改动**是第 3 步的转义：历史实现把 `extra_args` 用空格**裸拼**，
含空格的参数会在游戏侧被拆成多个 argv（`--arg "C:\Program Files\save"` → 游戏收到
`C:\Program` 和 `Files\save` 两个 argv）。这是 bug 修复而非协议变更；只影响真的传了
含空格/引号参数的调用，而在本次之前 Hibiki 从未传过任何 `--arg`。

## Steam 协议启动的已知限制

`steam://run/<appid>` 由 Steam 客户端拉起游戏，host 无法把命令行塞进去。此路径下
injector 会在 stderr 明确告警 `[steam] warning: custom --arg values are not forwarded
by the steam:// launch path`，参数**不会**生效。需要参数的 Steam 游戏应配合
`--force-direct-launch`。
