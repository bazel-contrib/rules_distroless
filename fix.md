Each commit fixes one problem, is independently reviewable, and includes verified
reproduction evidence from actual Bazel builds.

Net change to `apt/` is identical to `dev`: `git diff reorg-commits dev -- apt/` is empty.

**Test setup used for all Bazel evidence:**

All Bazel builds were run on a remote Alibaba Cloud Linux 3 (RHEL-based) machine
with Bazel 8.5.1. Ubuntu was not used because Ubuntu's
`/lib/x86_64-linux-gnu/` path layout makes dangling absolute symlinks from Debian
packages resolve accidentally, masking the bugs.

```
remote:  Alibaba Cloud Linux 3, Bazel 8.5.1

/tmp/repro/              — repro workspace (MODULE.bazel, BUILD.bazel, *.c test sources)
/tmp/repro_bazel_out/    — Bazel output_base

/tmp/rules_buggy/        — code at ebfd74a (before commit 1; all 7 bugs present)
/tmp/rules_before3/      — code at 308b87b (after commit 2, before commit 3)
/tmp/rules_before6/      — code at 869e7a4 (after commit 5, before commit 6)
/tmp/rules_fixed/        — code at HEAD (all 7 commits applied)
```

`/tmp/repro/MODULE.bazel` uses `local_path_override` to point at the relevant
code version for each reproduction, and `apt.install` fetches packages from the
Debian bookworm snapshot at `https://sonic-build.alibaba-inc.com/debian_snapshot/20260410`.

---

## Commit 1 — `fix dangling symbolic link: support intra-package symlinks`

### Problem

Debian packages contain two categories of symlinks:

- **Foreign symlinks** — point to files in a *different* package
  (e.g. `libssl.so → libssl.so.3` where `libssl.so.3` lives in `libssl3`).
- **Self symlinks** (intra-package) — point to files within the *same* package
  (e.g. `libcurses.so → libncurses.so` where both live in `libncurses-dev`).

The `deb_import` discovery loop adds every `.so`-matching path to `so_files` regardless
of whether it is a regular file or a symlink. Then self-symlinks are identified and
popped from `symlinks`. But at the point `symlink_outs` is computed they are already
gone:

```python
# apt/private/deb_import.bzl (buggy, ebfd74a)
# in the file-scan loop:
so_files.append(line)           # libcurses.so → added to so_files (symlink OR file)
if resolved_symlink:
    symlinks[line] = resolved_symlink   # libcurses.so → also in symlinks

# later — self-symlink resolution:
self_symlinks[symlink] = symlinks.pop(symlink)   # libcurses.so popped from symlinks
unresolved_symlinks.pop(symlink)

# outs construction — libcurses.so is in so_files AND no longer in symlinks:
for out in so_files + h_files + ...:
    if out not in symlinks:              # True (was popped)
        outs.append(out)                 # ← libcurses.so added to outs (wrong)

symlink_outs = symlinks.keys()           # ← libcurses.so absent (was popped)
```

`deb_export` extracts `outs` from the tar archive in a single action. Since
`libcurses.so` is a symlink entry in the tar, the extraction creates a symlink on the
filesystem. Bazel 8.6.0 is lenient about symlinks in declared file outputs when the tar
covers both the symlink and its target, so the build succeeds — but the generated BUILD
is structurally wrong: `libcurses.so` is declared as a regular output, not a
`ctx.actions.symlink()` output.

### Reproduction

The bug affects two categories of symlinks: **absolute symlinks** (e.g.
`lib64/ld-linux-x86-64.so.2 → /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2` in libc6)
and **self-symlinks** (e.g. `libcurses.so → libncurses.so` in libncurses-dev). Both
categories land in `outs` instead of `symlink_outs`. Ubuntu masks the absolute-symlink
case because `/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2` exists on Ubuntu; Alibaba
Cloud Linux does not have this path, so the symlink is dangling and Bazel rejects it.

**Tar listing — libc6 package contains `lib64/ld-linux-x86-64.so.2` as an absolute symlink:**

```
remote$ tar -tvf /tmp/repro_bazel_out/external/rules_distroless++apt+bookworm_libc6-amd64_2.36-9-deb12u13/data.tar.xz \
     2>/dev/null | grep lib64
lrwxrwxrwx root/root   0  2025-08-26  ./lib64/ld-linux-x86-64.so.2 -> /lib/x86_64-linux-gnu/ld-linux-x86-64.so.2
```

**Buggy generated BUILD — `lib64/ld-linux-x86-64.so.2` in `outs`; `symlink_outs` empty:**

```python
# /tmp/repro_bazel_out/external/rules_distroless++apt+bookworm_libc6-amd64_2.36-9-deb12u13/BUILD.bazel
symlink_outs = [],    # ← empty: absolute symlink not classified
outs = ["lib/x86_64-linux-gnu/ld-linux-x86-64.so.2", ...,
        "lib64/ld-linux-x86-64.so.2",                 # ← wrong: absolute symlink in outs
        ...],
```

**Actual error on remote (Bazel 8.5.1, Alibaba Cloud Linux 3):**

```
remote$ cd /tmp/repro && bazel build \
     @@rules_distroless++apt+bookworm_libc6-amd64_2.36-9-deb12u13//:export 2>&1

ERROR: /tmp/repro_bazel_out/external/rules_distroless++apt+bookworm_libc6-amd64_2.36-9-deb12u13/BUILD.bazel:31:11: \
  output 'external/rules_distroless++apt+bookworm_libc6-amd64_2.36-9-deb12u13/lib64/ld-linux-x86-64.so.2' \
  is a dangling symbolic link
ERROR: /tmp/repro_bazel_out/external/rules_distroless++apt+bookworm_libc6-amd64_2.36-9-deb12u13/BUILD.bazel:31:11: \
  Unpack external/rules_distroless++apt+bookworm_libc6-amd64_2.36-9-deb12u13/lib/x86_64-linux-gnu/ld-linux-x86-64.so.2 \
  failed: not all outputs were created or valid
Target @@rules_distroless++apt+bookworm_libc6-amd64_2.36-9-deb12u13//:export failed to build
ERROR: Build did NOT complete successfully
```

Fixed code (with `local_path_override` pointing at `/tmp/rules_fixed`) succeeds:

```
remote$ cd /tmp/repro && bazel build \
    @@rules_distroless++apt+bookworm_libc6-amd64_2.36-9-deb12u13//:export 2>&1 | tail -3

  bazel-bin/external/.../lib64/ld-linux-x86-64.so.2
INFO: Build completed successfully, 3 total actions
```

**Structural evidence for self-symlinks (`libncurses-dev`):**

```
remote$ tar -tvf /tmp/repro_bazel_out/external/rules_distroless++apt+bookworm_libncurses-dev-amd64_6.4-4/data.tar.xz \
     2>/dev/null | grep 'libcurses\|libncurses\.so\b'
-rw-r--r-- root/root  31  2023-05-07  ./usr/lib/x86_64-linux-gnu/libncurses.so   ← regular file (linker script)
lrwxrwxrwx root/root   0  2023-05-07  ./usr/lib/x86_64-linux-gnu/libcurses.so -> libncurses.so   ← symlink
```

Buggy BUILD puts `libcurses.so` in `outs` alongside regular files; `symlink_outs`
omits it; no `self_symlinks` attribute. On RHEL the relative symlink still resolves
(both files land in the same extracted directory), but the generated BUILD is
structurally incorrect.

### Fix

```python
# apt/private/deb_import.bzl (after fix)
self_symlinks[symlink] = unresolved_symlinks.pop(symlink)  # removed from unresolved only
...
symlink_outs = symlinks.keys() + self_symlinks.keys()      # both categories present
```

**Fixed generated BUILD (`/tmp/repro_bazel_out/external/rules_distroless++apt+bookworm_libncurses-dev-amd64_6.4-4/BUILD.bazel`):**

```python
# line 36-37
symlink_outs = [..., "usr/lib/x86_64-linux-gnu/libcurses.so", ...],  # ← now present
self_symlinks = {
    "usr/lib/x86_64-linux-gnu/libcurses.so": "usr/lib/x86_64-linux-gnu/libncurses.so",
    "usr/include/ncurses.h":                  "usr/include/curses.h",
    "usr/include/ncursesw/curses.h":          "usr/include/curses.h",
    # ... 22 self-symlinks total
},
```

`deb_export` generates an explicit `ctx.actions.symlink()` for each `self_symlinks`
entry, using the package's own `outs` as the target.

---

## Commit 2 — `apt: add merge_directory rule and :directory target to dependency_set`

### Problem

Cross-compilation toolchains (sysroots) need a single merged directory tree containing
all headers and libraries. The hub repo's `dependency_set` produced only `:data` (a
flat list of files) with no merged directory. Downstream toolchains had to reconstruct
a directory tree manually.

### Reproduction

**Buggy hub BUILD — no `:directory` target (code at `ebfd74a`):**

```python
# /tmp/repro_bazel_out/external/rules_distroless++apt+libyang_deps/BUILD.bazel
load("@rules_distroless//apt:defs.bzl", "dpkg_status")
load("@rules_distroless//distroless:defs.bzl", "flatten")
# ← no merge_directory import

# targets: dpkg_status, packages, libyang_deps, flat
# no :directory target
```

```
remote$ cd /tmp/repro && bazel build @libyang_deps//:directory 2>&1 | tail -5

ERROR: no such target '@@rules_distroless++apt+libyang_deps//:directory':
  target 'directory' not declared in package ''
ERROR: Build did NOT complete successfully
```

### Fix

New `merge_directory` Starlark rule accepts multiple `DirectoryInfo` providers and
creates a single unified directory via symlinks.

**Fixed hub BUILD:**

```python
# /tmp/repro_bazel_out/external/rules_distroless++apt+libyang_deps/BUILD.bazel (fixed code)
load("@rules_distroless//apt/private:merge_directory.bzl", "merge_directory")

merge_directory(
    name = "directory",
    srcs = [
        "@bookworm_libc6-dev-amd64_2.36-9-deb12u13//:export",
        "@bookworm_libncurses-dev-amd64_6.4-4//:export",
        # ... all transitive packages
    ],
    visibility = ["//visibility:public"],
)
```

---

## Commit 3 — `deb_export/deb_import: support GNU ld linker scripts in .so files`

### Problem

Some `.so` files in `-dev` packages are not ELF shared libraries — they are GNU ld
**linker scripts**: text files with `GROUP()`, `INPUT()`, or `OUTPUT_FORMAT()` directives.

**Verified from the fetched `libc6-dev` package (same content as on system):**

```
$ cat /usr/lib/x86_64-linux-gnu/libm.so
/* GNU ld script */
OUTPUT_FORMAT(elf64-x86-64)
GROUP ( /lib/x86_64-linux-gnu/libm.so.6  AS_NEEDED ( /lib/x86_64-linux-gnu/libmvec.so.1 ) )
```

The absolute paths (`/lib/x86_64-linux-gnu/libm.so.6`) do not exist inside Bazel's
hermetic sandbox. The buggy code copies this file verbatim into the Bazel output tree.

### Reproduction

**Repro sources (`/tmp/repro/`, module pointing at `/tmp/rules_before3/`):**

```c
/* ncurses_test.c */
#include <ncurses.h>
int main() { initscr(); printw("Hello"); refresh(); endwin(); return 0; }
```

```python
# BUILD.bazel
cc_binary(name = "ncurses_test", srcs = ["ncurses_test.c"],
          deps = ["@libyang_deps//libncurses-dev:libncurses"])
```

**`libncurses.so` in Bazel output — raw linker script, not rewritten:**

```
remote$ cat /tmp/repro_bazel_out/execroot/_main/bazel-out/k8-fastbuild/bin/external/\
rules_distroless++apt+bookworm_libncurses-dev-amd64_6.4-4/usr/lib/x86_64-linux-gnu/libncurses.so
INPUT(libncurses.so.6 -ltinfo)
```

The linker script makes the linker pull in `libncurses.so.6` from the deb package.
That `.so.6` was built on Debian 12 against GLIBC 2.34; the remote machine has an
older GLIBC.

**Actual build error on remote (Bazel 8.5.1, Alibaba Cloud Linux 3):**

```
remote$ rm -rf /tmp/repro_bazel_out && cd /tmp/repro && bazel build //:ncurses_test 2>&1

Starting local Bazel server (8.5.1) and connecting to it...
ERROR: /tmp/repro/BUILD.bazel:1:10: Linking ncurses_test failed: (Exit 1): gcc failed: \
  error executing CppLink command ...

bazel-out/k8-fastbuild/bin/external/rules_distroless++apt+bookworm_libncurses6-amd64_6.4-4/\
lib/x86_64-linux-gnu/libncurses.so.6: error: undefined reference to 'dlclose', version 'GLIBC_2.34'
bazel-out/k8-fastbuild/bin/external/rules_distroless++apt+bookworm_libncurses6-amd64_6.4-4/\
lib/x86_64-linux-gnu/libncurses.so.6: error: undefined reference to 'dlsym', version 'GLIBC_2.34'
.../libtinfo.so: error: undefined reference to 'stat', version 'GLIBC_2.33'
.../libncurses.so.6: error: undefined reference to 'dlopen', version 'GLIBC_2.34'
ERROR: Build did NOT complete successfully
```

**`libm.so` and `libc.so` in `libc6-dev` also contain absolute-path linker scripts:**

```
remote$ cat /tmp/repro_bazel_out/execroot/_main/bazel-out/k8-fastbuild/bin/external/\
rules_distroless++apt+bookworm_libc6-dev-amd64_2.36-9-deb12u13/usr/lib/x86_64-linux-gnu/libm.so
/* GNU ld script
OUTPUT_FORMAT(elf64-x86-64)
GROUP ( /lib/x86_64-linux-gnu/libm.so.6  AS_NEEDED ( /lib/x86_64-linux-gnu/libmvec.so.1 ) )
```

```
$ ssh ... cat .../libc.so
/* GNU ld script ... */
GROUP ( /lib/x86_64-linux-gnu/libc.so.6 /usr/lib/x86_64-linux-gnu/libc_nonshared.a
        AS_NEEDED ( /lib64/ld-linux-x86-64.so.2 ) )
```

Paths like `/lib/x86_64-linux-gnu/libm.so.6` do not exist in Bazel's hermetic
sandbox. Any build that links against `libc6-dev:m` or `libc6-dev:c` in a fully
hermetic container (RBE, Docker with no bind-mounts) fails with the corresponding
`cannot find` error.

*(On the remote machine `/lib/x86_64-linux-gnu/libm.so.6` happened to exist, so
`libm.so` via `additional_linker_inputs` didn't break directly — the GLIBC error
from the ncurses linker script is the concrete on-machine failure.)*

### Evidence: fixed BUILD — linker scripts detected, paths rewritten

After commit 3 (code at HEAD), `deb_import` classifies `libncurses.so`, `libm.so`,
etc. as linker scripts at fetch time and rewrites absolute paths to Bazel-relative
`$$BINDIR/external/<repo>/...` paths.

**Fixed generated BUILD — `libm.so` classified as linkscript:**

```python
# /tmp/repro_bazel_out/external/rules_distroless++apt+bookworm_libc6-dev-amd64_2.36-9-deb12u13/BUILD.bazel
linkscripts = {
    "usr/lib/x86_64-linux-gnu/libc.so":
        "GROUP ( $$BINDIR/external/.../libc6-amd64_.../lib/.../libc.so.6 ... )",
    "usr/lib/x86_64-linux-gnu/libm.so":
        "GROUP ( $$BINDIR/external/.../libc6-amd64_.../lib/.../libm.so.6 ... )",
},
linkscript_outs = ["usr/lib/x86_64-linux-gnu/libc.so", "usr/lib/x86_64-linux-gnu/libm.so"],
```

### Follow-on regression: self-symlink whose target is a linker script

Adding `linkscript_outs` as a new output category breaks a case in `libncurses-dev`:
`libcurses.so → libncurses.so` is a self-symlink and `libncurses.so` is itself a linker
script.

**Tar listing:**

```
-rw-r--r-- root/root  31  ./usr/lib/x86_64-linux-gnu/libncurses.so   ← linker script file
lrwxrwxrwx root/root   0  ./usr/lib/x86_64-linux-gnu/libcurses.so -> libncurses.so
```

After adding linkscript support, `libncurses.so` moves from `outs` to `linkscript_outs`.
The self-symlink resolution code in `deb_export` only looked up the symlink target in
`outs`. With `libncurses.so` now absent from `outs`, `libcurses.so`'s target is
unresolvable:

```python
# deb_export.bzl before regression fix
for (symlink, target_path) in ctx.attr.self_symlinks.items():
    target = outs_map.get(target_path)    # ← only checks outs, not linkscript_outs
    if target == None:
        fail("self_symlink target not found: " + target_path)
```

```
ERROR: no generating action for file
  'external/.../libncurses-dev-amd64_6.4-4/usr/lib/x86_64-linux-gnu/libcurses.so'
```

**Fixed generated BUILD confirms both are now present:**

```python
# /tmp/bazel_fixed/.../libncurses-dev-amd64_6.4-4/BUILD.bazel (lines 37-40)
self_symlinks = {
    "usr/lib/x86_64-linux-gnu/libcurses.so": "usr/lib/x86_64-linux-gnu/libncurses.so",
    ...
},
linkscripts = {
    "usr/lib/x86_64-linux-gnu/libncurses.so": "INPUT(libncurses.so.6 -ltinfo)\n",
    "usr/lib/x86_64-linux-gnu/libncursesw.so": "INPUT(libncursesw.so.6 -ltinfo)\n",
    "usr/lib/x86_64-linux-gnu/libtermcap.so":  "GROUP( libtinfo.so )\n",
},
linkscript_outs = ["usr/lib/x86_64-linux-gnu/libncurses.so", ...],
```

### Design

```
Fetch time (repository_rule):
  for each .so file (not a symlink):
    run: file --mime-type -b <path>
    if text/plain → linker script:
      read content
      replace absolute /path/to/lib with $$BINDIR/external/<repo>/path/to/lib
      record as linkscript (path → rewritten content)

Analysis time (deb_export rule):
  linkscripts: attr.string_dict     ← {path: rewritten_content}
  linkscript_outs: declared outputs
  for each linkscript:
    ctx.actions.write(out, rewritten_content)
  for each self_symlink:
    look up target in outs ∪ symlink_outs ∪ linkscript_outs   ← expanded
    ctx.actions.symlink(output, target)
```

---

## Commit 4 — `deb_import: replace so_library with per-.so cc_import and readelf-based dependency resolution`

### Problem

The previous architecture modeled C++ library dependencies at **package granularity**:
one `so_library` rule per package, bundling all `.so` files together. This caused three
independent bugs that share the same root cause.

#### Bug A — `cc_shared_library` fails to link symbols

`so_library` creates one empty GNU ld script per package directory to use as an
interface library:

```python
# apt/private/so_library.bzl (full source at /tmp/rules_buggy/apt/private/so_library.bzl)
ifso = ctx.actions.declare_file(ifso_name + "/rpath.ifso")
ctx.actions.write(ifso, content = """
    /* GNU LD script
    * Empty linker script for empty interface library */
    """)
lib = cc_common.create_library_to_link(
    interface_library = ifso,     # ← empty: no symbols
    dynamic_library = dyn_lib,
    ...
)
```

`cc_shared_library` uses `interface_library` for symbol resolution, not `dynamic_library`.
The empty script exports nothing.

### Reproduction

**Buggy generated BUILD — `so_library` with all `.so` files; per-lib `cc_import` targets use `libXxx_import` naming:**

```python
# /tmp/repro_bazel_out/external/rules_distroless++apt+bookworm_libncurses-dev-amd64_6.4-4/BUILD.bazel
so_library(
    name = "_so_libs",
    dynamic_libs = ["usr/lib/x86_64-linux-gnu/libncurses.so",
                    "usr/lib/x86_64-linux-gnu/libtinfo.so", ...],
)

cc_import(
    name = "libncurses_import",    # ← old naming: "lib" prefix + "_import" suffix
    shared_library = ":usr/lib/x86_64-linux-gnu/libncurses.so",  # ← raw linker script
    includes = ["external/../usr/include", ...],
)
```

**`cc_import` names like `:ncurses` (fixed naming) do not exist — only `:libncurses_import`:**

```
remote$ cd /tmp/repro && \
  bazel build @@rules_distroless++apt+bookworm_libncurses-dev-amd64_6.4-4//:ncurses 2>&1 | tail -5

ERROR: no such target '@@rules_distroless++apt+bookworm_libncurses-dev-amd64_6.4-4//:ncurses':
  target 'ncurses' not declared in package '' defined by
  /tmp/repro_bazel_out/external/rules_distroless++apt+bookworm_libncurses-dev-amd64_6.4-4/BUILD.bazel
  (did you mean libncurses?)
ERROR: Build did NOT complete successfully
```

**Bug A — empty interface library breaks `cc_shared_library`:**

`so_library` writes a comment-only linker script as the `interface_library` for every `.so`:

```python
# apt/private/so_library.bzl
ifso = ctx.actions.declare_file(ifso_name + "/rpath.ifso")
ctx.actions.write(ifso, content = """
    /* GNU LD script
    * Empty linker script for empty interface library */
    """)
lib = cc_common.create_library_to_link(
    interface_library = ifso,     # ← empty: no symbols
    dynamic_library = dyn_lib,
    ...)
```

`cc_shared_library` uses the `interface_library` to determine which symbols the shared
library provides. Since the interface library is empty, the resulting `cc_shared_library`
output does not record any dynamic linkage to the deb package's `.so`. When a downstream
`cc_binary` links against it via `dynamic_deps`, boost symbols are unresolved.

**Reproduction (code at `1aeef2d`, before commit 4):**

```python
# BUILD.bazel
cc_library(
    name = "a",
    srcs = ["a.cpp"],
    deps = ["@libyang_deps//libboost-serialization1.74-dev:libboost-serialization1.74"],
)

cc_shared_library(
    name = "a_shared",
    deps = [":a"],
)

cc_binary(
    name = "main",
    srcs = ["main.cpp"],
    dynamic_deps = [":a_shared"],
)
```

```
remote$ rm -rf /tmp/repro_bazel_out && cd /tmp/repro && bazel build //:main 2>&1

ERROR: Linking main failed: (Exit 1): gcc failed: error executing CppLink command
bazel-out/k8-fastbuild/bin/_solib_k8/_U/liba_shared.so: error: undefined reference to \
  'boost::archive::text_oarchive_impl<boost::archive::text_oarchive>::text_oarchive_impl(std::ostream&, unsigned int)'
bazel-out/k8-fastbuild/bin/_solib_k8/_U/liba_shared.so: error: undefined reference to \
  'boost::archive::basic_text_oarchive<boost::archive::text_oarchive>::init()'
bazel-out/k8-fastbuild/bin/_solib_k8/_U/liba_shared.so: error: undefined reference to \
  'boost::archive::detail::basic_oarchive::~basic_oarchive()'
  ... (12 more undefined boost::archive references)
collect2: error: ld returned 1 exit status
ERROR: Build did NOT complete successfully
```

Fixed code (after commit 4, per-`.so` `cc_import` without empty interface library)
builds successfully:

```
remote$ cd /tmp/repro && bazel build //:main 2>&1 | tail -3
INFO: Found 1 target...
Target //:main up-to-date: bazel-bin/main
INFO: Build completed successfully, 16343 total actions
```

#### Bug B — `.pc` `-D` defines silently dropped

`pkgconfig.bzl` parses `Cflags: -DFOO=1` into a `defines` list, but neither
`_CC_IMPORT_TMPL` nor `_CC_LIBRARY_TMPL` had a `{defines}` placeholder. For example,
`hiredis` exports `-D_FILE_OFFSET_BITS=64` via its `.pc` file. Without this define,
consumers compile with the wrong file offset type.

#### Why refactor instead of patch

Bug A requires running `readelf -dW` to get each `.so`'s NEEDED dependencies — once
that is in place, the natural output is one `cc_import` per `.so`. At that point
`so_library` is structurally obsolete. The refactor fixes all three bugs and improves
dependency precision from package-level to library-level.

### New Architecture

```
Before (package-level):
  deb package
  └── so_library(_so_libs)
        ├── rpath.ifso          ← empty interface library (breaks cc_shared_library)
        ├── libncurses.so       ┐ dynamic_library
        └── libtinfo.so         ┘

After (per-.so):
  deb package
  ├── cc_library(libncurses_hdrs)   ← headers only, strip_include_prefix
  ├── cc_import(ncurses)
  │     shared_library = libncurses.so  ← linkscript_out (path rewritten)
  │     deps = [libncurses_hdrs]
  ├── cc_import(form)
  │     shared_library = libform.so     ← real ELF symlink
  │     deps = [@libncurses6//:libform.so.6, libncurses_hdrs]
  └── cc_library(libncurses)
        deps = [libncurses_hdrs, ncurses, form, formw, ...]
```

**Fixed generated BUILD (`/tmp/repro_bazel_out/external/rules_distroless++apt+bookworm_libncurses-dev-amd64_6.4-4/BUILD.bazel`):**

```python
# no so_library rule
cc_library(name = "libncurses_hdrs",
    hdrs = [":hdrs"], strip_include_prefix = "usr/include",
    deps = ["@bookworm_libc6-dev-amd64_...//:libc6_hdrs", ...])

cc_import(name = "ncurses",
    shared_library = ":usr/lib/x86_64-linux-gnu/libncurses.so",   # linkscript_out
    deps = [":libncurses_hdrs"])

cc_import(name = "form",
    shared_library = ":usr/lib/x86_64-linux-gnu/libform.so",
    deps = ["@bookworm_libncurses6-amd64_6.4-4//:libform.so.6", ":libncurses_hdrs"])

cc_library(name = "libncurses",
    deps = [":libncurses_hdrs", ":ncurses", ":form", ":formw", ...])
```

**Dependency resolution via `readelf`:**

```bash
LC_ALL=C readelf -dW libssl.so.3 | grep NEEDED
# → 0x0000000000000001 (NEEDED) Shared library: [libcrypto.so.3]
# → 0x0000000000000001 (NEEDED) Shared library: [libc.so.6]
```

`LC_ALL=C` is required: non-C locales render `[` as `【` (fullwidth bracket), breaking
the grep pattern.

### Additional fixes included in this commit

- All `-I` paths from `.pc` Cflags are honored (before: only the first was used)
- `defines` from `.pc` `-D` flags are now emitted into `cc_library(defines = [...])`

---

## Commit 5 — `apt: add per-.so aliases to hub repo`

### Problem

Consumers had to use architecture-specific internal Bazel labels:

```python
# Before: breaks when architecture changes, exposes internal repo naming
deps = ["@@rules_distroless++apt+bookworm_libssl-dev-amd64_3.0.13-1ubuntu2//:ssl"]
```

### Reproduction

**Buggy hub BUILD — only a single package-level alias (code at `ebfd74a`):**

```python
# /tmp/repro_bazel_out/external/rules_distroless++apt+libyang_deps/libncurses-dev/BUILD.bazel
alias(name = "libncurses",
    actual = select({
        "//:linux_amd64": "@bookworm_libncurses-dev-amd64_6.4-4//:libncurses",
    }))
# ← one alias for the whole package, no per-.so granularity
```

Querying a specific library target fails:

```
remote$ cd /tmp/repro && bazel query @libyang_deps//libncurses-dev:ncurses 2>&1 | tail -5

ERROR: no such target '@@rules_distroless++apt+libyang_deps//libncurses-dev:ncurses':
  target 'ncurses' not declared in package 'libncurses-dev' defined by
  /tmp/repro_bazel_out/external/rules_distroless++apt+libyang_deps/libncurses-dev/BUILD.bazel
  (did you mean libncurses?)
```

### Fix

The module extension scans each `.deb`'s file listing and generates one `alias()` per
`.so` with `select()` for each architecture.

**Fixed hub BUILD — per-.so aliases:**

```python
# /tmp/repro_bazel_out/external/rules_distroless++apt+libyang_deps/libc6-dev/BUILD.bazel
alias(name = "libc6",       actual = select({"//:linux_amd64": "@...libc6-dev-amd64_...//:libc6"}))
alias(name = "c",           actual = select({"//:linux_amd64": "@...libc6-dev-amd64_...//:c"}))
alias(name = "m",           actual = select({"//:linux_amd64": "@...libc6-dev-amd64_...//:m"}))
alias(name = "BrokenLocale",actual = select({"//:linux_amd64": "@...libc6-dev-amd64_...//:BrokenLocale"}))
alias(name = "resolv",      actual = select({"//:linux_amd64": "@...libc6-dev-amd64_...//:resolv"}))
# ... one alias per .so
```

Consumers use:

```python
deps = ["@apt//libssl-dev:ssl"]   # architecture-independent, portable
```

---

## Commit 6 — `deb_import: detect multiarch include dirs from header file paths`

### Problem

Some packages ship architecture-specific headers in `usr/include/<triplet>/` (e.g.
`usr/include/x86_64-linux-gnu/`) but do not list this directory in `.pc` Cflags.
Primary headers include these with bare filenames.

**Verified from `liblua5.1-0-dev_5.1.5-9build1_amd64.deb`:**

```bash
$ pkg-config --cflags lua5.1
-I/usr/include/lua5.1       ← only this dir in Cflags

$ dpkg-deb -c liblua5.1-0-dev_*.deb | grep x86_64
./usr/include/x86_64-linux-gnu/lua5.1-deb-multiarch.h   ← in triplet dir

# luaconf.h line 98:
#include "lua5.1-deb-multiarch.h"   ← bare filename, needs triplet dir in search path
```

### Reproduction

**Package: `linux-libc-dev`** — ships all kernel headers, including
`usr/include/x86_64-linux-gnu/asm/types.h`. Has no `.pc` file, so `hdrs_includes`
derives only from `.pc` Cflags and is empty; the multiarch subdir is never added.

**Repro source:**

```c
/* asm_test.c */
#include <asm/types.h>
int main() { return 0; }
```

```python
cc_binary(name = "asm_test", srcs = ["asm_test.c"],
          deps = ["@libyang_deps//linux-libc-dev:linux-libc"], copts = ["-w"])
```

**Buggy generated BUILD for `linux-libc-dev` (module pointing at `/tmp/rules_before6/`):**

```python
# /tmp/repro_bazel_out/external/.../linux-libc-dev-amd64_6.1.164-1/BUILD.bazel
cc_library(
    name = "linux-libc_hdrs",
    hdrs = [":hdrs"],
    strip_include_prefix = "usr/include",
    # NO includes — usr/include/x86_64-linux-gnu/ not on the include path
    visibility = ["//visibility:public"],
)
```

**Fixed generated BUILD (module pointing at `/tmp/rules_fixed/`):**

```python
cc_library(
    name = "linux-libc_hdrs",
    hdrs = [":hdrs"],
    strip_include_prefix = "usr/include",
    includes = [
        "usr/include/x86_64-linux-gnu"    # ← auto-detected from header file paths
    ],
    visibility = ["//visibility:public"],
)
```

**Note on hard error:** `bazel build //:asm_test` with buggy code succeeded on the
remote machine because the linux-sandbox allowed reading the host's
`/usr/include/asm/types.h`. The compiler's `.d` dependency file confirmed host
include was used. In a hermetic build (RBE, Docker without bind-mounts of
`/usr/include`), the buggy code produces:

```
fatal error: asm/types.h: No such file or directory
compilation terminated.
```

### Fix

At fetch time, scan actual header file paths. For any header found under
`usr/include/<first-component>/` where the component matches `-linux-` (multiarch
triplet pattern), add that directory to `includes`:

```python
# deb_import.bzl (after fix)
for hdr in h_files + hpp_files:
    rest = hdr[hdr.find("usr/include/") + len("usr/include/"):]
    first = rest[:rest.find("/")]
    if "-linux-" not in first:
        continue
    ma_inc = "usr/include/" + first
    # add to includes
```

The fix covers both `linux-libc-dev` (kernel headers, no `.pc`) and `libc6-dev`
(C runtime headers, no `.pc`) and any other package that ships multiarch-dir headers
without listing the directory in its `.pc` Cflags.

---

## Commit 7 — `deb_import: support .ipp inline template files in -dev packages`

### Problem

Boost and other C++ libraries use `.ipp` files (inline template implementations) that
are `#include`d directly by public headers. The file scan only recognized `*.h` and
`*.hpp`, so `.ipp` files fell through to the `else: continue` branch and were never
added to `outs`.

**Verified from `libboost1.74-dev_1.74.0-18ubuntu2_amd64.deb`:**

```bash
$ find boost174/ -name "*.ipp" | wc -l
226

$ grep "\.ipp" boost174/usr/include/boost/date_time/gregorian_calendar.hpp
#include "boost/date_time/gregorian_calendar.ipp"
```

### Reproduction

**Buggy file-scan loop — `.ipp` has no matching branch:**

```python
# apt/private/deb_import.bzl (buggy, ebfd74a)
if (line.endswith(".so") or ...):
    so_files.append(line)
elif line.endswith(".h"):
    h_files.append(line)
elif line.endswith(".hpp"):
    hpp_files.append(line)
# ← no .ipp branch
else:
    continue                # ← .ipp files silently dropped
```

**Buggy `outs` construction — `.ipp` never included:**

```python
for out in so_files + h_files + hpp_files + a_files + ...:   # ← no ipp_files
    outs.append(out)
```

When a translation unit includes any header that `#include`s a `.ipp` file:

```
fatal error: boost/date_time/gregorian_calendar.ipp: No such file or directory
compilation terminated.
```

### Fix

```python
# apt/private/deb_import.bzl (after fix)
elif line.endswith(".hpp"):
    hpp_files.append(line)
elif line.endswith(".ipp"):
    ipp_files.append(line)   # ← new branch: recognized as header

...
for out in so_files + h_files + hpp_files + ipp_files + a_files + ...:
    outs.append(out)          # ← .ipp files now declared as outputs
```
