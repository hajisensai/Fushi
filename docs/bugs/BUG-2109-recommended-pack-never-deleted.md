## BUG-2109 · 推荐包 9.5GB zip 导入后永不删除（清理钩子挂在不再执行的引导页 initState）
- **报告**：2026-09-03（用户报「统计显示有问题」，见 [BUG-2096](BUG-2096-storage-category-detail-gap.md)）
- **真实性**：✅ 真 bug（代码路径闭合，未上真机）。
  新手引导下载的官方推荐包（词典 + 发音库，**9.5 GB** 整包 zip）落在
  `<appDirectory>/recommended_pack/`。导入走备份导入流程并**重启进程**，所以没法在导入
  成功后就地删包——设计是「导入前落 `imported.flag`，重启回来收尾删」。收尾链断在最后一环：
  - `fushi/lib/src/onboarding/recommended_pack.dart:458` `cleanupIfImported` 的**唯一调用点**
    是 `fushi/lib/src/pages/implementations/onboarding_wizard_page.dart:168`，即**新手引导页的
    `initState`**。
  - 而引导页只在 `fushi/lib/src/pages/implementations/home_page.dart:449`
    判 `!appModel.onboardingCompleted` 时才自动弹出。
  - 推荐包**本身就是一份含 settings 类目的备份**，导入是整层替换：
    `fushi/lib/src/sync/backup_service.dart:2270` 附近明确写着 settings layer
    "is replaced wholesale"。`preferences` 表连同 `onboarding_completed` 一起被换成备份里
    那份；而该键的缺省值本来也是 `true`
    （`fushi/lib/src/models/preferences_repository.dart:798`
    `getPref('onboarding_completed', defaultValue: true)`）——备份里没有这行也读到 true。
  - 于是导入后的那次重启，首页判定「引导已完成」，**不再弹引导页**，`initState` 不跑，
    9.5 GB 的 zip 永久留在盘上。`first_time_setup` 同在 preferences 表里，被一起替换，
    那条兜底路径同样救不回来。
  判据（flag）没错，错的是把收尾挂在了一个「导入成功就不会再出现」的页面上。
- **[x] ① 已修复** — 收尾搬到**启动必经路径**：`fushi/lib/src/models/app_model.dart` 初始化里
  那组「创建运行时目录」的 IO（已有同构先例 `purgePendingDictionaryDeletes`，且这组由
  `_guardInitIo` 兜掉盘时的 hang），调
  `RecommendedPackDownloader.cleanupIfImported(<appDirectory>/recommended_pack)`。
  引导页那处唯一入口一并移除（只留指向注释），避免两个入口各自漂移。
  flag 语义**不变**：没导入过、或只下了一半的包都不受影响，续传不会被作废。
- **[x] ② 已加自动化测试** — 新增 `fushi/test/onboarding/recommended_pack_cleanup_test.dart`
  - 行为三条：flag 在 → 整个包目录连 zip 一起删；flag 不在 → 原样保留（续传不作废）；
    包目录不存在 → 不抛（它现在跑在启动路径上，抛了就是启动失败）。
  - 守卫两条：`app_model.dart` 必须持有 `cleanupIfImported` 调用；引导页**不得**再出现该
    调用（注释提及允许，红线是调用）。
  - 两条守卫都做了**变异实测**：把 AppModel 里的调用改名 → 守卫 1 红；把调用加回引导页 →
    守卫 2 红；变异经 sha256 校验还原（未用 `git checkout`）。
- **备注**：真机未验证（用户设备未连本机 adb）。用户可自查
  `Android/data/<包名>/files/recommended_pack/`——若里面躺着 `fushi_recommended_pack.zip`
  （或 `.mpart` 预分配文件），即为本 bug 现场。本次修复只覆盖**已导入**的包；只下了一半
  从未导入的 `.mpart`（预分配就是完整 9.5 GB）仍按设计保留以便续传，但修好 BUG-2096 后它
  至少会在存储页明细里现身。
