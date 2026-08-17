import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// BUG-1702 守卫：Android release 的 R8 规则必须完整保住「宿主提供给 Mihon 扩展的
/// ABI 面」。
///
/// 为什么需要这条守卫：Mihon 扩展 APK 是独立编译的第三方 dex，把宿主提供的一切
/// （Kotlin 运行时、okhttp、jsoup、rx、injekt、source-api……）都当 compileOnly，
/// 字节码里写死的是**未混淆的原名**。宿主 APK 里少一个包、或某个包被 R8 改了名，
/// 扩展加载就 NoClassDefFoundError → `MihonHostException(LOAD_FAILED)`。
///
/// 这类回归**在 debug 构建上永远复现不了**（debug 不 minify，类名全在），只在
/// release APK 上必现，所以没有静态守卫就只能等用户报障。实测过的真实事故：
/// `kotlin.**` 从未被 keep，R8 把宿主的 `kotlin.Lazy` 改名成 `W4.f`，于是**每一个**
/// Kotlin 扩展在构造函数第一条 `invoke-static kotlin.LazyKt.lazy` 上就炸。
///
/// 基准清单不是拍脑袋列的，是从两个真实 Keiyoushi 扩展的 dex 里解析出的
/// 「引用了但自己没定义」的类（即必须由宿主提供的），来源见 [_hostAbiReferences]。
void main() {
  group('Mihon 扩展宿主 ABI 的 R8 keep 覆盖', () {
    late final File rules = File('android/app/proguard-rules.pro');

    test('proguard-rules.pro 存在（路径变了要同步改本守卫）', () {
      expect(
        rules.existsSync(),
        isTrue,
        reason: '找不到 ${rules.path}；R8 规则文件挪位置了就必须同步更新这条守卫。',
      );
    });

    test('每个扩展会引用的宿主类都被一条不可改名的 keep 覆盖', () {
      final List<_KeepRule> keeps = _parseKeepRules(rules.readAsStringSync());
      expect(keeps, isNotEmpty,
          reason: 'proguard-rules.pro 里一条 -keep class 都没解析出来');

      final List<String> uncovered = <String>[
        for (final String type in _hostAbiReferences)
          if (!keeps.any((_KeepRule rule) => rule.covers(type))) type,
      ];

      expect(
        uncovered,
        isEmpty,
        reason: '这些类扩展要用、宿主却没有以原名保住，release APK 上会让扩展加载失败：\n'
            '${uncovered.join('\n')}\n'
            '修法：在 android/app/proguard-rules.pro 的「Mihon 扩展宿主 ABI」区块补 keep。',
      );
    });
  });
}

/// 宿主必须以原名提供的类。
///
/// 提取方式：解出扩展 APK 的 classes.dex，取 `type_ids` 减去 `class_defs`
/// （= 引用了但本 dex 没定义的类），再去掉由 Android 系统 classloader 提供的
/// `android.` / `java.` / `javax.` / `dalvik.` 与纯注解包。
///
/// 样本（Keiyoushi 官方仓库，两个 extensions-lib 大版本各一）：
/// - `tachiyomi-all.ahottie-v1.6.4.apk`（lib 1.6）
/// - `tachiyomi-all.akuma-v1.4.10.apk`（lib 1.4）
///
/// 这是**下限**不是全集：换更多扩展只会让清单变长，所以补充样本时只该往里加。
const List<String> _hostAbiReferences = <String>[
  // extensions-lib / source-api（宿主按固定 Mihon commit 编入）
  'eu.kanade.tachiyomi.network.NetworkHelper',
  'eu.kanade.tachiyomi.network.OkHttpExtensionsKt',
  'eu.kanade.tachiyomi.network.RequestsKt',
  'eu.kanade.tachiyomi.source.ConfigurableSource',
  'eu.kanade.tachiyomi.source.SourceFactory',
  'eu.kanade.tachiyomi.source.model.Filter',
  'eu.kanade.tachiyomi.source.model.FilterList',
  'eu.kanade.tachiyomi.source.model.MangasPage',
  'eu.kanade.tachiyomi.source.model.Page',
  'eu.kanade.tachiyomi.source.model.SChapter',
  'eu.kanade.tachiyomi.source.model.SManga',
  'eu.kanade.tachiyomi.source.model.SMangaUpdate',
  'eu.kanade.tachiyomi.source.model.UpdateStrategy',
  'eu.kanade.tachiyomi.source.online.HttpSource',
  // 宿主自己一次都不调，最容易被 R8 整包删掉
  'eu.kanade.tachiyomi.util.JsoupExtensionsKt',
  // Kotlin 运行时：扩展 dex 不打包，构造函数里就会用
  'kotlin.Lazy',
  'kotlin.LazyKt',
  'kotlin.Metadata',
  'kotlin.Result',
  'kotlin.ResultKt',
  'kotlin.collections.CollectionsKt',
  'kotlin.coroutines.Continuation',
  'kotlin.coroutines.intrinsics.IntrinsicsKt',
  'kotlin.coroutines.jvm.internal.Boxing',
  'kotlin.coroutines.jvm.internal.ContinuationImpl',
  'kotlin.coroutines.jvm.internal.SpillingKt',
  'kotlin.io.FilesKt',
  'kotlin.jvm.functions.Function0',
  'kotlin.jvm.functions.Function1',
  'kotlin.jvm.internal.DefaultConstructorMarker',
  'kotlin.jvm.internal.Intrinsics',
  'kotlin.text.StringsKt',
  'kotlin.time.Duration',
  'kotlin.time.DurationKt',
  'kotlin.time.DurationUnit',
  // 网络栈
  'okhttp3.CacheControl',
  'okhttp3.Call',
  'okhttp3.CompressionInterceptor',
  'okhttp3.Gzip',
  'okhttp3.Headers',
  'okhttp3.HttpUrl',
  'okhttp3.Interceptor',
  'okhttp3.OkHttpClient',
  'okhttp3.Request',
  'okhttp3.RequestBody',
  'okhttp3.Response',
  'okhttp3.ResponseBody',
  'okhttp3.brotli.BrotliInterceptor',
  'okhttp3.zstd.Zstd',
  // 解析 / 响应式 / 注入
  'org.jsoup.nodes.Document',
  'org.jsoup.nodes.Element',
  'org.jsoup.select.Elements',
  'rx.Observable',
  'rx.functions.Func1',
  'uy.kohesive.injekt.InjektKt',
  'uy.kohesive.injekt.api.FullTypeReference',
  'uy.kohesive.injekt.api.InjektFactory',
  'uy.kohesive.injekt.api.InjektScope',
];

/// 一条**不允许改名**的 `-keep[,option…] class <pattern>` 规则。
///
/// 带 `allowobfuscation` 的规则在 [_parseKeepRules] 里就被丢掉了：R8 多条 keep 取
/// 并集，只有存在至少一条不可改名的规则，类名才真的保得住。
class _KeepRule {
  const _KeepRule({required this.pattern});

  final String pattern;

  /// ProGuard 通配语义：`**` 跨包匹配（含 `.`），`*` 只在单段内匹配。
  bool covers(String type) => _patternToRegExp(pattern).hasMatch(type);
}

final RegExp _keepLine = RegExp(r'^-keep([^\s]*)\s+class\s+([^\s{]+)');

List<_KeepRule> _parseKeepRules(String source) {
  final List<_KeepRule> rules = <_KeepRule>[];
  for (final String raw in source.split('\n')) {
    final String line = raw.trim();
    if (line.startsWith('#')) continue;
    final RegExpMatch? match = _keepLine.firstMatch(line);
    if (match == null) continue;
    if ((match.group(1) ?? '').contains('allowobfuscation')) continue;
    rules.add(_KeepRule(pattern: match.group(2)!));
  }
  return rules;
}

RegExp _patternToRegExp(String pattern) {
  final StringBuffer out = StringBuffer('^');
  for (int i = 0; i < pattern.length; i++) {
    final String char = pattern[i];
    if (char == '*') {
      final bool isDoubleStar = i + 1 < pattern.length && pattern[i + 1] == '*';
      if (isDoubleStar) {
        out.write('.*');
        i++;
      } else {
        out.write('[^.]*');
      }
    } else if (char == '?') {
      out.write('[^.]');
    } else {
      out.write(RegExp.escape(char));
    }
  }
  out.write(r'$');
  return RegExp(out.toString());
}
