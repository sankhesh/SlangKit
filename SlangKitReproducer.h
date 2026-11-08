// Copyright 2026 Sankhesh Jhaveri
// SPDX-License-Identifier: BSD-3-Clause

#pragma once

#include "SlangKitCompiler.h"

#include <string>
#include <vector>

namespace slangkit {

struct Reproducer
{
  std::string              source;
  std::vector<std::string> programModules;
  std::vector<std::string> entryPoints;
  CompileOptions           options;
};

SLANGKIT_EXPORT std::string reproducerName(const Reproducer& reproducer);

SLANGKIT_EXPORT bool writeReproducer(
  const std::string& directory, const Reproducer& reproducer, const Artifact& artifact);

SLANGKIT_EXPORT bool readReproducer(
  const std::string& directory, Reproducer& reproducer, std::string& error);

}
