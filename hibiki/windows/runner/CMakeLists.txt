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
  "audio_loopback_capture.cpp"
  "voice_hook_reader.cpp"
  "crash_dump.cpp"
  "external_video_handoff.cpp"
  "flutter_window.cpp"
  "floating_lyric_window.cpp"
  "foreground_selection.cpp"
  "global_lookup_window.cpp"
  "hook_toolbar_window.cpp"
  "ime_association_guard.cpp"
  "ime_space_dispatch.cpp"
  "low_level_mouse_hook.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "window_capture.cpp"
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
# for PNG encode.
target_link_libraries(${BINARY_NAME} PRIVATE d3d11 dxgi runtimeobject windowscodecs)
# galgame 一键制卡 A 阶段：audio_loopback_capture.cpp（WASAPI loopback 抓系统混音）。
# IMMDeviceEnumerator / IAudioClient / IAudioCaptureClient 的 CLSID/IID 由 uuid.lib（MSVC
# 默认链接）提供，CoCreateInstance 走已链接的 ole32；avrt 供将来 pro-audio 线程优先级用。
target_link_libraries(${BINARY_NAME} PRIVATE avrt)
# 剪切板面板背景逐像素透明（global_lookup_window composition 模式）：DirectComposition
# 视觉树承载 WebView2 composition controller 的透明像素，dxguid 提供 DComp/DXGI IID。
target_link_libraries(${BINARY_NAME} PRIVATE dcomp dxguid)
# BUG-1450: ImmAssociateContextEx — detach the IME from the window while no text
# field has focus so CJK IMEs stop swallowing every shortcut key.
target_link_libraries(${BINARY_NAME} PRIVATE imm32)
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
add_dependencies(${BINARY_NAME} flutter_assemble)

# BUG-1239: compile and execute the production IME Space predicate/dispatch
# seam as part of every Windows runner build. Source-string tests could not
# detect WM_KEYDOWN -> WM_KEYUP or removed Alt/Win guards.
add_executable(hibiki_windows_ime_space_test
  "ime_space_dispatch.cpp"
  "tests/ime_space_dispatch_test.cpp"
)
apply_standard_settings(hibiki_windows_ime_space_test)
target_compile_definitions(hibiki_windows_ime_space_test PRIVATE "NOMINMAX")
add_custom_target(hibiki_windows_ime_space_gate
  COMMAND "$<TARGET_FILE:hibiki_windows_ime_space_test>"
  DEPENDS hibiki_windows_ime_space_test
  VERBATIM
)
add_dependencies(${BINARY_NAME} hibiki_windows_ime_space_gate)

# BUG-1450: same treatment for the IME association state machine. Getting the
# coalescing or the failure path wrong either strands the window with the IME
# detached (no Chinese/Japanese input anywhere in the app) or re-attached (the
# whole shortcut table dies again), so it runs on every Windows runner build.
add_executable(hibiki_windows_ime_association_test
  "ime_association_guard.cpp"
  "tests/ime_association_guard_test.cpp"
)
apply_standard_settings(hibiki_windows_ime_association_test)
target_compile_definitions(hibiki_windows_ime_association_test PRIVATE "NOMINMAX")
target_link_libraries(hibiki_windows_ime_association_test PRIVATE imm32)
add_custom_target(hibiki_windows_ime_association_gate
  COMMAND "$<TARGET_FILE:hibiki_windows_ime_association_test>"
  DEPENDS hibiki_windows_ime_association_test
  VERBATIM
)
add_dependencies(${BINARY_NAME} hibiki_windows_ime_association_gate)

add_executable(hibiki_update_launcher WIN32
  "update_launcher.cpp"
)
apply_standard_settings(hibiki_update_launcher)
target_compile_definitions(hibiki_update_launcher PRIVATE "NOMINMAX")
target_link_libraries(hibiki_update_launcher PRIVATE shell32)
