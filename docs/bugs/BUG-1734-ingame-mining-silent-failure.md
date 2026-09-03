## BUG-1734 · 游戏内卡片制卡拿不到台词行时静默失败，无任何提示
- **报告**：2026-08-19（用户：真机验证游戏内查词制卡时发现）
- **真实性**：✅ 真 bug。根因 `fushi/lib/src/lookup/gal_hook_text_overlay_controller.dart:736-739`
- **[x] ① 已修复（根因）** — 根因是 `workbenchLines` 与 `selectedSessionLines` 这两个语义上
  必须同答案的判据**分叉了**：`sessionStartedAt == null` 时前者不过滤照常显示、后者直接返回空。
  已合成同一个 `_sessionScopedLines`，两个 getter 都委托给它
  （`fushi/lib/src/mining/gal_hook_session_controller.dart`）。
  修的是分歧本身，不是给制卡那条打补丁——「工作台显示了、制卡却当它不存在」这种自相矛盾的
  状态从此不可能出现。下面第二条（先报再返回）仍然保留：即便列表真的为空，也必须告诉用户。
- **[x] ①b 提示** — Dart 侧的静默返回已改成**先报再返回**，且按两种原因分开报：
  「本局一条台词都没有」用新 key `game_hook_mining_no_session_lines`（指向工作台换线程），
  「有台词但对不上当前这句」沿用 `game_hook_line_unavailable`。
  **但这还不是全解**：popup 侧收到 `ankiConnect:false` 依旧什么都不做
  （`fushi/assets/popup/popup.js` 的 mine 分支只在 `result.ankiConnect` 为真时才有动作），
  而游戏常是全屏/无边框，Fushi 的 toast 在游戏背后**用户可能仍然看不见**。
  真正解掉要让**游戏内那张卡片自己**显示失败态，即改 popup.js 并按三镜像同步；
  该改动必须有可视验证才敢下，本轮工作站已锁屏、未做。
- **[x] ② 已加自动化测试** — 根因那条是**行为测试**
  `fushi/test/mining/gal_session_lines_agree_test.dart`（2 项）：不启动会话（即
  `sessionStartedAt == null`）时写入台词，断言两个 getter 逐条一致、顺序一致、末元素是最后写入的那句。
  变异实测：把分叉放回去（`selectedSessionLines` 在 `startedAt == null` 时返回空）→
  两条全红且报的正是 `Expected: [...] Actual: []`；还原后源文件 sha256 逐字节相同
  （62B691CC…3BA012）。
  提示那条是源码守卫 `fushi/test/lookup/ingame_mining_failure_visibility_guard_test.dart`（6 项）：
  真文件断言「失败分支先 `FushiToast.show(` 再 return」这条**顺序不变量** + 两条文案各自存在；
  配三条变异（完全没有 toast / toast 排在 return 之后 / 锚点失效）与一条干净样本反向验证。
  变异实测：把真文件里那次 toast 注释掉 → 守卫红并报出预期断言，还原后 sha256 逐字节相同。
- **备注**：见下

### 复现（真机，2026-08-19）

《天使☆嚣嚣 RE-BOOT!》（KiriKiri Z）由 Fushi 启动，游戏内查词一切正常
（`lookup_diag=0x106F`，卡片已画进游戏图层，点击也已转发：`inputs=3`）。
点卡片右上角「+」制卡：

- **第一次**（还没选文本线程）：弹出「完成捕获设置：请先选择台词线程」。行为正确。
- **选完线程之后再点**：**什么都不发生**。没有 toast、没有进度、没有错误，Anki 一条都没多
  （AnkiConnect 前后 `total_notes` 13200 → 13200，`galgame_card_test` 12 → 12）。

用户视角完全无法区分「制卡失败了」和「我没点到按钮」。

### 根因

`fushi/lib/src/lookup/gal_hook_text_overlay_controller.dart:730-748` `_ingameMiningHandlerFor`：

```dart
final String? resolved = _resolveIngameMiningLineId(line);
if (resolved == null) {
  return const <String, Object?>{'ankiConnect': false, 'noteId': null};   // :736-739
}
```

**静默返回**：不 toast、不 `_record`、不打日志。
而 `_resolveIngameMiningLineId`（`:712-727`）第一步就读 `_session.selectedSessionLines`
（`gal_hook_session_controller.dart:768`），列表为空直接 `return null`（`:714`）。

对照：**浮窗点词那条制卡路径拿不到 entry 时是有提示的**——
`gal_hook_text_overlay_controller.dart:672-680` 会 `FushiToast.show(t.game_hook_line_unavailable, error)`。
两个入口对同一种失败的处理不对称，游戏内这条是纯静默死。

### 2026-08-20 补：Ren'Py 上的 A/B 把失败点钉死在行解析

同一个会话、同一句台词、同一个 app 构建（2.1.1-debug.11887）、同一份 hook DLL
（三处哈希核对过：我的构建产物 / `D:\APP\Hibiki\voice_hook\x86\` / Fushi 实际注入用的
暂存目录 `%APPDATA%\Fushi\Fushi\voice_hook_runtime\<hash>\x86\`，全部一致）：

| 入口 | 结果 |
|---|---|
| Ren'Py 会话 · **工作台弹窗**点词 →「+」 | ✅ Anki 13202 → **13203**（新卡 1787155671956） |
| Ren'Py 会话 · **游戏内卡片** →「+」 | ❌ 无任何反应，Anki 不变 |
| KiriKiri 会话 · **游戏内卡片** →「+」 | ✅ Anki 13201 → **13202**（新卡 1787154832868），`applied` 由 0 → 16 |

三条排除项（都是实测，不是推断）：

* **不是点击没到**：同一张游戏内卡片上点 ✕ 能精确关掉卡片、点 ☆ 能把星星变实心，
  `inputs` 相应递增。坐标映射无误。
* **不是截图那步**：诊断探针的 `applied=`（`lookup_frame_applied_seq`）在 Ren'Py 上**恒为 0**，
  而 KiriKiri 成功那次是 0 → 16。host 只有走到截图抑制握手才会推进它，恒 0 说明
  Ren'Py 这条**在到达截图之前就退出了**。
* **不是台词没进列表**：被查那句就是所选线程的最新一条（工作台里肉眼可见，
  且工作台那条路正是拿它写出了卡）。

于是失败只可能落在 `_ingameMiningHandlerFor` → `_resolveIngameMiningLineId` 返回 null
这条**静默分支**上——工作台那条路直接拿 `entry.id`，绕开了它，所以能成。
这条 A/B 同时证明本 bug 的用户可见后果是真的：用户在游戏里点「制卡」，屏幕上什么都不会发生。

#### 再排除一项：两侧台词**逐字节相同**

用工作台那行的「复制」按钮取 Fushi 侧原文到剪贴板，与探针打印的命中整行做字节比对：

```
sensor: len=27 bytes=27  hex=49 20 61 6D 20 6E 6F 74 20 61 20 66 61 6E 20 6F 66 20 6D 6F 72 6E 69 6E 67 73 2E
fushi : len=27 bytes=27  hex=49 20 61 6D 20 6E 6F 74 20 61 20 66 61 6E 20 6F 66 20 6D 6F 72 6E 69 6E 67 73 2E
exact_equal=True
```

没有尾随空格、没有 NBSP、没有零宽字符——`latest.text == line` 这个判等**本该成立**。
（这一步必须比字节：两行肉眼完全一样，任何不可见差异都只有 hex 看得见。）

#### 于是收敛到一个可直接验证的假设

`_resolveIngameMiningLineId` 读的是 `_session.selectedSessionLines`
（`gal_hook_session_controller.dart:768`），而工作台列表渲染的是 `workbenchLines`
（同文件 `:732`）——**两个不同的 getter**。既然台词内容一致、且它确实是工作台里的最后一条，
那么只可能是 `selectedSessionLines` 为空（或末元素不是它）。

**为什么偏偏 Ren'Py 中招**：它是唯一走「启动器 → 子进程」且
`follow_child_processes: true` 的引擎（`engine-support.yaml` 的 `renpy_ffmpeg.process_strategy`）。
KiriKiri 是单进程，两个 getter 自然一致。所以最可能的根因是
**会话身份挂在启动器 pid、而台词归属挂在子进程 pid（或反之）**，导致按会话过滤后为空。

#### 读代码后收敛到一个**确定的不一致**（不再是推测）

两个 getter 的过滤条件逐行比对（`gal_hook_session_controller.dart`）：

```dart
// workbenchLines (:732) —— 工作台列表渲染用
final DateTime? startedAt = _state.sessionStartedAt;
Iterable<...> scoped = entries.where(_publishesUnderSelection...);
if (startedAt != null) {                       // ← null 就【不过滤】，照常显示
  scoped = scoped.where((e) => !e.receivedAt.isBefore(startedAt));
}

// selectedSessionLines (:768) —— 游戏内制卡的行解析用
final DateTime? startedAt = _state.sessionStartedAt;
if (startedAt == null) return const <TexthookerLineEntry>[];   // ← null 就【直接返回空】
```

**两者只有这一处差异，而且方向相反。** 于是 `sessionStartedAt == null` 时：
用户在工作台**看得见台词**，游戏内制卡却认为**一条都没有** → `_resolveIngameMiningLineId`
返回 null → 静默失败。这与本轮 A/B 完全吻合（工作台那条路拿 `entry.id`，压根不经过它）。

`sessionStartedAt` 由 `bindWindow`（:1096）与 `launchAndCapture`（:1239）打戳，
由 `stopListening`（:1550）清空。Ren'Py 走「启动器 → 子进程」并开着
`follow_child_processes`，比单进程引擎多出若干次绑定/换绑时机，更容易落在它为 null 的窗口里。

**这本身就是要修的东西**：两个语义上必须一致的判据分叉了。修法不是给制卡那条打补丁，
而是让两者共用同一个谓词——顺带把「工作台显示了、制卡却当它不存在」这种自相矛盾的状态消掉。
（`sessionStartedAt` 为 null 时到底该显示还是该隐藏，是个产品决定；但两处必须同答案。）

仍未直接观测到的是「制卡那一刻 `sessionStartedAt` 是否真的为 null」——
用本分支（已含本 bug 的提示修复）构建一份 Fushi 跑同一场景即可坐实：
提示会直接说出是「本局一条台词都没有」还是「有台词但对不上」。

### 与 BUG-1733 的关系

BUG-1733 是**为什么列表是空的**（KiriKiriZ 线程的台词被伪影门丢了）；本条是**列表空时不该静默**。
两者要分别修：即便 1733 修好，仍会有「用户选了一条真的没台词的线程」这种合法情形，
那时也必须告诉用户，而不是让「+」按钮看起来坏了。

### 修复方向

失败分支给出与浮窗路径同源的提示（同一条 i18n key 或新增一条更准确的），
并区分两种原因：本会话没有任何台词行 / 有台词但匹配不上当前这句。
