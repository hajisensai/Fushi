# Fushi：Flutter 3.47.6 / Dart 3.13 编译兼容补丁

Dart 3.13 收紧了「被闭包捕获的可空局部变量跨 await 的类型提升」，原样的 pdfrx_engine-0.4.4
在 `flutter build` 的 kernel 编译阶段直接报错（`flutter analyze` 不分析依赖，抓不到）。

改动只有一处语义不变的非空断言：lib/src/native/pdf_file_cache.dart:380/382 用 `cache!`（被 `read` 闭包捕获的可空 `cache` 在 `await _downloadBlock` 之后不再保持提升）。
原值在该路径上必定非空（同一闭包前几行已用 `!` 取过），不改行为。

**删除条件**：锁文件升到上游已修复的版本（pdfrx_engine-0.4.4 的新版本要求的依赖本仓暂不能升：
dartssh2 2.15+ 需 pointycastle ^4（2.15 仍有同一错误，2.22.5 已重写该段），pdfrx_engine 0.4.6+ 才修且需 archive ^4 / image ^4.8）后删除本目录。
