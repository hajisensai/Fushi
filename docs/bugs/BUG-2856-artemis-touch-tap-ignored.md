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
- **[ ] ① 未修复** — 要让触摸点字查词成立，传感器需要直接观察引擎的触摸输入（`WM_TOUCH` / `GetTouchInputInfo` 路径，
  按引擎结构定位，不按游戏特判），而原版游戏本身不接受触摸推进；属于能力扩展，留待单独的 Artemis 任务。
- **[ ] ② 未加自动化测试** — 随①一起加。
- **备注**：
  - 触摸注入脚本必须声明 per-monitor DPI 感知；否则 150 % 缩放下注入坐标被重缩放，触点落到游戏后面的窗口上
    （本次第一次注入就因此激活了别的应用窗口）。
