# permission_handler_windows (vendored)

上游：`permission_handler_windows` **0.1.2**（pub.dev，Baseflow）。
vendored 原因见 BUG-1887（`docs/bugs/BUG-1887-webview2-location-in-use.md`）。

## 为什么 fork

上游插件的**构造函数**无条件订阅 `Geolocator::PositionChanged`：

```cpp
PermissionHandlerWindowsPlugin::PermissionHandlerWindowsPlugin(){
  m_positionChangedRevoker = geolocator.PositionChanged(winrt::auto_revoke,
    [this](Geolocator const& geolocator, PositionChangedEventArgs e)
    {
    });   // ← 回调是空的
}
```

订阅 `PositionChanged` = 让 Windows **开一个持续的定位会话**。插件对象在
`RegisterPlugins()` 期间构造，所以任何嵌入这个插件的 Windows 应用，从启动那一刻
到进程退出，都会被 Windows 的 CapabilityAccessManager 记成「正在使用定位」，出现在
「设置 → 隐私和安全性 → 定位」的应用列表里 —— 哪怕这个 app 从来不碰定位权限。

Fushi 就是这种情况：`permission_handler` 只在 Android / iOS 上用来查 storage /
camera（`fushi/lib/src/platform/android/android_permission_service.dart`、
`ios_permission_service.dart`），Windows 端一次都没调过，更没有任何定位功能。

实测（Debug 构建、干净数据根、离屏、零用户交互）：账本在启动后 **0.7 秒**内写下
`LastUsedTimeStart`、`LastUsedTimeStop=0`，`Geolocation.dll` / `LocationFrameworkPS.dll`
加载进 `fushi.exe` 自身进程。把所有 WebView2 环境创建全部弄失败（零个
`msedgewebview2.exe` 子进程）后账本照写 —— 与 WebView2 无关。

## 补丁内容

`windows/permission_handler_windows_plugin.cpp` 一处改动：把 Geolocator 的构造与
`PositionChanged` 订阅从**插件构造函数**推迟到**唯一读它的地方**
（`IsLocationServiceEnabled`，即 `checkServiceStatus(LOCATION*)`）：

- 成员改成空句柄 `Geolocator geolocator{nullptr}`，新增 `EnsureGeolocator()`。
- 构造函数改为 `= default`。
- `IsLocationServiceEnabled()` 开头调 `EnsureGeolocator()`。

**保留**订阅而不是删掉：它在上游不是无用代码 —— `Geolocator::LocationStatus()`
只有在存在定位会话时才报真实状态，没有会话时返回 `NotInitialized`。所以真的有 app
去问「定位服务开没开」时，行为与上游一致（第一次问会开会话）；不问的 app 则永远
不开。差异只有一处：**首次**调用时订阅刚建立，`LocationStatus()` 可能还是
`NotInitialized` → 按上游同样的判据（`!= NotAvailable`）返回 `ENABLED`。

## 撤销条件

上游把这个订阅改成按需（或删掉空回调订阅）后即可撤销本 fork，恢复 pub.dev 版本。
守卫：`fushi/test/windows/location_capability_guard_test.dart`。
