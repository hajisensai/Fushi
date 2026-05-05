# Anki 导出行为重构 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将 silentExport 设置的语义从"静默导出（不显示通知）"改为"快速导出（不打开制卡界面）"，默认开启，且导出成功后始终显示 toast。

**Architecture:** 三处改动——默认值翻转、addNote 中移除 silentExport 对 toast 的控制、i18n 字符串重命名+描述更新。

**Tech Stack:** Flutter/Dart, Fluttertoast, slang i18n

---

### Task 1: 修改 silentExport 默认值

**Files:**
- Modify: `hibiki/hibiki/lib/src/models/app_model.dart:3789-3791`

- [ ] **Step 1: 将 defaultValue 从 false 改为 true**

```dart
bool get silentExport {
  return _getPref('silent_export', defaultValue: true);
}
```

- [ ] **Step 2: 运行 analyze 验证**

Run: `cd d:\APP\vs_claude_code\hibiki\hibiki && flutter analyze lib/src/models/app_model.dart`
Expected: No issues found

---

### Task 2: 导出成功后始终显示 toast

**Files:**
- Modify: `hibiki/hibiki/lib/src/models/app_model.dart:2656-2662`

- [ ] **Step 1: 移除 silentExport 条件判断，始终显示 toast**

将：
```dart
if (!silentExport) {
  Fluttertoast.showToast(
    msg: t.card_exported(deck: deck),
    toastLength: Toast.LENGTH_SHORT,
    gravity: ToastGravity.BOTTOM,
  );
}
```

改为：
```dart
Fluttertoast.showToast(
  msg: t.card_exported(deck: deck),
  toastLength: Toast.LENGTH_SHORT,
  gravity: ToastGravity.BOTTOM,
);
```

- [ ] **Step 2: 运行 analyze 验证**

Run: `cd d:\APP\vs_claude_code\hibiki\hibiki && flutter analyze lib/src/models/app_model.dart`
Expected: No issues found

---

### Task 3: 重命名 i18n 字符串

**Files:**
- Modify: `hibiki/hibiki/lib/i18n/strings.i18n.json:357-361, 715`

- [ ] **Step 1: 修改主语言文件（英文）**

将：
```json
"silent_export": "Silent Export",
"silent_export_on": "Export notifications are now disabled.",
"silent_export_off": "Export notifications are now enabled.",
```

改为：
```json
"silent_export": "Quick Export",
"silent_export_on": "Cards will be exported directly without opening the editor.",
"silent_export_off": "The card editor will open before exporting.",
```

将 `anki_silent_export_hint`（第715行）：
```json
"anki_silent_export_hint": "Do not show a notification after successfully exporting a card.",
```

改为：
```json
"anki_silent_export_hint": "Export cards directly without opening the card editor.",
```

- [ ] **Step 2: 重新生成 strings.g.dart**

Run: `cd d:\APP\vs_claude_code\hibiki\hibiki && dart run slang`
Expected: 生成成功，无报错

- [ ] **Step 3: 运行 flutter analyze**

Run: `cd d:\APP\vs_claude_code\hibiki\hibiki && flutter analyze`
Expected: No issues found

---

### Task 4: 更新设置页 toggle toast 文案

**Files:**
- Modify: `hibiki/hibiki/lib/src/pages/implementations/anki_settings_page.dart:152-156`

当前 toggle 后显示的 toast 引用了 `t.silent_export_on` / `t.silent_export_off`，这些字符串在 Task 3 已经改为新文案，无需额外代码改动。只需确认逻辑正确：toggle ON 时显示"直接导出不打开编辑器"，toggle OFF 时显示"导出前打开编辑器"。

- [ ] **Step 1: 确认 anki_settings_page.dart 无需改动**

当前代码：
```dart
Fluttertoast.showToast(
  msg: appModel.silentExport
      ? t.silent_export_on
      : t.silent_export_off,
);
```

逻辑正确：toggle 后 `silentExport` 的新值为 true → 显示 `silent_export_on`（直接导出），false → 显示 `silent_export_off`（打开编辑器）。无需改动。

---

### Task 5: 编译验证 + Commit

- [ ] **Step 1: 编译 release APK**

Run: `cd d:\APP\vs_claude_code\hibiki\hibiki && flutter build apk --release --split-per-abi --target-platform android-arm64`
Expected: BUILD SUCCESSFUL

- [ ] **Step 2: Commit**

```bash
git add lib/src/models/app_model.dart lib/i18n/strings.i18n.json lib/i18n/strings.g.dart
git commit -m "refactor(anki): rename Silent Export to Quick Export, default ON, always show toast"
```
