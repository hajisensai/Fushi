## BUG-1996 · 漫画扩展装不上：METADATA_MISMATCH（根因未定位）
- **报告**：2026-09-01（用户：电脑版最新调试版安装不了漫画扩展。点「安装」弹出 `MihonRuntimeException(METADATA_MISMATCH): Downloaded APK does not match the extension store metadata`，仓库 Keiyoushi，扩展列表能正常刷出）
- **真实性**：⚠️ **未复现 / 根因未定位**。用户症状是真的，但本文档第一版给出的根因**已被实测证伪**，不能作为结论使用。

  第一版声称「索引 `index.pb` field 5 是裸的扩展版本号（SamuraiScan=69 / Manga Mura=5），APK `android:versionCode` 是 `pack(libVersion)*1000+code`（104069 / 104005），两侧不同量纲，所以 keiyoushi 每个扩展都必然 METADATA_MISMATCH」。

  **复核实测**（2026-09-01，直连拉取 Fushi 默认仓库地址 `https://github.com/keiyoushi/extensions/raw/repo/index.pb`，gzip 解压 688322 字节，protobuf raw decode）：

  | 扩展 | 索引 `index.pb` field 5 | 索引 `index.json` `versionCode` | 两侧 `versionName` |
  |---|---|---|---|
  | SamuraiScan | **104069** | `"104069"` | `1.4.69` |
  | Manga Mura | **104005** | `"104005"` | `1.4.5` |

  即索引侧写的**就是**加了 libVersion 前缀的那个数，与 APK 的 `android:versionCode` 是**同一个量**。上游 `keiyoushi/extensions-source` 的 `ExtensionPlugin.kt` 把同一个 `androidVersionCodeProvider` 同时喂给 APK output 与索引元数据，构造上不可能分叉。第一版表格里的 `69` / `5` 两个数字不是从索引里读出来的。

  连带作废的推论：`versionName` 与 `versionCode` 上游是双射（`versionName = "$libVersion.$code"`、`androidVersionCode = pack(libVersion)*1000 + code`），所以把判据从 versionCode 换成 versionName **不可能**放过任何原本被拒的 APK——那条修复对声明的场景是 no-op。「更新角标永不亮」的推论同样不成立（两侧同量，`>` 一直是对的）。

  **还需要的证据**（下一份用户报告必须带上）：出错扩展的包名、该 store 行的 `format` 与 `indexUrl`、以及异常里现在会打印的两侧实际值。可疑方向（未证实）：`github_mirrors.dart` 让索引与 APK 分别经不同公共镜像取，镜像缓存不同步时会拿到版本不一致的两半。
- **[x] ① 已做的事（不是根因修复）** — 三项，都建立在实测之上：
  1. **可诊断性**：`METADATA_MISMATCH` 原来是一句常量，看不出哪个字段不匹配。现在把两侧的 `packageName` / `versionCode` / `versionName` 全写进 message（`mihon_manager.dart`）——这才是这条 bug 暴露出的真缺口。
  2. **身份门保留 versionCode 等值并补上 versionName**（`mihon_manager.dart`）：三个字段全等才放行，严格更强。第一版把 versionCode 从判据里拿掉是基于被证伪的前提，且 `versionName` 在三个解析路径里都是 `?? ''`、桌面 sidecar 又不校验非空，两侧同时缺失就退化成空门。
  3. **修一个实测存在的解析缺陷**：keiyoushi 的 `index.json` 是 protobuf-JSON，int64 按规范编码成**字符串**（`"versionCode": "104069"`），而 `mihon_extension_store_client.dart` 用的是 `json['versionCode'] as num?`——对 `currentJson` 格式的 store 会当场抛 `TypeError`，整个仓库索引解析失败。改为 `_parseStoreInt`，数字/字符串两种编码都收。
- **[x] ② 已加自动化测试** — `fushi/test/media/manga/mihon_manager_install_test.dart`：
  - `BUG-1996: index.json encodes int64 versionCode as a STRING; it parses and matches the APK versionCode exactly`——索引 `"104069"`（字符串）与 APK `104069` 全等放行；变异回 `as num?` 即红。
  - `BUG-1996: a mismatched versionName is still rejected`——versionCode 两侧同为 104070、只有 versionName 不同仍抛 METADATA_MISMATCH，且断言异常 message 里带上两侧实际值。
  - fixture helper `_inspection` 允许单独指定 versionName / libVersion（旧 fixture 用同一个整数同时造两侧，结构上测不出两侧分叉）。
- **备注**：数据模型里的两个字段仍分开命名（`MihonAvailableExtension.extensionVersionCode` / `MihonExtensionInspection.apkVersionCode`），但注释已改成「名字只标**出处**，两者是同一个量、可直接比较」——第一版把「不同尺度」这个假不变式写进了两处 doc comment，比原代码更有害。
