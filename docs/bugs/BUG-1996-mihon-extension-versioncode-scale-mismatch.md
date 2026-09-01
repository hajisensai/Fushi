## BUG-1996 · 漫画扩展装不上：索引 versionCode 与 APK android:versionCode 尺度不同
- **报告**：2026-09-01（用户：电脑版最新调试版安装不了漫画扩展。点「安装」弹出 `MihonRuntimeException(METADATA_MISMATCH): Downloaded APK does not match the extension store metadata`，仓库 Keiyoushi，扩展列表能正常刷出）
- **真实性**：✅ 真 bug，且 keiyoushi 的**每一个**扩展都必然中招。根因 `fushi/lib/src/media/manga/mihon/mihon_manager.dart:517-525`（`_prepareInstallBytes` 的身份门比 `inspection.versionCode != expected.versionCode`）。

  两侧的 `versionCode` 从 2026-05-15 起就不是同一个量了：

  | 扩展 | 索引 `index.pb` field 5 | APK `android:versionCode` | 两侧 `versionName` |
  |---|---|---|---|
  | SamuraiScan | **69** | **104069** | `1.4.69` / `1.4.69` |
  | Manga Mura | **5** | **104005** | `1.4.5` / `1.4.5` |

  上游出处 `keiyoushi/extensions-source` → `gradle/build-logic/src/main/kotlin/ExtensionPlugin.kt:133-135`：APK 的 versionCode 被改成 `pack(libVersion)*1000 + versionCode`（`"1.4"` → `"0104"` → 104 × 1000 + 69 = 104069），而 `publish-repo.py:118` 写进索引的仍是**未加前缀**的扩展版本号。改版提交是 `153fbece5 "Rework Gradle build logic"`，改版前 `common.gradle:38-39` 两者相等——所以这条等值断言当初是对的。keiyoushi 只保留最近 7 个 release，仓库里已经没有一个旧约定的 APK。

  **排除**的其它方向（均有硬证据）：不是下载到 HTML 错误页（`file` 判定为合法 APK，sidecar 的 `ApkVerifier` 已通过）；不是签名问题（索引 `signingKey` 与 APK v2 签名块算出的证书 SHA-256 逐字节相同）；不是 proto 类型问题（field 5 是 `int64`，解出 69 无误）；不是桌面 JVM 解析差异（Android 侧 `longVersionCode` 同样是 104069，**这个 bug 在 Android 上一样发作**，只是用户先在 Windows 撞见）。
- **[x] ① 已修复** — 身份门只比**两侧同义**的字段：`packageName` + `versionName`。

  刻意**不**采用「枚举新旧两种编码」（`apk == pack(lib)*1000 + index` 或 `apk == index`）：那要把 keiyoushi 构建脚本的实现细节复制进我们的校验里，上游下次再调构建逻辑照样挂。`versionName`（`1.4.69`）两侧逐字相同，且本身就编码了 libVersion + 扩展版本号，约束强度不低于原来那条等值——这是把不同义的量从判据里**拿掉**，不是放宽。真实性本来就不由本门负责：`SIGNATURE_MISMATCH`（对仓库 `signingKey`）和 `SIGNATURE_CHANGED`（对已装版本签名）一个字没动。

  同时把两个尺度在数据模型里分开命名，让类型系统挡住下一次「看到两个都叫 versionCode 就拿来比」：`MihonAvailableExtension.versionCode` → `extensionVersionCode`（仓库尺度）、`MihonExtensionInspection.versionCode` → `apkVersionCode`（Android 尺度）。改名让编译器逐个点出消费方，因此**顺带修好一个静默失效**：`mihon_extensions_page.dart:1039` 的「有更新」角标原本是 `extension.versionCode > installed.versionCode`——左边仓库尺度(69)、右边 DB 里的 APK 尺度(104069)，keiyoushi 扩展的更新角标**永远不会亮**；改为比 `versionName`。`DOWNGRADE_REJECTED`（两侧同为 APK 尺度）与 DB 列名（冻结，语义即 APK 尺度）不动。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/mihon_manager_install_test.dart`：
  - `BUG-1996: keiyoushi APK whose android:versionCode carries the libVersion prefix still installs`（索引 code=69 / versionName=`1.4.69`，APK versionCode=104069 / versionName=`1.4.69`）；
  - `BUG-1996: a mismatched versionName is still rejected`——证明门没有变成一张空门（索引 `1.4.69` vs APK `1.4.70` 仍抛 METADATA_MISMATCH）；
  - fixture helper `_inspection` 现在允许**单独指定** versionName/libVersion。这是关键：旧 fixture 用同一个整数同时造两侧（`versionCode: n` + `versionName: '1.6.$n'`），正是踩坑的那个假设，所以旧守卫结构上抓不到这个 bug。
  - 638 tests ran, all passed。
- **备注**：上游 Mihon 自己（`ExtensionApi.kt:39`）也在跨尺度比 versionCode，但它安装走系统 PackageInstaller、没有这条元数据等值门，所以在 Mihon 那边只表现为「更新检测失效」，不会拦住安装。`PackageUtil.kt:12` 有个 `versionCode.toInt()` 的 Long→Int 收窄（upstream pristine），104069 还远未溢出，暂不构成问题。
