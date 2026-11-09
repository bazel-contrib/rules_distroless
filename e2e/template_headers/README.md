# Imported C++ template headers

Run `bazel test //...` here on native AMD64 or ARM64 with a C++ compiler,
CMake and Make available. The tests use the local rules_distroless checkout
and checksum-pinned Debian Boost 1.83 development packages.

`declared_headers_test` requires the Xpressive and Spirit `basic_chset.ipp`
files in the imported compilation context. It fails if the importer drops
those files, even when Boost is installed on the host.

`foreign_headers_test` stages that compilation context through
rules_foreign_cc, builds graph/regex code with CMake/Make, and runs it.
CMake searches only the staged include directory, and the source checks
Boost's version. This reproduces the missing-header failure encountered
while building P4C's graph backend.
