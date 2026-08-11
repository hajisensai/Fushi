import 'package:fushi/utils.dart';

/// Coarse, user-facing category for a persisted download job error.
///
/// The pipeline and the legacy importer persist raw English diagnostics in
/// `VideoDownloadJobs.lastError` (BUG-1540). Those strings stay untouched in
/// the database and in the detail dialog — this layer only classifies them so
/// the task card can show one short localized summary line instead of dumping
/// the raw engine text into the layout.
enum VideoDownloadErrorCategory {
  /// Legacy import could not confirm the backend torrent by hash, title and
  /// category.
  backendUnconfirmed,

  /// The managed video source row is gone or not accessible on this device.
  managedSourceMissing,

  /// Required subtitles are unavailable, unpaired or failed to install.
  subtitleUnavailable,

  /// The download backend (instance/profile/category/save path) is missing,
  /// unreachable or no longer matches the job.
  backendUnavailable,

  /// The torrent identity (id / info hash) is missing or unverifiable.
  torrentInfoMissing,

  /// Anything else produced by the legacy import path.
  legacyImport,

  /// Unrecognized diagnostics — summarized generically, raw text stays in the
  /// detail dialog.
  unknown,
}

/// Classifies a raw `lastError` string into a [VideoDownloadErrorCategory].
///
/// Matching is substring-based on the lowercased raw text because compound
/// messages join several reasons with `';'` (e.g. the legacy importer's
/// `needsAttention: backend torrent was not confirmed by hash, title, and
/// category; legacy subtitle selection was unavailable`). Priority order
/// resolves compounds to their primary cause.
VideoDownloadErrorCategory classifyVideoDownloadError(String rawError) {
  final String lower = rawError.toLowerCase();
  if (lower.contains('not confirmed by hash')) {
    return VideoDownloadErrorCategory.backendUnconfirmed;
  }
  if (lower.contains('managed video source')) {
    return VideoDownloadErrorCategory.managedSourceMissing;
  }
  if (lower.contains('subtitle')) {
    return VideoDownloadErrorCategory.subtitleUnavailable;
  }
  if (lower.contains('download backend') ||
      lower.contains('backend instance') ||
      lower.contains('backend save path') ||
      lower.contains('backend path mapping') ||
      lower.contains('path mapping') ||
      lower.contains('backend organization failed')) {
    return VideoDownloadErrorCategory.backendUnavailable;
  }
  if (lower.contains('torrent id is missing') ||
      lower.contains('info hash') ||
      lower.contains('backend torrent id')) {
    return VideoDownloadErrorCategory.torrentInfoMissing;
  }
  if (lower.contains('legacy')) {
    return VideoDownloadErrorCategory.legacyImport;
  }
  return VideoDownloadErrorCategory.unknown;
}

/// One-line localized summary for a raw `lastError` string.
///
/// Unknown errors collapse to a generic localized summary; the untouched raw
/// text is always available in the error detail dialog.
String videoDownloadErrorSummary(String rawError) =>
    switch (classifyVideoDownloadError(rawError)) {
      VideoDownloadErrorCategory.backendUnconfirmed =>
        t.download_task_error_summary_backend_unconfirmed,
      VideoDownloadErrorCategory.managedSourceMissing =>
        t.download_task_error_summary_source_missing,
      VideoDownloadErrorCategory.subtitleUnavailable =>
        t.download_task_error_summary_subtitle,
      VideoDownloadErrorCategory.backendUnavailable =>
        t.download_task_error_summary_backend_unavailable,
      VideoDownloadErrorCategory.torrentInfoMissing =>
        t.download_task_error_summary_torrent_info,
      VideoDownloadErrorCategory.legacyImport =>
        t.download_task_error_summary_legacy,
      VideoDownloadErrorCategory.unknown =>
        t.download_task_error_summary_generic,
    };
