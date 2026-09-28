## BUG-2756 · iOS 上导入 .mokuro 文件必失败（选单文件只拷进来 .mokuro、选文件夹无沙盒外读权限）
- **报告**：2026-09-28（转述 iPhone 用户：mokuro 文件传不上去）
- **真实性**：✅ 真 bug（代码路径确认，未在 iPhone 上复现）。漫画导入框 `fushi/lib/src/media/manga/manga_import_dialog.dart` 调 `pickRealFilePath`，`fushi/lib/src/media/import/real_path_directory_picker.dart` 在 iOS 上按「返回真实路径、不复制」处理（`isRealPath: true`），这个前提是错的：file_picker 8.3.7 iOS 选文件用 `UIDocumentPickerModeImport`（`FilePickerPlugin.m:217`），选中的文件被挪进 `NSTemporaryDirectory()/<文件名>`（`:411-427`），只有那一个 `.mokuro`；`packages/fushi_engine/lib/media/manga/manga_importer.dart` `importFromMokuroPath` 在 `.mokuro` 同目录找页图 → 缺图报错。选文件夹走 `UIDocumentPickerModeOpen`，直接返回沙盒外路径，插件和本仓（`ios/Runner`、`lib`）都没有 `startAccessingSecurityScopedResource`，`dart:io` 列目录会被拒。`Info.plist` 也没开 `UIFileSharingEnabled` / `LSSupportsOpeningDocumentsInPlace`，用户没法把卷放进 app 自己的容器。
- **[ ] ① 未修复** — 需要 iOS 原生改动：目录选择拿到 URL 后 `startAccessingSecurityScopedResource` 并把整卷拷进 app 存储（或持有访问权直到导入结束）；单选 `.mokuro` 时明确提示「iOS 请选整卷文件夹或 zip/cbz」。须在 Mac 上编译 + 真机/模拟器验证，本轮未做。
- **[ ] ② 未加自动化测试**
- **备注**：当前可用的绕行办法：把整卷（页图 + `.mokuro`）打包成 zip / cbz 导入，归档导入会读包内的 `.mokuro`（`fushi/lib/src/media/manga/import/manga_archive_importer.dart`）。
