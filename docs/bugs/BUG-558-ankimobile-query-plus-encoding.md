## BUG-558 · iOS AnkiMobile 制卡字段空格显示成加号
- **报告**：2026-07-05（用户：wight）
- **真实性**：✅ 真 bug。用户截图里字段值出现 `(明鏡国語辞典+第三版)+はい`，沿真实路径确认模板渲染先产出普通 `Map<String,String>` 字段，Android 通过 `AddContentApi.addNote(..., String[] fields, ...)` 直传字段，Hoshi Reader 也只把渲染后的 `fields` 字典交给 AnkiConnect JSON；只有 iOS AnkiMobile 路径在 `hibiki/lib/src/anki/ankimobile_repository.dart:30` 用 `Uri.replace(queryParameters: ...)` 构造 `anki://x-callback-url/addnote`，Dart 会把 query 空格编码为 `+`，AnkiMobile 字段参数按字面显示后污染卡片内容。
- **[x] ① 根因修复** — `buildAnkiMobileAddNoteUri` 改为为 AnkiMobile addnote query 手动使用 `Uri.encodeComponent` 百分号编码，空格输出 `%20`、字面加号输出 `%2B`，不改变模板渲染、字段名和 Android/Hoshi 语义。提交：本提交。
- **[x] ② 自动化测试** — `hibiki/test/anki/ankimobile_repository_test.dart` 新增回归用例，先复现原始 query 含 `+` 的失败，再守住 deck、note type、字段、tags 与回调里的空格均不再以 `+` 进入 addnote URL；验证：`/Users/wight/fvm/versions/3.44.0/bin/flutter test test/anki/ankimobile_repository_test.dart`。
- **备注**：本轮已验证纯 URL 构造层；真机 AnkiMobile 最终展示仍需在 iPhone 上创建同一张卡肉眼复看，因本地无法自动驱动 AnkiMobile 第三方确认界面。
