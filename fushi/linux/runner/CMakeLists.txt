cmake_minimum_required(VERSION 3.13)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME}
  "main.cc"
  "my_application.cc"
  "clipboard_image_channel.cc"
  "external_open_handoff.cc"
  "floating_ball_channel.cc"
  "floating_ball_window.cc"
  "screen_capture.cc"
  "screen_ocr_overlay.cc"
  "deck_buttons.cc"
  "global_lookup_channel.cc"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
)

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})
# Fushi's own runner code is C++20 (std::jthread, std::format). Plugins keep
# the standard settings' C++14.
target_compile_features(${BINARY_NAME} PRIVATE cxx_std_20)
target_compile_options(${BINARY_NAME} PRIVATE -Werror)

# Add preprocessor definitions for the application ID.
add_definitions(-DAPPLICATION_ID="${APPLICATION_ID}")

# Add dependency libraries. Add any application-specific dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter)
target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GTK)

target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# Screen capture in Steam Deck Game Mode (screen_capture.h): Gamescope's
# PipeWire stream through GStreamer. Optional: without it, Game Mode screen OCR
# fails with "capture_failed" (the X root there is Steam's display).
pkg_check_modules(GSTREAMER QUIET IMPORTED_TARGET
  gstreamer-1.0 gstreamer-app-1.0 gstreamer-video-1.0)
if(GSTREAMER_FOUND)
  target_compile_definitions(${BINARY_NAME} PRIVATE FUSHI_GAMESCOPE_CAPTURE)
  target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::GSTREAMER)
else()
  message(WARNING "Game Mode screen capture not built: needs gstreamer-1.0, "
    "gstreamer-app-1.0 and gstreamer-video-1.0")
endif()

# Primary selection from Wayland apps (wayland_selection.h): ext-data-control-v1
# client code generated from wayland-protocols. Optional: without it the
# selection lookup reads X11 PRIMARY only.
pkg_check_modules(WAYLAND_CLIENT QUIET IMPORTED_TARGET wayland-client)
pkg_check_modules(WAYLAND_PROTOCOLS QUIET wayland-protocols>=1.39)
find_program(WAYLAND_SCANNER wayland-scanner)
if(WAYLAND_CLIENT_FOUND AND WAYLAND_PROTOCOLS_FOUND AND WAYLAND_SCANNER)
  enable_language(C)
  pkg_get_variable(WAYLAND_PROTOCOLS_DIR wayland-protocols pkgdatadir)
  set(DATA_CONTROL_XML
    "${WAYLAND_PROTOCOLS_DIR}/staging/ext-data-control/ext-data-control-v1.xml")
  set(DATA_CONTROL_GEN "${CMAKE_CURRENT_BINARY_DIR}/wayland-gen")
  file(MAKE_DIRECTORY "${DATA_CONTROL_GEN}")
  add_custom_command(
    OUTPUT "${DATA_CONTROL_GEN}/ext-data-control-v1-client-protocol.h"
           "${DATA_CONTROL_GEN}/ext-data-control-v1-protocol.c"
    COMMAND "${WAYLAND_SCANNER}" client-header "${DATA_CONTROL_XML}"
            "${DATA_CONTROL_GEN}/ext-data-control-v1-client-protocol.h"
    COMMAND "${WAYLAND_SCANNER}" private-code "${DATA_CONTROL_XML}"
            "${DATA_CONTROL_GEN}/ext-data-control-v1-protocol.c"
    DEPENDS "${DATA_CONTROL_XML}")
  target_sources(${BINARY_NAME} PRIVATE
    "wayland_selection.cc"
    "${DATA_CONTROL_GEN}/ext-data-control-v1-client-protocol.h"
    "${DATA_CONTROL_GEN}/ext-data-control-v1-protocol.c")
  target_include_directories(${BINARY_NAME} PRIVATE "${DATA_CONTROL_GEN}")
  target_compile_definitions(${BINARY_NAME} PRIVATE FUSHI_WAYLAND_SELECTION)
  target_link_libraries(${BINARY_NAME} PRIVATE PkgConfig::WAYLAND_CLIENT)
else()
  message(WARNING "Wayland selection reader not built: needs wayland-client, "
    "wayland-protocols >= 1.39 and wayland-scanner (X11 PRIMARY only)")
endif()
