# injector 命令行契约（Hibiki ↔ hibiki-hook）

Hibiki 与 `hibiki_voice_injector.exe` 之间是**进程边界 + 命令行 + stdout 文本握手**，
没有共享代码。任何一侧改这组 flag 都必须先改本文件，并在同一个 PR 同步生产者/消费者，
否则即使同仓也会发生静默契约漂移。

- Hibiki 侧生产者：`hibiki/lib/src/mining/galgame_audio_source.dart` 的
  `buildEngineHookInjectorArguments`（唯一构造点）。
- hibiki-hook 侧消费者：`injector/injector_main.cpp` 的 `main()` 参数循环。

## launch 模式：把参数透传给游戏 exe

| flag | 值 | 语义 |
|---|---|---|
| `--launch <exe>` | 单个路径 | 目标游戏 exe（与 `--pid` 二选一） |
| `--workdir <dir>` | 单个路径 | 游戏工作目录。**省略 = injector 缺省取 exe 所在目录**（历史行为） |
| `--arg <value>` | 单个参数，**可重复** | 追加一个传给游戏的命令行参数；一个 `--arg` = 游戏侧一个 argv |

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
   `hibiki/lib/src/mining/galgame_library.dart`）：用户在设置里写的是**一整行命令行**
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

**新 Hibiki + 老 injector**（用户尚未更新 helper）：`--arg` / `--workdir` 自 helper 引入
launch 模式起就已存在，不是本次新增；即便遇到完全不认识的 flag，injector 的参数循环是
一条没有 `else` 分支的 if-else 链，**未知 flag 被静默忽略，不报错、不退出**。
再加上 Hibiki 侧「用户没配置就一个 `--arg` 都不发」，未配置参数的用户命令行与旧版逐字节
相同。

**老 Hibiki + 新 injector**：老 Hibiki 从不发 `--arg`，`extra_args` 为空，
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
