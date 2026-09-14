# No GPG Keys Negative E2E Test

This sub-workspace verifies that configuring `apt.sources_list` without specifying `gpg_keys` (and without opting in to `allow_unsigned = True`) fails immediately during extension evaluation before making any network requests.

It is executed in CI as an expected-failure build step (`! bazel build //...`).
