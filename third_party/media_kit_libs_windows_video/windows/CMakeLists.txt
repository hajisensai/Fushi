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
# HIBIKI FORK (BUG-073): upstream media_kit_libs_windows_video pins libmpv from
# media-kit/libmpv-win32-video-build, whose newest release is 2023-09-24 — and
# that FFmpeg build ships NO working TrueHD/MLP decoder (`Failed to initialize a
# decoder for codec 'truehd'` at runtime, even though the "truehd" string is in
# the DLL). TrueHD 5.1 movies (the default audio track of most Blu-ray REMUX)
# therefore play with NO sound; AC3/EAC3/DTS already decode fine on the old
# build, so ONLY TrueHD was affected. The same DLL backs both the video player
# and the audiobook player (just_audio_media_kit), so audiobooks were silent on
# TrueHD too. Root fix: point at a maintained full-FFmpeg libmpv
# (zhongfly/mpv-winbuild, still releasing daily) whose build decodes TrueHD and
# exports the same client + render API media_kit needs. Verified against the
# downloaded DLL via ctypes (truehd `Opening decoder` OK on the real movie +
# mpv_render_context_create/render present) before the swap. Cost: libmpv-2.dll
# grows ~30MB → ~118MB (full FFmpeg). Drop this fork once upstream ships a newer
# libmpv with TrueHD. The .7z layout (libmpv-2.dll + include/mpv) matches what
# the extract step below expects, so only the URL/MD5/name change.
#
# MIRROR (TODO-1137): zhongfly/mpv-winbuild only keeps a ~30-day rolling window
# of releases - older tagged assets get pruned and 404, breaking every fresh
# Windows build (V37/V38 both hit this). Root fix: we now mirror the exact
# zhongfly .7z into our own permanent GitHub release
# (hajisensai/hibiki `vendor-libmpv`, assets never deleted), so the cmake
# file(DOWNLOAD) no longer depends on zhongfly's rolling deletion. To bump to a
# newer libmpv: download the newest LIVE zhongfly `mpv-dev-x86_64-...` asset
# (GPL full FFmpeg with TrueHD): NOT `-lgpl` (drops TrueHD -> re-opens BUG-073),
# NOT `-v3` (needs Haswell+, crashes on older CPUs); `gh release upload
# vendor-libmpv <file> --repo hajisensai/hibiki`; then update the name/URL/MD5
# below. sha256 of this pin (verified against zhongfly sha256.txt AND re-verified
# from the mirror before the swap):
# 2651a618ba6906ac869a87f669c4db157ef3b9d566eb946362fadafcd2e253c1
set(LIBMPV "mpv-dev-x86_64-20260704-git-33111f3212.7z")

# Provenance of the vendored libmpv archive (TODO-1172: no longer downloaded
# at build time). URL is the permanent mirror (hajisensai/hibiki release),
# kept so the origin stays auditable; the committed .7z is the source of truth.
set(LIBMPV_URL "https://github.com/hajisensai/hibiki/releases/download/vendor-libmpv/${LIBMPV}")
set(LIBMPV_MD5 "89702937368b0181cbce41c30e811c76")

# Vendored archive (committed) + build-dir extraction target (TODO-1172).
set(LIBMPV_ARCHIVE "${VENDORED_DIR}/${LIBMPV}")
set(LIBMPV_SRC "${CMAKE_BINARY_DIR}/libmpv")

verify_vendored_archive("${LIBMPV_ARCHIVE}" "${LIBMPV_MD5}" "libmpv")

check_directory_exists_and_not_empty(${LIBMPV_SRC} LIBMPV_SRC_VALID)

# Extract the libmpv archive.
if(NOT LIBMPV_SRC_VALID)
  message(STATUS "Extracting ${LIBMPV}...")
  make_directory("${LIBMPV_SRC}")
  add_custom_target("${PROJECT_NAME}_LIBMPV_EXTRACT" ALL)
  add_custom_command(
    TARGET "${PROJECT_NAME}_LIBMPV_EXTRACT"
    COMMAND "${CMAKE_COMMAND}" -E tar xzf "\"${LIBMPV_ARCHIVE}\""
    COMMAND xcopy "\"${LIBMPV_SRC}/include/mpv\"" "\"${LIBMPV_SRC}/mpv\"" /E /H /C /I
    COMMAND rmdir "\"${LIBMPV_SRC}/include\"" /S /Q
    COMMAND ren "\"${LIBMPV_SRC}/mpv\"" "\"include\""
    WORKING_DIRECTORY "${LIBMPV_SRC}"
  )
endif()

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
  "${LIBMPV_SRC}/libmpv-2.dll"
  "${ANGLE_SRC}/d3dcompiler_47.dll"
  "${ANGLE_SRC}/libEGL.dll"
  "${ANGLE_SRC}/libGLESv2.dll"
  "${ANGLE_SRC}/vk_swiftshader.dll"
  "${ANGLE_SRC}/vulkan-1.dll"
  "${ANGLE_SRC}/zlib.dll"
  PARENT_SCOPE
)
