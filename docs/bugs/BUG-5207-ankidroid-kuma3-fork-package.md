## BUG-5207 · 装了改版 AnkiDroid（kuma3 Anki）时设置里一直显示「未安装 AnkiDroid」、权限框也不弹
- **报告**：2026-11-22（用户：开发者自报，应用内反馈 f8ING_Sh_m；同诉求 4GcjYXFAJe）
- **真实性**：✅ 真 bug。装的是 kuma3 Anki（AnkiDroid 分支，release 包名 `io.github.pedrubik2000.kuma3`，上游 `AnkiDroid/build.gradle` 的 `androidComponents.onVariants` 钉死；provider / 权限沿用 `${applicationId}.flashcards` / `${applicationId}.permission.READ_WRITE_DATABASE`）时，`AnkiDroidTarget.CANDIDATE_PACKAGES`（`fushi/android/app/src/main/java/app/fushi/reader/AnkiDroidTarget.java`）只认 `com.ichi2.anki` 与并行版，manifest 也没有它的 `<queries>` / `<uses-permission>`，Android 11+ 上看不见它、权限框不弹，设置里一直「未安装 AnkiDroid」。与 BUG-2195 同一机制。
- **[x] ① 已修复** — 候选表加 `KUMA3_PACKAGE`（排在官方主包与并行版之后，同时装时官方仍先命中），manifest 同步声明包可见性与它自己的读写权限；走并行版同一条 `DirectAnkiProvider` 路径。用户自定义包名做不到：包可见性与自定义权限必须在 manifest 里静态声明。
- **[x] ② 已加自动化测试** — `fushi/test/android/ankidroid_live_target_test.dart` 新场景 `kuma3-fork-main-priority`（JVM 上实跑生产 `AnkiDroidTarget.resolve`）；`ankidroid_parallel_build_guard_test.dart` 钉候选表含 kuma3 且排在主包后，原有「候选 ↔ manifest 逐条对应」守卫覆盖新项。
- **备注**：
