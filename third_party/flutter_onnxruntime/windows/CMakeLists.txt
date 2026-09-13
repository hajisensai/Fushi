# The Flutter tooling requires that developers have CMake 3.10 or later installed. You should not increase this version,
# as doing so will cause the plugin to fail to compile for some customers of the plugin.
cmake_minimum_required(VERSION 3.10)

# Project-level configuration.
set(PROJECT_NAME "flutter_onnxruntime")
project(${PROJECT_NAME} LANGUAGES CXX)

# This value is used when generating builds using this plugin, so it must not be changed.
set(PLUGIN_NAME "flutter_onnxruntime_plugin")

# === ONNX Runtime DirectML configuration ===
# Pin the official NuGet artifacts instead of using the generic GitHub release
# archive. The generic Windows archive is CPU-only and therefore advertises no
# DmlExecutionProvider even though the Dart API accepts DIRECT_ML.
set(ONNXRUNTIME_VERSION "1.22.0")
set(DIRECTML_VERSION "1.15.4")
set(ONNXRUNTIME_NUPKG_SHA256 "29F9872D786236B79AA83F94482F3A17C14297E4833768D6D0ED4883EE732E60")
set(DIRECTML_NUPKG_SHA256 "4E7CB7DDCE8CF837A7A75DC029209B520CA0101470FCDF275C1F49736A3615B9")

if(CMAKE_GENERATOR_PLATFORM STREQUAL "ARM64" OR CMAKE_SYSTEM_PROCESSOR MATCHES "^(ARM64|arm64|aarch64)$")
  set(ONNXRUNTIME_RID "win-arm64")
  set(DIRECTML_ARCH "arm64-win")
elseif(CMAKE_SIZEOF_VOID_P EQUAL 8)
  set(ONNXRUNTIME_RID "win-x64")
  set(DIRECTML_ARCH "x64-win")
else()
  set(ONNXRUNTIME_RID "win-x86")
  set(DIRECTML_ARCH "x86-win")
endif()

set(ONNXRUNTIME_DOWNLOAD_DIR "${CMAKE_CURRENT_BINARY_DIR}/onnxruntime-directml-${ONNXRUNTIME_VERSION}")
set(ONNXRUNTIME_EXTRACT_DIR "${ONNXRUNTIME_DOWNLOAD_DIR}/onnxruntime")
set(DIRECTML_EXTRACT_DIR "${ONNXRUNTIME_DOWNLOAD_DIR}/directml")
set(ONNXRUNTIME_NUPKG "${ONNXRUNTIME_DOWNLOAD_DIR}/onnxruntime-directml.nupkg")
set(DIRECTML_NUPKG "${ONNXRUNTIME_DOWNLOAD_DIR}/directml.nupkg")

if(NOT EXISTS "${ONNXRUNTIME_EXTRACT_DIR}/build/native/include/dml_provider_factory.h")
  file(MAKE_DIRECTORY "${ONNXRUNTIME_DOWNLOAD_DIR}" "${ONNXRUNTIME_EXTRACT_DIR}")
  file(
    DOWNLOAD
    "https://api.nuget.org/v3-flatcontainer/microsoft.ml.onnxruntime.directml/${ONNXRUNTIME_VERSION}/microsoft.ml.onnxruntime.directml.${ONNXRUNTIME_VERSION}.nupkg"
    "${ONNXRUNTIME_NUPKG}"
    EXPECTED_HASH "SHA256=${ONNXRUNTIME_NUPKG_SHA256}"
    TLS_VERIFY ON
    SHOW_PROGRESS)
  execute_process(
    COMMAND ${CMAKE_COMMAND} -E tar xf "${ONNXRUNTIME_NUPKG}"
    WORKING_DIRECTORY "${ONNXRUNTIME_EXTRACT_DIR}"
    RESULT_VARIABLE ONNXRUNTIME_EXTRACT_RESULT)
  if(NOT ONNXRUNTIME_EXTRACT_RESULT EQUAL 0)
    message(FATAL_ERROR "Failed to extract ONNX Runtime DirectML package: ${ONNXRUNTIME_EXTRACT_RESULT}")
  endif()
endif()

if(NOT EXISTS "${DIRECTML_EXTRACT_DIR}/bin/${DIRECTML_ARCH}/DirectML.dll")
  file(MAKE_DIRECTORY "${DIRECTML_EXTRACT_DIR}")
  file(
    DOWNLOAD
    "https://api.nuget.org/v3-flatcontainer/microsoft.ai.directml/${DIRECTML_VERSION}/microsoft.ai.directml.${DIRECTML_VERSION}.nupkg"
    "${DIRECTML_NUPKG}"
    EXPECTED_HASH "SHA256=${DIRECTML_NUPKG_SHA256}"
    TLS_VERIFY ON
    SHOW_PROGRESS)
  execute_process(
    COMMAND ${CMAKE_COMMAND} -E tar xf "${DIRECTML_NUPKG}"
    WORKING_DIRECTORY "${DIRECTML_EXTRACT_DIR}"
    RESULT_VARIABLE DIRECTML_EXTRACT_RESULT)
  if(NOT DIRECTML_EXTRACT_RESULT EQUAL 0)
    message(FATAL_ERROR "Failed to extract DirectML redistributable: ${DIRECTML_EXTRACT_RESULT}")
  endif()
endif()

set(ONNXRUNTIME_INCLUDE_DIRS "${ONNXRUNTIME_EXTRACT_DIR}/build/native/include")
set(ONNXRUNTIME_NATIVE_DIR "${ONNXRUNTIME_EXTRACT_DIR}/runtimes/${ONNXRUNTIME_RID}/native")
set(ONNXRUNTIME_LIBRARY "${ONNXRUNTIME_NATIVE_DIR}/onnxruntime.lib")
set(ONNXRUNTIME_DLL "${ONNXRUNTIME_NATIVE_DIR}/onnxruntime.dll")
set(ONNXRUNTIME_PROVIDERS_SHARED_DLL "${ONNXRUNTIME_NATIVE_DIR}/onnxruntime_providers_shared.dll")
set(DIRECTML_DLL "${DIRECTML_EXTRACT_DIR}/bin/${DIRECTML_ARCH}/DirectML.dll")

foreach(REQUIRED_FILE IN ITEMS "${ONNXRUNTIME_LIBRARY}" "${ONNXRUNTIME_DLL}"
                               "${ONNXRUNTIME_PROVIDERS_SHARED_DLL}" "${DIRECTML_DLL}")
  if(NOT EXISTS "${REQUIRED_FILE}")
    message(FATAL_ERROR "Required ONNX Runtime DirectML artifact is missing: ${REQUIRED_FILE}")
  endif()
endforeach()

set(ONNXRUNTIME_LIBRARIES "${ONNXRUNTIME_LIBRARY}")
set(flutter_onnxruntime_bundled_libraries "${ONNXRUNTIME_DLL}" "${ONNXRUNTIME_PROVIDERS_SHARED_DLL}"
                                           "${DIRECTML_DLL}")

# Define Windows-specific preprocessor macros
add_definitions(-DWIN32_LEAN_AND_MEAN -DNOMINMAX -DUNICODE -D_UNICODE)

# Any new source files that you add to the plugin should be added here.
list(APPEND PLUGIN_SOURCES "src/async_dispatch.cc" "src/dml_provider.cc" "src/dxgi_memory.cc"
  "src/session_manager.cc" "src/value_conversion.cc" "src/tensor_manager.cc"
     "src/windows_utils.cc")

# Define the plugin library target. Its name must not be changed (see comment on PLUGIN_NAME above).
add_library(${PLUGIN_NAME} SHARED "flutter_onnxruntime_plugin.cpp" "flutter_onnxruntime_plugin.h" ${PLUGIN_SOURCES})

# Apply a standard set of build settings that are configured in the application-level CMakeLists.txt. This can be
# removed for plugins that want full control over build settings.
apply_standard_settings(${PLUGIN_NAME})

# Symbols are hidden by default to reduce the chance of accidental conflicts between plugins. This should not be
# removed; any symbols that should be exported should be explicitly exported with the FLUTTER_PLUGIN_EXPORT macro.
set_target_properties(${PLUGIN_NAME} PROPERTIES CXX_VISIBILITY_PRESET hidden)
target_compile_definitions(${PLUGIN_NAME} PRIVATE FLUTTER_PLUGIN_IMPL FLUTTER_ONNXRUNTIME_HAS_DIRECTML=1)

# Add WINDOWS_EXPORT_ALL_SYMBOLS to ensure the generation of the import library (.lib file)
set_target_properties(${PLUGIN_NAME} PROPERTIES WINDOWS_EXPORT_ALL_SYMBOLS ON)

# Enable C++17 features
target_compile_features(${PLUGIN_NAME} PRIVATE cxx_std_17)

# Source include directories and library dependencies. Add any plugin-specific dependencies here.
target_include_directories(
  ${PLUGIN_NAME} PRIVATE "${CMAKE_CURRENT_SOURCE_DIR}/include" "${CMAKE_CURRENT_SOURCE_DIR}" "${FLUTTER_EPHEMERAL_DIR}"
                         "${CMAKE_CURRENT_SOURCE_DIR}/windows/include" "${ONNXRUNTIME_INCLUDE_DIRS}")

# Install debugging message
message(STATUS "Include directories: ${CMAKE_CURRENT_SOURCE_DIR}/include")
message(STATUS "Binary directory: ${CMAKE_CURRENT_BINARY_DIR}/include")
message(STATUS "This file: ${CMAKE_CURRENT_LIST_FILE}")

# Install public headers for the plugin
install(FILES "include/flutter_onnxruntime/flutter_onnxruntime_plugin.h" "include/flutter_onnxruntime/export.h"
        DESTINATION "${CMAKE_BINARY_DIR}/include/flutter_onnxruntime")

# Also create symlinks in the build directory to ensure includes work during build
file(MAKE_DIRECTORY "${CMAKE_BINARY_DIR}/include/flutter_onnxruntime")

# Copy headers with error handling
file(
  COPY "${CMAKE_CURRENT_SOURCE_DIR}/include/flutter_onnxruntime/flutter_onnxruntime_plugin.h"
  DESTINATION "${CMAKE_BINARY_DIR}/include/flutter_onnxruntime/"
  FOLLOW_SYMLINK_CHAIN)

file(
  COPY "${CMAKE_CURRENT_SOURCE_DIR}/include/flutter_onnxruntime/export.h"
  DESTINATION "${CMAKE_BINARY_DIR}/include/flutter_onnxruntime/"
  FOLLOW_SYMLINK_CHAIN)

# Add include directories for the plugin
target_include_directories(${PLUGIN_NAME} PUBLIC $<BUILD_INTERFACE:${CMAKE_BINARY_DIR}/include>
                                                 $<INSTALL_INTERFACE:include>)

# Add ONNX Runtime include directories
target_include_directories(${PLUGIN_NAME} PRIVATE ${ONNXRUNTIME_INCLUDE_DIRS})

# Link against Flutter and other libraries
target_link_libraries(${PLUGIN_NAME} PRIVATE flutter flutter_wrapper_plugin)

# Link against ONNX Runtime
target_link_libraries(${PLUGIN_NAME} PRIVATE ${ONNXRUNTIME_LIBRARIES})

# Link against Windows Shell API library for PathRemoveFileSpecW
target_link_libraries(${PLUGIN_NAME} PRIVATE Shlwapi dxgi)

# Copy the complete DirectML runtime next to the plugin for local runs. Flutter
# also consumes flutter_onnxruntime_bundled_libraries when assembling the app.
foreach(BUNDLED_LIBRARY IN LISTS flutter_onnxruntime_bundled_libraries)
  add_custom_command(
    TARGET ${PLUGIN_NAME}
    POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E copy_if_different "${BUNDLED_LIBRARY}" $<TARGET_FILE_DIR:${PLUGIN_NAME}>
    COMMENT "Copying ${BUNDLED_LIBRARY} to plugin build directory")
endforeach()

# List of absolute paths to libraries that should be bundled with the plugin. This list could contain prebuilt
# libraries, or libraries created by an external build triggered from this build file.
set(flutter_onnxruntime_bundled_libraries
    "${flutter_onnxruntime_bundled_libraries}"
    PARENT_SCOPE)
