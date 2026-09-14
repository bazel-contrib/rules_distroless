# Invalid GPG Key Negative E2E Test

This sub-workspace verifies that configuring `apt.sources_list` with a GPG keyring that does not contain the repository's signing key fails during build and emits a `GPG verification failed` error.

It is executed in CI as an expected-failure build step (`! bazel build //...`).
