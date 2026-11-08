# Copyright 2026 Sankhesh Jhaveri
# SPDX-License-Identifier: BSD-3-Clause

add_executable(SlangKitTestCompiler TestCompiler.cpp)
target_link_libraries(SlangKitTestCompiler PRIVATE SlangKit::SlangKit)
target_compile_definitions(SlangKitTestCompiler
  PRIVATE SLANGKIT_SOURCE_DIR="${PROJECT_SOURCE_DIR}"
          SLANGKIT_TEST_TMP_DIR="${CMAKE_CURRENT_BINARY_DIR}")
add_test(NAME SlangKit.Compiler COMMAND SlangKitTestCompiler)

add_executable(SlangKitTestParameters TestParameters.cpp)
target_link_libraries(SlangKitTestParameters PRIVATE SlangKit::SlangKit)
target_compile_definitions(SlangKitTestParameters PRIVATE SLANGKIT_SOURCE_DIR="${PROJECT_SOURCE_DIR}")
add_test(NAME SlangKit.Parameters COMMAND SlangKitTestParameters)

if(TARGET skc)
  set(_data "${CMAKE_CURRENT_SOURCE_DIR}/data")
  function(skc_test name exit_code regex)
    string(REPLACE ";" "|" _args "${ARGN}")
    add_test(NAME SlangKit.skc.${name}
      COMMAND "${CMAKE_COMMAND}" "-DTOOL=$<TARGET_FILE:skc>" "-DARGS=${_args}"
        "-DEXIT=${exit_code}" "-DREGEX=${regex}" -P "${CMAKE_CURRENT_SOURCE_DIR}/RunTool.cmake")
  endfunction()

  skc_test(Usage 2 "give one program")
  skc_test(Program 0 "" ${_data}/surface_host.slang --no-tint)
  skc_test(Reflect 0 "group 0 binding 0: scene" ${_data}/surface_host.slang --reflect --no-tint)
  skc_test(Schema 0 "hooks.amount.*Range.*Amount"
    ${_data}/surface_host.slang -m ${_data}/good_hooks.slang -s IShaderHooks=Halve --schema -
    --no-tint)
  skc_test(BrokenModule 1 "undefinedAmount"
    ${_data}/surface_host.slang -m ${_data}/broken_hooks.slang -s IShaderHooks=Broken --no-tint)
  skc_test(NonUniformWithoutTint 0 ""
    ${_data}/fragment_host.slang -m ${_data}/nonuniform_hooks.slang -s IShaderHooks=Sparkle
    --no-tint)
  if(SLANGKIT_TINT_EXECUTABLE)
    skc_test(UniformWithTint 0 ""
      ${_data}/fragment_host.slang -m ${_data}/good_hooks.slang -s IShaderHooks=Halve
      --tint ${SLANGKIT_TINT_EXECUTABLE})
    skc_test(NonUniformWithTint 1 "uniform control flow"
      ${_data}/fragment_host.slang -m ${_data}/nonuniform_hooks.slang -s IShaderHooks=Sparkle
      --tint ${SLANGKIT_TINT_EXECUTABLE})
  endif()
  add_test(NAME SlangKit.skc.Replay
    COMMAND "${CMAKE_COMMAND}" "-DTOOL=$<TARGET_FILE:skc>" "-DDATA=${_data}"
      "-DWORK=${CMAKE_CURRENT_BINARY_DIR}/replay" -P "${CMAKE_CURRENT_SOURCE_DIR}/ReplayTool.cmake")
endif()
