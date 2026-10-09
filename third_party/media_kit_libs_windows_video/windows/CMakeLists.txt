# This file is a part of media_kit (https://github.com/media-kit/media-kit).
#
# Copyright © 2021 & onwards, Hitesh Kumar Saini <saini123hitesh@gmail.com>.
# All rights reserved.
# Use of this source code is governed by MIT license that can be found in the LICENSE file.

cmake_minimum_required(VERSION 3.14)

# This option is read by the other packages which are part of package:media_kit.
option(MEDIA_KIT_LIBS_AVAILABLE "package:media_kit libraries are available." ON)

set(PROJECT_NAME "media_kit_libs_windows_video")
project(${PROJECT_NAME} LANGUAGES CXX)

# Deal with MSVC incompatiblity
add_compile_definitions(_DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR)

# ------------------------------------------------------------------------------
# HIBIKI FORK (TODO-1172): upstream fetched these .7z archives from GitHub
# at *configure* time via file(DOWNLOAD) and hard FATAL_ERROR'd on any
# network/integrity hiccup, making Windows CI builds intermittently red.
# TODO-1137 already mirrored libmpv to a permanent release to survive
# zhongfly's rolling-window pruning, but the archives were still downloaded
# at build time -- so a transient network failure still broke the build.
# Both archives are now VENDORED into ../vendored (committed, self-contained,
# same rationale as third_party/ffmpeg-min). This step reads + MD5-verifies
# the local copy; no runtime GitHub download remains. The integrity check now
# guards against a corrupt committed file and never deletes the source.
function(verify_vendored_archive path md5 label)
  if(NOT EXISTS "${path}")
    message(FATAL_ERROR
      "${label}: vendored archive missing at ${path}. It must be committed "
      "under third_party/media_kit_libs_windows_video/vendored (TODO-1172).")
  endif()

  file(MD5 "${path}" ARCHIVE_MD5)

  if(md5 STREQUAL ARCHIVE_MD5)
    message(STATUS "${label}: vendored archive verified (${path}).")
  else()
    message(FATAL_ERROR
      "${label}: vendored archive ${path} integrity check failed "
      "(expected ${md5}, got ${ARCHIVE_MD5}). The committed file is corrupt; "
      "restore it from git.")
  endif()
endfunction()

function(check_directory_exists_and_not_empty dir result_var)
  # Check if the directory exists
  if(EXISTS "${dir}")
    # Check if the directory is not empty
    file(GLOB dir_contents "${dir}/*")

    if(dir_contents)
      set(${result_var} TRUE PARENT_SCOPE)
    else()
      set(${result_var} FALSE PARENT_SCOPE)
      message(STATUS "Directory ${dir} exists but is empty!")
    endif()
  else()
    set(${result_var} FALSE PARENT_SCOPE)
    message(STATUS "Directory ${dir} does not exist!")
  endif()
endfunction()

# Directory holding the vendored (committed) .7z archives, resolved to a
# clean absolute path so the extract commands below never carry a "../"
# segment (TODO-1172).
get_filename_component(
  VENDORED_DIR
  "${CMAKE_CURRENT_SOURCE_DIR}/../vendored"
  ABSOLUTE
)

# libmpv archive containing the pre-built shared libraries & headers.
#
# BUG-073: keep a full FFmpeg build with a working TrueHD/MLP decoder. The
# original media-kit 2023 runtime listed TrueHD but failed to initialize it.
# Validate actual decoding as well as client/render API exports before repinning.
#
# MINIMUM VERSION (BUG-1644): this pin must stay at or after mpv upstream
# 1d15686142fd5d53c954aab7526cedab05ef9dc3 (2026-07-31, "hwdec_d3d11egl: fix
# EGL_EXT_device_query availability check"), i.e. a zhongfly build dated
# 2026-07-31 or later. Older libmpv checks `EGL_EXT_device_query` against the
# EGL *display* extension string only, while ANGLE (since ANGLE 56663dbfa780)
# lists it in the *client* string - so `hwdec_d3d11egl::init()` returns -1
# before it ever looks at the D3D11 device, silently disabling native d3d11va
# interop and forcing `d3d11va-copy` (every decoded frame read back to system
# memory and re-uploaded). Measured on the previous 20260704 pin: mpv logged
# `Loading hwdec driver 'd3d11-egl'` -> `Loading failed.` with no reason; on
# this pin the same probe reaches `d3d11-egl: Failed to create hwdevice_ctx`,
# i.e. past that gate. Do NOT bump backwards past 2026-07-31.
# Fushi builds the upstream 2026-10-08 menu implementation with the narrow
# patches/disc-navigation-state.patch. See NATIVE_BUILD.md for provenance.
set(LIBMPV "mpv-dev-x86_64-20261008-git-36abaa32d0-fushi-discnav1.7z")

# Upstream source provenance; the committed patched archive is the build input.
set(LIBMPV_URL "https://github.com/mpv-player/mpv/tree/36abaa32d00a7229ee206aae12dc0e97e7962dca")
set(LIBMPV_MD5 "93da2208746a035210a76b0b39335035")

# Vendored archive (committed) + build-dir extraction target (TODO-1172).
set(LIBMPV_ARCHIVE "${VENDORED_DIR}/${LIBMPV}")
set(LIBMPV_SRC "${CMAKE_BINARY_DIR}/libmpv-${LIBMPV_MD5}")
set(MEDIA_KIT_LIBMPV_SRC "${LIBMPV_SRC}" CACHE INTERNAL "Pinned libmpv SDK directory" FORCE)

verify_vendored_archive("${LIBMPV_ARCHIVE}" "${LIBMPV_MD5}" "libmpv")

# The hash-addressed SDK prevents an existing build from retaining the old DLL.
# Extract at configure time so the verified runtime manifest is available here.
if(NOT EXISTS "${LIBMPV_SRC}/runtime-files.cmake")
  message(STATUS "Extracting ${LIBMPV}...")
  file(MAKE_DIRECTORY "${LIBMPV_SRC}")
  execute_process(COMMAND "${CMAKE_COMMAND}" -E tar xzf "${LIBMPV_ARCHIVE}"
    WORKING_DIRECTORY "${LIBMPV_SRC}" RESULT_VARIABLE LIBMPV_EXTRACT_RESULT)
  if(NOT LIBMPV_EXTRACT_RESULT EQUAL 0)
    message(FATAL_ERROR "Failed to extract verified libmpv archive: ${LIBMPV_EXTRACT_RESULT}")
  endif()
  file(COPY "${LIBMPV_SRC}/include/mpv/" DESTINATION "${LIBMPV_SRC}/include")
endif()
include("${LIBMPV_SRC}/runtime-files.cmake")
set(LIBMPV_RUNTIME_FILES)
foreach(name IN LISTS LIBMPV_RUNTIME_NAMES)
  if(NOT EXISTS "${LIBMPV_SRC}/${name}")
    message(FATAL_ERROR "Incomplete native runtime: ${name}")
  endif()
  list(APPEND LIBMPV_RUNTIME_FILES "${LIBMPV_SRC}/${name}")
endforeach()

# ------------------------------------------------------------------------------

# ANGLE archive containing the pre-built shared libraries & headers.
set(ANGLE "ANGLE.7z")

# Provenance of the vendored ANGLE archive (TODO-1172: no longer downloaded).
set(ANGLE_URL "https://github.com/alexmercerind/flutter-windows-ANGLE-OpenGL-ES/releases/download/v1.0.1/ANGLE.7z")
set(ANGLE_MD5 "e866f13e8d552348058afaafe869b1ed")

# Vendored archive (committed) + build-dir extraction target (TODO-1172).
set(ANGLE_ARCHIVE "${VENDORED_DIR}/${ANGLE}")
set(ANGLE_SRC "${CMAKE_BINARY_DIR}/ANGLE")

verify_vendored_archive("${ANGLE_ARCHIVE}" "${ANGLE_MD5}" "ANGLE")

check_directory_exists_and_not_empty(${ANGLE_SRC} ANGLE_SRC_VALID)

# Extract the ANGLE archive.
if(NOT ANGLE_SRC_VALID)
  message(STATUS "Extracting ${ANGLE}...")
  make_directory("${ANGLE_SRC}")
  add_custom_target("${PROJECT_NAME}_ANGLE_EXTRACT" ALL)
  add_custom_command(
    TARGET "${PROJECT_NAME}_ANGLE_EXTRACT"
    COMMAND "${CMAKE_COMMAND}" -E tar xzf "\"${ANGLE_ARCHIVE}\""
    WORKING_DIRECTORY "${ANGLE_SRC}"
  )
endif()

# ------------------------------------------------------------------------------
set(PLUGIN_NAME "media_kit_libs_windows_video_plugin")

add_library(
  ${PLUGIN_NAME} SHARED
  "include/media_kit_libs_windows_video/media_kit_libs_windows_video_plugin_c_api.h"
  "media_kit_libs_windows_video_plugin_c_api.cpp"
)

apply_standard_settings(${PLUGIN_NAME})

set_target_properties(
  ${PLUGIN_NAME}
  PROPERTIES
  CXX_VISIBILITY_PRESET
  hidden
)
target_compile_definitions(
  ${PLUGIN_NAME}
  PRIVATE
  FLUTTER_PLUGIN_IMPL
)

target_include_directories(
  ${PLUGIN_NAME} INTERFACE
  "${CMAKE_CURRENT_SOURCE_DIR}/include"
)
target_link_libraries(
  ${PLUGIN_NAME}
  PRIVATE
  flutter
  flutter_wrapper_plugin
)

set(
  media_kit_libs_windows_video_bundled_libraries
  ${LIBMPV_RUNTIME_FILES}
  "${LIBMPV_SRC}/libbluray-j2se-1.5.0.jar"
  "${LIBMPV_SRC}/libbluray-awt-j2se-1.5.0.jar"
  "${ANGLE_SRC}/d3dcompiler_47.dll"
  "${ANGLE_SRC}/libEGL.dll"
  "${ANGLE_SRC}/libGLESv2.dll"
  "${ANGLE_SRC}/vk_swiftshader.dll"
  # libmpv's newer loader has a private fbd name; preserve ANGLE's existing
  # public loader for other consumers instead of replacing their dependency.
  "${ANGLE_SRC}/vulkan-1.dll"
  "${ANGLE_SRC}/zlib.dll"
  PARENT_SCOPE
)

# The on-demand Java runtime installer has one source of truth. Its small
# pinned JAR/source/probe bundle is offline; the private JRE is fetched on demand.
get_filename_component(BDJ_BUNDLE "${CMAKE_CURRENT_SOURCE_DIR}/../bdj" ABSOLUTE)
# Keep this plugin self-contained: crossing outside Flutter's junction with
# ../../.. is not portable, even after CMake REALPATH on Windows.
if(NOT EXISTS "${BDJ_BUNDLE}/bdj_runtime.ps1")
  message(FATAL_ERROR "The vendored BD-J installer is missing from ${BDJ_BUNDLE}")
endif()
install(DIRECTORY "${BDJ_BUNDLE}/" DESTINATION "${CMAKE_INSTALL_PREFIX}/bluray/bdj")
install(DIRECTORY "${LIBMPV_SRC}/licenses/"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/bluray/native-licenses")
install(FILES "${LIBMPV_SRC}/runtime-manifest.json" "${LIBMPV_SRC}/msys2-packages.json"
  "${LIBMPV_SRC}/source-provenance.json" "${LIBMPV_SRC}/private-dll-map.json"
  "${LIBMPV_SRC}/dynamic-dll-references.json"
  DESTINATION "${CMAKE_INSTALL_PREFIX}/bluray")
