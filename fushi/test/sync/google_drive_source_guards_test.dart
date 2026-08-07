import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Google Drive 存储空间 source-scan 守卫。
///
/// 历史（TODO-836）：同步根从可见 Drive 搬进隐藏 appDataFolder，每个 `files.list`
/// 必须显式带 `spaces`，否则子查询默认落回可见 Drive、静默返回空。
///
/// 现状（Hoshi 兼容）：Drive 同步支持两种存储空间 [GoogleDriveSyncSpace]——默认隐藏
/// appDataFolder（`drive.appdata`），开「与 Hoshi/ッツ 共享」后走可见 My Drive /
/// `ttu-reader-data`（完整 `drive`）。空间/scope/根目录名不再硬编码字面量，而是统一从
/// `_space` 字段取。这些守卫因此从「必须硬编码 appDataFolder」改为「必须始终把空间
/// 显式接到 `_space`，绝不遗漏、绝不写死单一空间」——原来的安全意图（`spaces` 绝不能
/// 缺省）完整保留，只是值变成动态的。
void main() {
  /// HARD GUARD: 每个 `api.files.list(...)` 仍必须显式传 `spaces`，且值必须是
  /// `_space.spaces`（不是写死的 'appDataFolder'/'drive'）。缺省 → appData 模式静默
  /// 返回空；写死单一空间 → Hoshi 兼容模式打错空间。
  group('space-field pins (google_drive_handler.dart)', () {
    final File handler = File('lib/src/sync/google_drive_handler.dart');

    test('every api.files.list( call passes spaces: _space.spaces', () {
      expect(handler.existsSync(), isTrue,
          reason: 'run from the fushi/ package root');
      final String src = handler.readAsStringSync();

      // Split the source into each files.list( ... ); call block by bracket
      // matching from the '(' that follows 'api.files.list'.
      final List<String> blocks = <String>[];
      final RegExp listCall = RegExp(r'api\.files\.list\(');
      for (final RegExpMatch m in listCall.allMatches(src)) {
        int depth = 0;
        int i = m.end - 1; // position at the '('
        final StringBuffer buf = StringBuffer();
        for (; i < src.length; i++) {
          final String c = src[i];
          buf.write(c);
          if (c == '(') {
            depth++;
          } else if (c == ')') {
            depth--;
            if (depth == 0) break;
          }
        }
        blocks.add(buf.toString());
      }

      expect(blocks.length, 8,
          reason: 'expected exactly 8 files.list calls in the handler; if this '
              'changed, audit each new call for spaces: _space.spaces');

      final List<int> missing = <int>[];
      for (int b = 0; b < blocks.length; b++) {
        if (!blocks[b].contains('spaces: _space.spaces')) missing.add(b);
      }
      expect(missing, isEmpty,
          reason: 'files.list block(s) at index $missing lack '
              'spaces: _space.spaces → would either silently query the visible '
              'Drive in appData mode or hit the wrong space in Hoshi-compat mode '
              '(TODO-836 / GoogleDriveSyncSpace)');
    });

    test('no files.list hardcodes a single space literal', () {
      final String src = handler.readAsStringSync();
      // The migration to a dynamic space is only complete when NO call still
      // pins a literal space — a leftover literal would ignore the toggle.
      expect(src.contains("spaces: 'appDataFolder'"), isFalse,
          reason: 'hardcoded appDataFolder ignores the Hoshi-compat toggle; '
              'use _space.spaces (GoogleDriveSyncSpace)');
      expect(src.contains("spaces: 'drive'"), isFalse,
          reason: 'hardcoded drive space ignores appData mode; '
              'use _space.spaces (GoogleDriveSyncSpace)');
    });

    test('the sync root is created under the space parent alias', () {
      final String src = handler.readAsStringSync();
      expect(src.contains('..parents = [_space.rootParent]'), isTrue,
          reason: 'findOrCreateRootFolder must anchor the root in the current '
              'space (parents=[_space.rootParent]), not a hardcoded alias');
      expect(src.contains("..parents = ['appDataFolder']"), isFalse,
          reason: 'hardcoded appDataFolder parent ignores the Hoshi-compat '
              'toggle (GoogleDriveSyncSpace)');
      expect(src.contains('name = _space.rootFolderName'), isTrue,
          reason: 'the root folder name must come from the space '
              '(hibiki-data vs ttu-reader-data), not a hardcoded literal');
    });
  });

  /// 两种空间的 scope / 空间别名 / 根目录名的真值源，逐字段守死。
  ///   - appData：drive.appdata / appDataFolder / hibiki-data（老用户数据原地）。
  ///   - ttuShared：完整 drive / drive / ttu-reader-data（与 Hoshi/ッツ 共享）。
  group('sync space definitions (google_drive_sync_space.dart)', () {
    final File spaceFile = File('lib/src/sync/google_drive_sync_space.dart');

    String source() {
      expect(spaceFile.existsSync(), isTrue,
          reason: 'run from the fushi/ package root');
      return spaceFile.readAsStringSync();
    }

    test('declares only the hidden appdata scope（Hoshi 共享空间已移除）', () {
      final String s = source();
      expect(
          s.contains('https://www.googleapis.com/auth/drive.appdata'), isTrue,
          reason: 'appData space must keep the hidden drive.appdata scope');
      expect(s.contains("'https://www.googleapis.com/auth/drive'"), isFalse,
          reason: '完整 drive 敏感 scope 只为已删除的 Hoshi 共享空间存在，'
              '不得回潮（触发 Google 重新审核）');
    });

    test('never falls back to the visible drive.file scope', () {
      expect(source().contains('auth/drive.file'), isFalse,
          reason: 'drive.file 与隐藏 appdata 空间语义不符，禁用');
    });
  });

  /// auth 侧接线：scope 不再硬编码，统一取自 `_space.scope`；移动端与桌面端因此天然
  /// 用同一个 scope（云数据落同一空间）。可见-Drive 的 drive.file 仍必须缺席。
  group('auth scope wiring (google_drive_auth.dart)', () {
    final File authFile = File('lib/src/sync/google_drive_auth.dart');

    String source() {
      expect(authFile.existsSync(), isTrue,
          reason: 'run from the fushi/ package root');
      return authFile.readAsStringSync();
    }

    test('no longer requests the visible-Drive drive.file scope', () {
      expect(source().contains('auth/drive.file'), isFalse,
          reason: 'drive.file forced the whole-Drive root lookup → 403; and it '
              'cannot read Hoshi files. Must stay removed (TODO-836)');
    });

    test('mobile and desktop both derive the Drive scope from _space.scope',
        () {
      final String s = source();
      // Mobile: GoogleSignIn(scopes: [_space.scope])
      expect(RegExp(r'scopes:\s*\[_space\.scope\]').hasMatch(s), isTrue,
          reason: 'mobile sign-in must request the current space scope');
      // Desktop PKCE auth URL passes scope: _space.scope down into the builder.
      expect(s.contains('scope: _space.scope'), isTrue,
          reason: 'desktop auth URL must request the current space scope');
      // The old single-mode hardcoded scope constant must be gone.
      expect(s.contains('_driveAppdataScope'), isFalse,
          reason: 'scope is now sourced from GoogleDriveSyncSpace, not a '
              'hardcoded _driveAppdataScope constant');
    });
  });
}
