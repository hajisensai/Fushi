// Unity IL2CPP in-game lookup: binds the shared Unity canvas-text lookup
// (unity_mono_lookup.inc runtime + unity_mono_lookup_core.h frameworks 3 TMP /
// 4 UI.Text, provider kLookupGeometryProviderIdUnityMono) to the IL2CPP
// scripting backend through the accessor layer in unity_il2cpp_api.h.
// Included after unity_adapter.inc (the IL2CPP text path and its scan record)
// and unity_mono_adapter.inc (the shared runtime).
//
// Everything here runs on HookWorker, once:
//   identity   GameAssembly.dll loaded, `<stem>_Data\il2cpp_data\` on disk and
//              every il2cpp_* export the resolvers read (missing ones are
//              logged by name -- obfuscated / stripped exports fail closed);
//   text scan  the IL2CPP text path (TryHookUnityIl2CppAudio) has scanned the
//              text classes after the window appeared and says which canvas
//              setters are hooked (the lookup only models canvas kinds whose
//              lanes exist: the TMP set_text / SetText(string,bool) pair,
//              UI.Text.set_text);
//   resolve    inside an IL2CPP thread-attach scope, the same
//              ResolveUmCanvasLookup the Mono backend uses; the sampling point
//              is the AOT body of `static void Canvas.SendWillRenderCanvases()`
//              (MethodInfo.methodPointer inside GameAssembly.dll);
//   install    after detach, InstallUnityMonoLookupHooks (UmIl2CppWillRender-
//              Detour, the UnityWndClass click claim, the per-tick model).
// The main-thread sampler, model, click claim and hit publication are the
// shared runtime's; this file only decides whether and how to start it.
//
// Bounded diagnostics (one line each, never dialogue text), in the same file
// and format as the Mono backend:
//   unity-il2cpp: runtime GameAssembly=.. il2cpp_data=.. exports=found/required
//                 missing=<names> header_export=.. gchandle=.. image=<base>+<size>
//                 arch=..
//   unity-il2cpp-text: classes ... hooked ...
//   unity-il2cpp-lookup: gate=runtime-unsupported reason=...   (terminal)
//   unity-il2cpp-lookup: gate=no-canvas-text-hooks ...          (terminal)
//   unity-il2cpp-lookup: tmp sites ... hooks=N why=... / uitext sites ...
//   unity-il2cpp-lookup: gate=sites-unresolved ... nojit=..
//   unity-il2cpp-lookup: gate=<retire reason> step=.. / model ... / OfferReady

static_assert(uil2cpp::kLaneTmpSetText.bit == kUmTmpLaneSetText &&
                  uil2cpp::kLaneTmpSetTextBool.bit == kUmTmpLaneSetTextBool &&
                  uil2cpp::kLaneUiTextSetText.bit == kUmLaneUiTextSetText &&
                  uil2cpp::kLaneTmpSetTextSingle.bit ==
                      kUmTmpLaneSetTextSingle &&
                  uil2cpp::kLaneNaninovelSetText.bit == kUmLaneClassDecided,
              "IL2CPP canvas lanes share the runtime's candidate bits");

struct UnityIl2CppLookupState {
  bool done = false;       // the one resolution attempt ran
  bool framework = false;  // a canvas kind was attempted (lanes exist)
};
UnityIl2CppLookupState g_unity_il2cpp_lookup;

// GameAssembly.dll's mapped image, from its own PE header.
bool UnityIl2CppImageRange(HMODULE module, uintptr_t* begin, uintptr_t* end) {
  *begin = *end = 0u;
  if (module == nullptr) return false;
  const uintptr_t base = reinterpret_cast<uintptr_t>(module);
  const auto* dos = reinterpret_cast<const IMAGE_DOS_HEADER*>(base);
  if (dos->e_magic != IMAGE_DOS_SIGNATURE || dos->e_lfanew <= 0) return false;
  const auto* nt = reinterpret_cast<const IMAGE_NT_HEADERS*>(
      base + static_cast<uintptr_t>(dos->e_lfanew));
  if (nt->Signature != IMAGE_NT_SIGNATURE ||
      nt->OptionalHeader.SizeOfImage == 0u) {
    return false;
  }
  *begin = base;
  *end = base + nt->OptionalHeader.SizeOfImage;
  return true;
}

void RejectUnityIl2CppLookup(const wchar_t* reason) {
  auto& rt = g_um_lookup;
  // resolved && !hooks_installed: the host reports this exe as rejected
  // (with its digest), the terminal "this runtime shape is not supported".
  rt.resolved = true;
  UmLookupLog(L"%s: gate=runtime-unsupported reason=%s", rt.log_tag, reason);
}

void TryInstallUnityIl2CppLookup() {
  auto& st = g_unity_il2cpp_lookup;
  if (st.done || !g_capture_enabled) return;
  HMODULE game = GetModuleHandleW(L"GameAssembly.dll");
  if (game == nullptr || !HasCurrentProcessTopLevelWindow()) return;
  const UnityIl2CppTextScan& scan = g_unity_il2cpp_text_scan;
  if (!scan.scanned && !scan.scan_refused) return;  // the text scan decides
  st.done = true;

  auto& rt = g_um_lookup;
  rt.runtime = kUmRuntimeIl2Cpp;
  rt.log_tag = L"unity-il2cpp-lookup";

  const uil2cpp::LayoutReport layout = uil2cpp::HostUnityIl2CppLayout();
  uil2cpp::Il2CppExports exports;
  const uil2cpp::ExportReport report = uil2cpp::LoadIl2CppExports(
      [game](const char* name) -> void* {
        return reinterpret_cast<void*>(GetProcAddress(game, name));
      },
      &exports);
  uintptr_t image_begin = 0u, image_end = 0u;
  const bool image = UnityIl2CppImageRange(game, &image_begin, &image_end);
  UmLookupLog(
      L"unity-il2cpp: runtime GameAssembly=%d il2cpp_data=%d exports=%u/%u "
      L"missing=%hs header_export=%d gchandle=%d image=%p+0x%Ix arch=%s",
      layout.game_assembly ? 1 : 0, layout.il2cpp_data ? 1 : 0, report.found,
      report.required, report.missing[0] == 0 ? "-" : report.missing,
      report.header_size_export ? 1 : 0, report.gchandle_exports ? 1 : 0,
      reinterpret_cast<void*>(image_begin), image_end - image_begin,
#if defined(_M_IX86)
      L"x86"
#else
      L"x64"
#endif
  );
  UmLookupLog(
      L"unity-il2cpp-text: classes tmp=%d uitext=%d textmesh=%d naninovel=%d "
      L"hooked set_text=%d SetText(s,b)=%d SetText(s)=%d uitext=%d "
      L"textmesh=%d naninovel=%d scan_refused=%d",
      scan.tmp_class ? 1 : 0, scan.ui_text_class ? 1 : 0,
      scan.text_mesh_class ? 1 : 0, scan.naninovel_class ? 1 : 0,
      scan.tmp_set_text ? 1 : 0, scan.tmp_set_text_bool ? 1 : 0,
      scan.tmp_set_text_single ? 1 : 0, scan.ui_text_set_text ? 1 : 0,
      scan.text_mesh_set_text ? 1 : 0, scan.naninovel_set_text ? 1 : 0,
      scan.scan_refused ? 1 : 0);

  if (scan.scan_refused) {
    RejectUnityIl2CppLookup(L"text-scan-exports");
    return;
  }
  if (!layout.Complete()) {
    RejectUnityIl2CppLookup(L"layout");
    return;
  }
  // A canvas kind is modelled when a lane can name its objects: the TMP
  // setter pair / UI.Text.set_text, or Naninovel's RevealableText.set_Text
  // (a UI.Text or TextMeshProUGUI subclass; its class picks the kind).
  const bool naninovel = scan.naninovel_set_text;
  const bool want_tmp = (scan.tmp_set_text && scan.tmp_set_text_bool) ||
                        (naninovel && scan.tmp_class);
  const bool want_ui_text =
      scan.ui_text_set_text || (naninovel && scan.ui_text_class);
  if (!want_tmp && !want_ui_text) {
    // No canvas-text lane to pick the dialogue by: nothing to model.
    UmLookupLog(
        L"%s: gate=no-canvas-text-hooks tmp=%d uitext=%d naninovel=%d",
        rt.log_tag, want_tmp ? 1 : 0, want_ui_text ? 1 : 0, naninovel ? 1 : 0);
    return;
  }
  UmLookupLog(L"%s: canvas want tmp=%d uitext=%d naninovel=%d", rt.log_tag,
              want_tmp ? 1 : 0, want_ui_text ? 1 : 0, naninovel ? 1 : 0);
  st.framework = true;
  uil2cpp::Facade facade;
  const uil2cpp::FacadeResult installed = uil2cpp::InstallFacade(
      exports, report, image ? image_begin : 0u, image ? image_end : 0u,
      &facade);
  if (installed != uil2cpp::FacadeResult::kReady) {
    RejectUnityIl2CppLookup(
        installed == uil2cpp::FacadeResult::kExportsMissing ? L"exports"
        : installed == uil2cpp::FacadeResult::kNoCodeRange  ? L"image-range"
                                                            : L"array-header");
    return;
  }
  void* code = nullptr;
  {
    const fushi_voice_hook::Il2CppThreadFns thread_fns{
        exports.thread_current, exports.thread_attach, exports.thread_detach,
        exports.domain_get};
    fushi_voice_hook::Il2CppManagedThreadScope managed_thread(thread_fns);
    if (!managed_thread.safe()) {
      RejectUnityIl2CppLookup(L"thread-attach");
      return;
    }
    rt.resolved = true;
    code = ResolveUmCanvasLookup(facade.api, facade.lookup, facade.sizes,
                                 facade.classes, want_tmp, want_ui_text);
  }
  // Detached: MH_EnableHook suspends every thread.
  InstallUnityMonoLookupHooks(code);
}

bool UnityIl2CppLookupSensorInstalled() {
  return UnityMonoLookupSensorInstalled(kUmRuntimeIl2Cpp);
}
bool UnityIl2CppLookupRejected() {
  return UnityMonoLookupSitesRejected(kUmRuntimeIl2Cpp);
}
// The attempt ran and no canvas-text lane existed to model.
bool UnityIl2CppLookupUnsupported() {
  return g_unity_il2cpp_lookup.done && !g_unity_il2cpp_lookup.framework &&
         !UnityIl2CppLookupRejected();
}
