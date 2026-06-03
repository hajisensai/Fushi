# app 外查词统一到 Flutter 嵌套弹窗 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 让 Android 外部查词（PROCESS_TEXT / SEND / TRANSLATE / `hibiki://lookup`）渲染与桌面/app 内同一套支持嵌套的 Flutter `PopupDictionaryPage`，替换原生 WebView 平铺替换弹窗。

**Architecture:** 新建一个 `:popup` 进程内的透明 `FlutterActivity`（`PopupDictFlutterActivity`），托管一个常驻热缓存的 FlutterEngine 运行已有的 `popupMain` Dart 入口；通过已有的 `app.hibiki.reader/popup` MethodChannel 把外部选中的文本喂给 Dart，Dart 侧 `PopupDictionaryPage` 现成的 `_stack` 嵌套逻辑提供层叠下钻 + 逐层返回。manifest 把 4 个外部入口的 intent-filter 从原生 `PopupDictActivity` 迁到新 Activity；原生 Activity 本轮只失活不删。

**Tech Stack:** Kotlin（FlutterActivity / FlutterEngine / FlutterEngineCache / GeneratedPluginRegistrant）、AndroidManifest、Dart（flutter_test 源码守卫 + widget 测）、Gradle（assembleRelease）。

设计来源：`docs/specs/2026-06-03-app-external-lookup-nested-popup-design.md`

---

## 关键事实（实现前必读）

- Dart 入口已就绪：`hibiki/lib/popup_main.dart` 的 `@pragma('vm:entry-point') popupMain()` → `PopupDictApp` → `PopupDictionaryPage`（`hibiki/lib/src/pages/implementations/popup_dictionary_page.dart`，已实现 `_stack` 嵌套 + `PopScope` 返回 + `_close()→PopupChannel.finishPopup`）。
- Dart channel 已就绪：`hibiki/lib/src/utils/misc/popup_channel.dart`。`PopupChannel.init` 在引擎启动后 **轮询 `getInitialProcessText`**，并监听 `onNewProcessText`。channel 名 `app.hibiki.reader/popup`（Dart：`HibikiChannels.popup`；Kotlin 常量：`app.hibiki.reader.constants.ChannelNames.POPUP`）。
- **冷启动时序坑**：因为 Dart 一启动就轮询 `getInitialProcessText`，原生 `/popup` channel handler 必须在 `executeDartEntrypoint()` **之前**注册好。本计划把 handler 注册放进引擎构建函数里、execute 之前。
- 主题 `PopupDictTheme`（`hibiki/android/app/src/main/res/values/styles.xml`）已是半透明（`windowIsTranslucent=true` + 透明背景 + 禁 dim），透明 FlutterActivity 直接复用。
- `FlutterEngine(context, null, false)` 关闭自动插件注册，随后 `GeneratedPluginRegistrant.registerWith(engine)` 手动注册全量插件（**必须包含 flutter_inappwebview**，嵌套层由 WebView 渲染）。
- 测试工作目录为 `hibiki/`，源码守卫测试用相对路径 `android/...` 读文件（见现有 `hibiki/test/pages/native_popup_dictionary_static_test.dart`）。
- 原生 `PopupDictActivity.kt` 本轮**不改动**（保留作回退），其现有源码守卫测试继续通过。

## File Structure

- Create: `hibiki/android/app/src/main/java/app/hibiki/reader/PopupEngineHolder.kt` — 构建/缓存热引擎 + 注册 `/popup` channel handler + 推送文本。
- Create: `hibiki/android/app/src/main/java/app/hibiki/reader/PopupDictFlutterActivity.kt` — 透明 FlutterActivity，取词 + 生命周期接管。
- Modify: `hibiki/android/app/src/main/AndroidManifest.xml` — 新增 `<activity>` 并迁移 4 个 intent-filter。
- Create: `hibiki/test/pages/popup_dict_flutter_activity_static_test.dart` — 原生 Kotlin 源码守卫。
- Create: `hibiki/test/pages/popup_external_manifest_test.dart` — manifest intent-filter 指向守卫。
- Create: `hibiki/test/pages/popup_dictionary_page_nested_test.dart` — Dart 嵌套栈行为守卫。

---

## Task 1: PopupEngineHolder（热引擎 + channel handler）

**Files:**
- Create: `hibiki/android/app/src/main/java/app/hibiki/reader/PopupEngineHolder.kt`
- Test: `hibiki/test/pages/popup_dict_flutter_activity_static_test.dart`（本 Task 先建一半，Task 2 补全）

- [ ] **Step 1: 写失败的源码守卫测试（针对 Holder）**

创建 `hibiki/test/pages/popup_dict_flutter_activity_static_test.dart`：

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const String holderPath =
      'android/app/src/main/java/app/hibiki/reader/PopupEngineHolder.kt';

  test('popup engine holder runs popupMain on a cached engine', () {
    final String src = File(holderPath).readAsStringSync();
    // 关闭自动注册后手动全量注册插件（含 inappwebview）。
    expect(src, contains('FlutterEngine(context.applicationContext, null, false)'));
    expect(src, contains('GeneratedPluginRegistrant.registerWith(engine)'));
    // 正确的 popupMain 入口。
    expect(src, contains('"popupMain"'));
    expect(src, contains('executeDartEntrypoint'));
    expect(src, contains('FlutterEngineCache.getInstance()'));
    // 用统一 channel 常量，不硬编码字符串。
    expect(src, contains('ChannelNames.POPUP'));
    // 冷启动时序坑：channel handler 注册必须在 executeDartEntrypoint 之前。
    final int handlerIdx = src.indexOf('setMethodCallHandler');
    final int executeIdx = src.indexOf('executeDartEntrypoint');
    expect(handlerIdx, isNonNegative);
    expect(executeIdx, isNonNegative);
    expect(handlerIdx, lessThan(executeIdx),
        reason: 'handler 必须在 executeDartEntrypoint 之前注册，否则 Dart '
            'getInitialProcessText 轮询拿不到首词');
    // 必须实现两个方法。
    expect(src, contains('getInitialProcessText'));
    expect(src, contains('finishPopup'));
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run（在 `hibiki/` 下）: `flutter test --no-pub test/pages/popup_dict_flutter_activity_static_test.dart`
Expected: FAIL — `PopupEngineHolder.kt` 不存在，`File(...).readAsStringSync()` 抛 FileSystemException。

- [ ] **Step 3: 创建 PopupEngineHolder.kt**

创建 `hibiki/android/app/src/main/java/app/hibiki/reader/PopupEngineHolder.kt`：

```kotlin
package app.hibiki.reader

import android.content.Context
import app.hibiki.reader.constants.ChannelNames
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant

/**
 * Builds and caches one warm FlutterEngine running the `popupMain` Dart
 * entrypoint inside the :popup process. External dictionary lookups
 * (PROCESS_TEXT / SEND / TRANSLATE / hibiki://lookup) reuse this engine so
 * the nested-capable Flutter popup (PopupDictionaryPage) replaces the old
 * native WebView popup.
 *
 * The `/popup` channel handler is registered BEFORE executeDartEntrypoint
 * because Dart's PopupChannel.init polls `getInitialProcessText` as soon as
 * the engine boots; registering after execute would lose the first word.
 */
object PopupEngineHolder {
    const val ENGINE_ID: String = "hibiki_popup_engine"
    private const val ENTRYPOINT: String = "popupMain"

    @Volatile
    private var pendingText: String = ""

    @Volatile
    private var onFinish: (() -> Unit)? = null

    private var channel: MethodChannel? = null

    fun setPendingText(text: String) {
        pendingText = text
    }

    fun setOnFinish(callback: (() -> Unit)?) {
        onFinish = callback
    }

    /** Returns true when the engine had to be created now (cold start). */
    fun ensureEngine(context: Context): Boolean {
        val cache = FlutterEngineCache.getInstance()
        if (cache.get(ENGINE_ID) != null) return false

        val engine = FlutterEngine(context.applicationContext, null, false)
        GeneratedPluginRegistrant.registerWith(engine)

        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, ChannelNames.POPUP)
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "getInitialProcessText" -> {
                    val map = HashMap<String, Any>()
                    map["text"] = pendingText
                    map["charIndex"] = -1
                    result.success(map)
                }
                "finishPopup" -> {
                    result.success(null)
                    onFinish?.invoke()
                }
                else -> result.notImplemented()
            }
        }
        channel = ch

        val bundlePath = FlutterInjector.instance().flutterLoader().findAppBundlePath()
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(bundlePath, ENTRYPOINT)
        )
        cache.put(ENGINE_ID, engine)
        return true
    }

    /** Warm-reuse / onNewIntent path: push a new term into the running Dart app. */
    fun pushProcessText(text: String) {
        if (text.isBlank()) return
        pendingText = text
        val args = HashMap<String, Any>()
        args["text"] = text
        args["charIndex"] = -1
        channel?.invokeMethod("onNewProcessText", args)
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `flutter test --no-pub test/pages/popup_dict_flutter_activity_static_test.dart`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add hibiki/android/app/src/main/java/app/hibiki/reader/PopupEngineHolder.kt hibiki/test/pages/popup_dict_flutter_activity_static_test.dart
git commit -m "feat(popup): add warm Flutter engine holder for external lookup"
```

---

## Task 2: PopupDictFlutterActivity（透明 FlutterActivity）

**Files:**
- Create: `hibiki/android/app/src/main/java/app/hibiki/reader/PopupDictFlutterActivity.kt`
- Test: `hibiki/test/pages/popup_dict_flutter_activity_static_test.dart`（追加用例）

- [ ] **Step 1: 追加失败的源码守卫测试（针对 Activity）**

在 `hibiki/test/pages/popup_dict_flutter_activity_static_test.dart` 的 `main()` 末尾追加：

```dart
  const String activityPath =
      'android/app/src/main/java/app/hibiki/reader/PopupDictFlutterActivity.kt';

  test('popup flutter activity is transparent, cached-engine, pushes text', () {
    final String src = File(activityPath).readAsStringSync();
    expect(src, contains('class PopupDictFlutterActivity : FlutterActivity()'));
    // 复用缓存热引擎、不随宿主销毁、透明背景。
    expect(src, contains('getCachedEngineId(): String = PopupEngineHolder.ENGINE_ID'));
    expect(src, contains('shouldDestroyEngineWithHost(): Boolean = false'));
    expect(src, contains('BackgroundMode.transparent'));
    // 冷启动前先设好待查文本，再确保引擎，warm reuse 时显式推送。
    final int setPendingIdx = src.indexOf('PopupEngineHolder.setPendingText');
    final int ensureIdx = src.indexOf('PopupEngineHolder.ensureEngine');
    expect(setPendingIdx, isNonNegative);
    expect(ensureIdx, isNonNegative);
    expect(setPendingIdx, lessThan(ensureIdx),
        reason: '冷启动 executeDartEntrypoint 前必须先 setPendingText');
    expect(src, contains('PopupEngineHolder.pushProcessText'));
    // onNewIntent 走热推送。
    expect(src, contains('override fun onNewIntent('));
    // 取词回退顺序：PROCESS_TEXT → EXTRA_TEXT → hibiki://lookup?word。
    final String extractSrc = _functionSource(
      src,
      'private fun extractProcessText(intent: Intent?): String? {',
      // 函数后没有更多方法时读到类结尾的 '}'，用文件末尾兜底。
      '\n}',
    );
    final int pIdx = extractSrc.indexOf('EXTRA_PROCESS_TEXT');
    final int tIdx = extractSrc.indexOf('EXTRA_TEXT');
    final int uIdx = extractSrc.indexOf('"lookup"');
    expect(pIdx, isNonNegative);
    expect(tIdx, greaterThan(pIdx));
    expect(uIdx, greaterThan(tIdx));
    // 销毁时清掉 onFinish，避免陈旧 activity 被 finish。
    expect(src, contains('PopupEngineHolder.setOnFinish(null)'));
  });
}

String _functionSource(String source, String startToken, String endToken) {
  final int start = source.indexOf(startToken);
  expect(start, isNonNegative, reason: 'missing $startToken');
  final int end = source.indexOf(endToken, start + startToken.length);
  expect(end, greaterThan(start), reason: 'missing $endToken after $startToken');
  return source.substring(start, end);
}
```

注意：把 `_functionSource` 放在文件底部（与现有 `native_popup_dictionary_static_test.dart` 同范式）。`main()` 闭合的 `}` 要在追加用例之后。

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test --no-pub test/pages/popup_dict_flutter_activity_static_test.dart`
Expected: FAIL — `PopupDictFlutterActivity.kt` 不存在。

- [ ] **Step 3: 创建 PopupDictFlutterActivity.kt**

创建 `hibiki/android/app/src/main/java/app/hibiki/reader/PopupDictFlutterActivity.kt`：

```kotlin
package app.hibiki.reader

import android.content.Intent
import android.os.Bundle
import io.flutter.embedding.android.FlutterActivity

/**
 * Transparent FlutterActivity (in the :popup process) that hosts the warm
 * popup engine and renders the nested-capable Flutter PopupDictionaryPage for
 * external dictionary lookups. Replaces the old native PopupDictActivity for
 * the PROCESS_TEXT / SEND / TRANSLATE / hibiki://lookup entry points.
 */
class PopupDictFlutterActivity : FlutterActivity() {
    private var engineWasCold: Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        // Set the term BEFORE ensureEngine: a cold start executes the Dart
        // entrypoint inside ensureEngine and Dart immediately polls
        // getInitialProcessText.
        val text: String = extractProcessText(intent).orEmpty()
        PopupEngineHolder.setPendingText(text)
        engineWasCold = PopupEngineHolder.ensureEngine(this)
        PopupEngineHolder.setOnFinish { runOnUiThread { finish() } }
        super.onCreate(savedInstanceState)
        if (!engineWasCold) {
            // Warm reuse: Dart is already mounted and won't re-poll
            // getInitialProcessText, so push the new term explicitly.
            PopupEngineHolder.pushProcessText(text)
        }
    }

    override fun getCachedEngineId(): String = PopupEngineHolder.ENGINE_ID

    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun getBackgroundMode(): BackgroundMode = BackgroundMode.transparent

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        PopupEngineHolder.pushProcessText(extractProcessText(intent).orEmpty())
    }

    override fun onDestroy() {
        PopupEngineHolder.setOnFinish(null)
        super.onDestroy()
    }

    private fun extractProcessText(intent: Intent?): String? {
        if (intent == null) return null
        intent.getCharSequenceExtra(Intent.EXTRA_PROCESS_TEXT)?.toString()?.let { return it }
        intent.getCharSequenceExtra(Intent.EXTRA_TEXT)?.toString()?.let { return it }
        intent.data?.let { uri ->
            if (uri.scheme == "hibiki" && uri.host == "lookup") {
                uri.getQueryParameter("word")?.trim()?.takeIf { it.isNotEmpty() }
                    ?.let { return it }
            }
        }
        return null
    }
}
```

- [ ] **Step 4: 运行测试确认通过**

Run: `flutter test --no-pub test/pages/popup_dict_flutter_activity_static_test.dart`
Expected: PASS。

- [ ] **Step 5: 提交**

```bash
git add hibiki/android/app/src/main/java/app/hibiki/reader/PopupDictFlutterActivity.kt hibiki/test/pages/popup_dict_flutter_activity_static_test.dart
git commit -m "feat(popup): add transparent Flutter activity for external lookup"
```

---

## Task 3: Manifest 注册新 Activity 并迁移 intent-filter

**Files:**
- Modify: `hibiki/android/app/src/main/AndroidManifest.xml`（当前 PopupDictActivity 在第 98-130 行附近）
- Test: `hibiki/test/pages/popup_external_manifest_test.dart`

- [ ] **Step 1: 写失败的 manifest 守卫测试**

创建 `hibiki/test/pages/popup_external_manifest_test.dart`：

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const String manifestPath = 'android/app/src/main/AndroidManifest.xml';

  String activityBlock(String src, String activityName) {
    final int start = src.indexOf('android:name="$activityName"');
    expect(start, isNonNegative, reason: '缺少 activity $activityName');
    // 回退到 <activity 起点，前进到该 activity 的闭合 </activity>。
    final int open = src.lastIndexOf('<activity', start);
    final int close = src.indexOf('</activity>', start);
    expect(open, isNonNegative);
    expect(close, greaterThan(open));
    return src.substring(open, close);
  }

  test('external lookup intent-filters point to PopupDictFlutterActivity', () {
    final String src = File(manifestPath).readAsStringSync();
    final String flutterBlock = activityBlock(src, '.PopupDictFlutterActivity');

    expect(flutterBlock, contains('android.intent.action.PROCESS_TEXT'));
    expect(flutterBlock, contains('android.intent.action.SEND'));
    expect(flutterBlock, contains('android.intent.action.TRANSLATE'));
    expect(flutterBlock, contains('android:scheme="hibiki"'));
    expect(flutterBlock, contains('android:host="lookup"'));
    // 仍跑在独立 popup 进程、透明主题、singleTop。
    expect(flutterBlock, contains('android:process=":popup"'));
    expect(flutterBlock, contains('@style/PopupDictTheme'));
    expect(flutterBlock, contains('android:launchMode="singleTop"'));
  });

  test('legacy native PopupDictActivity no longer holds intent-filters', () {
    final String src = File(manifestPath).readAsStringSync();
    final String nativeBlock = activityBlock(src, '.PopupDictActivity');
    expect(nativeBlock, isNot(contains('<intent-filter>')),
        reason: '原生 Activity 应失活（暂留定义，无 filter）');
  });
}
```

- [ ] **Step 2: 运行测试确认失败**

Run: `flutter test --no-pub test/pages/popup_external_manifest_test.dart`
Expected: FAIL — manifest 里还没有 `.PopupDictFlutterActivity`，且 `.PopupDictActivity` 仍有 4 个 intent-filter。

- [ ] **Step 3: 改 manifest**

在 `hibiki/android/app/src/main/AndroidManifest.xml` 中，把现有 `.PopupDictActivity` 块（第 98-130 行）替换为下面**两个** `<activity>`：保留原生 Activity 定义但删掉它的全部 `<intent-filter>`，并新增带 4 个 filter 的 Flutter Activity。

```xml
        <!-- 失活：暂留作回退，本轮不删；intent-filter 已迁到 PopupDictFlutterActivity -->
        <activity
            android:name=".PopupDictActivity"
            android:theme="@style/PopupDictTheme"
            android:process=":popup"
            android:taskAffinity="app.hibiki.reader.popup"
            android:excludeFromRecents="true"
            android:autoRemoveFromRecents="true"
            android:launchMode="singleTop"
            android:exported="false"
            android:hardwareAccelerated="true"
            android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"
            android:windowSoftInputMode="adjustResize" />

        <activity
            android:name=".PopupDictFlutterActivity"
            android:theme="@style/PopupDictTheme"
            android:process=":popup"
            android:taskAffinity="app.hibiki.reader.popup"
            android:excludeFromRecents="true"
            android:autoRemoveFromRecents="true"
            android:launchMode="singleTop"
            android:exported="true"
            android:hardwareAccelerated="true"
            android:configChanges="orientation|keyboardHidden|keyboard|screenSize|smallestScreenSize|locale|layoutDirection|fontScale|screenLayout|density|uiMode"
            android:windowSoftInputMode="adjustResize">
            <intent-filter>
                <action android:name="android.intent.action.PROCESS_TEXT" />
                <data android:mimeType="text/plain" />
                <category android:name="android.intent.category.DEFAULT" />
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.SEND" />
                <category android:name="android.intent.category.DEFAULT" />
                <data android:mimeType="text/*" />
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.TRANSLATE" />
                <category android:name="android.intent.category.DEFAULT" />
            </intent-filter>
            <intent-filter>
                <action android:name="android.intent.action.VIEW" />
                <category android:name="android.intent.category.DEFAULT" />
                <category android:name="android.intent.category.BROWSABLE" />
                <data android:scheme="hibiki" android:host="lookup" />
            </intent-filter>
        </activity>
```

注意：原生 Activity 的 `android:exported` 改为 `false`（不再被外部直接拉起）。

- [ ] **Step 4: 运行测试确认通过**

Run: `flutter test --no-pub test/pages/popup_external_manifest_test.dart`
Expected: PASS（两个用例）。

- [ ] **Step 5: 提交**

```bash
git add hibiki/android/app/src/main/AndroidManifest.xml hibiki/test/pages/popup_external_manifest_test.dart
git commit -m "feat(popup): route external lookup intents to Flutter popup activity"
```

---

## Task 4: Dart 嵌套栈行为守卫测试

说明：`PopupDictionaryPage` 的嵌套能力**已实现**，本 Task 是把"点词 → push 新层 → 返回 → pop"这一行为用 widget 测**锁死**，防回归。栈管理在 `_pushSearch` / `_popAt` / `_stack.removeRange`；WebView 内容无法在 widget 测中点击，故通过驱动 `DictionaryPopupLayer` 的 `onTextSelected` 回调路径来验证栈增长。

**Files:**
- Test: `hibiki/test/pages/popup_dictionary_page_nested_test.dart`
- 参考（不改）：`hibiki/lib/src/pages/implementations/popup_dictionary_page.dart`

- [ ] **Step 1: 先确认 PopupDictionaryPage 的可测注入点**

阅读 `popup_dictionary_page.dart`，确认：base 层 `DictionaryPopupLayer.onTextSelected`（第 228-233 行）在 `_stack.length>1` 时 `removeRange(1,...)` 再 `_pushSearch`；嵌套层经 `buildNestedPopupLayer(onPush:...)`（第 200-206 行）。`pushNestedPopup` 来自 `DictionaryPageMixin`，会触发一次词典查询（依赖 `mixinAppModel`）。
若 `pushNestedPopup` 强依赖真实 `AppModel` 初始化导致 widget 测难以隔离，则本 Task 降级为**源码守卫测试**（断言 `popup_dictionary_page.dart` 含 `pushNestedPopup(`、`popNestedPopupAt(`、`_stack.removeRange(1, _stack.length)`、`buildNestedPopupLayer(`，且 `PopScope` 的 `onPopInvokedWithResult` 在 `_stack.length > 1` 时 `_popAt(_stack.length - 1)`）。先尝试 widget 测，不可行再降级，并在提交信息注明。

- [ ] **Step 2: 写守卫测试（源码守卫版，稳定不依赖引擎）**

创建 `hibiki/test/pages/popup_dictionary_page_nested_test.dart`：

```dart
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const String pagePath =
      'lib/src/pages/implementations/popup_dictionary_page.dart';

  test('popup dictionary page keeps the nested lookup stack contract', () {
    final String src = File(pagePath).readAsStringSync();
    // 共享嵌套实现（与 app 内/桌面同源）。
    expect(src, contains('with DictionaryPageMixin'));
    expect(src, contains('pushNestedPopup('));
    expect(src, contains('popNestedPopupAt('));
    expect(src, contains('buildNestedPopupLayer('));
    // base 层点词/点链：先截断旧栈再 push 新层（嵌套下钻）。
    expect(src, contains('_stack.removeRange(1, _stack.length)'));
    expect(src, contains('onTextSelected:'));
    expect(src, contains('onLinkClick:'));
    // 返回手势逐层 pop，到底才关闭。
    expect(src, contains('PopScope'));
    expect(src, contains('_popAt(_stack.length - 1)'));
    expect(src, contains('PopupChannel.instance.finishPopup()'));
  });
}
```

- [ ] **Step 3: 运行测试确认通过（行为已存在）**

Run: `flutter test --no-pub test/pages/popup_dictionary_page_nested_test.dart`
Expected: PASS（守卫现有实现）。若某断言 FAIL，说明实际代码与本计划引用不符，停下来核对 `popup_dictionary_page.dart` 当前内容再调整断言字符串（不要改产品代码去迁就测试）。

- [ ] **Step 4: 提交**

```bash
git add hibiki/test/pages/popup_dictionary_page_nested_test.dart
git commit -m "test(popup): guard PopupDictionaryPage nested lookup stack contract"
```

---

## Task 5: 全量校验（analyze / format / 全测 / release 构建）

**Files:** 无（仅校验）

- [ ] **Step 1: 格式化**

Run（在 `hibiki/` 下）: `dart format .`
Expected: 仅本轮新增 Dart 文件被格式化，无大面积 churn。

- [ ] **Step 2: 静态分析**

Run（在 `hibiki/` 下）: `flutter analyze`
Expected: No issues found（或仅与本改动无关的既有告警）。

- [ ] **Step 3: 跑全量测试**

Run（在 `hibiki/` 下）: `flutter test --no-pub`
Expected: 全绿，含三个新测试文件。

- [ ] **Step 4: Android release 构建（manifest/原生改动必做）**

Run（在 `hibiki/android/` 下，Windows）: `.\gradlew.bat :app:assembleRelease`
Expected: BUILD SUCCESSFUL。
注意：若单独跑 assembleRelease 因 GeneratedPluginRegistrant 残留 integration_test 失败，改用 `flutter build apk --release`（见记忆 audio-sources 经验）。

- [ ] **Step 5: 提交（若 format 产生改动）**

```bash
git add -- hibiki/lib hibiki/test
git commit -m "chore(popup): format external lookup changes" || echo "nothing to format-commit"
```

---

## Task 6: 设备验证（CLAUDE.md 强制，查词类必做）

**Files:** 无（手动验证 + 留证据到 `.codex-test/`，不入库）

- [ ] **Step 1: 装 release/debug APK 到模拟器或指定设备**

参考 `docs/agent/integration-testing.md` 选 emulator serial、provision。

- [ ] **Step 2: 触发 hibiki://lookup 深链**

Run: `adb shell am start -a android.intent.action.VIEW -d "hibiki://lookup?word=日本語"`
Expected: 弹出 Flutter `PopupDictionaryPage`（贴顶卡片、透明背景浮于桌面），自动查 `日本語`。

- [ ] **Step 3: 触发 PROCESS_TEXT**

Run: `adb shell am start -a android.intent.action.PROCESS_TEXT --es android.intent.extra.PROCESS_TEXT "勉強"`
Expected: 同上弹窗，查 `勉強`。

- [ ] **Step 4: 验证嵌套 + 返回**

在弹窗词条里点一个词 → 出现层叠的嵌套层（新卡片）；按返回手势 → 逐层回退；回到底层再返回/点外 → `finish()` 关闭。截图取证到 `.codex-test/`。

- [ ] **Step 5: 验证热引擎复用**

关闭弹窗后再次 `am start ... hibiki://lookup?word=漢字`，应**明显更快**（无冷启动），且显示新词（验证 `onNewProcessText` 生效）。

- [ ] **Step 6: 记录结果**

把验证结论（含截图路径）回填到设计文档 §8，并在本轮总结里说明 4 个入口的实测情况。若某入口异常，按根因修复（不要加延迟/重试绕过），修完重验。

---

## 后续（另开一轮，不在本计划）

设备验证全绿后，单独一轮删死代码：`PopupDictActivity.kt` + `HoshiBridge.kt` + `PopupDbReader.kt` + `native/hoshidicts/hoshidicts_jni.cpp` 的 HoshiBridge 绑定 + 失活的原生 `<activity>` + 旧 `native_popup_dictionary_static_test.dart`。注意 `assets/popup/*` 被 Flutter `DictionaryPopupWebView` 共享，**不删**。

---

## Self-Review

- **Spec coverage**：设计 §4.1→Task 2、§4.2→Task 1、§4.3→Task 3、§4.4→零改动(Task 4 守卫)、§5 数据流→Task 1/2 实现 + Task 6 验证、§6 清理→"后续"段、§7 风险→Task 1(插件全量)/Task 2(透明+时序)、§8 测试→Task 1/2/3/4 + Task 6、§9 验收→Task 5/6。无遗漏。
- **Placeholder scan**：无 TBD/TODO；每个代码步骤含完整代码。
- **Type consistency**：`PopupEngineHolder.ENGINE_ID`/`ensureEngine`/`setPendingText`/`setOnFinish`/`pushProcessText` 在 Task 1 定义、Task 2 调用，签名一致；channel 方法名 `getInitialProcessText`/`finishPopup`/`onNewProcessText` 与 Dart `popup_channel.dart` 一致；`ChannelNames.POPUP` 为既有常量。
