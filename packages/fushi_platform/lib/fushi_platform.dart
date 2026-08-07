library hibiki_platform;

// HBK-AUDIT-136: removed dead abstractions TtsEngine / PlatformIntegration /
// StoragePaths — generated from the 2026-05-16 multiplatform-design spec but
// never implemented or consumed (TTS goes through TtsChannel, storage paths
// through path_provider directly). Exporting empty interfaces as public API
// was pseudo-extensibility scaffolding; the files have been deleted.
export 'src/services/platform_directory_service.dart';
export 'src/services/platform_lifecycle_service.dart';
export 'src/services/platform_clipboard_service.dart';
export 'src/services/platform_permission_service.dart';
export 'src/services/platform_device_info_service.dart';
