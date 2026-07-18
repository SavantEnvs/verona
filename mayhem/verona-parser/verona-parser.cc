// Copyright Microsoft and Project Verona Contributors.
// SPDX-License-Identifier: MIT
//
// In-process libFuzzer harness for the Verona front-end lexer/parser.
//
// The old mayhemheroes/verona Mayhem target `verona-parser` was a raw file-CLI
// (`/verona-parser @@`): an uninstrumented black box that yields 0 edges under
// Mayhem. This replaces it with an in-process libFuzzer harness driving the
// SAME code path — `verona::parser().parse(source)` — fully instrumented with
// ASan+UBSan and SanitizerCoverage.
//
// NB: this file is not compiled on its own. mayhem/build.sh emits a single
// unity translation unit that #includes every src/*.cc (except main.cc) and
// then this file, so all of Verona's `inline` well-formedness DSL globals
// (wf.h) are defined and initialised in ONE TU in source order. Verona's
// multi-TU layout otherwise trips a static-initialisation-order fiasco (the wf
// DSL maps are built from Token globals that another TU may not have
// initialised yet) which SEGVs before main. The unity build makes the order
// deterministic; see mayhem/build.sh for the rationale.
#include "lang.h"

#include <cstddef>
#include <cstdint>
#include <string>
#include <trieste/driver.h>

// `verona::Options::configure` lives in the compiler's main.cc — the one
// translation unit the fuzz build deliberately excludes (it carries `main`).
// Re-provide it here so the `verona::Options` vtable/typeinfo is emitted; this
// mirrors main.cc exactly.
namespace verona
{
  void Options::configure(CLI::App& cli)
  {
    cli.add_flag("--no-std", no_std, "Don't import the standard library.");
  }
}

extern "C" int LLVMFuzzerTestOneInput(const uint8_t* data, size_t size)
{
  std::string input(reinterpret_cast<const char*>(data), size);
  auto source = trieste::SourceDef::synthetic(input);

  try
  {
    auto ast = verona::parser().parse(source);
    (void)ast;
  }
  catch (...)
  {
    // A thrown C++ exception is not a memory-safety defect; swallow it so the
    // fuzzer keeps exploring. ASan/UBSan aborts (real defects) still terminate.
  }

  return 0;
}
