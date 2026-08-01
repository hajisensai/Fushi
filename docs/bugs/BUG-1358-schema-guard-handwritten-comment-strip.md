## BUG-1358 · PR#679 新守卫手写 startsWith('//') 剥注释，违反 source_guard 纪律，develop 单测门红

- **报告**：2026-08-02（用户：巡检发现 develop 单测门红）
- **真实性**：✅ 真 bug。根因 `hibiki/test/database/package_schema_version_literal_guard_test.dart:54`（PR#679 正文 commit `e48c82587` 新增），写的是

  ```dart
  if (lines[i].trimLeft().startsWith('//')) continue;
  ```

  这是 `hibiki/test/helpers/banned_comment_strip.dart` 明令禁用的第一号手写形态，于是
  `hibiki/test/tools/source_guard_adoption_test.dart` 的
  「test/ 下不得再手写注释剥离，一律走 helpers/source_guard.dart」当场判红：

  ```
  Expected: empty
    Actual: ['test/database/package_schema_version_literal_guard_test.dart:54  用了 startsWith(\'//\') —— 改用 maskComments / containsCodeLine']
  ```

  讽刺之处：PR#679 本身就是去修 BUG-1352 那条 CI 红的，它引入的守卫又踩了另一条纪律。

- **为什么这条纪律存在**：手写「整行以 `//` 开头就跳过」三个方向都漏——剥不掉行尾注释、
  剥不掉 `/* */` 块注释、删行还会让后续 `indexOf`/`substring` 的下标与原文错位。
  对**禁止型**守卫（本例）表现为块注释里的代码被误判成违规（假阳）；对**要求型**守卫
  则是「把实现删光、只在块注释里留下断言字面量」即可骗绿（假阴）。TODO-2358 / TODO-2477
  已把存量 22 处迁到共享 helper，`source_guard_adoption_test` 就是防止第 23 处复活的看门人。

- **[x] ① 已修复** — 把注释剥离换成共享词法掩码 `maskComments`
  （`hibiki/test/helpers/source_guard.dart`）：先整文件掩码，再逐行跑判据正则。
  没用 `containsCodeLine` 是因为本守卫的判据是**正则**、且报告要给行号，而它只收字面量
  needle、只返回 bool；`maskComments` 正是它内部用的同一个原语，且**等长等行**，
  掩码行下标可以直接回原文取证（报告里引用的仍是原始源码行）。
  提交：见本文件所在 PR。

- **[x] ② 已加自动化测试** — 本条修的就是守卫自身，覆盖它的是既有的
  `hibiki/test/tools/source_guard_adoption_test.dart`（修前红、修后绿），
  加上被改守卫自己 `hibiki/test/database/package_schema_version_literal_guard_test.dart`。

- **变异实测**（证明换 helper 后原守卫仍守得住，且顺带修掉一个假阳）：
  - 变异 A：把 `packages/hibiki_core/test/mihon_database_test.dart:27` 的
    `expect(database.schemaVersion, greaterThanOrEqualTo(65), ...)` 改回等值字面量
    `expect(database.schemaVersion, 65, ...)`。该变异**可编译且真跑**，
    `flutter test` 报 `Expected: <65> Actual: <66>`——正是 BUG-1352 的 CI 红原貌。
    守卫**如期转红**，并精确报出
    `../packages/hibiki_core/test/mihon_database_test.dart:27: expect(database.schemaVersion, 65,`
    （行号正确即证明等长掩码没让下标漂移）。
  - 变异 B：把 `expect(database.schemaVersion, 65);` 塞进一段 `/* */` 块注释。
    新版守卫**如期保持绿**（块注释里的不是代码）；旧的 `startsWith('//')` 写法会把这行
    误判成违规——这就是换 helper 顺带修掉的假阳。
  - 两次变异均用**反向 Edit 替换**还原（未对未提交文件用 `git checkout --`），
    还原后 `git status --short` 只剩本轮唯一目标文件。

- **备注**：同一轮实测里 `hibiki/test/.../update_manifest_publish_race_test` 另有 5 个用例红，
  是 Windows 上 `/tmp/tmp.*` 路径的环境问题，在裸 `origin/develop` 上同样复现，与本条无关。
