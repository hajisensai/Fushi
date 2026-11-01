## BUG-3959 · srs-timeline-restore-empty-templates
- **报告**：2026-11-01（用户：Windows 安装版，「同步历史」时间线恢复后打开笔记类型编辑页，Styling 恢复了，Front / Back template 两个编辑框都空，预览提示「正面为空，这张卡不会出现」，模板名 Card 1）
- **真实性**：✅ 真 bug（机制在内核测试里复现；用户本机活库副本里没有找到这次恢复，见备注）。
  根因：时间线恢复把「那一刻这个键还没有任何记录」写成一条值为 `null` 的补偿修改，而读路径只在标量读取里把 null 当「没有」，
  带子键的映射却把 null 当成一份定义：
  - `native/fushi_fsrs/src/store/sync2/timeline.rs` `plan` → 旧 `value_at`（无记录时 `register_value` 返回 null）→ `edit_body(…, then = null)`；
  - `native/fushi_fsrs/src/registers.rs` `note_type_view` 遍历 `tmplDef/` / `fieldDef/` 时对 null 值照样 `template_def(id, null)` /
    `field_def(id, null)`，得到 name/front/back 全空的定义，并 `templates.put` **盖住内置类型的代码默认模板**（内置类型用户没改过时
    没有任何修改记录，模板跟随代码）。`css` 是标量，`pick("css")` 对 null 回落到内置默认值——所以「CSS 恢复了、模板空了」。
  - 同类（同一根因的其它表现）：之后才加的模板 / 字段在恢复后变成一份无名、无正文的空定义（不消失）；笔记之后才填的 `f/<id>`
    恢复后在字段列表里留一个空串项；卡片标志（`suspended` / `buried` / `flag` / `deck` / `newPos`）那一刻没有自己的记录、靠血统
    继承前身的值时，恢复写的 null 会**挡住继承**（自己的 null 是显式值，`buried = null` = 取消埋卡），新卡丢掉继承来的挂起等。
- **[x] ① 已修复** — 提交见 PR（分支 `pr/srs-timeline-restore-templates`）。
  - `registers.rs` 新增 `Entity::is_set`：生效值为 null 与没有记录是同一状态（「未设」），笔记 `f/`、笔记类型
    `fieldDef/` `tmplDef/` `fieldDesc/` 的映射遍历与浏览取值（`note_browse_values`）都跳过未设项——内置类型回到跟随代码，
    之后才加的项消失。卡片血统继承保持「自己的 null 是显式值」不变。
  - `timeline.rs`：`value_at` 区分「那一刻没有生效记录」（`None`）与「记录了 null」；新 `restored_value`：卡片标志那一刻没有
    自己的记录时，按 `cards_group` 同一血统规则（广度优先、前身按 ID 排、最多 256 张）写回当时继承到的值，否则写 null（= 未设）。
- **[x] ② 已加自动化测试** — `native/fushi_fsrs/src/store/sync2/tests_timeline.rs`（4 条：内置模板回到代码默认值、之后才加的模板 /
  字段 / 字段说明 / 笔记字段消失、卡片标志写回继承值、全种类 × 全键类恢复后逐寄存器等于那一刻的值）；去掉 registers.rs 的修复后
  前两条红（模板 front 为空），恢复修复后全绿。
- **备注**：
  - 用户活库副本（2026-11-01 23:13 连 WAL 拷出）里 `sync2_checkpoints` 没有任何 `reason = 'restore'` 的还原点、全库搜不到预览笔记
    「孤児院」、全部 `tmplDef/` 记录的 front / back 都非空——这次恢复不是在这台机器的这个库上做的（或恢复本身没执行），无法在
    副本上直接复演用户那一次；以上根因是在内核里按用户描述的形态复现的。
  - 用户数据能否找回：恢复只追加补偿操作、不删历史；被写成 null 的模板在操作日志里仍有旧记录。装上修复后的版本，null 自动按「未设」
    读——内置类型的模板立即回到代码默认值；若用户在还原点之前改过模板（那一刻有记录），恢复本来就写回了那份内容，不受影响；
    要回到「恢复之前」的内容，在时间线里恢复到这次恢复自动打的还原点（`before restore to …`）即可。
  - 已知未修（需所有者拍板，见 PR）：按时刻恢复的版本向量按操作的墙钟截断（`vv_at`），而迁移进来的旧修改记录的墙钟是**迁移时刻**、
    不是旧记录本身的时刻；选到最早一次迁移之前的时刻会把迁移来的全部实体当成「之后才建的」而删除（预览里会显示巨大的删除数）。
    在用户库副本上实测 `sync2_plan_restore`（修复后的内核，只读预演）：11-01 21:40 → fields 44 / revived 12 / tags 19（19.6 s）；
    10-30 → fields 50 / removed 21（21.4 s）；10-27（两次迁移之间）→ **fields 6003** / removed 78（**208 s**，第二台设备 10-29 迁移进来的
    旧记录全被当成「之后」）；10-25 及更早（首次迁移之前）→ **removed 15250 / fields 16938**（= 全库）。页面每次恢复调两次预演，
    10-27 那种时刻要等约 7 分钟。
