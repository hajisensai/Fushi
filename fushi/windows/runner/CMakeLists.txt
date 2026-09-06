cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# TODO-617: WebView2 SDK for the global lookup overlay (global_lookup_window.cpp).
# Pinned to the same version the flutter_inappwebview_windows fork uses so the
# COM interfaces (ICoreWebView2_3 / ...Environment10 / ...EnvironmentOptions4)
# match. The shared top-level ${CMAKE_BINARY_DIR}/packages is also where that
# fork downloads WebView2, so this is idempotent.
set(WEBVIEW_VERSION "1.0.2792.45")
set(WIL_VERSION "1.0.231216.1")
find_program(NUGET nuget)
if(NOT NUGET)
  message(NOTICE "Nuget is not installed! The global lookup overlay (WebView2) requires it. https://inappwebview.dev/docs/intro#setup-windows")
endif()
add_custom_target(runner_WEBVIEW2_DOWNLOAD ALL)
add_custom_command(
  TARGET runner_WEBVIEW2_DOWNLOAD PRE_BUILD
  COMMAND ${NUGET} install Microsoft.Windows.ImplementationLibrary -Version ${WIL_VERSION} -ExcludeVersion -OutputDirectory ${CMAKE_BINARY_DIR}/packages
  COMMAND ${NUGET} install Microsoft.Web.WebView2 -Version ${WEBVIEW_VERSION} -ExcludeVersion -OutputDirectory ${CMAKE_BINARY_DIR}/packages
  DEPENDS ${NUGET}
)

add_executable(${BINARY_NAME} WIN32
  "attached_text_surface_window.cpp"
  "audio_loopback_capture.cpp"
  "layer_origin_solver.cpp"
  "voice_hook_reader.cpp"
  "crash_dump.cpp"
  "external_video_handoff.cpp"
  "flutter_window.cpp"
  "floating_lyric_window.cpp"
  "foreground_selection.cpp"
  "global_lookup_shadow.cpp"
  "global_lookup_window.cpp"
  "global_mouse_trigger.cpp"
  "hdr_video_host_window.cpp"
  "hook_toolbar_window.cpp"
  "ime_association_guard.cpp"
  "ime_space_dispatch.cpp"
  "low_level_mouse_hook.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "window_capture.cpp"
  "window_recorder.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)
add_dependencies(${BINARY_NAME} runner_WEBVIEW2_DOWNLOAD)
apply_standard_settings(${BINARY_NAME})
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")
target_compile_definitions(${BINARY_NAME} PRIVATE
  "FLUTTER_VERSION=\"${FLUTTER_VERSION}\""
  "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}"
  "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}"
  "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}"
  "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}"
)
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
# dwmapi: DWM caption/text color theming for the native title bar.
target_link_libraries(${BINARY_NAME} PRIVATE dwmapi)
# ole32 / shell32: IShellLink + IPersistFile + SHGetKnownFolderPath /
# SHChangeNotify for TODO-901 (rewriting desktop/Start-menu .lnk icons on app
# icon change).
target_link_libraries(${BINARY_NAME} PRIVATE ole32 shell32)
# d2d1 / dwrite: rendering + char hit-testing for the desktop floating lyric
# strip (floating_lyric_window.cpp).
target_link_libraries(${BINARY_NAME} PRIVATE d2d1 dwrite)
# bcrypt: SHA-256 fingerprint for attached galgame surface profiles. The hash
# fences per-executable calibration from being reused by a different build.
target_link_libraries(${BINARY_NAME} PRIVATE bcrypt)
# WebView2 + WIL (.targets auto-add include dirs, import lib and WebView2Loader
# deployment) for the global lookup overlay; Shlwapi for SHCreateMemStream.
target_link_libraries(${BINARY_NAME} PRIVATE
  ${CMAKE_BINARY_DIR}/packages/Microsoft.Web.WebView2/build/native/Microsoft.Web.WebView2.targets)
target_link_libraries(${BINARY_NAME} PRIVATE
  ${CMAKE_BINARY_DIR}/packages/Microsoft.Windows.ImplementationLibrary/build/native/Microsoft.Windows.ImplementationLibrary.targets)
target_link_libraries(${BINARY_NAME} PRIVATE Shlwapi.lib)
# uiautomationcore: the UI Automation COM GUIDs (CLSID_CUIAutomation /
# IID_IUIAutomation*) used by foreground_selection.cpp to read the foreground
# app's text selection + surrounding context (TODO-1030 M0 global lookup).
target_link_libraries(${BINARY_NAME} PRIVATE uiautomationcore.lib)
# TODO-1162: window_capture.cpp (external-window mining) — Windows.Graphics.Capture
# single-frame screenshot needs D3D11 + DXGI + the WinRT activation runtime
# (RoInitialize / RoGetActivationFactory / WindowsCreateStringReference) and WIC
# for PNG encode. window_recorder.cpp (galgame rolling window recording) shares
# the same stack and adds WIC JPEG encode.
target_link_libraries(${BINARY_NAME} PRIVATE d3d11 dxgi runtimeobject windowscodecs)
# galgame 一键制卡 A 阶段：audio_loopback_capture.cpp（WASAPI loopback 抓系统混音）。
# IMMDeviceEnumerator / IAudioClient / IAudioCaptureClient 的 CLSID/IID 由 uuid.lib（MSVC
# 默认链接）提供，CoCreateInstance 走已链接的 ole32；avrt 供将来 pro-audio 线程优先级用。
target_link_libraries(${BINARY_NAME} PRIVATE avrt)
# 剪切板面板背景逐像素透明（global_lookup_window composition 模式）：DirectComposition
# 视觉树承载 WebView2 composition controller 的透明像素，dxguid 提供 DComp/DXGI IID。
target_link_libraries(${BINARY_NAME} PRIVATE dcomp dxguid)
# v19 galgame 查词准入：注入侧算不出游戏 exe 摘要时由 host 兜底算 SHA-256
# （voice_hook_reader.cpp 的 Sha256HexOfFile）。
target_link_libraries(${BINARY_NAME} PRIVATE bcrypt)
# BUG-1450: ImmAssociateContextEx — detach the IME from the window while no text
# field has focus so CJK IMEs stop swallowing every shortcut key.
target_link_libraries(${BINARY_NAME} PRIVATE imm32)
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
add_dependencies(${BINARY_NAME} flutter_assemble)

# BUG-1239: compile and execute the production IME Space predicate/dispatch
# seam as part of every Windows runner build. Source-string tests could not
# detect WM_KEYDOWN -> WM_KEYUP or removed Alt/Win guards.
add_executable(fushi_windows_ime_space_test
  "ime_space_dispatch.cpp"
  "tests/ime_space_dispatch_test.cpp"
)
apply_standard_settings(fushi_windows_ime_space_test)
target_compile_definitions(fushi_windows_ime_space_test PRIVATE "NOMINMAX")
add_custom_target(fushi_windows_ime_space_gate
  COMMAND "$<TARGET_FILE:fushi_windows_ime_space_test>"
  DEPENDS fushi_windows_ime_space_test
  VERBATIM
)
add_dependencies(${BINARY_NAME} fushi_windows_ime_space_gate)

# BUG-1450: same treatment for the IME association state machine. Getting the
# coalescing or the failure path wrong either strands the window with the IME
# detached (no Chinese/Japanese input anywhere in the app) or re-attached (the
# whole shortcut table dies again), so it runs on every Windows runner build.
add_executable(fushi_windows_ime_association_test
  "ime_association_guard.cpp"
  "tests/ime_association_guard_test.cpp"
)
apply_standard_settings(fushi_windows_ime_association_test)
target_compile_definitions(fushi_windows_ime_association_test PRIVATE "NOMINMAX")
target_link_libraries(fushi_windows_ime_association_test PRIVATE imm32)
add_custom_target(fushi_windows_ime_association_gate
  COMMAND "$<TARGET_FILE:fushi_windows_ime_association_test>"
  DEPENDS fushi_windows_ime_association_test
  VERBATIM
)
add_dependencies(${BINARY_NAME} fushi_windows_ime_association_gate)

# BUG-1455: compile and execute the WM_ACTIVATE focus policy on every Windows
# runner build. This guards both sides of the contract: popup drag deactivation
# must not raise the main window, while ordinary main-window click/activation
# must still restore focus to the live Flutter child. HWND ownership cases cover
# view teardown/recreation and Windows handle reuse.
add_executable(fushi_windows_activation_policy_test
  "tests/window_activation_policy_test.cpp"
)
apply_standard_settings(fushi_windows_activation_policy_test)
target_compile_definitions(fushi_windows_activation_policy_test PRIVATE
  "NOMINMAX")
add_custom_target(fushi_windows_activation_policy_gate
  COMMAND "$<TARGET_FILE:fushi_windows_activation_policy_test>"
  DEPENDS fushi_windows_activation_policy_test
  VERBATIM
)
add_dependencies(${BINARY_NAME} fushi_windows_activation_policy_gate)

# Capture suppression is authorized by an exact epoch/token, while text may
# advance behind the hidden surface. Keep that release contract executable so
# a sentence change cannot strand the invisible catch window forever or let an
# old epoch/token reveal a newer surface.
add_executable(fushi_windows_attached_capture_token_test
  "tests/attached_capture_token_test.cpp"
)
apply_standard_settings(fushi_windows_attached_capture_token_test)
target_compile_definitions(fushi_windows_attached_capture_token_test PRIVATE
  "NOMINMAX")
add_custom_target(fushi_windows_attached_capture_token_gate
  COMMAND "$<TARGET_FILE:fushi_windows_attached_capture_token_test>"
  DEPENDS fushi_windows_attached_capture_token_test
  VERBATIM
)
add_dependencies(${BINARY_NAME} fushi_windows_attached_capture_token_gate)

# Attached runtime hit geometry is replaceable while a physical left button is
# still held.  Keep the down/up latch rule executable: clearing a snapshot marks
# cancellation but only the paired up may consume the transaction release.
add_executable(fushi_windows_attached_glyph_latch_test
  "tests/attached_glyph_transaction_latch_test.cpp"
)
apply_standard_settings(fushi_windows_attached_glyph_latch_test)
target_compile_definitions(fushi_windows_attached_glyph_latch_test PRIVATE
  "NOMINMAX")
add_custom_target(fushi_windows_attached_glyph_latch_gate
  COMMAND "$<TARGET_FILE:fushi_windows_attached_glyph_latch_test>"
  DEPENDS fushi_windows_attached_glyph_latch_test
  VERBATIM
)
add_dependencies(${BINARY_NAME} fushi_windows_attached_glyph_latch_gate)

# v19 lookup hits are untrusted shared-memory payloads. Compile and run strict
# UTF-8/UTF-16 span, production provider-pair and bounded geometry validation
# before the runner target may link.
add_executable(fushi_windows_lookup_hit_validation_test
  "tests/lookup_hit_validation_test.cpp"
)
apply_standard_settings(fushi_windows_lookup_hit_validation_test)
target_compile_definitions(fushi_windows_lookup_hit_validation_test PRIVATE
  "NOMINMAX")
add_custom_target(fushi_windows_lookup_hit_validation_gate
  COMMAND "$<TARGET_FILE:fushi_windows_lookup_hit_validation_test>"
  DEPENDS fushi_windows_lookup_hit_validation_test
  VERBATIM
)
add_dependencies(${BINARY_NAME} fushi_windows_lookup_hit_validation_gate)

# Attached profiles cross a MethodChannel and are therefore untrusted. Keep
# the native scalar bounds and alignment enums executable so invalid values
# cannot silently fall through to DirectWrite's left/top defaults.
add_executable(fushi_windows_attached_layout_validation_test
  "tests/attached_layout_validation_test.cpp"
)
apply_standard_settings(fushi_windows_attached_layout_validation_test)
target_compile_definitions(fushi_windows_attached_layout_validation_test PRIVATE
  "NOMINMAX")
add_custom_target(fushi_windows_attached_layout_validation_gate
  COMMAND "$<TARGET_FILE:fushi_windows_attached_layout_validation_test>"
  DEPENDS fushi_windows_attached_layout_validation_test
  VERBATIM
)
add_dependencies(${BINARY_NAME} fushi_windows_attached_layout_validation_gate)

# 直连覆盖窗的画布→客户区映射决定卡片贴在哪、以及它是否还留在游戏画面内。这段几何
# 一旦回归就表现为「卡片偏位/跑到画面外」，故保持纯函数且可执行。
#
# 注意：1:1 下 scale==1、信箱边为 0 只是**这三个映射函数**的恒等性质；整条直连路径在
# 1:1 下的落点已经随 GlyphAnchoredCardOrigin 一起变了（水平由左对齐改中心对齐、垂直由
# 优先下方改优先上方），是有意的策略变更。对照表在 gal_direct_card_geometry.h 头部。
add_executable(fushi_windows_gal_direct_card_geometry_test
  "tests/gal_direct_card_geometry_test.cpp"
)
apply_standard_settings(fushi_windows_gal_direct_card_geometry_test)
target_compile_definitions(fushi_windows_gal_direct_card_geometry_test PRIVATE
  "NOMINMAX")
add_custom_target(fushi_windows_gal_direct_card_geometry_gate
  COMMAND "$<TARGET_FILE:fushi_windows_gal_direct_card_geometry_test>"
  DEPENDS fushi_windows_gal_direct_card_geometry_test
  VERBATIM
)
add_dependencies(${BINARY_NAME} fushi_windows_gal_direct_card_geometry_gate)

# Attached catch pixels are useful only while the mapped presentation HWND is
# actually composable above the game.  Keep the fail-closed decision pure and
# executable so borderless/Magpie admission cannot regress into a fullscreen
# rectangle heuristic, and exclusive/unknown VidPN ownership remains rejected.
add_executable(fushi_windows_attached_overlayability_test
  "tests/attached_overlayability_test.cpp"
)
apply_standard_settings(fushi_windows_attached_overlayability_test)
target_compile_definitions(fushi_windows_attached_overlayability_test PRIVATE
  "NOMINMAX")
add_custom_target(fushi_windows_attached_overlayability_gate
  COMMAND "$<TARGET_FILE:fushi_windows_attached_overlayability_test>"
  DEPENDS fushi_windows_attached_overlayability_test
  VERBATIM
)
add_dependencies(${BINARY_NAME} fushi_windows_attached_overlayability_gate)

# The pure decision is insufficient if the production path publishes LL glyph
# boxes before consulting it.  Pin the target-specific VidPN/DWM probes and the
# final pre-publication ordering on every runner build.
add_executable(fushi_windows_attached_overlayability_source_test
  "tests/attached_overlayability_source_test.cpp"
)
apply_standard_settings(fushi_windows_attached_overlayability_source_test)
target_compile_definitions(
  fushi_windows_attached_overlayability_source_test PRIVATE
  "NOMINMAX"
  "FUSHI_RUNNER_SOURCE_DIR=\"${CMAKE_CURRENT_SOURCE_DIR}\"")
add_custom_target(fushi_windows_attached_overlayability_source_gate
  COMMAND "$<TARGET_FILE:fushi_windows_attached_overlayability_source_test>"
  DEPENDS fushi_windows_attached_overlayability_source_test
  VERBATIM
)
add_dependencies(${BINARY_NAME}
  fushi_windows_attached_overlayability_source_gate)

# WH_MOUSE_LL runs synchronously in the system input path. Lock regressions in
# the attached down/up path can freeze all desktop mouse delivery, so guard the
# non-blocking source contract in addition to the pure transaction reducer.
add_executable(fushi_windows_attached_mouse_hook_nonblocking_source_test
  "tests/attached_mouse_hook_nonblocking_source_test.cpp"
)
apply_standard_settings(
  fushi_windows_attached_mouse_hook_nonblocking_source_test)
target_compile_definitions(
  fushi_windows_attached_mouse_hook_nonblocking_source_test PRIVATE
  "NOMINMAX"
  "FUSHI_RUNNER_SOURCE_DIR=\"${CMAKE_CURRENT_SOURCE_DIR}\"")
add_custom_target(fushi_windows_attached_mouse_hook_nonblocking_source_gate
  COMMAND "$<TARGET_FILE:fushi_windows_attached_mouse_hook_nonblocking_source_test>"
  DEPENDS fushi_windows_attached_mouse_hook_nonblocking_source_test
  VERBATIM
)
add_dependencies(${BINARY_NAME}
  fushi_windows_attached_mouse_hook_nonblocking_source_gate)

# A same-PID game window may be destroyed and recreated while the injected
# mapping survives. Keep shield status target/transaction/epoch attribution
# executable so a new HWND cannot borrow an old fault or verified conclusion,
# while active/unacknowledged tails still block the re-handshake.
add_executable(fushi_windows_attached_shield_status_policy_test
  "tests/attached_shield_status_policy_test.cpp"
)
apply_standard_settings(fushi_windows_attached_shield_status_policy_test)
target_compile_definitions(
  fushi_windows_attached_shield_status_policy_test PRIVATE
  "NOMINMAX"
  "FUSHI_RUNNER_SOURCE_DIR=\"${CMAKE_CURRENT_SOURCE_DIR}\"")
add_custom_target(fushi_windows_attached_shield_status_policy_gate
  COMMAND "$<TARGET_FILE:fushi_windows_attached_shield_status_policy_test>"
  DEPENDS fushi_windows_attached_shield_status_policy_test
  VERBATIM
)
add_dependencies(${BINARY_NAME}
  fushi_windows_attached_shield_status_policy_gate)

# Shift+hover lookup on the attached calibrated glyph surface: the polling
# timer must fire once per distinct cluster while Shift is held and never
# without Shift. Keep the de-dup/anchor-release seam executable so a hover
# storm (one lookup per 60ms tick) or a dead anchor cannot regress silently.
add_executable(fushi_windows_attached_hover_tracker_test
  "tests/attached_hover_tracker_test.cpp"
)
apply_standard_settings(fushi_windows_attached_hover_tracker_test)
target_compile_definitions(fushi_windows_attached_hover_tracker_test PRIVATE
  "NOMINMAX")
add_custom_target(fushi_windows_attached_hover_tracker_gate
  COMMAND "$<TARGET_FILE:fushi_windows_attached_hover_tracker_test>"
  DEPENDS fushi_windows_attached_hover_tracker_test
  VERBATIM
)
add_dependencies(${BINARY_NAME} fushi_windows_attached_hover_tracker_gate)

# Rolling window recording for galgame video cards: the fps keep decision, the
# max_seconds / byte-cap eviction, the export range (to<=0 = now) and the box
# downscale are pure STL and run on every Windows runner build, so a regression
# cannot silently turn the ring into an unbounded buffer or export the wrong
# frames.
add_executable(fushi_windows_window_recorder_ring_test
  "tests/window_recorder_ring_test.cpp"
)
apply_standard_settings(fushi_windows_window_recorder_ring_test)
target_compile_definitions(fushi_windows_window_recorder_ring_test PRIVATE
  "NOMINMAX")
add_custom_target(fushi_windows_window_recorder_ring_gate
  COMMAND "$<TARGET_FILE:fushi_windows_window_recorder_ring_test>"
  DEPENDS fushi_windows_window_recorder_ring_test
  VERBATIM
)
add_dependencies(${BINARY_NAME} fushi_windows_window_recorder_ring_gate)

add_executable(fushi_update_launcher WIN32
  "update_launcher.cpp"
)
apply_standard_settings(fushi_update_launcher)
target_compile_definitions(fushi_update_launcher PRIVATE "NOMINMAX")
target_link_libraries(fushi_update_launcher PRIVATE shell32)
