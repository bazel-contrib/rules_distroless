"deb_import"

load(":lockfile.bzl", "lockfile")
load(":pkgconfig.bzl", "pkgconfig")
load(":util.bzl", "util")

# BUILD.bazel template
_DEB_IMPORT_BUILD_TMPL = '''
load("@rules_distroless//apt/private:deb_postfix.bzl", "deb_postfix")
load("@rules_distroless//apt/private:deb_export.bzl", "deb_export")
load("@rules_distroless//apt/private:so_library.bzl", "so_library")
load("@rules_cc//cc/private/rules_impl:cc_import.bzl", "cc_import")
load("@rules_cc//cc:cc_library.bzl", "cc_library")
load("@bazel_skylib//rules/directory:directory.bzl", "directory")

deb_postfix(
    name = "data",
    srcs = glob(["data.tar*"]),
    outs = ["content.tar.gz"],
    mergedusr = {mergedusr},
    visibility = ["//visibility:public"],
)

filegroup(
    name = "control",
    srcs = glob(["control.tar.*"]),
    visibility = ["//visibility:public"],
)

filegroup(
    name = "{target_name}",
    srcs = {depends_on} + [":data"],
    visibility = ["//visibility:public"],
)


deb_export(
    name = "export",
    srcs = glob(["data.tar*"]),
    foreign_symlinks = {foreign_symlinks},
    symlink_outs = {symlink_outs},
    outs = {outs},
    visibility = ["//visibility:public"]
)

directory(
    name = "directory",
    srcs = {symlink_outs} + {outs},
    visibility = ["//visibility:public"]
)

{cc_import_targets}
'''

_CC_LIBRARY_LIBC_TMPL = """
alias(
    name = "{name}_wodeps",
    actual = ":{name}",
    visibility = ["//visibility:public"]
)

cc_library(
    name = "{name}",
    hdrs = {hdrs},
    additional_compiler_inputs = {additional_compiler_inputs},
    additional_linker_inputs = {additional_linker_inputs},
    includes = {includes},
    visibility = ["//visibility:public"],
)
"""

_CC_IMPORT_TMPL = """
cc_import(
    name = "{name}",
    hdrs = {hdrs},
    includes = {includes},
    linkopts = {linkopts},
    shared_library = {shared_lib},
    static_library = {static_lib},
)
"""

_CC_LIBRARY_TMPL = """
cc_library(
    name = "{name}_wodeps",
    hdrs = {hdrs},
    deps = {direct_deps},
    linkopts = {linkopts},
    additional_compiler_inputs = {additional_compiler_inputs},
    additional_linker_inputs = {additional_linker_inputs},
    strip_include_prefix = {strip_include_prefix},
    visibility = ["//visibility:public"],
)

cc_library(
    name = "{name}",
    deps = [":{name}_wodeps"] + {deps},
    visibility = ["//visibility:public"],
)
"""

def resolve_symlink(target_path, relative_symlink):
    # Split paths into components
    target_parts = target_path.split("/")
    symlink_parts = relative_symlink.split("/")

    # Remove the file name from target path to get the directory
    target_dir_parts = target_parts[:-1]

    # Process the relative symlink
    result_parts = target_dir_parts[:]
    for part in symlink_parts:
        if part == "..":
            # Move up one directory by removing the last component
            if result_parts:
                result_parts.pop()
        elif part == "." or part == "":
            # Ignore current directory or empty components
            continue
        else:
            # Append the component to the path
            result_parts.append(part)

    # Join the parts back into a path
    resolved_path = "/".join(result_parts)
    return resolved_path

def _list_data_contents(rctx):
    result = rctx.execute([
        "sh",
        "-c",
        "dpkg-deb --fsys-tarfile package.deb | tar --exclude='./usr/share/**' --exclude='./**/' -tvf -",
    ])
    if result.return_code != 0:
        fail("Failed to list package.deb filesystem tar stream: {}".format(result.stderr))
    return result

def _extract_data_files(rctx, files):
    if not files:
        return
    result = rctx.execute([
        "sh",
        "-c",
        "dpkg-deb --fsys-tarfile package.deb | tar -xvf - " + " ".join(files),
    ])
    if result.return_code != 0:
        fail("Failed to extract selected files from package.deb: {}".format(result.stderr))

def _library_stem(path):
    filename = path[path.rfind("/") + 1:]
    so_index = filename.find(".so")
    if so_index == -1:
        return ""
    return filename[:so_index]

def _normalize_path(path):
    return path.strip().removeprefix("./")

def _is_linkable_shared_lib(path):
    filename = path[path.rfind("/") + 1:]
    # Keep only linker-facing soname stubs (for example "libudev.so").
    # Versioned runtime objects and plugin modules (for example gconv codecs)
    # should not be converted into `-l` flags by downstream rules.
    if not (filename.startswith("lib") and filename.endswith(".so")):
        return False

    # Glibc ships profiling/debug helper DSOs that must never be linked into
    # regular binaries by default. Treat them as runtime artifacts only.
    if filename in [
        "libmemusage.so",
        "libpcprofile.so",
        "libc_malloc_debug.so",
    ]:
        return False

    return True

def _discover_contents(rctx, depends_on, depends_file_map, target_name):
    normalized_dep_files = {}
    for dep_name, files in depends_file_map.items():
        normalized_dep_files[dep_name] = [
            _normalize_path(f)
            for f in (files or [])
        ]

    result = _list_data_contents(rctx)
    contents_raw = result.stdout.splitlines()

    so_files = []
    a_files = []
    h_files = []
    hpp_files = []
    hpp_files_woext = []
    pc_files = []
    o_files = []
    symlinks = {}

    for line in contents_raw:
        # Skip directories
        if line.endswith("/"):
            continue

        line = line[line.find(" ./") + 3:].strip()

        # Skip everything in man pages and examples
        if line.startswith("usr/share"):
            continue

        is_symlink_idx = line.find(" -> ")
        symlink_separator_len = 4
        if is_symlink_idx == -1:
            is_symlink_idx = line.find(" link to ")
            symlink_separator_len = len(" link to ")
        resolved_symlink = None
        if is_symlink_idx != -1:
            symlink_target = line[is_symlink_idx + symlink_separator_len:].strip()
            line = line[:is_symlink_idx].strip()
            if line.endswith(".pc"):
                continue

            # An absolute symlink
            if symlink_target.startswith("/") or symlink_target.startswith("./"):
                resolved_symlink = _normalize_path(symlink_target.removeprefix("/"))
            else:
                resolved_symlink = _normalize_path(resolve_symlink(line, symlink_target))

        if (line.endswith(".so") or line.find(".so.") != -1) and line.find("lib") != -1:
            if line.find("libthread_db") != -1:
                continue
            so_files.append(line)
        elif line.endswith(".a") and line.find("lib"):
            a_files.append(line)
        elif line.endswith(".pc") and line.find("pkgconfig"):
            pc_files.append(line)
        elif line.endswith(".h"):
            h_files.append(line)
        elif line.endswith(".hpp"):
            hpp_files.append(line)
        elif line.find("include/c++") != -1:
            hpp_files_woext.append(line)
        elif line.endswith(".o"):
            o_files.append(line)
        else:
            continue

        if resolved_symlink:
            symlinks[line] = resolved_symlink

    # Resolve symlinks:
    unresolved_symlinks = {} | symlinks

    # Resolve links whose target is in the current package first. This is
    # required for chains such as libfoo.so -> ../llvm/libfoo.so where the
    # intermediate target is another link entry in this package.
    package_files = {
        path: True
        for path in so_files + h_files + hpp_files + a_files + hpp_files_woext
    }
    for (symlink, symlink_target) in list(unresolved_symlinks.items()):
        if symlink_target in package_files:
            symlinks.pop(symlink)
            unresolved_symlinks.pop(symlink)

    # Resolve cross-package links from dependency file maps.
    dep_key_by_name = {}
    for dep in depends_on:
        (_, name, _, _) = lockfile.parse_package_key(dep)
        dep_key_by_name[name] = dep

    for (symlink, symlink_target) in list(unresolved_symlinks.items()):
        for (dep_name, files) in normalized_dep_files.items():
            if symlink_target not in files:
                continue
            dep_key = dep_key_by_name.get(dep_name)
            if dep_key:
                unresolved_symlinks.pop(symlink)
                symlinks[symlink] = "@%s//:%s" % (util.sanitize(dep_key), symlink_target)
            break

    # Fallback when Contents maps are incomplete: match against dependency package
    # names using the SONAME stem (for example libudev.so.1 -> libudev1).
    for (symlink, symlink_target) in list(unresolved_symlinks.items()):
        stem = _library_stem(symlink_target)
        if not stem:
            continue
        matches = []
        for (dep_name, dep_key) in dep_key_by_name.items():
            if dep_name.endswith("-dev"):
                continue
            if dep_name.startswith(stem):
                matches.append(dep_key)
        if len(matches) == 1:
            unresolved_symlinks.pop(symlink)
            symlinks[symlink] = "@%s//:%s" % (util.sanitize(matches[0]), symlink_target)

    if len(unresolved_symlinks):
        util.warning(
            rctx,
            "some symlinks could not be solved for {}. \nresolved: {}\nunresolved:{}".format(
                target_name,
                json.encode_indent(symlinks),
                json.encode_indent(unresolved_symlinks),
            ),
        )
        # Keep unresolved links as archive-native link entries instead of trying to
        # synthesize cross-package symlinks. As a fallback, drop unresolved link
        # paths from generated targets to avoid dangling-output failures.
        for symlink in unresolved_symlinks.keys():
            symlinks.pop(symlink)
            if symlink in so_files:
                so_files.remove(symlink)
            if symlink in a_files:
                a_files.remove(symlink)
            if symlink in h_files:
                h_files.remove(symlink)
            if symlink in hpp_files:
                hpp_files.remove(symlink)
            if symlink in hpp_files_woext:
                hpp_files_woext.remove(symlink)
            if symlink in o_files:
                o_files.remove(symlink)

    outs = []

    for out in so_files + h_files + hpp_files + a_files + hpp_files_woext + o_files:
        if out not in symlinks:
            outs.append(out)

    deps = []
    for dep in depends_on:
        (suite, name, arch, version) = lockfile.parse_package_key(dep)
        deps.append(
            "@%s//:%s_wodeps" % (util.sanitize(dep), name.removesuffix("-dev")),
        )

    pkgconfigs = []
    if len(pc_files):
        # TODO: use rctx.extract instead.
        _extract_data_files(rctx, ["./" + pc for pc in pc_files])
        for pc in pc_files:
            if rctx.path(pc).exists:
                pkgconfigs.append(pc)

    linkable_so_files = []
    for so in so_files:
        if not _is_linkable_shared_lib(so):
            continue
        resolved = symlinks.get(so)
        if resolved and resolved.startswith("@"):
            linkable_so_files.append(resolved)
        else:
            linkable_so_files.append(so)

    build_file_content = """
so_library(
    name = "_so_libs",
    dynamic_libs = {}
)
""".format(linkable_so_files)

    rpaths = {}
    for so in so_files + a_files:
        rpath = so[:so.rfind("/")]
        rpaths[rpath] = None

    # Package has a pkgconfig, use that as the source of truth.
    if len(pkgconfigs):
        link_paths = []
        includes = []

        static_lib = None
        shared_lib = None

        import_targets = []

        for pc_file in pkgconfigs:
            pkgc = pkgconfig(rctx, pc_file)
            includes += pkgc.includes
            link_paths += pkgc.link_paths

            if len(pkgc.libnames) == 0:
                continue

            for libname in pkgc.libnames:
              if libname + "_import" in import_targets:
                continue

              subtarget = libname + "_import"
              import_targets.append(subtarget)

              # Look for a static archive
              # for ar in a_files:
              #     if ar.endswith(pkgc.libname + ".a"):
              #         static_lib = '":%s"' % ar
              #         break

              # Look for a dynamic library
              IGNORE = ["libfl"]
              for so_lib in so_files:
                  if libname and libname not in IGNORE and so_lib.endswith(libname + ".so"):
                      resolved = symlinks.get(so_lib)
                      if resolved and resolved.startswith("@"):
                          shared_lib = '"%s"' % resolved
                      else:
                          shared_lib = '":%s"' % so_lib
                      break

              build_file_content += _CC_IMPORT_TMPL.format(
                  name = subtarget,
                  shared_lib = shared_lib,
                  static_lib = static_lib,
                  hdrs = [],
                  includes = {
                      "external/.." + include: True
                      for include in includes + ["/usr/include", "/usr/include/x86_64-linux-gnu"]
                  }.keys(),
                  linkopts = pkgc.linkopts,
              )

        # Some distro .pc files still advertise generic paths (for example
        # /usr/lib) while actual shared libs are installed in multiarch dirs.
        # Include discovered package lib dirs as fallback search paths.
        for rp in rpaths:
            if rp not in link_paths:
                link_paths.append(rp)

        build_file_content += _CC_LIBRARY_TMPL.format(
            name = target_name,
            hdrs = h_files + hpp_files,
            additional_compiler_inputs = hpp_files_woext,
            additional_linker_inputs = so_files + o_files,
            linkopts = {
                opt: True
                for opt in [
                    # # Needed for cc_test binaries to locate its dependencies.
                    # "-Wl,-rpath=../{}/{}".format(rctx.attr.name, rpath)
                    # for rp in rpaths
                ] + [
                    # Needed for cc_test binaries to locate its dependencies as a build tool
                    # "-Wl,-rpath=./external/{}/{}".format(rctx.attr.name, rpath)
                    # for rp in rpaths
                ] + [
                    "-L$(BINDIR)/external/{}/{}".format(rctx.attr.name, lp)
                    for lp in link_paths
                ]
            }.keys(),
            direct_deps = import_targets + [":_so_libs"],
            deps = deps,
            strip_include_prefix = None,
        )

    elif (len(hpp_files) or len(h_files)) and ((target_name.find("libc") != -1 or target_name.find("libstdc") != -1 or target_name.find("libgcc") != -1)):
        build_file_content += _CC_LIBRARY_LIBC_TMPL.format(
            name = target_name,
            hdrs = h_files + hpp_files,
            additional_compiler_inputs = hpp_files_woext,
            additional_linker_inputs = so_files + a_files + o_files,
            includes = [],
        )
    else:
        extra_linkopts = []
        strip_include_prefix = '"usr/include"'
        for header in h_files + hpp_files:
            if not header.startswith("usr/include/"):
                strip_include_prefix = None
                break
        if target_name == "libbsd0":
            extra_linkopts = [
                "-Wl,--remap-inputs=/usr/lib/x86_64-linux-gnu/libbsd.so.0.11.7=$(BINDIR)/external/{}/usr/lib/x86_64-linux-gnu/libbsd.so.0.11.7".format(rctx.attr.name),
            ]
        build_file_content += _CC_LIBRARY_TMPL.format(
            name = target_name,
            hdrs = h_files + hpp_files,
            deps = deps,
            additional_compiler_inputs = hpp_files_woext,
            additional_linker_inputs = so_files + o_files,
            linkopts = [
                # Required for linker to find .so libraries
                "-L$(BINDIR)/external/{}/{}".format(rctx.attr.name, rp)
                for rp in rpaths
            ] + [
                # # Required for bazel test binary to find its dependencies.
                # "-Wl,-rpath=../{}/{}".format(rctx.attr.name, rp)
                # for rp in rpaths
            ] + extra_linkopts,
            strip_include_prefix = strip_include_prefix,
            direct_deps = [":_so_libs"],
        )

    return (build_file_content, outs, symlinks)

def _deb_import_impl(rctx):
    rctx.download(
        url = rctx.attr.urls,
        output = "package.deb",
        sha256 = rctx.attr.sha256,
    )
    extract_result = rctx.execute(["ar", "x", "package.deb"])
    if extract_result.return_code != 0:
        fail("Failed to extract package.deb: {}".format(extract_result.stderr))

    # TODO: only do this if package is -dev or dependent of a -dev pkg.
    cc_import_targets, outs, symlinks = _discover_contents(
        rctx,
        rctx.attr.depends_on,
        json.decode(rctx.attr.depends_file_map),
        rctx.attr.package_name.removesuffix("-dev"),
    )

    foreign_symlinks = {}
    for (i, symlink) in enumerate(symlinks.values()):
      if symlink not in foreign_symlinks:
        foreign_symlinks[symlink] = []
      foreign_symlinks[symlink].append(i)

    foreign_symlinks = {
      symlink: json.encode(indices)
      for (symlink, indices) in foreign_symlinks.items()
    }

    rctx.file("BUILD.bazel", _DEB_IMPORT_BUILD_TMPL.format(
        mergedusr = rctx.attr.mergedusr,
        depends_on = ["@" + util.sanitize(dep_key) + "//:data" for dep_key in rctx.attr.depends_on],
        target_name = rctx.attr.target_name,
        cc_import_targets = cc_import_targets,
        outs = outs,
        foreign_symlinks = foreign_symlinks,
        symlink_outs = symlinks.keys(),
    ))

deb_import = repository_rule(
    implementation = _deb_import_impl,
    attrs = {
        "urls": attr.string_list(mandatory = True, allow_empty = False),
        "sha256": attr.string(),
        "depends_on": attr.string_list(),
        "depends_file_map": attr.string(),
        "mergedusr": attr.bool(),
        "target_name": attr.string(),
        "package_name": attr.string(),
    },
)
