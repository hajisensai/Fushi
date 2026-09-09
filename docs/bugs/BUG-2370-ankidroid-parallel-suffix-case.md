## BUG-2370 · AnkiDroid 并行版后缀大小写写错导致恒判未安装

- **报告**：2026-09-09（用户：官网下载的最新调试版；设备上装的是官方并行版 AnkiDroid.E）
- **现象**：新手引导 4/9「配置 Anki」点「测试连接」，红字报「未安装 AnkiDroid（或其 API 被禁用），无法授予卡片访问权限」。用户实际装着 AnkiDroid.E，制卡链路整条不可用。
- **真实性**：✅ 真 bug。根因 `fushi/android/app/src/main/java/app/fushi/reader/AnkiDroidTarget.java:64`（原 `CANDIDATE_PACKAGES` 里的 `.A`–`.E`）。

### 根因

BUG-2195 引入 `AnkiDroidTarget` 逐候选探测并行版时，候选后缀抄的是**显示名**的大小写。
上游 `tools/parallel-package-release.sh`（v2.15.0 至今未变）把两者分开传：

```sh
LCBUILD=`tr '[:upper:]' '[:lower:]' <<< $BUILD`
./gradlew ... -PcustomSuffix="$LCBUILD" -PcustomName="AnkiDroid.$BUILD"
```

- `customName` = `AnkiDroid.E` → 用户桌面图标上那个**大写**的名字；
- `customSuffix` = `e` → 经 `applicationIdSuffix` 拼成 applicationId `com.ichi2.anki.e`，
  provider authority `com.ichi2.anki.e.flashcards`、权限 `com.ichi2.anki.e.permission.READ_WRITE_DATABASE`
  （上游 `AnkiDroid/src/main/AndroidManifest.xml` 用的都是 `${applicationId}`）。

Android 包名大小写敏感，于是 `resolveContentProvider("com.ichi2.anki.E.flashcards")` 恒 null：
候选表里五个并行版条目**一条都匹配不到任何真实安装**，`isApiAvailable` 恒 false，
`AnkiChannelHandler.requirePermission` 直接抛 `ANKI_NOT_INSTALLED`。
即 BUG-2195 的并行版支持从落地起就从未真正生效过，只是把失败点从「权限框不弹」挪成了「报未安装」。

同一处 manifest 的 `<queries>` / `<uses-permission>` 五条声明也全是大写，一起落空。

### 为什么两层测试都没抓住

- `ankidroid_parallel_build_guard_test.dart` 只钉「候选表 ↔ manifest 逐条对应」——两边一起大写就一起错过去了；
- `ankidroid_live_target_test.dart` 真的 javac + 跑 `AnkiDroidTarget.resolve`，但它的桩包名是自己编的
  `MAIN + ".A"`，与被测常量同源同错，所以 enable 什么就 resolve 到什么，恒绿。

典型的「测试桩的事实不来自真实世界，而是照抄被测代码」。

- **[x] ① 已修复** — `AnkiDroidTarget.CANDIDATE_PACKAGES` 与 `AndroidManifest.xml` 的
  `<queries>` / `<uses-permission>` 五条并行版后缀统一改为小写 `a`–`e`。
  大写后缀从未被上游发布过，不保留兼容条目。
- **[x] ② 已加自动化测试** — `fushi/test/android/ankidroid_parallel_build_guard_test.dart`
  新增「并行版后缀必须小写（BUG-2370）」+「候选表必须含 a–e 五个真实发布包名」；
  `ankidroid_live_target_test.dart` 的桩包名改为真实发布过的 `com.ichi2.anki.e`。
  变异实测：把候选表改回 `.E` → `flutter test test/android/` exit=1，守卫点名
  「com.ichi2.anki.E 含大写」；改回 `.e` → 33 用例全绿 exit=0。

### 备注：顺带发现的文案问题（未在本轮修）

红字文案 `anki_error_ankidroid_unavailable` 里「或其 API 被禁用」这半句在现代 AnkiDroid 上
不成立——上游 provider 是 `android:enabled="true"` 写死的，AnkiDroid 设置里没有对应开关。
用户照这句去 AnkiDroid 里找开关只会白找。改它要动 17 个语言文件，与本 bug 根因无关，单独处理。
