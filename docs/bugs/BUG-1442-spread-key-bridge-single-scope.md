## BUG-1442 · 双页 spread 键桥只能解析 reader scope，跨 scope 动作在 spread 里恒解析不到

- **报告**：2026-08-02（整合线：PR#722 合并阻塞排查）
- **真实性**：✅ 真 bug（设计缺陷型，非用户可见症状）。根因是键桥把「导出哪些动作」与
  「解析哪个 scope」写成**两处真值**：
  - `hibiki/lib/src/pages/implementations/reader_hibiki_page.dart:680`
    `kSpreadBridgedActions` —— 数据侧，4 个动作恰好全是 reader scope；
  - `hibiki/lib/src/pages/implementations/reader_hibiki/webview.part.dart:2113`（修复前）
    `onSpreadKey` 的 `resolveKeyboard(..., scope: ShortcutScope.reader)` —— 硬编码单 scope。

  两者不联动，于是往 `kSpreadBridgedActions` 里加**任何非 reader scope 的动作**都会
  **静默失效**：`spreadKeyBridgeTokens` 照样把它的键导进 JS token 表、用户按下也照样
  `callHandler('onSpreadKey', token)` 回传 Dart，但 `resolveKeyboard` 在 reader scope
  里找不到它 → `action == null` → handler 早退。键桥对该动作形同虚设，且**没有任何
  报错**，只有「按了没反应」。

  这条缺陷是 PR#722（「返回上一级」全 app 统一成一个可改键动作）的**合并阻塞**：
  #722 删掉 `ShortcutAction.readerExitBook`、把退出语义并进新的 `universal` scope 下的
  `globalBack`；把 `kSpreadBridgedActions:684` 那行机械换成 `globalBack` 后
  `flutter analyze` 绿，但 `test/reader/spread_page_turn_input_test.dart` 红，报文
  「Escape 解析成 null，不在 spread 声明的动作集里」——正是本缺陷。

- **[x] ① 已修复** —— 解析侧的 scope 列表改为**从动作集自身按出现序去重导出**，动作集成为
  唯一真值：新增 `spreadKeyBridgeScopes()` / `resolveSpreadKeyBridgeAction()`
  （`reader_hibiki_page.dart`），`onSpreadKey` 改调后者、handler 体内不再出现任何
  `ShortcutScope.xxx` 字面量。scope 顺序 = 动作集里各 scope 首次出现的顺序，所以页面专属
  scope 排在兜底 scope 之前 → **页面专属键永远优先于兜底**，与 Flutter 焦点路径的
  「reader → audiobook 逐级回退」同构。
  `kSpreadBridgedActions` 内容**本次不动**（仍全是 reader scope），故 develop 上零行为变化；
  `spreadKeyBridgeScopes()` 今天返回 `[reader]`。

- **[x] ② 已加自动化测试** —— `hibiki/test/reader/spread_page_turn_input_test.dart`
  新增 group「键桥跨 scope 解析 (BUG-1442)」6 条 + 改写既有 2 条断言。逐条变异实测：
  | 变异（生产代码反向改坏） | 转红的用例 |
  |---|---|
  | `spreadKeyBridgeScopes` 返回固定 `[reader]` 不再导出 | 「scope 列表按动作集出现序去重导出」+「动作集里混入别的 scope 时，那个 scope 的键真能解析到」 |
  | 导出顺序反转（`scopes.insert(0, …)`） | 「scope 列表按动作集出现序去重导出」+「同键被页面 scope 与兜底 scope 都绑时，页面专属胜出」 |
  | `onSpreadKey` 恢复硬编码 `scope: ShortcutScope.reader` | 「注册了 onSpreadKey 处理器，走注册表解析并 reclaim 焦点」 |
  | 删掉 `spreadKeyBridgeTokens` 里裸 Space 的 `continue` | 「…且恒排除裸 Space」+「裸 Space 的排除与 scope 无关」 |
  | `resolveSpreadKeyBridgeAction` 循环里把 scope 钉死成 reader | 「动作集里混入别的 scope 时，那个 scope 的键真能解析到」 |

  五次变异均为 17 tests completed 的**断言失败**（非编译失败/零测试执行）。

- **备注**：
  - **裸空格中和不受影响**：`spreadKeyBridgeTokens` 的裸 Space 排除判据只看**单条绑定
    本身**（`key == space && modifiers.isEmpty`），与动作属于哪个 scope 无关。所以将来往
    动作集里加的跨 scope 兜底动作即便被用户绑成裸 Space 也进不了 token 表，不会在 spread
    页复活「裸 Space 双触发」，`global_navigation.dart` 把裸空格中和为 `DoNothingIntent`
    的纪律也不受影响。已由「裸 Space 的排除与 scope 无关」用例钉死（同时断言 `Ctrl+Space`
    仍能正常进表，排除的只是「裸」的那一条）。
  - 本条**不改 develop 的运行时行为**，是给 PR#722 让路的使能修复。#722 rebase 后只需把
    `kSpreadBridgedActions` 里的 `readerExitBook` 换成 `globalBack`，解析侧零改动。
