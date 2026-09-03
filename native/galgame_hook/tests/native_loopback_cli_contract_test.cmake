if(NOT DEFINED INJECTOR OR INJECTOR STREQUAL "")
  message(FATAL_ERROR "INJECTOR is required")
endif()

execute_process(
  COMMAND "${INJECTOR}" --capabilities
  RESULT_VARIABLE capability_result
  OUTPUT_VARIABLE capability_stdout
  ERROR_VARIABLE capability_stderr)
string(STRIP "${capability_stdout}" capability_stdout)
if(NOT capability_result EQUAL 0)
  message(FATAL_ERROR
    "--capabilities failed rc=${capability_result} stderr=${capability_stderr}")
endif()
if(NOT capability_stdout STREQUAL "native_loopback_policy_v1")
  message(FATAL_ERROR
    "unexpected capability output: '${capability_stdout}'")
endif()

# Policy parsing is independent from target discovery. Both valid values retain
# the same side-effect-free capability result.
foreach(policy IN ITEMS allow deny)
  execute_process(
    COMMAND "${INJECTOR}" --native-loopback-policy "${policy}" --capabilities
    RESULT_VARIABLE policy_result
    OUTPUT_VARIABLE policy_stdout
    ERROR_VARIABLE policy_stderr)
  string(STRIP "${policy_stdout}" policy_stdout)
  if(NOT policy_result EQUAL 0 OR
     NOT policy_stdout STREQUAL "native_loopback_policy_v1")
    message(FATAL_ERROR
      "policy ${policy} capability failed rc=${policy_result} "
      "stdout='${policy_stdout}' stderr='${policy_stderr}'")
  endif()
endforeach()

foreach(invalid IN ITEMS bogus ALLOW)
  execute_process(
    COMMAND "${INJECTOR}" --native-loopback-policy "${invalid}"
    RESULT_VARIABLE invalid_result
    OUTPUT_VARIABLE invalid_stdout
    ERROR_VARIABLE invalid_stderr)
  if(invalid_result EQUAL 0)
    message(FATAL_ERROR "invalid policy '${invalid}' unexpectedly succeeded")
  endif()
  if(NOT invalid_stderr MATCHES "invalid --native-loopback-policy value")
    message(FATAL_ERROR
      "invalid policy '${invalid}' missing deterministic error: "
      "'${invalid_stderr}'")
  endif()
endforeach()

execute_process(
  COMMAND "${INJECTOR}" --native-loopback-policy
  RESULT_VARIABLE missing_result
  OUTPUT_VARIABLE missing_stdout
  ERROR_VARIABLE missing_stderr)
if(missing_result EQUAL 0 OR
   NOT missing_stderr MATCHES "invalid --native-loopback-policy value")
  message(FATAL_ERROR
    "missing policy value did not fail closed: rc=${missing_result} "
    "stderr='${missing_stderr}'")
endif()
