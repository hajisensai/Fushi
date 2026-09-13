## BUG-2195 · AnkiDroid 并行版（com.ichi2.anki.A）不被识别、权限框从不弹出
- **报告**：2026-09-06（用户：「连接似乎写死的是 ankidroid，我手机某次装的 parallel.a 一直用下来的，就无法识别请求权限连接了，hsa 倒是正常请求权限」）
- **真实性**：✅ 真 bug。根因是**并行版的三个标识全都带后缀，而我们三处全按主包写死**。
- **上游事实（实测，不是推断）**：
  - `ankidroid/Anki-Android` 的 `AnkiDroid/src/main/AndroidManifest.xml`：
    provider 是 `android:authorities="${applicationId}.flashcards"`，
    权限是 `<permission android:name="${applicationId}.permission.READ_WRITE_DATABASE">`。
  - `AnkiDroid/build.gradle`：`applicationIdSuffix project.property("customSuffix")…`
    —— 并行版就是主包 + 后缀，所以**包名 / authority / 权限名三者同时变**。
  - 解包我们依赖的 `com.github.ankidroid:Anki-Android:2.17alpha14` 的 AAR，
    逐个 class 扫常量池：`FlashCardsContract` 里躺着
    `content://com.ichi2.anki.flashcards`、`com.ichi2.anki.flashcards`、
    `com.ichi2.anki.permission.READ_WRITE_DATABASE`；`AddContentApi$Companion`
    里也有 `com.ichi2.anki.flashcards`（就是 `getAnkiDroidPackageName` 用的那个）。
    **全是编译期常量，没有任何注入点。**
- **三处写死，对应三个后果**：
  1. `AndroidManifest.xml` 的 `<queries>` 只声明了 `com.ichi2.anki` →
     Android 11+ 包可见性把并行版整个挡在外面，`resolveContentProvider` 查不到；
  2. `AnkiDroidHelper.isApiAvailable` 走 `AddContentApi.getAnkiDroidPackageName`
     （只认写死的主包 authority）→ 恒 false →
     `AnkiChannelHandler.requestAnkidroidPermissions` 在 `isApiAvailable` 那一步
     直接短路成 `unavailable`，**`requestPermissions` 一次都不会被调到**，
     这就是用户说的「无法识别、不请求权限」；
  3. `<uses-permission>` 只有主包那一个 → 就算前两条修好，申请的仍是别人的权限名，
     系统会静默判拒且不弹框（并行版定义的是
     `com.ichi2.anki.A.permission.READ_WRITE_DATABASE`）。
  另外 `grantUriPermission("com.ichi2.anki", …)` 与
  `FlashCardsContract.AnkiMedia.CONTENT_URI` 也是写死的，媒体插入同样落空。
  BUG-2098 修的是「权限申请不等结果」，与本条无关，它修完之后这条路依然全程不通。
- **[x] ① 已修复** — `worktree-fix-dict-download-error-anki-parallel`：
  - **新增 `AnkiDroidTarget`**：按候选包名逐个 `resolveContentProvider(<pkg>.flashcards)`
    探测，命中即得「包名 / authority / 权限名」三件套，进程内缓存。候选表为
    主包 + 官方并行版 A–E + `.debug`，**主包永远排第一**（同时装了两份时行为与修复前
    一致）。上游 `customSuffix` 理论上任意，这张表不可能穷尽；不用
    `QUERY_ALL_PACKAGES` 去穷举（Play 政策受限权限，为这点功能用它属于滥用）。
  - **manifest**：`<queries>` 与 `<uses-permission>` 逐个候选各加一条。
  - **`AnkiDroidHelper`**：`isApiAvailable` 改走 `AnkiDroidTarget.resolve`；
    权限名收敛到新的 `readWritePermission()`，检查 / 申请 / rationale 三处共用。
  - **`AnkiChannelHandler`**：`grantUriPermission` 授给解析出的包；
    `AnkiMedia.CONTENT_URI` 经 `target.rebase(...)` 重挂 authority。
  - **provider 抽象层**（`AnkiProvider` + `AnkiNote`）：
    - `AddContentApiProvider` —— 主包用，**逐行委托** AAR 的 `AddContentApi`，
      唯一的加工是把 `NoteInfo` 换成自己的 `AnkiNote`（并行版造不出 `NoteInfo`：
      它只有 Kotlin 合成构造和 internal 的 `buildFromCursor$api_release`）。
      守卫钉死这个类里不许出现 `ContentResolver` / `Cursor`。
    - `DirectAnkiProvider` —— 并行版用，自己驱动 ContentResolver，authority 来自
      `AnkiDroidTarget`。**列名 / path 段 / query 参数全部复用
      `FlashCardsContract` 的常量**（它们不带包名，是 provider 契约的一部分），
      唯一变的是 authority 一处。查重走 `notes_v2` 的 `mid=? and csum in (?)`
      —— 与 AAR 的 spec-2 实现同一条路（它的格式串 `"%s=%d and %s in (%s)"`
      就在常量池里），命中后仍逐条比首字段。
  - **为什么是双路而不是收成一条**：这是**显式的临时兼容层**，理由是外部依赖不可
    改（AAR 的 authority 是编译期常量）。**清理条件**：等 `DirectAnkiProvider` 在真机
    上把「建卡组 / 建笔记类型 / 加笔记 / 查重 / 改字段」全部验证过，就把主包也切到它、
    删掉 `AddContentApiProvider` 与对 AAR 的依赖，两条合并成一条。在那之前不合并，
    是因为主包那条路是今天所有 Android 用户在走的，不能让「支持并行版」这件事拿它
    冒险。
- **[x] ② 已加自动化测试** — 新增
  `fushi/test/android/ankidroid_parallel_build_guard_test.dart`（9 条源码守卫）。
  定向批 5 个文件共 **33 条全绿**。Android 侧没有 JVM 单测基建，同类不变式历来用
  源码扫描钉（见 `anki_native_createmodel_guard_test.dart`）。
  - **候选表 ↔ manifest 逐条对应**：从 `CANDIDATE_PACKAGES` 解析出包名，
    逐个断言 `<package>` 与 `<uses-permission>` 都在。这是最容易出的错——
    「加了候选却忘了改 manifest」，那一项在 Android 11+ 上会恒不可见。
  - 主包必须排第一、候选不得重复。
  - `isApiAvailable` 不得回到 `AddContentApi.getAnkiDroidPackageName`。
  - 权限名三处都走 `readWritePermission()`。
  - `grantUriPermission` 不得写死主包；我们自己发的 URI 必须 `rebase`。
  - 主包实现必须是纯委托（不得出现 `ContentResolver` / `Cursor`）。
  - 并行版实现的代码里不得残留 `com.ichi2.anki.flashcards`。
  - **变异实测**（非空转）：删掉 manifest 里 `.D` 那条 `<uses-permission>`
    → 守卫立刻红在第 78 行；还原后文件 sha256 与变异前逐字节一致。
  - **编译验证**：`flutter build apk --debug` 通过（`√ Built app-debug.apk`）。
    过程中真抓到一个错——`FlashCardsContract.Deck` 的常量不叫 `CONTENT_URI`
    而是 `CONTENT_ALL_URI`（另有 `CONTENT_SELECTED_URI`）。
- **未做 / 已知缺口（重要）**：
  - **真机行为未验证**。本机无 Android 设备接入本次会话，`DirectAnkiProvider`
    的每一条写路径都只过了编译与源码守卫，**没有在真的并行版上跑过一次**。
    按仓库纪律这条只能算 `implemented_unverified`：修好的是「识别 + 弹权限框」
    这一段（那部分逻辑简单且有守卫），「并行版上真的能写卡」尚待用户在
    `com.ichi2.anki.A` 上实测。
  - 需要用户复测的顺序：① 打开 Anki 设置页看是否弹出权限框；② 授权后看卡组 /
    笔记类型列表能否列出；③ 制一张卡；④ 带图片/音频的卡（走 media 插入那条）；
    ⑤ 重复词条是否能正确识别为重复。任何一步失败请把错误码发回来。
  - 用户当前的可用绕行：设置里打开「在手机上使用 AnkiConnect」。
