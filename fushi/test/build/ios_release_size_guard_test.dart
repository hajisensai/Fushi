// iOS 出包体积的两道闸（BUG-4655 / BUG-4656）：
//   * 两条 iOS 出包命令都 `--split-debug-info`（不混淆），拆出来的 Dart 符号按序号存 artifact，
//     与 dSYM 同保留期——没有它诊断里的 Dart 栈还原不了；
//   * 未签名 IPA 打包前对每个 Mach-O `strip -x`，strip 后导出符号不变、再核一遍 Runner 的 C ABI。
// slang flat map（BUG-4640）见 slang_flat_map_disabled_guard_test.dart。
import 'dart:io';

import 'package:test/test.dart';

void main() {
  final String desktop = File(
    '../.github/workflows/release-desktop.yml',
  ).readAsStringSync().replaceAll('\r\n', '\n');

  String step(String name) {
    final int at = desktop.indexOf('- name: $name\n');
    expect(at, isNonNegative, reason: '缺少步骤「$name」');
    final int next = desktop.indexOf('\n      - name: ', at + 1);
    return desktop.substring(at, next < 0 ? desktop.length : next);
  }

  int at(String name) => desktop.indexOf('- name: $name\n');

  group('BUG-4655 Dart 调试信息拆分', () {
    const Map<String, String> builds = <String, String>{
      'Build iOS release app (no codesign)': 'build/ios/dart-symbols-unsigned',
      'Build signed iOS App Store IPA': 'build/ios/dart-symbols-testflight',
    };

    test('两条 iOS 出包命令都带 --split-debug-info，且不混淆', () {
      builds.forEach((String name, String dir) {
        final String s = step(name);
        expect(s, contains('--split-debug-info=$dir'), reason: name);
        // runtimeType.toString() 判断在混淆后会坏，混淆只多省 0.7 MB。
        expect(s, isNot(contains('--obfuscate')), reason: name);
      });
    });

    test('Dart 符号按序号存 artifact，与 dSYM 同保留期，不混进 Release 资产', () {
      const Map<String, List<String>> uploads = <String, List<String>>{
        'Upload iOS release Dart symbols (no codesign)': <String>[
          'ios-dart-symbols-unsigned-',
          'fushi/build/ios/dart-symbols-unsigned',
          'Build iOS release app (no codesign)',
          'Upload iOS release dSYMs (no codesign)',
        ],
        'Upload signed iOS archive Dart symbols': <String>[
          'ios-dart-symbols-testflight-',
          'fushi/build/ios/dart-symbols-testflight',
          'Build signed iOS App Store IPA',
          'Upload signed iOS archive dSYMs',
        ],
      };
      uploads.forEach((String name, List<String> spec) {
        final String s = step(name);
        expect(s, contains('actions/upload-artifact@'), reason: name);
        expect(
          s,
          contains(
            'name: ${spec[0]}'
            r'${{ steps.channel.outputs.release_sequence }}',
          ),
          reason: name,
        );
        expect(s, contains('path: ${spec[1]}\n'), reason: name);
        expect(s, contains('continue-on-error: true'), reason: name);
        expect(s, isNot(contains('name: desktop-artifacts-')), reason: name);
        final String dsym = step(spec[3]);
        final String retention = RegExp(
          r'retention-days: (\d+)',
        ).firstMatch(dsym)!.group(1)!;
        expect(s, contains('retention-days: $retention'), reason: name);
        expect(at(name), greaterThan(at(spec[2])), reason: name);
      });
    });
  });

  group('BUG-4656 iOS 包 strip -x', () {
    String prepareStep() => step('Prepare unsigned iOS IPA release asset');
    String stripScript() => File(
      '../tool/ios_strip_local_symbols.sh',
    ).readAsStringSync().replaceAll('\r\n', '\n');

    test('ditto 之后、zip 之前 strip，strip 后再核 Runner 的 C ABI', () {
      final String prepare = prepareStep();
      final int ditto = prepare.indexOf('ditto "\$app_dir"');
      final int strip = prepare.indexOf('tool/ios_strip_local_symbols.sh');
      final int zip = prepare.indexOf('zip -qry');
      expect(ditto, isNonNegative);
      expect(strip, greaterThan(ditto));
      expect(zip, greaterThan(strip));
      expect(
        prepare,
        contains(
          'tool/ios_strip_local_symbols.sh" "\$payload_dir/Payload/Runner.app"',
        ),
      );
      // Release Runner 符号核对那一步的每个 verify_abi，strip 后在发出去的 Runner 上再跑一遍。
      final String verify = step(
        'Verify fushi_p2p + fushi_fsrs + fushi_compute + fushi_web_core + '
        'fushi_rwkv + fushi_music + fushi_corpus symbols are linked into '
        'Runner (iOS release)',
      );
      final Iterable<String> crates = RegExp(
        r'native/(fushi_\w+)/verify_abi\.sh',
      ).allMatches(verify).map((RegExpMatch m) => m.group(1)!);
      expect(crates.length, greaterThanOrEqualTo(7));
      for (final String crate in crates) {
        final RegExp after = RegExp(
          'native/$crate/verify_abi\\.sh"? (--no-plugin )?"\\\$runner" nm',
        );
        final int pos = prepare.indexOf(after);
        expect(pos, greaterThan(strip), reason: '$crate 没在 strip 后复核');
        expect(pos, lessThan(zip), reason: crate);
      }
    });

    test('TestFlight 归档：strip 嵌入 framework 后重新导出，再交给上传', () {
      const String name =
          'Strip local symbols from signed iOS archive and re-export IPA';
      final String s = step(name);
      expect(s, contains("if: steps.signing.outputs.signed == 'true'"));
      final int strip = s.indexOf('tool/ios_strip_local_symbols.sh" "\$app"');
      final int export = s.indexOf('xcodebuild -exportArchive');
      expect(strip, isNonNegative);
      expect(s, contains('app="\$archive/Products/Applications/Runner.app"'));
      expect(s.indexOf('verify_abi.sh', strip), greaterThan(strip));
      expect(s.indexOf('rm -rf build/ios/ipa'), greaterThan(strip));
      expect(export, greaterThan(s.indexOf('rm -rf build/ios/ipa')));
      // 用同一份 ExportOptions 重签导出，否则签名方式和首次导出不一致。
      expect(
        s,
        contains('-exportOptionsPlist "\$RUNNER_TEMP/ExportOptions.plist"'),
      );
      expect(at(name), greaterThan(at('Build signed iOS App Store IPA')));
      expect(at(name), lessThan(at('Upload signed TestFlight IPA artifact')));
    });

    test('只去本地符号，导出集合与 FFI 前缀计数前后不变', () {
      final String script = stripScript();
      expect(script, contains('"\${STRIP[@]}" -x "\$bin"'));
      expect(script, contains('STRIP=(xcrun strip)'));
      // 不许退化成全量 strip（会去掉 dlsym / DynamicLibrary.process() 要的导出）。
      expect(script, isNot(matches(RegExp(r'strip[^\n]*\s-(S|u|r)\b'))));
      expect(script, contains('-gUj'));
      expect(script, contains('cmp -s "\$work/before.txt" "\$work/after.txt"'));
      // FFI 前缀覆盖每个 verify_abi 校验的前缀。
      final String prefixRe = RegExp(
        r"FFI_PREFIX_RE='\^_\(([a-z0-9|]+)\)_'",
      ).firstMatch(script)!.group(1)!;
      final Set<String> covered = prefixRe.split('|').toSet();
      for (final FileSystemEntity e in Directory('../native').listSync()) {
        final File verify = File('${e.path}/verify_abi.sh');
        if (!verify.existsSync()) continue;
        final RegExpMatch? m = RegExp(
          r"grep -E '\^(f[a-z0-9_|()]+)_'",
        ).firstMatch(verify.readAsStringSync());
        if (m == null) continue;
        String p = m.group(1)!;
        // `f(fc|cp)` 展开成 ffc / fcp。
        final RegExpMatch? alt = RegExp(r'^(\w*)\(([\w|]+)\)$').firstMatch(p);
        final List<String> names = alt == null
            ? <String>[p]
            : alt
                  .group(2)!
                  .split('|')
                  .map((String s) => '${alt.group(1)}$s')
                  .toList();
        for (p in names) {
          expect(covered, contains(p), reason: '${verify.path} 的前缀 $p');
        }
      }
    });
  });
}
