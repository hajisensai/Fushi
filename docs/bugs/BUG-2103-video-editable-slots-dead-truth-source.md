## BUG-2103 · 视频控制条可编辑槽真相源零消费且与真实能力矛盾
- **报告**：2026-09-03（排查用户「视频自定义区域无效」时发现；与 BUG-2102 同批）
- **真实性**：✅ 真 bug（结构性，非用户可见行为变化）。根因 `fushi/lib/src/media/video/video_control_customization.dart` 的 `VideoControlSlot.editableSlots`：

  该常量自称「编辑器暴露哪些槽」的真相源，注释与测试都强调 `topCenter` **不在其中**（「固定标题 chrome 区，不开放为可拖动槽」）。但：
  - 全仓 grep：**生产代码零消费**，只有 3 个测试文件引用它；
  - 两个编辑器各自硬编码了一份槽位表，且**都含 topCenter**：设置页 `video_control_layout_editor.dart`、画面内覆盖层 `video_control_layout_edit_overlay.dart`；
  - `canMoveToSlot` 一直允许 `VideoControlItem.title` 进 topCenter。

  也就是说这份「真相源」与真实能力**相反**，而且没有任何机制拦住两份硬编码表继续漂开——新增槽位时漏改其中一处，用户就会看到一个「画出来了却不存在」的区域。这也是整个编辑器里最容易被读成「这个自定义区域无效」的地方：topCenter 画成了投放目标，拖任何非标题按钮进去都只闪一句「此控制不能放在这里」。

- **[x] ① 已修复** — 把两个维度分开，并让真相源说真话且真的被消费：
  - `editableSlots` 纳入 `topCenter`（插在 topLeft 之后，得到的次序与覆盖层原硬编码表**逐项相同**，故覆盖层视觉零变化）。这个清单定的是**编辑器暴露哪些槽**；**每个槽收哪些按钮**仍由 `canMoveToSlot` 单独把关——topCenter 依旧只收标题。
  - 覆盖层 `_editorSlots` 改为直接返回 `VideoControlSlot.editableSlots`，删掉那份副本。
  - 提交：`7e17c7aff6`
- **[x] ② 已加自动化测试** — `fushi/test/media/video/video_control_layout_test.dart`：
  - 「两个维度」新用例：断言 `title.canMoveToSlot(topCenter) == true`，且**其余每一个** `VideoControlItem` 对 topCenter 都是 false（暴露不等于放宽收件能力）。
  - 「两个编辑器的槽位表都来自唯一真相源」新用例：覆盖层必须出现 `VideoControlSlot.editableSlots`；设置页编辑器按三行分组排版（版式不是成员资格），故断言**它提到的槽位集合 == `editableSlots`**，多一个少一个都红（先 `maskComments` 剥注释）。
  - 「学习键能移进每一个它被允许进的可编辑槽」原用例改判据：从「editableSlots 里的每一个都必须被接受」改成「以 `canMoveToSlot` 为判据分流」，并加 `honored > 0` 防空转。
  - 连带更新 `fushi/test/pages/video_topbar_guards_test.dart` 里断言 topCenter 不在清单的那条。
  - `test/media/video/` 3062 条 + `test/pages/` 3309 条通过。
- **备注**：本条**不改变任何用户可见行为**（覆盖层槽位与次序不变、topCenter 收件能力不变），只是消掉一个会说谎的真相源和两份会漂开的副本。若用户所说的「自定义区域无效」实指「顶栏（中间）拖什么都进不去」，那属于产品决策（要不要让 topCenter 收普通按钮），需用户裁定后另开一条。
