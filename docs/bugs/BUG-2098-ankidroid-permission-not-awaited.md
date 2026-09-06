## BUG-2098 · AnkiDroid 权限申请不等结果 + 错误码域不通导致英文原文外泄
- **报告**：2026-09-03（用户：Android 制卡设置页截图——「创建 Lapis 卡组」失败，页面红字与 snackbar 都是 `PlatformException(PERMISSION_DENIED, AnkiDroid permission not granted. Please grant and retry., null, null)`，全英文；且从头到尾没弹出过系统权限申请对话框）
- **真实性**：✅ 真 bug。三个各自独立的根因：
  1. **权限申请「发完就不管」**（主因）——`AnkiChannelHandler.java:346` 的
     `case "requestAnkidroidPermissions"` 发起 `ActivityCompat.requestPermissions` 后
     **立刻** `result.success(true)`；而全 app 没有任何 `onRequestPermissionsResult`
     实现（`requestCode = AD_PERM_REQUEST = 0` 的结果无人接收），Dart 侧
     `anki_repository.dart` 6 处 `await invokeMethod('requestAnkidroidPermissions')`
     拿到 true 后不等用户答复就直接查 provider。于是权限对话框还在屏幕上，错误已经
     报完了。i18n 文案 `anki_error_permission_denied` 写着「请在刚弹出的系统授权对话
     框中允许」，代码却从不等那个对话框，逻辑自相矛盾。
  2. **错误码两个码域不相通**——native 返回裸码 `PERMISSION_DENIED`
     （`AnkiChannelHandler.java:374`），本地化表 `localizeAnkiMineError`
     （`error_log_service.dart:564`）匹配的却是
     `AnkiErrorCode.permissionDenied == 'ANKI_PERMISSION_DENIED'`
     （`anki_models.dart:1298`）。只有制卡路径有 `_classifyMineError`
     （`anki_repository.dart:294`）做转换；fetch 路径 `anki_repository.dart:151`
     直传 `e.code`，`localizeAnkiFetchError` 恒查不中 → 回退 `return message`
     显示英文原文。**中文文案早就写好了，只是永远显示不出来。**
     建 Lapis 路径更糟：`_lapisSetupFailureMessage`（`anki_view_model.dart:275`）
     只对 AnkiConnect 传输层异常本地化，`PlatformException` 直接落进 `e.toString()`，
     连 code/message 都不拆，整个 `PlatformException(...)` 糊给用户。
     另外 `createLapisSetup` 里 fetch 失败分支（`anki_view_model.dart:236`）也漏了
     `localizeAnkiFetchError`——同一个错误走刷新是中文、走建 Lapis 就变英文。
  3. **三种拒绝态被压成一种**——没有任何 `shouldShowRequestPermissionRationale`
     判断。权限被永久拒绝（Android 11+ 拒一次即「不再询问」）或 AnkiDroid 未安装
     （`com.ichi2.anki.permission.READ_WRITE_DATABASE` 是 AnkiDroid 自己定义的权限，
     没装时系统里根本不存在）时，`requestPermissions` 立即静默判拒且**不弹框**，
     用户在这个页面上**没有任何路径能把权限授出来**——这就是「没弹出申请」的观感。
- **[x] ① 已修复** — 三层根治，`fix/bug-2098-ankidroid-permission-flow`：
  - **native**：`requestAnkidroidPermissions` 改为挂起 `MethodChannel.Result`
    （`pendingPermissionResult`），由新增的 `AnkiChannelHandler.onRequestPermissionsResult`
    在系统回调到达时 resolve，返回五态字符串 `granted` / `denied` /
    `permanently_denied` / `no_activity` / `unavailable`；`MainActivity` 新增
    `onRequestPermissionsResult` 覆写转发（此前全 app 一个都没有）。永久拒绝判据走
    新增的 `AnkiDroidHelper.canAskPermissionAgain`（rationale）。`unavailable` 由
    `AnkiDroidHelper.isApiAvailable` 前置判定，避免把「没装 AnkiDroid」误报成「去设置
    授权」。新增 `openAnkiPermissionSettings` 跳系统应用详情页。
    `requirePermission` 守卫不再自己发起请求（发起与等待收归单一职责，否则一次操作
    弹两次框、且那次请求无人等待）。
  - **fushi_anki**：6 处裸 `invokeMethod('requestAnkidroidPermissions')` 收口成
    `_ensurePermission()`，非授权终态短路成带稳定码的 `PlatformException`（旧 native /
    测试桩返回 `true`/`null` 仍视为已授权，向后兼容）；`_classifyMineError` 提升为
    唯一分类入口 `classifyPlatformError`，**fetch 路径也走它**（消灭两套码域）；
    新增错误码 `ANKI_PERMISSION_PERMANENTLY_DENIED` / `ANKI_DROID_UNAVAILABLE`。
  - **fushi**：`localizeAnkiMineError` 补两个新码的本地化；`_lapisSetupFailure`
    先过 AnkiDroid 分类再退回原文（且只取 `message` 不再吐整个 `toString()`）；
    `createLapisSetup` 的 fetch 失败分支补上 `localizeAnkiFetchError`；
    `LapisSetupResult` 带回 `code`，永久拒绝时 snackbar 给「去设置」按钮。
    i18n 经 `tool/i18n_sync.dart --add` 新增 3 key × 17 语言。
- **[x] ② 已加自动化测试** — `packages/fushi_anki/test/ankidroid_permission_flow_test.dart`
  （16 条，全绿；连同原 BUG-824 守卫 7 条共 23 条绿）：
  - 行为层：native 回四种非授权终态时**一个 provider 方法都不许被调到**，且错误码
    必须是带 `ANKI_` 前缀的稳定码；`granted` 正常放行；旧契约 `true`/`null` 仍放行。
  - 分类层：裸码→稳定码映射、三个权限态互不相等、message 兜底、无关异常不冒领、
    fetch 失败带回稳定码而非裸码。
  - native 源码扫描守卫：`Result` 挂起、`onRequestPermissionsResult` 存在、
    `MainActivity` 转发、永久拒绝/未安装两态分开、`requirePermission` 不再发起请求。
  - **变异实测**（非空转）：删掉 `MainActivity` 转发那行 → 守卫红；把非授权态改成
    放行 → 三条行为断言红；两次还原后源文件 sha256 与变异前逐字节一致。
- **备注**：真机复测（真实 AnkiDroid 上走「拒绝 → 再点 → 弹框 → 允许 → 成功」和
  「不再询问 → 去设置」两条路径）**未做**——本机无 Android 设备/模拟器接入本次会话，
  Java 侧行为只由源码扫描守卫覆盖。这是本条已知验证缺口。
