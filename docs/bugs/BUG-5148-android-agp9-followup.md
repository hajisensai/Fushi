## BUG-5148 · Flutter 3.50 下 Android 构建仍用即将停支持的 Gradle 9.3.1 / AGP 9.1.1 / KGP 2.4.10，且关着 built-in Kotlin / newDsl
- **报告**：2026-11-22（来源：PR #3400 Flutter 3.50 升级交接「已知但不在本 PR 修」；拍板台 pr3400）
- **真实性**：✅ 真问题（技术债，尚未造成构建失败）。Flutter 3.50.0 的 Gradle 插件在 `:app:assembleRelease` 时打印
  「Flutter support for your project's Kotlin version (2.4.10) will soon be dropped… at least 2.4.20」，
  Gradle / AGP 同类提示（建议至少 Gradle 9.5.0 / AGP 9.3.1）。版本钉点在 `fushi/android/settings.gradle`（AGP / KGP）、
  `fushi/android/gradle/wrapper/gradle-wrapper.properties`（Gradle）、`fushi/android/build.gradle`（Kotlin 强制版本）。
  另外 `fushi/android/gradle.properties:8,10` 的 `android.builtInKotlin=false` / `android.newDsl=false` 是 Flutter 3.50
  迁移器自动加的退出开关：app 与所有插件模块仍 apply `org.jetbrains.kotlin.android`，每个模块都报
  「Deprecated 'org.jetbrains.kotlin.android' plugin usage」。
- **[ ] ① 部分修复**（2026-11-22，PR #3400）— 已做：钉点升到 Flutter 3.50 建议下限 Gradle 9.5.0 / AGP 9.3.1 / KGP 2.4.20
  （`gradle-wrapper.properties`、`settings.gradle`、根 `build.gradle` 的 Kotlin 强制版本、`app/build.gradle` 的 kotlin-stdlib /
  kotlin-test，vendored `desktop_drop` / `flutter_onnxruntime` / `receive_intent` / `fushi_launch_presence` 的 buildscript 同步）。
  本机 Flutter 3.50.0 `:app:assembleRelease`：`BUILD SUCCESSFUL in 16m 37s`，heavy exit 0（峰值 17220 MB，24 GB 上限），
  日志里不再出现 Gradle / AGP / KGP「soon be dropped」提示。仍待做：`:app` 迁 built-in Kotlin（删 kotlin-android 插件、
  `kotlin { compilerOptions }` 改 AGP 内置写法），插件侧要等上游或在 `ci/patches/hosted` / `third_party` 里逐个迁，
  全迁完才能删 `android.builtInKotlin=false` / `android.newDsl=false` 两个退出开关。
- **[ ] ② 部分自动化** — 版本下限已由 `android_agp9_gradle9_compat_guard_test.dart` 按 9.5.0 / 9.3.1 / 2.4.20 钉住；built-in Kotlin 迁完后加守卫禁止退出开关回流。
- **备注**：版本钉点随 PR #3400 一并升（本机出包已绿，16 GB 上限会撞内存、24 GB 够）；built-in Kotlin 迁移牵涉全部插件，单独做。
