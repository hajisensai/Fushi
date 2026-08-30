#include <cassert>
#include <fstream>
#include <iterator>
#include <string>

#ifndef FUSHI_RUNNER_SOURCE_DIR
#error FUSHI_RUNNER_SOURCE_DIR must identify the Windows runner source tree
#endif

namespace {

std::string FunctionSlice(const std::string &source, const char *start,
                          const char *next) {
  const size_t begin = source.find(start);
  assert(begin != std::string::npos);
  const size_t end = source.find(next, begin + 1);
  assert(end != std::string::npos);
  return source.substr(begin, end - begin);
}

} // namespace

int main() {
  std::ifstream input(std::string(FUSHI_RUNNER_SOURCE_DIR) +
                      "/attached_text_surface_window.cpp");
  assert(input.good());
  const std::string source((std::istreambuf_iterator<char>(input)),
                           std::istreambuf_iterator<char>());

  // Global DWM enablement is only one fact.  The production collector must
  // also query target/window-specific VidPN ownership and the mapped
  // presentation HWND's DWM frame.
  const std::string collector = FunctionSlice(
      source, "AttachedTextSurfaceWindow::CurrentOverlayability() const",
      "bool AttachedTextSurfaceWindow::NativeProviderCanPresentWithoutDesktopOverlay");
  assert(collector.find("DwmIsCompositionEnabled(") != std::string::npos);
  assert(source.find("D3DKMTQueryVidPnExclusiveOwnership") !=
         std::string::npos);
  assert(source.find("D3DKMTCheckExclusiveOwnership") != std::string::npos);
  assert(collector.find("QueryWindowExclusiveOwnership(") !=
         std::string::npos);
  assert(collector.find("DWMWA_EXTENDED_FRAME_BOUNDS") != std::string::npos);
  assert(collector.find("ResolveScalingSourceWindow(presentation)") !=
         std::string::npos);
  assert(collector.find("MonitorFromWindow(") == std::string::npos);
  assert(collector.find("GetMonitorInfo(") == std::string::npos);

  // The final overlayability evaluation must happen inside the publication
  // function and precede the LL glyph snapshot write.  A timer-only check
  // leaves a click-swallow window when the game enters exclusive fullscreen.
  const std::string publish = FunctionSlice(
      source, "bool AttachedTextSurfaceWindow::PublishInteractiveSnapshot(",
      "void AttachedTextSurfaceWindow::RenderLayerBitmap(");
  const size_t admission = publish.find("CurrentOverlayability()");
  const size_t snapshot =
      publish.find("UpdateLowLevelAttachedGlyphHitRegions(");
  assert(admission != std::string::npos);
  assert(snapshot != std::string::npos);
  assert(admission < snapshot);
  assert(publish.find("evaluation.overlayable") != std::string::npos);

  // Only the explicitly proved KiriKiri in-process render-tree route may
  // bypass an unavailable desktop overlay; generic native geometry is not a
  // presenter capability.
  const std::string native = FunctionSlice(
      source,
      "bool AttachedTextSurfaceWindow::NativeProviderCanPresentWithoutDesktopOverlay",
      "bool AttachedTextSurfaceWindow::NativeProviderPreferred() const");
  assert(native.find("HasInProcessRenderTreePresenter(") != std::string::npos);

  const std::string sync = FunctionSlice(
      source, "void AttachedTextSurfaceWindow::SyncToTarget()",
      "void AttachedTextSurfaceWindow::HideSurface()");
  const size_t non_calibration =
      sync.find("if (mode_ != Mode::kCalibration)");
  const size_t native_monitor = sync.find("!EnsureWindow(", non_calibration);
  const size_t active_native = sync.find("\"activeNative\"");
  assert(non_calibration != std::string::npos);
  assert(native_monitor != std::string::npos);
  assert(active_native != std::string::npos);
  assert(native_monitor < active_native);
  const size_t active_native_hide = sync.rfind("HideSurface();", active_native);
  assert(active_native_hide != std::string::npos);
  const size_t destroy_after_hide =
      sync.find("DestroySurfaceWindow();", active_native_hide);
  assert(destroy_after_hide == std::string::npos ||
         destroy_after_hide > active_native);

  std::ifstream flutter_input(std::string(FUSHI_RUNNER_SOURCE_DIR) +
                              "/flutter_window.cpp");
  assert(flutter_input.good());
  const std::string flutter_source(
      (std::istreambuf_iterator<char>(flutter_input)),
      std::istreambuf_iterator<char>());
  const std::string direct_presenter = FunctionSlice(
      flutter_source, "SetLookupDirectPresenter(",
      "SetLookupCaptureRequest(");
  const size_t overlay_gate =
      direct_presenter.find("DesktopOverlayAvailableForTarget(");
  const size_t reveal =
      direct_presenter.find("RevealOverProcessClient(");
  assert(overlay_gate != std::string::npos);
  assert(reveal != std::string::npos);
  assert(overlay_gate < reveal);
  const size_t gated_return =
      direct_presenter.find("return false;", overlay_gate);
  assert(gated_return != std::string::npos);
  assert(gated_return < reveal);
  return 0;
}
