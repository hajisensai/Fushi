import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// The Android application identity lives in exactly one place
/// (`android/app/build.gradle`). Everything that has to name the app package —
/// most importantly the R8 keep rule that shields the whole app from
/// obfuscation and class merging — must be derived from it, never hardcoded to
/// a stale copy.
///
/// This guard exists because the W8 `hibiki/` -> `fushi/` rename moved
/// `applicationId` to `app.fushi.reader` but left
/// `-keep class app.hibiki.reader.** { *; }` behind in proguard-rules.pro. The
/// rule then matched zero classes, so every app-side class entered R8's
/// optimization surface for the first time; R8 merged the anonymous
/// `FullTypeReference` subclasses that Injekt's reified `addSingleton` /
/// `addSingletonFactory` inline into `MihonChannelHandler`, `genericSuperclass`
/// stopped being a `ParameterizedType`, and every launch died in
/// `MainActivity.onCreate` with
/// "Internal error: TypeReference constructed without actual type information".
///
/// A stale keep rule is invisible: it is valid ProGuard syntax, R8 does not warn
/// about rules that match nothing, and `flutter analyze` cannot see build config
/// at all. Only a release build on a real device surfaces it. Hence this guard.
void main() {
  final File buildGradle = File('android/app/build.gradle');
  final File proguard = File('android/app/proguard-rules.pro');

  /// Active (non-comment, non-blank) lines of a ProGuard config.
  List<String> activeRules(String source) => source
      .split('\n')
      .map((String line) => line.trim())
      .where((String line) => line.isNotEmpty && !line.startsWith('#'))
      .toList();

  String? singleQuotedValue(String source, String key) {
    final RegExpMatch? match =
        RegExp(r'^\s*' + key + r'\s+"([^"]+)"', multiLine: true)
            .firstMatch(source);
    return match?.group(1);
  }

  test('R8 keep rule for the app package tracks applicationId', () {
    final String gradle = buildGradle.readAsStringSync();
    final String? applicationId = singleQuotedValue(gradle, 'applicationId');
    final String? namespace = singleQuotedValue(gradle, 'namespace');

    expect(applicationId, isNotNull,
        reason: 'android/app/build.gradle must declare applicationId.');
    expect(namespace, applicationId,
        reason: 'namespace and applicationId must be the same package, '
            'otherwise a single keep rule cannot cover the app.');

    final List<String> rules = activeRules(proguard.readAsStringSync());

    expect(
      rules,
      contains('-keep class $applicationId.** { *; }'),
      reason: 'proguard-rules.pro must keep the whole app package '
          '($applicationId). Without it R8 class-merges the anonymous '
          'FullTypeReference subclasses Injekt inlines into '
          'MihonChannelHandler and the app crashes on launch. If the app is '
          'renamed again, this rule must be renamed in the same commit.',
    );
  });

  test('no keep rule still names a stale app.<name>.reader package', () {
    final String gradle = buildGradle.readAsStringSync();
    final String applicationId = singleQuotedValue(gradle, 'applicationId')!;

    final RegExp appPackage = RegExp(r'app\.[A-Za-z0-9_]+\.reader');
    final List<String> stale = <String>[];
    for (final String rule in activeRules(proguard.readAsStringSync())) {
      if (!rule.startsWith('-keep')) continue;
      for (final RegExpMatch match in appPackage.allMatches(rule)) {
        if (match.group(0) != applicationId) {
          stale.add(rule);
        }
      }
    }

    expect(
      stale,
      isEmpty,
      reason: 'These keep rules name an app package that is not the current '
          'applicationId ($applicationId), so they match zero classes and '
          'silently drop the app out of R8 protection: $stale',
    );
  });

  test('Injekt FullTypeReference subclasses are excluded from class merging',
      () {
    final List<String> rules = activeRules(proguard.readAsStringSync());

    // Package-independent backstop: even if the app package keep rule is ever
    // narrowed or the app is renamed again, the reflective-generics classes
    // Injekt depends on must keep their superclass signature. allowshrinking +
    // allowobfuscation is deliberate: it keeps them removable and renameable
    // (no size regression) while opting them out of horizontal/vertical class
    // merging — the same pattern R8 ships for Gson's TypeToken.
    const String base = 'uy.kohesive.injekt.api.FullTypeReference';
    expect(
      rules,
      contains('-keep,allowshrinking,allowobfuscation class * extends $base'),
      reason: 'Subclasses of $base are generated at every reified '
          'addSingleton/addSingletonFactory call site and are read back via '
          'javaClass.genericSuperclass. R8 class merging destroys that '
          'signature.',
    );
    expect(
        rules, contains('-keep,allowshrinking,allowobfuscation class $base'));
    expect(
      rules,
      contains(
          '-keep,allowshrinking,allowobfuscation class uy.kohesive.injekt.api.TypeReference'),
    );
  });

  test('guard premise still holds: release minifies and Injekt is inlined', () {
    final String gradle = buildGradle.readAsStringSync();
    expect(
      gradle,
      contains('minifyEnabled true'),
      reason:
          'If minification is ever disabled, this whole guard is moot — but '
          'disabling it is a size/startup regression, not a fix. Removing R8 '
          'must be a deliberate, reviewed decision, not a silent workaround for '
          'the next keep-rule bug.',
    );

    final String applicationId = singleQuotedValue(gradle, 'applicationId')!;
    final File handler = File(
      'android/app/src/main/kotlin/${applicationId.replaceAll('.', '/')}'
      '/mihon/MihonChannelHandler.kt',
    );
    expect(handler.existsSync(), isTrue,
        reason: 'MihonChannelHandler must live under the applicationId package '
            'so the app-wide keep rule covers it.');

    final String source = handler.readAsStringSync();
    expect(
      source,
      contains('uy.kohesive.injekt'),
      reason: 'If Injekt usage disappears from the app, the FullTypeReference '
          'keep rules above become dead weight and should be revisited.',
    );
    expect(
      RegExp(r'addSingleton(Factory)?\s*[({]').hasMatch(source),
      isTrue,
      reason: 'These reified inline calls are what generate the '
          'FullTypeReference subclasses the keep rules protect.',
    );
  });

  test('an optional manga-extension failure cannot brick MainActivity', () {
    // Defence in depth for the same crash class. The keep rule above removes
    // *this* trigger, but MihonChannelHandler's constructor still runs Injekt
    // wiring on the synchronous onCreate path, so any future failure in that
    // optional subsystem would again make the app unlaunchable. It must be
    // contained: construction guarded, field left null, registration skipped.
    // The Dart side already turns an unregistered channel into
    // MihonRuntimeException('UNAVAILABLE'), so degrading is a supported state.
    final String activity =
        File('android/app/src/main/java/app/fushi/reader/MainActivity.java')
            .readAsStringSync();

    final int construct = activity.indexOf('new MihonChannelHandler(');
    expect(construct, isNonNegative);

    final String before = activity.substring(0, construct);
    final int tryIndex = before.lastIndexOf('try {');
    final int stmtEnd = before.lastIndexOf(';');
    expect(
      tryIndex,
      greaterThan(stmtEnd),
      reason: 'new MihonChannelHandler(...) must be the first statement inside '
          'a try block, otherwise an Injekt/extension-loader failure escapes '
          'into onCreate and the whole app fails to start.',
    );

    final int catchIndex = activity.indexOf('catch (Throwable', construct);
    expect(catchIndex, isNonNegative,
        reason: 'The guard must catch Throwable: the observed failure was an '
            'IllegalArgumentException thrown from a static initializer path, '
            'and R8/linkage failures surface as Errors, not Exceptions.');

    final int register = activity.indexOf('mihonChannelHandler.register(');
    expect(register, isNonNegative);
    // Narrow window on purpose: MainActivity null-checks the same field at the
    // teardown site too, and a whole-file `contains` is satisfied by that
    // unrelated check even when the register site is left unguarded.
    expect(
      activity.substring(register < 120 ? 0 : register - 120, register),
      contains('mihonChannelHandler != null'),
      reason: 'If construction was skipped the field is null; registering it '
          'unconditionally would just move the crash to configureFlutterEngine.',
    );
  });
}
