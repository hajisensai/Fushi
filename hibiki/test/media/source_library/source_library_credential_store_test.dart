// TODO-1274 SourceLibraryCredentialStore 测试：
//  - save/read 往返（password / privateKey）。
//  - 🔴 红线：Preferences 里存的是 base64，绝不裸存明文密码。
//  - 按 sourceId 命名空间隔离；空凭据 = 删除；delete 幂等。

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fushi/src/media/source_library/source_library_credential_store.dart';
import 'package:fushi_core/fushi_core.dart';

HibikiDatabase _memDb() => HibikiDatabase.forTesting(NativeDatabase.memory());

void main() {
  test('prefKeyForSource is a stable per-source namespace', () {
    expect(SourceLibraryCredentialStore.prefKeyForSource(7),
        'media_source_secret_7');
    expect(SourceLibraryCredentialStore.prefKeyForSource(42),
        'media_source_secret_42');
  });

  test('save then read round-trips password + private key', () async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    final SourceLibraryCredentialStore store = SourceLibraryCredentialStore(db);

    await store.saveSecret(1,
        password: 'hunter2', privateKey: '-----BEGIN KEY-----');
    final SourceLibrarySecret secret = await store.readSecret(1);
    expect(secret.password, 'hunter2');
    expect(secret.privateKey, '-----BEGIN KEY-----');
    expect(secret.isEmpty, isFalse);
  });

  test('🔴 red line: stored preference is base64, not plaintext password',
      () async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    final SourceLibraryCredentialStore store = SourceLibraryCredentialStore(db);

    await store.saveSecret(3, password: 'plaintext-should-not-appear');
    final String? raw =
        await db.getPref(SourceLibraryCredentialStore.prefKeyForSource(3));
    expect(raw, isNotNull);
    expect(raw, isNot(contains('plaintext-should-not-appear')),
        reason: 'password must be base64-encoded, never stored in the clear');
    // But it decodes back to the original secret.
    expect(utf8.decode(base64Decode(raw!)),
        contains('plaintext-should-not-appear'));
    expect((await store.readSecret(3)).password, 'plaintext-should-not-appear');
  });

  test('empty credentials delete the entry (read yields empty)', () async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    final SourceLibraryCredentialStore store = SourceLibraryCredentialStore(db);

    await store.saveSecret(5, password: 'temp');
    expect((await store.readSecret(5)).isEmpty, isFalse);

    await store.saveSecret(5); // both null -> delete
    final SourceLibrarySecret after = await store.readSecret(5);
    expect(after.isEmpty, isTrue);
    expect(after.password, isNull);
    expect(after.privateKey, isNull);
  });

  test('deleteSecret is idempotent and scoped to the source id', () async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    final SourceLibraryCredentialStore store = SourceLibraryCredentialStore(db);

    await store.saveSecret(1, password: 'one');
    await store.saveSecret(2, password: 'two');

    await store.deleteSecret(1);
    expect((await store.readSecret(1)).isEmpty, isTrue);
    // Source 2 untouched.
    expect((await store.readSecret(2)).password, 'two');

    // Deleting again / a missing id does not throw.
    await store.deleteSecret(1);
    await store.deleteSecret(999);
  });

  test('missing / corrupt preference reads back as empty (no throw)', () async {
    final HibikiDatabase db = _memDb();
    addTearDown(db.close);
    final SourceLibraryCredentialStore store = SourceLibraryCredentialStore(db);

    // Never saved.
    expect((await store.readSecret(10)).isEmpty, isTrue);

    // Corrupt base64/JSON payload.
    await db.setPref(
        SourceLibraryCredentialStore.prefKeyForSource(11), 'not-base64!!!');
    expect((await store.readSecret(11)).isEmpty, isTrue);
  });
}
