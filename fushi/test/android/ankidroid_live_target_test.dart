import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../helpers/source_guard.dart';

/// Executes the production resolver on the JVM. Only the Android boundary is
/// replaced: PackageManager exposes a mutable set of currently enabled providers.
/// Each scenario changes that set within one Java process, without invalidation.
void main() {
  const String javaRoot = 'android/app/src/main/java/app/fushi/reader';
  late Directory sandbox;

  String jdkTool(String name) {
    final String? javaHome = Platform.environment['JAVA_HOME'];
    if (javaHome != null) {
      final File executable = File(
        '$javaHome/bin/$name${Platform.isWindows ? '.exe' : ''}',
      );
      if (executable.existsSync()) return executable.path;
    }
    return name;
  }

  setUpAll(() async {
    sandbox = Directory.systemTemp.createTempSync('ankidroid-live-target-');
    addTearDown(() => sandbox.deleteSync(recursive: true));
    final List<String> sources = <String>[];
    for (final MapEntry<String, String> fixture in _javaFixtures.entries) {
      final File source = File('${sandbox.path}/${fixture.key}');
      source.parent.createSync(recursive: true);
      source.writeAsStringSync(fixture.value);
      sources.add(source.path);
    }
    final File production = File('$javaRoot/AnkiDroidTarget.java');
    sources.add(production.absolute.path);
    final ProcessResult compile = await Process.run(jdkTool('javac'), <String>[
      '-encoding',
      'UTF-8',
      '-d',
      sandbox.path,
      ...sources,
    ]);
    expect(
      compile.exitCode,
      0,
      reason:
          'Production Java must compile: ${compile.stdout}\n'
          '${compile.stderr}',
    );
  });

  for (final String scenario in <String>[
    'absent-available-absent',
    'parallel-main-priority',
    'provider-disabled-reenabled',
  ]) {
    test('resolver observes $scenario within the same process', () async {
      final ProcessResult result = await Process.run(jdkTool('java'), <String>[
        '-cp',
        sandbox.path,
        'app.fushi.reader.LiveTargetHarness',
        scenario,
      ]);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout.toString().trim(), 'PASS $scenario');
    });
  }

  test('long-lived helper resolves its provider on each operation', () {
    final String helper = maskComments(
      File('$javaRoot/AnkiDroidHelper.java').readAsStringSync(),
    );
    expect(
      RegExp(
        r'private\s+(?:final\s+)?AnkiProvider\s+\w+\s*[;=]',
      ).hasMatch(helper),
      isFalse,
      reason: 'A helper may outlive installation, removal or provider changes.',
    );
    expect(
      methodBody(helper, 'public AnkiProvider getApi()'),
      contains('AnkiProviders.forContext(mContext)'),
      reason:
          'Rechecking availability must also refresh the provider instance.',
    );
    for (final String signature in <String>[
      'private SparseArray<List<AnkiNote>> findDuplicateNotesByKeys(',
      'public Long findModelIdByName(',
      'public Long findDeckIdByName(',
    ]) {
      expect(
        methodBody(helper, signature),
        contains('getApi()'),
        reason: '$signature must use a current operation-local provider.',
      );
    }
  });
}

const Map<String, String> _javaFixtures = <String, String>{
  'android/content/Context.java': r'''
package android.content;
import android.content.pm.PackageManager;
public abstract class Context {
    public abstract PackageManager getPackageManager();
}
''',
  'android/content/pm/PackageManager.java': r'''
package android.content.pm;
public abstract class PackageManager {
    public abstract ProviderInfo resolveContentProvider(String authority, int flags);
}
''',
  'android/content/pm/ProviderInfo.java': r'''
package android.content.pm;
public class ProviderInfo {}
''',
  'android/net/Uri.java': r'''
package android.net;
// The resolver does not use Uri; these signatures compile its unrelated rebase API.
public abstract class Uri {
    public abstract String getAuthority();
    public abstract Builder buildUpon();
    public abstract static class Builder {
        public abstract Builder authority(String authority);
        public abstract Uri build();
    }
}
''',
  'app/fushi/reader/LiveTargetHarness.java': r'''
package app.fushi.reader;

import android.content.Context;
import android.content.pm.PackageManager;
import android.content.pm.ProviderInfo;
import java.util.HashSet;
import java.util.Set;

public final class LiveTargetHarness {
    private static final String MAIN = "com.ichi2.anki";
    // BUG-2370：必须是官方**真实发布过**的并行版包名（小写后缀，见
    // 上游 tools/parallel-package-release.sh 的 customSuffix）。此前这里写的是
    // 自己编的 ".A"，与当时同样写错的生产候选表一起错，于是这条用例恒绿——
    // 用户装着 AnkiDroid.E 被判「未安装」，这个「实跑 resolve」的测试却毫无反应。
    private static final String PARALLEL = MAIN + ".e";

    private static final class MutablePackages extends PackageManager {
        final Set<String> authorities = new HashSet<>();

        void enable(String packageName) {
            authorities.add(packageName + ".flashcards");
        }

        void disable(String packageName) {
            authorities.remove(packageName + ".flashcards");
        }

        @Override public ProviderInfo resolveContentProvider(String authority, int flags) {
            return authorities.contains(authority) ? new ProviderInfo() : null;
        }
    }

    private static final class Device extends Context {
        final MutablePackages packages = new MutablePackages();
        @Override public PackageManager getPackageManager() { return packages; }
    }

    private static void expectTarget(Device device, String expected) {
        AnkiDroidTarget actual = AnkiDroidTarget.resolve(device);
        if (expected == null) {
            if (actual != null) throw new AssertionError("Expected unavailable, got " + actual.packageName);
            return;
        }
        if (actual == null || !expected.equals(actual.packageName)) {
            throw new AssertionError("Expected " + expected + ", got " +
                (actual == null ? "unavailable" : actual.packageName));
        }
        if (!(expected + ".flashcards").equals(actual.authority) ||
            !(expected + ".permission.READ_WRITE_DATABASE").equals(actual.permission)) {
            throw new AssertionError("Provider authority and permission must follow the selected package");
        }
        if (actual.isMainBuild() != MAIN.equals(expected)) {
            throw new AssertionError("Provider implementation selection must follow the selected package");
        }
    }

    public static void main(String[] args) {
        Device device = new Device();
        switch (args[0]) {
            case "absent-available-absent":
                expectTarget(device, null);
                device.packages.enable(MAIN);
                expectTarget(device, MAIN);
                device.packages.disable(MAIN);
                expectTarget(device, null);
                break;
            case "parallel-main-priority":
                device.packages.enable(PARALLEL);
                expectTarget(device, PARALLEL);
                device.packages.enable(MAIN);
                expectTarget(device, MAIN);
                device.packages.disable(MAIN);
                expectTarget(device, PARALLEL);
                device.packages.disable(PARALLEL);
                expectTarget(device, null);
                break;
            case "provider-disabled-reenabled":
                device.packages.enable(MAIN);
                expectTarget(device, MAIN);
                device.packages.disable(MAIN);
                expectTarget(device, null);
                device.packages.enable(MAIN);
                expectTarget(device, MAIN);
                break;
            default: throw new AssertionError("Unknown scenario: " + args[0]);
        }
        System.out.println("PASS " + args[0]);
    }
}
''',
};
