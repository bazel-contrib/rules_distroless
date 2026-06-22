# Using rules_distroless to generate a sysroot for toolchains_llvm

It is possible to create sysroots for toolchains_llvm on the fly using rules_distroless.
This allows a low-effort hermetic C++ toolchain setup, without having to keep track of the sysroot
outside of Bazel.

# Prerequisites

Sysroots for toolchains_llvm require the "mergedusr" layout.
To enable this, we require dependency checking of directories in Bazel.
This was enabled by default with Bazel 8.5.1 (https://github.com/bazelbuild/bazel/pull/25870).

If you are using an older version of Bazel, you can enable this by adding the following line in your `.bazelrc`:

```
startup --host_jvm_args=-DBAZEL_TRACK_SOURCE_DIRECTORIES=1
```

If you are missing this configuration on an older Bazel version, you will see many warnings about directory inputs.

# Example Usage

The sysroot example is configured in the [MODULE.bazel](/examples/MODULE.bazel) file.

## Configuration Steps

### 1. Define Package Sources
First, specify the package sources (URLs, suites, architectures):

```starlark
apt.sources_list(
    architectures = ["amd64", "arm64"],
    components = ["main"],
    suites = ["noble", "noble-security", "noble-updates"],
    types = ["deb"],
    uris = ["https://snapshot.ubuntu.com/ubuntu/20260401T000000Z"],
)
```

### 2. Install Packages
Define the packages to include in your sysroot using `apt.install` with `mergedusr=True`:

```starlark
apt.install(
    dependency_set = "ubuntu24_04_sysroot",
    packages = [
        "libc6",
        "libc6-dev",
        "linux-libc-dev",
        "libstdc++6",
        "libstdc++-13-dev",
        "libgcc-s1",
        "libatomic1",
    ],
    suites = ["noble", "noble-security", "noble-updates"],
    mergedusr = True,  # Required for toolchains_llvm
)
```

### 3. Create Sysroot for Specific Architectures
Use `apt.sysroot` to create separate unpacked sysroot repositories for specific architectures:

```starlark
apt.sysroot(
    dependency_set = "ubuntu24_04_sysroot",
    architectures = ["amd64", "arm64"],
)
```

This creates separate repositories:
- `@ubuntu24_04_sysroot_amd64` with unpacked sysroot at `//sysroot`
- `@ubuntu24_04_sysroot_arm64` with unpacked sysroot at `//sysroot`

Each sysroot repository is independent and contains only the unpacked files for that architecture.

### 4. Configure LLVM Toolchain
Reference the separate sysroot repositories in your toolchains_llvm configuration:

```starlark
llvm = use_extension(
    "@toolchains_llvm//toolchain/extensions:llvm.bzl",
    "llvm",
    dev_dependency = True,
)
llvm.toolchain(
    llvm_version = "19.1.7",
    stdlib = {"": "stdc++"},
)

llvm.sysroot(
    name = "llvm_toolchain",
    label = "@ubuntu24_04_sysroot_amd64//sysroot",
    targets = ["linux-x86_64"],
)
llvm.sysroot(
    name = "llvm_toolchain",
    label = "@ubuntu24_04_sysroot_arm64//sysroot",
    targets = ["linux-aarch64"],
)
use_repo(llvm, "llvm_toolchain")
register_toolchains("@llvm_toolchain//:cc-toolchain-x86_64-linux", dev_dependency=True)
```

# Why This Design?

The separation of concerns and architecture-specific repositories provides:

1. **Clarity**: `apt.install` focuses on package selection and layout options (mergedusr), 
   while `apt.sysroot` explicitly indicates which architectures need unpacked sysroots.

2. **Independent Repositories**: Each sysroot architecture is a separate repository, 
   allowing independent management, caching, and reuse across different toolchain configurations.

3. **Architecture Isolation**: Each sysroot repo contains only the files for a single architecture,
   avoiding cross-architecture dependencies and reducing repository size.

4. **Repository Fetch Time**: The sysroot unpacking happens at repository fetch time 
   (when Bazel initializes the extension), making the unpacked directories available 
   to toolchains and other build rules immediately.

5. **Flexibility**: You can use the same dependency set in different contexts:
   - Create sysroots for only the architectures you need
   - Reference the sysroots directly from the architecture-specific repositories
   - Combine multiple sysroot repositories in your toolchain configuration
