# `rules_distroless`

Bazel helper rules to aid with some of the steps needed to create a Linux /
Debian installation. These rules are designed to replace commands such as
`apt-get install`, `passwd`, `groupadd`, `useradd`, `update-ca-certificates`.

> [!CAUTION]
>
> `rules_distroless` is currently in beta and does not yet offer a stable
> Public API. However, many users are already successfully using it in
> production environments. Check [Adopters](#adopters) to see who's already
> using it.

# Contributing

This ruleset is primarily funded to support [Google's `distroless` container
images]. We may not work on feature requests that do not support this mission.

We will however accept fully tested contributions via pull requests if they
align with the project goals (e.g. add support for a different compression
format) and may reject requests that do not (e.g. supporting other packaging
formats other than `.deb`).

> [!TIP]
> There's limited maintainer time for this project, so we strongly encourage
> focused, small, and readable Pull Requests.

# Usage

## Bzlmod (Bazel 6+)

> [!NOTE]
> If you are using Bazel 6 you need to enable Bzlmod by adding
> `common --enable_bzlmod` to `.bazelrc` If you are using Bazel 7+
> [it's enabled by default].

Add the following to your `MODULE.bazel` file:

```starlark
bazel_dep(name = "rules_distroless", version = "0.5.1")
```

You can find the latest release version in the [Bazel Central Registry].

If you want to use a specific commit (e.g. there are commits in `main` that are
still not part of a release) you can use one of the few mechanisms that Bazel
provides to override repos.

You can use [`git_override`], [`archive_override`], etc (or
[`local_path_override`] if you want to test a local patch):

```starlark
bazel_dep(name = "rules_distroless", version = "0.5.1")

git_override(
    module_name = "rules_distroless",
    remote = "https://github.com/bazel-contrib/rules_distroless.git",
    commit = "a69bc1949d5daf2d1b0906890667d69b0897688b",
)
```

## `WORKSPACE` (legacy)

> [!WARNING]
> Bzlmod is replacing the legacy `WORKSPACE` system. The `WORKSPACE` file will
> be disabled by default in Bazel 8 (late 2024) and will be completely removed
> in Bazel 9 (late 2025). Please migrate to Bzlmod following the steps in the
> [Bzlmod migration guide].

You can find the latest release in the [`rules_distroless` Github releases
page].

# Examples

The [examples](/examples) demonstrate how to accomplish typical tasks such as
**create a new user group** or **create a new home directory**:

- [groupadd](/examples/group)
- [passwd](/examples/passwd)
- [useradd --home](/examples/home)
- [update-ca-certificates](/examples/cacerts)
- [keytool](/examples/java_keystore)
- [apt-get install](/examples/debian_snapshot) from Debian repositories.
- [apt-get install](/examples/ubuntu_snapshot) from Ubuntu repositories.

We also have `distroless`-specific rules that could be useful:

- [flatten](/examples/flatten): flatten multiple `tar` archives.
- [os_release](/examples/os_release): create an `/etc/os-release` file.
- [locale](/examples/locale): strip `/usr/lib/locale` to be smaller.
- [dpkg_statusd](/examples/statusd): creates a `/var/lib/dpkg/status.d`
  package database for scanners to discover installed packages.

# Public API Docs

To read more specific documentation for each of the rules in the repo please
check the following docs:

- [apt](/docs/apt.md): repository rule for installing Debian/Ubuntu packages.
- [apt macro](/docs/apt_macro.md): legacy macro for installing Debian/Ubuntu
  packages.
- [rules](/docs/rules.md): various helper rules to aid with creating a Linux /
  Debian installation from scratch.

# Adopters

- [Google's `distroless` container images](https://github.com/GoogleContainerTools/distroless)
- [Arize AI](https://www.arize.com)

> [!TIP]
> Are you using `rules_distroless`? Please send us a Pull Request to add your
> project or company name here!

[it's enabled by default]: https://blog.bazel.build/2023/12/11/bazel-7-release.html#bzlmod
[Bazel Central Registry]: https://registry.bazel.build/modules/rules_distroless
[`git_override`]: https://bazel.build/versions/6.0.0/rules/lib/globals#git_override
[`archive_override`]: https://bazel.build/versions/6.0.0/rules/lib/globals#archive_override
[`local_path_override`]: https://bazel.build/versions/6.0.0/rules/lib/globals#local_path_override
[Bzlmod migration guide]: https://bazel.build/external/migration
[`rules_distroless` Github releases page]: https://github.com/bazel-contrib/rules_distroless/releases
[Update on the future stability of source code archives and hashes]: https://github.blog/2023-02-21-update-on-the-future-stability-of-source-code-archives-and-hashes
[Google's `distroless` container images]: https://github.com/bazel-contrib/distroless
[Arize AI]: https://www.arize.com
