## BUG-2380 · AnkiDroid 建牌组/笔记类型失败被吞成成功，一键创建 Lapis 改选用户自己的牌组
- **报告**：2026-09-09（用户：旧人间，QQ 群）
- **真实性**：✅ 真 bug。根因两段，都在「创建失败」这条路径上被静默吞掉：
  - `fushi/android/app/src/main/java/app/fushi/reader/AnkiChannelHandler.java:360`（修前）
    裸调 `api.addNewDeck(deckName)` 后**丢掉返回值**，紧接着无条件 `result.success(null)`。
    `addNewDeck` 的契约是「失败返回 null」（`AnkiProvider.java:43`），所以 provider 的
    `insert` 返回 null 时，Dart 侧拿到的是**成功**。`createNoteType`
    （`AnkiChannelHandler.java:843` 修前）同样丢掉 `addNewCustomModel` 的返回值。
    同一文件里 `addNote`（:143）与 `addFileToMedia`（:420）一直都在判空，
    只有这两条**建结构**的路径漏了。
  - `fushi/lib/src/anki/anki_view_model.dart:294`（修前）
    `createLapisSetup` 建完回读清单时用
    `firstWhere(name == 'Lapis', orElse: () => list.first)`：找不到 Lapis 就退而选清单里的
    **第一个**牌组/笔记类型，顺手套上 Lapis 的字段映射，最后仍返回 `created`。
- **用户可见形态**：新装 AnkiDroid、自己建了一个叫「日语」的牌组。点「一键创建 Lapis 卡组」
  之后没有出现 Lapis，界面显示的选中牌组就是「日语」，还提示创建成功。字段映射是按
  Lapis 的字段名排的，在「基础」笔记类型上一个都对不上 → 首字段恒空 → 真去制卡时被 Anki
  以 `cannot create note because it is empty` 拒收。
- **旁证（为什么守卫没拦住）**：`fushi/test/anki/anki_native_createmodel_guard_test.dart`
  只断言 `addNewDeck` / `addNewCustomModel` 这些**字符串在不在**。bug 期间它们一直都在，
  被丢掉的是**返回值**，所以守卫全程绿灯。native 侧没有任何 JVM / instrumentation 测试。
- **[x] ① 已修复** — 三处根因 + 一处判据统一：
  - native 判空：`addNewDeck` 返回 null → `CREATE_DECK_FAILED`；
    `addNewCustomModel` 返回 null → 抛出并映射成 `CREATE_MODEL_FAILED`。
  - native 如实回传「新建 / 本来就有」（`result.success(true/false)`），
    Dart 侧删掉自己那份**第二份存在性判据**。两份判据本来就不一致（native 是
    `equalsIgnoreCase` / 名字+字段数，Dart 是精确相等），分歧时「Dart 要求创建 →
    native 静默跳过 → 报成功」是本 bug 的第二段。判据只留一处，分歧就无从产生。
  - `createLapisSetup` 删掉 `orElse` 兜底：回读清单里看不到 Lapis 就返回
    `AnkiErrorCode.lapisSetupMissing` 失败，绝不改选用户自己的牌组、绝不套 Lapis 字段映射。
  - 新增 `AnkiSettings.canMineCards`（`packages/fushi_anki/lib/src/anki_models.dart`）：
    「这套配置真能制出卡吗」的唯一判据，与制卡时的 `preflightNoteFields` 同源（Anki 的
    `fields_check()` 只看首字段）。连接 Anki 之后与新手引导离开 Anki 步之前各判一次，
    判不过弹同一个「创建并选用 Lapis」弹窗（`promptCreateLapisIfCannotMine`）。
  - 按钮文案「创建 Lapis 卡组」→「创建并选用 Lapis」。
- **[x] ② 已加自动化测试** —
  - `fushi/test/anki/anki_settings_can_mine_cards_test.dart`（新增，11 例）：`canMineCards`
    的判据，含「Lapis 字段映射套在别人的笔记类型上 → 不能制卡」这条用户实际形态，
    以及反面「用户自己的笔记类型只要首字段接了模板就算合格」（防止把非 Lapis 用户也弹窗）。
  - `fushi/test/anki/anki_view_model_lapis_test.dart`：新增「建完在清单里看不到 Lapis 时
    失败，绝不改选用户自己的牌组」——直接钉死用户报的那一幕；以及「只补建了牌组时报
    created 而非 alreadyExisted」（`createDeck` 返回值此前也被丢掉）。
  - `fushi/test/anki/anki_native_createmodel_guard_test.dart`：把守卫从「字符串在不在」
    升级成「**返回值被用上了**」——断言 native 判了 `== null` 并走 error 分支、
    如实回传 true/false，且 Dart 侧不再自带第二份存在性判据。同时把原有那条按
    `invokeMethod('createNoteType'` **连写**钉死的断言放宽成对换行不敏感（它钉的是写法
    不是不变式，参数一多换行就红）。
- **验证**（均按退出码判绿）：
  - `flutter analyze`（fushi）→ No issues found，exit=0。
  - `dart analyze`（packages/fushi_anki，`flutter analyze` 不覆盖 path 依赖包）→ exit=0。
  - `flutter test test/anki --no-pub` → 381 例全绿，exit=0。
  - `flutter test`（packages/fushi_anki，须 cd 到包目录）→ 544 例全绿，exit=0。
  - 相邻域 `test/i18n test/onboarding test/settings` 571 例，唯一一条红是
    `lookup_audio_volume_granularity_test.dart` 的 `loading` 型装载失败；单跑 5 例全绿
    （exit=0）→ 并发伪红，与本次改动无关。
  - **踩坑记一笔**：给 `flutter test` 注入 `HTTPS_PROXY`/`HTTP_PROXY` 会让
    `packages/fushi_anki/test/ankiconnect_service_test.dart` 的
    「default transport tags a failed connection before HTTP delivery」假红——那条走
    真实 socket 判连接失败的分类。去掉代理环境变量即绿。判红前先看有没有给测试挂代理。
  - Android Java 改动**不经任何 Dart 测试编译**（native 侧零 JVM 测试），另跑
    `flutter build apk --debug` 真编一次 `AnkiChannelHandler.java`。
- **备注**：native 侧仍无 JVM 测试，`addNewDeck` 返回 null 的**具体触发条件**（主包路径的
  `AddContentApi` 是编译好的 AAR，钉在 `2.17alpha14`，本仓无源码）未能进一步定位；本次修的是
  「失败不再被吞成成功」这个不变式，用户现在会拿到明确的失败提示而不是一个静默配坏的目标。
  真机复测尚未进行。
