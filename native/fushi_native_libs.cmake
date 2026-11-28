# Registry-driven packaging of the prebuilt native libraries for the Windows / Linux runners.
#
#   include("${CMAKE_CURRENT_SOURCE_DIR}/../../native/fushi_native_libs.cmake")
#   fushi_install_native_libs(windows windows-x64 "powershell -ExecutionPolicy Bypass -File")
#
# Walks native/crates.json and handles every crate whose platforms.<platform>.bundled_by is "app":
# the artifact native/<crate>/prebuilt/<prebuilt_dir>/<artifact> goes next to the executable
# (INSTALL_BUNDLE_LIB_DIR of the caller) according to platforms.<platform>.required:
#   always   missing = configure-time FATAL_ERROR, every configuration (no Dart fallback);
#   release  missing = configure-time WARNING, and Profile/Release installs fail (Debug builds of
#            pure UI work keep going; the library reports itself missing at runtime);
#   optional copy-if-present; the registry's `fallback` says what degrades.
# Adding a crate to a desktop bundle = one registry entry; nothing here names a crate.
# Guard: fushi/test/build/native_crate_registry_guard_test.dart.

function(fushi_install_native_libs platform prebuilt_dir build_runner)
  if(CMAKE_VERSION VERSION_LESS 3.19)
    message(FATAL_ERROR
      "native/fushi_native_libs.cmake reads native/crates.json with string(JSON), which needs CMake 3.19+ "
      "(found ${CMAKE_VERSION}).")
  endif()
  set(native_dir "${CMAKE_CURRENT_FUNCTION_LIST_DIR}")
  file(READ "${native_dir}/crates.json" registry)
  string(JSON crate_count LENGTH "${registry}" crates)
  math(EXPR last "${crate_count} - 1")
  foreach(i RANGE ${last})
    string(JSON entry ERROR_VARIABLE no_entry GET "${registry}" crates ${i} platforms ${platform})
    if(no_entry)
      continue()
    endif()
    string(JSON bundled_by ERROR_VARIABLE no_bundled GET "${entry}" bundled_by)
    if(no_bundled OR NOT bundled_by STREQUAL "app")
      continue()
    endif()
    string(JSON name GET "${registry}" crates ${i} name)
    string(JSON artifact GET "${entry}" artifact)
    string(JSON required GET "${entry}" required)
    string(JSON script GET "${registry}" crates ${i} build ${platform})
    set(lib "${native_dir}/${name}/prebuilt/${prebuilt_dir}/${artifact}")
    set(build_hint "${build_runner} native/${name}/${script}")
    if(required STREQUAL "always")
      if(NOT EXISTS "${lib}")
        message(FATAL_ERROR
          "${name} is a required native dependency, but ${lib} is missing. "
          "Build it first: ${build_hint} (needs Rust/cargo; tool/bootstrap.ps1 / tool/bootstrap.sh build it for new worktrees).")
      endif()
      install(FILES "${lib}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
    elseif(required STREQUAL "release")
      if(EXISTS "${lib}")
        install(FILES "${lib}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
      else()
        message(WARNING
          "${name}: ${lib} not found. Run ${build_hint}; Profile/Release bundles refuse to build without it.")
      endif()
      install(CODE "
        if(CMAKE_INSTALL_CONFIG_NAME MATCHES \"^(Profile|Release)$\" AND NOT EXISTS \"${lib}\")
          message(FATAL_ERROR
            \"Missing required native library ${artifact}. \"
            \"Run ${build_hint} before building a Profile/Release bundle.\")
        endif()
      " COMPONENT Runtime)
    elseif(required STREQUAL "optional")
      if(EXISTS "${lib}")
        install(FILES "${lib}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}" COMPONENT Runtime)
      endif()
    else()
      message(FATAL_ERROR "native/crates.json: ${name}.platforms.${platform}.required is '${required}' (always|release|optional)")
    endif()
  endforeach()
endfunction()
