# Execute the actual x86 installation code with controlled OS/identity inputs.
# Include from native/galgame_hook/CMakeLists.txt. No second implementation of
# the reservation policy is compiled into this fixture.
if(WIN32 AND MSVC AND CMAKE_SIZEOF_VOID_P EQUAL 4)
  get_filename_component(_shield_native_root "${CMAKE_CURRENT_LIST_DIR}/.." ABSOLUTE)
  set(_shield_generic "${_shield_native_root}/hook/generic_input_shield.inc")
  set(_shield_lookup "${_shield_native_root}/hook/adapters/siglus_lookup.inc")
  set(_shield_legacy "${_shield_native_root}/hook/adapters/siglus_lookup_legacy.inc")
  set_property(DIRECTORY APPEND PROPERTY CMAKE_CONFIGURE_DEPENDS
    "${_shield_generic}" "${_shield_lookup}" "${_shield_legacy}")

  function(_shield_extract file start_marker end_marker output)
    file(READ "${file}" source)
    string(FIND "${source}" "${start_marker}" start)
    string(FIND "${source}" "${end_marker}" end)
    if(start LESS 0 OR end LESS 0 OR end LESS_EQUAL start)
      message(FATAL_ERROR "Cannot extract live shield installation block from ${file}")
    endif()
    math(EXPR length "${end} - ${start}")
    string(SUBSTRING "${source}" ${start} ${length} fragment)
    set(${output} "${fragment}" PARENT_SCOPE)
  endfunction()
  _shield_extract("${_shield_legacy}" "bool IsLegacySiglusLookup("
    "bool ReadSiglusLegacyMemory(" _shield_family)
  _shield_extract("${_shield_lookup}" "bool ShouldReserveSiglusKeyboardState("
    "bool ReadSiglusDesignSize(" _shield_reservation)
  _shield_extract("${_shield_generic}" "bool HookGenericExport("
    "bool ExactSgreOwnsDirectInput(" _shield_install)
  set(_shield_generated "${CMAKE_CURRENT_BINARY_DIR}/generic_input_shield_install_production.inc")
  file(GENERATE OUTPUT "${_shield_generated}"
    CONTENT "// Generated from production source; do not edit.\n${_shield_family}\n${_shield_reservation}\n${_shield_install}")
  add_executable(fushi_generic_input_shield_install_test
    "${_shield_native_root}/tests/generic_input_shield_install_test.cpp")
  target_include_directories(fushi_generic_input_shield_install_test PRIVATE
    "${_shield_native_root}/include" "${CMAKE_CURRENT_BINARY_DIR}")
  target_compile_features(fushi_generic_input_shield_install_test PRIVATE cxx_std_17)
  target_compile_options(fushi_generic_input_shield_install_test PRIVATE /utf-8 /O2 /W4 /WX)
  add_test(NAME fushi_generic_input_shield_install_test
    COMMAND fushi_generic_input_shield_install_test)
endif()
