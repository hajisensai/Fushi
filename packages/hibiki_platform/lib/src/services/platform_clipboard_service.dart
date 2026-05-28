abstract class PlatformClipboardService {
  Future<void> copyToClipboard(String text);
  bool get shouldShowCopyToast;
}
