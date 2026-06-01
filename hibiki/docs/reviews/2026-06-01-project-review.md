# 2026-06-01 Project Review

## Round 1 - Dictionary Sync Backup Option

### Scope

- Commit range reviewed: `74a5da4a..d17d9962`.
- Files reviewed:
  - `lib/src/sync/backup_service.dart`
  - `lib/src/sync/sync_repository.dart`
  - `lib/src/sync/sync_settings_schema.dart`
  - `test/sync/backup_service_test.dart`
  - `test/sync/sync_repository_test.dart`
  - `test/sync/sync_settings_visibility_test.dart`
  - `test/settings/settings_redesign_static_test.dart`
  - `lib/i18n/*.i18n.json`
  - `lib/i18n/strings.g.dart`
- Review type: code path review plus regression tests for backup/export/import consistency. No emulator/manual reader path was exercised because this change is settings plus backup logic, not reader rendering.

### Findings

#### HBK-AUDIT-170

- severity: high
- status: fixed
- files/lines:
  - `lib/src/sync/backup_service.dart` export path around dictionary inclusion
  - `test/sync/backup_service_test.dart` dictionary backup regression tests
- root cause: The first implementation treated "dictionary sync enabled + resource root path provided" as enough proof that dictionary DB state could be exported. That is the wrong data structure test. The real invariant is that every `dictionary_metadata` row must have matching resource files under `dictionaryResources/<dictionaryName>/`.
- impact: A backup could preserve dictionary metadata/history without the matching resources, especially when the resource root was missing, empty, or contained only unrelated temp files. Restoring that backup would create ghost dictionaries that exist in DB state but cannot be queried.
- fix: Export now calls `_hasCompleteDictionaryResources(...)`, which reads the current dictionary metadata and requires each dictionary-specific resource directory to contain at least one file before keeping dictionary state. Otherwise `_stripDictionaryState(...)` runs and the backup remains internally consistent.
- verification:
  - Red test first: `flutter.bat test test/sync/backup_service_test.dart --reporter expanded` failed for `exportBackup strips dictionary state when enabled but resources are missing`.
  - Fixed run: `flutter.bat test test/sync/backup_service_test.dart --reporter expanded` passed with 25 tests.

#### HBK-AUDIT-171

- severity: high
- status: fixed
- files/lines:
  - `lib/src/sync/backup_service.dart` import path around `_restoreDictionaryResources`
  - `test/sync/backup_service_test.dart` dictionary restore regression tests
- root cause: Import only touched `dictionaryResources/` when the archive contained resource entries. If the imported DB had no dictionary state, stale resource files from the previous local install remained on disk. The implementation also originally validated dictionary resource archive paths only after the DB overwrite had already happened.
- impact: Importing a backup without dictionary resources could leave stale dictionary files behind, so disk state no longer matched the restored DB. A malformed archive path could also fail after destructive DB replacement, leaving a partially changed restore.
- fix: Import now builds and validates the dictionary resource restore plan before overwriting the DB. After the DB replacement it always recreates the target resource root when a dictionary resource directory is supplied, making an archive without dictionary resources restore to an empty directory. Invalid resource paths throw before DB/resource mutation.
- verification:
  - Red tests first: `flutter.bat test test/sync/backup_service_test.dart --reporter expanded` failed for stale resources and late invalid-path failure.
  - Fixed run: `flutter.bat test test/sync/backup_service_test.dart --reporter expanded` passed with 25 tests.

### Non-Findings

- The new `sync_dictionary_enabled` preference is intentionally not in `SyncRepository.deviceLocalPrefKeys`. It is a user behavior setting like stats/audiobook/content sync, not a device credential or backend secret.
- The current `SyncManager` has no backend contract for cross-device dictionary package discovery, versioning, upload, or import. Wiring this new setting into that per-book sync manager without a protocol would create a fake sync switch. The current implementation therefore uses the setting for local backup inclusion only.

### Next Scope

- If cloud dictionary sync is required later, design a real dictionary package protocol first: remote manifest, package upload/download, conflict policy, size handling, and import transaction semantics.
