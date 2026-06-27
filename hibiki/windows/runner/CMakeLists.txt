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
  "crash_dump.cpp"
  "external_video_handoff.cpp"
  "flutter_window.cpp"
  "floating_lyric_window.cpp"
  "global_lookup_window.cpp"
  "main.cpp"
  "utils.cpp"
  "win32_window.cpp"
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
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")
add_dependencies(${BINARY_NAME} flutter_assemble)

add_executable(hibiki_update_launcher WIN32
  "update_launcher.cpp"
)
apply_standard_settings(hibiki_update_launcher)
target_compile_definitions(hibiki_update_launcher PRIVATE "NOMINMAX")
target_link_libraries(hibiki_update_launcher PRIVATE shell32)
