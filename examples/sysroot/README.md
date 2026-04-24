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

If you are missing this configuration on an older Bazel version, you will see many warnings like:

> input 'unpack_amd64' to //some_pkg:some_label is a directory; dependency checking of directories is unsound

# Example Usage

The sysroot example is mainly contained in the [MODULE.bazel](/examples/MODULE.bazel) file in the examples.
Check out the inline comments in the example for a description of the basic steps and mandatory configurations.
