## BUG-1887 · Windows 显示 Fushi 正在使用定位（permission_handler_windows 启动即开定位会话）
- **报告**：2026-08-27（用户：Windows「设置 → 隐私和安全性 → 定位」把 `D:\APP\Hibiki\fushi.exe` 列为「正在使用」，启动即开始、退出才停）
- **真实性**：✅ 真 bug（显示属实，但 Fushi 没有任何读取或上传位置的功能）。根因 `third_party/permission_handler_windows/windows/permission_handler_windows_plugin.cpp`（上游 0.1.2 的插件构造函数）。
- **[x] ① 已修复** — vendor `permission_handler_windows` 0.1.2，把 `Geolocator` 的构造与 `PositionChanged` 订阅从**插件构造函数**推迟到唯一读它的地方（`checkServiceStatus(LOCATION*)`）。另外给 runner 自有的两个裸 WebView2（app 外查词浮窗 + 剪贴板面板）补上 `add_PermissionRequested → put_State(DENY)`。
- **[x] ② 已加自动化测试** — `fushi/test/windows/location_capability_guard_test.dart`（源码守卫 6 条，5 个变异全部实测被杀）。
- **备注**：真机实测：修复前账本在启动 10s 内写下 `Start`、`Stop=0`；修复后同一 exe 路径全程 `ABSENT`，而 WebView2 照常运行（2 个浏览器进程 / 10 个渲染进程）。

### 根因

不是 Fushi 有功能在读或上传位置，也不是「网页请求定位没被拒绝」。

`permission_handler_windows` 0.1.2 的插件**构造函数**无条件订阅 `Geolocator::PositionChanged`：

```cpp
PermissionHandlerWindowsPlugin::PermissionHandlerWindowsPlugin(){
  m_positionChangedRevoker = geolocator.PositionChanged(winrt::auto_revoke,
    [this](Geolocator const& geolocator, PositionChangedEventArgs e)
    {
    });   // ← 回调体是空的
}
```

订阅 `PositionChanged` = 让 Windows **开一个持续的定位会话**。插件对象在 `RegisterPlugins()`
期间构造，所以从 app 启动那一刻到进程退出，CapabilityAccessManager 一直把它记成
「正在使用定位」，归到宿主进程 `fushi.exe` 名下。

Fushi 的 Windows 端**一次都没调用过** permission_handler：它只在 Android / iOS 上查
storage / camera（`fushi/lib/src/platform/android/android_permission_service.dart`、
`ios_permission_service.dart`）。这个插件在 Windows 上纯属被自动注册进来的死代码，
代价却是一条常驻定位会话。

### 复现与证据（本机实测）

账本：`HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\CapabilityAccessManager\ConsentStore\location\NonPackaged\<exe 路径，\ 换成 #>`，
键 `LastUsedTimeStart` / `LastUsedTimeStop`（`Stop=0` 即「正在使用」）。

**基线**（未修复的 Debug 构建，干净数据根 + 离屏 + 零用户交互 + 无任何 `navigator.geolocation` 调用）：

```
t=10s alive=True wv2Children=3 wv2Grand=15 ledger=Start=134322925499785801 Stop=0
VERDICT: LEDGER_WRITTEN
```

**判别实验**（把所有 WebView2 环境的 user data folder 指向不存在的盘符，让环境创建全部失败）：

```
t=15s alive=True wv2Children=0 ledger=Start=134322932148016981
VERDICT: LEDGER_WRITTEN_WITHOUT_WEBVIEW2
```

零个 `msedgewebview2.exe` 子进程，账本照写 → **与 WebView2 无关**。同一轮里
`Geolocation.dll` / `LocationFrameworkPS.dll` 加载在 `fushi.exe` 自己进程内，账本在
启动后 **0.7 秒**就写下 —— 早于 Flutter 初始化完成，指向 native 插件注册阶段。

**修复后**（同一 exe 路径、同一探针、清空账本）：

```
t=10s ... t=120s  alive=True wv2Children=2 wv2Grand=10 ledger=ABSENT
AFTER-EXIT ABSENT
VERDICT: NO_LEDGER
```

### 排查中被否掉的假设

- **Android 权限**：报告初期查偏的方向，与 Windows 无关。
- **代码里有定位业务逻辑**：全仓无 `navigator.geolocation` / 经纬度读取。
- **WebView2 是元凶**（最初的主假设，写进过一版补丁后被推翻）：曾给三个 WebView2 环境加
  `--disable-features=WinSystemLocationPermission`，实测**账本照写**；再做上面的判别实验，
  确认没有 WebView2 时也写。该补丁已完整回退，不留无谓的行为改动。
- **只加权限拒绝门就能修**：`add_PermissionRequested` 只拦**页面运行期发起**的请求，拦不住
  插件注册期开的定位会话。它仍然值得加（见修复 ②），但它修不掉这个显示。
- **用 Edge 主浏览器当探针**：Edge 有包身份，不写 NonPackaged 账本，探不出来。

### 陷阱（下次别再踩）

- 探针跑不起来的两个坑，都会让账本「看起来是干净的」造成假阴性：① 用户实例在跑时，单实例守卫
  （`FushiSingleInstanceMutex`）会让第二个 exe 10 秒内自杀 —— 探针必须设 `FUSHI_TEST_HIDDEN=1`；
  ② 查词浮窗的 WebView2 profile 是固定路径 `%LOCALAPPDATA%\Fushi\GlobalLookupWebView2`，
  会和用户实例抢锁 —— 探针必须把 `LOCALAPPDATA` 指到沙箱目录。
- 进程被强杀时 Windows 不写 `LastUsedTimeStop`，账本会停在 `Stop=0`。判定必须看 `Start` 是否
  **新写**（先删键再跑），不能只看 `Stop`。
- 账本按**宿主进程**记账。看到 `fushi.exe` 不代表是 Fushi 自己的代码在调，也可能是它的子进程；
  反过来，子进程干净也不代表宿主干净。定位到具体调用方要靠「模块加载 + 写入时刻 + 排除实验」。
- 升级到修复版后，用户机器上那条旧账本记录不会自动消失，会以「最近使用过」留在列表里
  （新版不再写新的 Start）。想彻底清掉就删对应注册表键。
