# Copyright 2026 Sankhesh Jhaveri
# SPDX-License-Identifier: BSD-3-Clause

cmake_minimum_required(VERSION 3.21)

project(SlangKit VERSION 0.1.0 LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)
set(CMAKE_INSTALL_MESSAGE LAZY)

include(GNUInstallDirs)
include(CMakePackageConfigHelpers)
include(FetchContent)

# Installed libraries find SlangKit and Slang next to them; skc finds them from bin/.
if(APPLE)
  set(CMAKE_INSTALL_RPATH "@loader_path;@loader_path/../${CMAKE_INSTALL_LIBDIR}")
else()
  set(CMAKE_INSTALL_RPATH "$ORIGIN;$ORIGIN/../${CMAKE_INSTALL_LIBDIR}")
endif()

option(SLANGKIT_USE_SLANG "Enable Slang JIT compilation" ON)
set(SLANGKIT_SLANG_ENABLED FALSE)

if(SLANGKIT_USE_SLANG AND NOT EMSCRIPTEN)
  find_package(Slang QUIET)

  if(NOT Slang_FOUND)
    set(_SLANG_VER "2026.13.1")
    if(APPLE AND CMAKE_SYSTEM_PROCESSOR MATCHES "arm64|aarch64")
      set(_SLANG_ARCHIVE "slang-${_SLANG_VER}-macos-aarch64.zip")
    elseif(APPLE)
      set(_SLANG_ARCHIVE "slang-${_SLANG_VER}-macos-x86_64.zip")
    elseif(WIN32)
      set(_SLANG_ARCHIVE "slang-${_SLANG_VER}-windows-x86_64.zip")
    else()
      set(_SLANG_ARCHIVE "slang-${_SLANG_VER}-linux-x86_64.zip")
    endif()

    FetchContent_Declare(slang_dist
      URL "https://github.com/shader-slang/slang/releases/download/v${_SLANG_VER}/${_SLANG_ARCHIVE}"
      DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
    FetchContent_MakeAvailable(slang_dist)

    set(_SLANG_INC "${slang_dist_SOURCE_DIR}/include")
    if(APPLE)
      set(_SLANG_LIB "${slang_dist_SOURCE_DIR}/lib/libslang.dylib")
    elseif(WIN32)
      set(_SLANG_LIB "${slang_dist_SOURCE_DIR}/bin/slang.dll")
    else()
      set(_SLANG_LIB "${slang_dist_SOURCE_DIR}/lib/libslang.so")
    endif()

    if(EXISTS "${_SLANG_LIB}" AND EXISTS "${_SLANG_INC}/slang.h")
      add_library(Slang::Slang SHARED IMPORTED GLOBAL)
      set_target_properties(Slang::Slang PROPERTIES
        IMPORTED_LOCATION             "${_SLANG_LIB}"
        INTERFACE_INCLUDE_DIRECTORIES "${_SLANG_INC}")
      set(Slang_FOUND TRUE)
    endif()
  endif()

  if(Slang_FOUND)
    set(SLANGKIT_SLANG_ENABLED TRUE)
    message(STATUS "SlangKit: Slang found — JIT compilation enabled (SPIR-V + WGSL output)")
  else()
    message(STATUS "SlangKit: Slang not found — only precompiled programs are available")
  endif()
else()
  message(STATUS "SlangKit: Slang disabled — only precompiled programs are available")
endif()

set(_PUBLIC_INCLUDE_DIR "${CMAKE_CURRENT_BINARY_DIR}/include")
configure_file(
  "${CMAKE_CURRENT_SOURCE_DIR}/cmake/SlangKitVersion.h.in"
  "${_PUBLIC_INCLUDE_DIR}/SlangKitVersion.h"
  @ONLY)
foreach(_header IN ITEMS SlangKit.h SlangKitCompiler.h SlangKitParameters.h SlangKitReproducer.h
    SlangKitWebGPU.h)
  configure_file("${CMAKE_CURRENT_SOURCE_DIR}/${_header}" "${_PUBLIC_INCLUDE_DIR}/${_header}"
    COPYONLY)
endforeach()

set(_SHADER_DIR   "${CMAKE_CURRENT_SOURCE_DIR}/shaders")
set(_SOURCES_HDR  "${CMAKE_CURRENT_BINARY_DIR}/SlangKitSources.h")

set(_SLANG_FILES
  "${_SHADER_DIR}/slangkit_attributes.slang"
  "${_SHADER_DIR}/slangkit_core.slang"
  "${_SHADER_DIR}/slangkit_shading.slang"
  "${_SHADER_DIR}/slangkit_hooks.slang"
  "${_SHADER_DIR}/slangkit_surface.slang")

add_custom_command(
  OUTPUT  "${_SOURCES_HDR}"
  COMMAND "${CMAKE_COMMAND}"
    -DSHADER_DIR=${_SHADER_DIR}
    -DOUT_HEADER=${_SOURCES_HDR}
    -P "${CMAKE_CURRENT_SOURCE_DIR}/cmake/EmbedShaders.cmake"
  DEPENDS ${_SLANG_FILES}
          "${CMAKE_CURRENT_SOURCE_DIR}/cmake/EmbedShaders.cmake"
  COMMENT "Embedding Slang shader sources into SlangKitSources.h"
  VERBATIM)

add_custom_target(SlangKit_embed_shaders DEPENDS "${_SOURCES_HDR}")

add_library(SlangKit SHARED
  SlangKitCompiler.cpp
  SlangKitParameters.cpp
  SlangKitReproducer.cpp)

add_library(SlangKit::SlangKit ALIAS SlangKit)

add_dependencies(SlangKit SlangKit_embed_shaders)

target_include_directories(SlangKit
  PUBLIC
    $<BUILD_INTERFACE:${_PUBLIC_INCLUDE_DIR}>
    $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}/SlangKit>
  PRIVATE
    "${CMAKE_CURRENT_BINARY_DIR}")

if(SLANGKIT_SLANG_ENABLED)
  target_link_libraries(SlangKit PRIVATE Slang::Slang)
  target_compile_definitions(SlangKit PRIVATE SLANGKIT_USE_SLANG)
endif()

include(GenerateExportHeader)
generate_export_header(SlangKit
  EXPORT_MACRO_NAME SLANGKIT_EXPORT
  EXPORT_FILE_NAME  "${_PUBLIC_INCLUDE_DIR}/SlangKitExport.h")

option(SLANGKIT_BUILD_TOOLS "Build the skc command line tool" ${PROJECT_IS_TOP_LEVEL})
if(SLANGKIT_SLANG_ENABLED AND SLANGKIT_BUILD_TOOLS)
  find_program(SLANGKIT_TINT_EXECUTABLE tint
    DOC "tint executable that skc uses by default to validate WGSL")
  set(_tint "")
  if(SLANGKIT_TINT_EXECUTABLE)
    set(_tint "${SLANGKIT_TINT_EXECUTABLE}")
  endif()
  add_executable(skc tools/skc.cpp)
  add_executable(SlangKit::skc ALIAS skc)
  target_link_libraries(skc PRIVATE SlangKit)
  target_compile_definitions(skc PRIVATE SLANGKIT_TINT_EXECUTABLE="${_tint}")
  install(TARGETS skc EXPORT SlangKitTargets RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})
endif()

install(TARGETS SlangKit
  EXPORT  SlangKitTargets
  LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
  ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
  RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR}
  INCLUDES DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/SlangKit)

# A downloaded Slang is installed nowhere else, so install the parts of its runtime that SlangKit
# loads. slang-llvm and slang-rt only serve CPU targets.
if(SLANGKIT_SLANG_ENABLED AND DEFINED slang_dist_SOURCE_DIR)
  if(WIN32)
    install(DIRECTORY "${slang_dist_SOURCE_DIR}/bin/"
      DESTINATION ${CMAKE_INSTALL_BINDIR}
      FILES_MATCHING PATTERN "slang*.dll"
      PATTERN "slang-llvm*" EXCLUDE
      PATTERN "slang-rt*" EXCLUDE)
  else()
    install(DIRECTORY "${slang_dist_SOURCE_DIR}/lib/"
      DESTINATION ${CMAKE_INSTALL_LIBDIR}
      FILES_MATCHING PATTERN "libslang*"
      PATTERN "libslang-llvm*" EXCLUDE
      PATTERN "libslang-rt*" EXCLUDE
      PATTERN "cmake" EXCLUDE
      PATTERN "pkgconfig" EXCLUDE
      PATTERN "slang-standard-module-*" EXCLUDE)
  endif()
endif()

install(FILES
  "${_PUBLIC_INCLUDE_DIR}/SlangKit.h"
  "${_PUBLIC_INCLUDE_DIR}/SlangKitCompiler.h"
  "${_PUBLIC_INCLUDE_DIR}/SlangKitParameters.h"
  "${_PUBLIC_INCLUDE_DIR}/SlangKitReproducer.h"
  "${_PUBLIC_INCLUDE_DIR}/SlangKitWebGPU.h"
  "${_PUBLIC_INCLUDE_DIR}/SlangKitVersion.h"
  "${_PUBLIC_INCLUDE_DIR}/SlangKitExport.h"
  DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/SlangKit)

install(DIRECTORY shaders/
  DESTINATION ${CMAKE_INSTALL_DATADIR}/SlangKit/shaders
  FILES_MATCHING PATTERN "*.slang")

install(EXPORT SlangKitTargets
  FILE      SlangKitTargets.cmake
  NAMESPACE SlangKit::
  DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/SlangKit)

export(EXPORT SlangKitTargets
  FILE      "${CMAKE_CURRENT_BINARY_DIR}/SlangKitTargets.cmake"
  NAMESPACE SlangKit::)

configure_package_config_file(
  "${CMAKE_CURRENT_SOURCE_DIR}/cmake/SlangKitConfig.cmake.in"
  "${CMAKE_CURRENT_BINARY_DIR}/SlangKitConfig.cmake"
  INSTALL_DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/SlangKit")

write_basic_package_version_file(
  "${CMAKE_CURRENT_BINARY_DIR}/SlangKitConfigVersion.cmake"
  VERSION ${PROJECT_VERSION}
  COMPATIBILITY SameMajorVersion)

install(FILES
  "${CMAKE_CURRENT_BINARY_DIR}/SlangKitConfig.cmake"
  "${CMAKE_CURRENT_BINARY_DIR}/SlangKitConfigVersion.cmake"
  DESTINATION "${CMAKE_INSTALL_LIBDIR}/cmake/SlangKit")

option(SLANGKIT_BUILD_TESTING "Build SlangKit tests" ${PROJECT_IS_TOP_LEVEL})
if(SLANGKIT_BUILD_TESTING)
  enable_testing()
  add_subdirectory(tests)
endif()
