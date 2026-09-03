## BUG-2099 · 安卓文件选择器把 .mdx/.dsl/.ifo/.ass 置灰选不中
- **报告**：2026-09-03（用户：截图「LDOCE5++ V 2-15.mdx」在 SAF 里点不动；同日补报「导入视频字幕的时候只能选 srt 不能选 ass」）
- **真实性**：✅ 真 bug。根因不在词典页/字幕页，在「把扩展名过滤交给平台」这件事本身。
  - 直接来源：`file_picker-8.3.7/android/.../FileUtils.java:44-63` 的 `getMimeTypes()`
    ——逐个扩展名查 `MimeTypeMap.getSingleton().getMimeTypeFromExtension()`，
    **查不到就 `continue` 静默跳过**（只打一行 warning），剩下的才由
    `FilePickerDelegate.java:321` 塞进 `Intent.EXTRA_MIME_TYPES`。
  - 于是词典导入传的 `['zip','dsl','mdx','ifo','css']` 到 SAF 只剩
    `application/zip` + `text/css`，字幕导入传的 `['srt','vtt','ass','ssa']` 只剩
    srt/vtt（`.ass`/`.ssa` 不在系统 MIME 词表里）。SAF 按 MIME 放行，其余全部置灰。
    用户截图里 `.mdx` / `.mdd` 显示成「BIN 文件」正是「系统不认识这个扩展名」。
  - 消费端根因 `file:line`：`fushi/lib/src/media/import/real_path_directory_picker.dart:337`
    的 `filterAfterPick` 判据当年只覆盖了 iOS（`dyn.*` UTI 是同一个病的另一半），
    安卓照旧走 `FileType.custom`；另有 14 处业务页**裸调** `FilePicker.pickFiles(
    type: FileType.custom)` 绕过统一入口，同样中招（词典 ×2、字幕 ×4、`.aix`
    漫画源、`.lua` mpv 脚本、`.glsl/.hook` 着色器、字体、apk、torrent、json、zip）。
- **[x] ① 已修复** — 移动端（安卓 + iOS）一律「`FileType.any` 打开选择器 + Dart 端按
  扩展名校验」，桌面维持原生过滤（桌面对话框直接吃扩展名字符串，可靠）。
  判据抽成单一真相源 `_platformDropsUnknownExtensions`，新增公开原语
  `pickSystemFilePaths`（多选路径版）与 `pickFilesByExtensions`（保留
  `FilePickerResult` 语义，供需要 bytes / 多选的调用方），14 处裸调点全部收编。
  **不做「哪些扩展名有 MIME」的白名单**：`MimeTypeMap` 是系统词表，各 ROM / 各
  Android 版本内容不同，app 侧既改不了也查不到，硬编码清单只会把下一个扩展名的
  同款事故推迟发生。
  提交：见下方「备注」。
- **[x] ② 已加自动化测试** —
  - 行为测试 `fushi/test/media/import/picker_extension_filter_test.dart`（9 条）：
    把 `FilePicker.platform` 换成记录入参的假实现，真的走一遍两个公开原语，断言
    「安卓/iOS 收到 `FileType.any` 且 `allowedExtensions == null`」「桌面仍收到
    `FileType.custom`」「Dart 端过滤只留合格条目」「全不合格返回 null 而不是让
    调用方的 `.single` 抛」「`withData` 等参数原样透传」。改回 `FileType.custom` 必红。
  - 源码守卫 `fushi/test/tools/file_picker_discipline_guard_test.dart` 新增
    `kCustomFileTypeAllowlist` + 禁止型断言：`lib/` 下不得再裸用 `FileType.custom`
    （豁免只剩 `saveFile` 保存对话框与 Windows 专属 galgame 入口，只减不增）。
    原 `kFilePickerAllowlist` 同步缩到 6 条（都是 `FileType.image` / `FileType.any`
    的调用，没有可被丢弃的扩展名清单）。
- **备注**：真机复测缺口——本轮未在安卓真机/模拟器上跑「导词典选 .mdx」「导字幕选
  .ass」的原始失败路径，结论建立在「上游 Java 源码 + 用户截图 + Dart 侧行为测试」
  三方证据链上。桌面行为不变（仍是原生过滤），移动端的变化是选择器不再灰掉无关
  文件、选错时弹「不支持的格式」提示。
