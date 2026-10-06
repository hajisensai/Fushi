## BUG-2856 · Artemis 触屏点按：引擎不认触摸提升的单击，游戏内点字查词与推进都不响应
- **报告**：2026-10-02（agent 真机验收发现；用户要求「内嵌查词是游戏内可以点击查词」，CLAUDE.md 第④条要求鼠标与 Windows 触摸都成立）
- **真实性**：✅ 真限制，但根因在引擎输入模型，不是 Fushi 回归。
  - 真机（アマカノ3，Artemis x64，`Amakano3.exe`）`InjectTouchInput`（PT_TOUCH）点按：系统确实把它提升成鼠标——
    `WH_MOUSE_LL` 看到 `LDOWN`→26 ms→`LUP`，`flags=0x1`、`dwExtraInfo=0xff515799`（触摸签名），落点
    `WindowFromPoint` 就是游戏窗口（`Artemis` 类，无覆盖窗）。
  - **不挂 hook 的原版游戏**同样不响应：触摸点按 / 250 ms 长触 / 点空白处都不推进台词（前后截图只差等待光标动画），
    同一位置鼠标点击立即推进。触点只把游戏的悬停光标移过去（底栏按钮会高亮并出提示），按下不生效。
  - 引擎导入 `RegisterTouchWindow` / `GetTouchInputInfo`、按键走 `GetAsyncKeyState`：它把自己注册成触摸窗口，
    触摸提升出的单击不进它的按键状态。Fushi 的 Artemis 查词传感器（`native/galgame_hook/hook/adapters/artemis_lookup.inc`
    `ArtemisInputUpdateDetour` / `ClaimArtemisLeftButton`）读的正是引擎 `Input::Update` 的左键状态，所以触摸点字也拿不到命中
    （hook 日志无 `artemis-lookup: hit`），游戏前台保持不变、台词不推进。
  - 鼠标路径同一会话全部通过：`accept4` text / audio（`matched/game_resource`）/ lookup / no_advance / dismiss_no_advance /
    relookup 均 PASS。
  - **根因更正（2026-10-04 Frida 只读探针，同一游戏）**：引擎**从不调用** `GetTouchInputInfo`；它收到
    `WM_POINTERENTER/DOWN/UPDATE/UP/LEAVE` 并自己调 `GetPointerType` / `GetPointerInfo` / `GetPointerTouchInfo`，随后系统照常投递
    提升出的 `WM_LBUTTONDOWN`（w=1）与 `WM_LBUTTONUP`，背靠背、落点就在字上。`Input::Update` 每帧用 `GetAsyncKeyState`
    采样左键，亚帧的按下/抬起整对落在两次采样之间，采样器（与引擎）都看不到——与 Siglus 的 BUG-2769 同型。
- **[x] ① 已修复** — `native/galgame_hook/hook/adapters/artemis_lookup.inc` 加消息层观察点：传感器装好且模型就绪后，HookWorker
  在游戏窗口的消息线程上挂 `WH_GETMESSAGE` 线程钩子（只认 `PM_REMOVE`，且须与 `Input::Update` 采样线程同一线程，消息原样放行、
  只观察不吞）。`WM_LBUTTONDOWN/DBLCLK` 命中当前模型唯一字形时武装 `TapLatch`（记下模型代 / 字形 / 采样计数）；`WM_LBUTTONUP`
  时若采样器在其间一次都没见过按键非空闲（`sampled_presses` 未变）、并且抬起点用同一套准入门（`ArtemisPointEligible`：
  NativeInputAllowed / 护盾 / 前台 / 修饰键 / WindowFromPoint / 客户区尺寸 / 唯一命中）复核到同一模型同一字形，就入队查词
  （`via=tap`）。采样器见过的按压仍归原 claim（鼠标路径行为不变）。原版引擎本就忽略这种按压，④ 天然成立。判据只来自引擎
  输入模型（逐帧采样 + 系统提升），不按游戏特判。提交 `ac99b85589`。
- **[x] ② 已加自动化测试** — `native/galgame_hook/tests/artemis_lookup_test.cpp` `TestSubFrameTap`（触摸点按提交、一次按下至多一次
  查词、采样器见过即不提交、抬起离字 / 换字 / 模型换代不提交、未命中的按下清掉旧武装、无按下的抬起不提交、空指针）；
  `tests/adapter_structure_test.py` 钉住：准入门统一在 `ArtemisPointEligible`、`ObserveArtemisTap` 必经 `ArmTap` / `ReleaseTap` 与
  采样计数、钩子过程只处理 `PM_REMOVE` 且 `CallNextHookEx`、`ReleaseTap` 比较采样计数、停机卸钩，新函数纳入「回调不做 IO」检查。
  变异实测：`ReleaseTap` 去掉采样计数比较 → `fushi_artemis_lookup_test` 变红，还原后绿。x64 133/133、x86 137/137、Python 69 OK。
- **运行时证据（2026-10-04，アマカノ3 x64，原始启动路径，x64 helper 装入 Debug 宿主）**：
  - `artemis-lookup: tap hook owner=26256 sampler=26256 ok=1`（消息线程即采样线程）。
  - 触摸（`InjectTouchInput` PT_TOUCH）点字 `放課後。` → `hit … via=tap published=1`、弹卡、台词不推进、前台恒为 `Artemis`；
    卡内点按与竖滑后前台仍是游戏；卡外点按 `global click … consumed=1` 关卡不推进；再点字重开；卡上横滑关卡；卡开着时卡外横滑
    `consumed=1` 关卡不推进；长按 900 ms 不推进。（无卡时卡外滑动会推进台词——那是游戏自身的拖动输入，不经查词。）
  - 鼠标回归 `accept4`：text / lookup / no_advance / dismiss_no_advance / relookup / card（假 AnkiConnect 真卡）全 PASS，日志每次点击
    恰一条 `via=sampler`，触摸路径无重复提交；`audio=FAIL` 仅因该旁白行无配音（Artemis 引擎语音此前已在有声行 `matched/game_resource` 证明）。
- **备注**：
  - 触摸注入脚本必须声明 per-monitor DPI 感知；否则 150 % 缩放下注入坐标被重缩放，触点落到游戏后面的窗口上
    （本次第一次注入就因此激活了别的应用窗口）。
