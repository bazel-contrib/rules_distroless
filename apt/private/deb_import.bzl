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
load("@rules_distroless//apt/private:cc_deb_library.bzl", "cc_deb_library")
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
    self_symlinks = {self_symlinks},
    outs = {outs},
    linkscripts = {linkscripts},
    linkscript_outs = {linkscript_outs},
    linkscript_deps = {linkscript_deps},
    visibility = ["//visibility:public"]
)

directory(
    name = "directory",
    srcs = {symlink_outs} + {outs} + {linkscript_outs},
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

_CC_SYS_LIBRARY_TMPL = """
cc_deb_library(
    name = "{name}_wodeps",
    hdrs = {hdrs},
    deps = {direct_deps},
    linkopts = {linkopts},
    additional_compiler_inputs = {additional_compiler_inputs},
    additional_linker_inputs = {additional_linker_inputs},
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

def _discover_contents(rctx, depends_on, depends_file_map, target_name):
    result = rctx.execute(["tar", "--exclude='./usr/share/**'", "--exclude='./**/'", "-tvf", "data.tar.xz"])
    contents_raw = result.stdout.splitlines()

    so_files = []
    a_files = []
    h_files = []
    hpp_files = []
    hpp_files_woext = []
    pc_files = []
    o_files = []
    linkscripts = []
    linkscript_dep_labels = []
    symlinks = {}

    for line in contents_raw:
        # Skip directories
        if line.endswith("/"):
            continue

        line = line[line.find(" ./") + 3:]

        # Skip everything in man pages and examples
        if line.startswith("usr/share"):
            continue

        is_symlink_idx = line.find(" -> ")
        resolved_symlink = None
        if is_symlink_idx != -1:
            symlink_target = line[is_symlink_idx + 4:]
            line = line[:is_symlink_idx]
            if line.endswith(".pc"):
                continue

            # An absolute symlink
            if symlink_target.startswith("/"):
                resolved_symlink = symlink_target.removeprefix("/")
            else:
                resolved_symlink = resolve_symlink(line, symlink_target).removeprefix("./")

        if (line.endswith(".so") or line.find(".so.") != -1) and line.find("lib") != -1:
            if line.find("libthread_db") != -1:
                continue

            # Will be classified as so_file or linkscript after extraction
            so_files.append(line)
        elif line.endswith(".a") and line.find("lib"):
            a_files.append(line)
        elif line.endswith(".pc") and line.find("pkgconfig"):
            pc_files.append(line)
        elif line.endswith(".h"):
            h_files.append(line)
        elif line.endswith(".hpp"):
            hpp_files.append(line)
        elif line.find("include/c++") != -1 or (line.find("usr/include/") != -1 and line[line.rfind("/") + 1:].find(".") == -1):
            hpp_files_woext.append(line)
        elif line.endswith(".o"):
            o_files.append(line)
        else:
            continue

        if resolved_symlink:
            symlinks[line] = resolved_symlink

    # Resolve symlinks:
    unresolved_symlinks = {} | symlinks

    foreign_symlinks = {}

    # TODO: this is highly inefficient, change the filemapping to be
    # file -> package instead of package -> files
    for dep in depends_on:
        (suite, name, arch, _) = lockfile.parse_package_key(dep)
        filemap = depends_file_map.get(name, []) or []
        for file in filemap:
            if len(unresolved_symlinks) == 0:
                break
            for (symlink, symlink_target) in unresolved_symlinks.items():
                if file == symlink_target:
                    unresolved_symlinks.pop(symlink)
                    foreign_symlinks[symlink] = "@%s//:%s" % (util.sanitize(dep), file)

    # Resolve self symlinks
    self_symlinks = {}
    for file in so_files + h_files + hpp_files + a_files + hpp_files_woext:
        for (symlink, symlink_target) in unresolved_symlinks.items():
            if file == symlink_target:
                self_symlinks[symlink] = unresolved_symlinks.pop(symlink)
                if len(unresolved_symlinks) == 0:
                    break

    if len(unresolved_symlinks):
        util.warning(
            rctx,
            "some symlinks could not be solved for {}. \nresolved: {}\nunresolved:{}".format(
                target_name,
                json.encode_indent(symlinks),
                json.encode_indent(unresolved_symlinks),
            ),
        )

    # Detect link scripts: files that look like .so but are actually text files (linker scripts)
    # Extract candidate so_files that are not symlinks to check their content
    so_non_symlink = [f for f in so_files if f not in symlinks]
    if so_non_symlink:
        rctx.execute(
            ["tar", "-xvf", "data.tar.xz"] + ["./" + f for f in so_non_symlink],
        )

        # Build a mapping from file path -> dep repo name for resolving linkscript references
        # Extract the module extension prefix from rctx.attr.name (e.g. "rules_distroless++apt+")
        # so that dependency repo names use the full canonical name.
        self_sanitized = rctx.attr.target_name
        repo_prefix = ""
        if rctx.attr.name.endswith(self_sanitized):
            repo_prefix = rctx.attr.name[:-len(self_sanitized)]

        file_to_repo = {}
        for dep in depends_on:
            (suite, name, arch, _) = lockfile.parse_package_key(dep)
            filemap = depends_file_map.get(name, []) or []
            repo_name = repo_prefix + util.sanitize(dep)
            for file in filemap:
                file_to_repo[file] = repo_name

        for f in so_non_symlink:
            if rctx.path(f).exists:
                # Use `file` command to check if it's a text file (not ELF binary)
                file_result = rctx.execute(["file", "--mime-type", "-b", f])
                mime_type = file_result.stdout.strip()
                is_text = mime_type.startswith("text/")

                if is_text:
                    content = rctx.read(rctx.path(f))

                    # Collect all absolute paths referenced in the linkscript and
                    # build a replacement map to actual generated output paths.
                    # Only consider actual library files (not directories) to avoid
                    # substring matches like /usr/lib replacing part of a longer path.
                    replacements = {}
                    delimiters = [" ", ")", ",", "\n", "\t", "("]
                    for (rel_path, repo) in file_to_repo.items():
                        if rel_path.find(".") == -1 or rel_path.endswith("/"):
                            continue
                        abs_path = "/" + rel_path

                        # Only match if the path appears as a complete token
                        # (followed by a delimiter or at end of content)
                        found = False
                        for delim in delimiters:
                            if (abs_path + delim) in content:
                                found = True
                                break
                        if not found and content.endswith(abs_path):
                            found = True
                        if found:
                            replacements[abs_path] = "$$BINDIR/external/{}/{}".format(repo, rel_path)

                    # Also check self package files (exclude current linkscript file)
                    for self_file in so_files + a_files:
                        if self_file == f:
                            continue
                        abs_path = "/" + self_file
                        found = False
                        for delim in delimiters:
                            if (abs_path + delim) in content:
                                found = True
                                break
                        if not found and content.endswith(abs_path):
                            found = True
                        if found and abs_path not in replacements:
                            replacements[abs_path] = "$$BINDIR/external/{}/{}".format(rctx.attr.name, self_file)

                    # Collect foreign dep labels from replacements
                    for (abs_path, replacement) in replacements.items():
                        # Foreign deps are from other repos (not self package)
                        rel_path = abs_path.lstrip("/")
                        if rel_path in file_to_repo:
                            repo = file_to_repo[rel_path]

                            # Strip repo_prefix to get the apparent name visible from this repo
                            apparent_repo = repo
                            if repo_prefix and repo.startswith(repo_prefix):
                                apparent_repo = repo[len(repo_prefix):]
                            label = "@{}//:{}".format(apparent_repo, rel_path)
                            if label not in linkscript_dep_labels:
                                linkscript_dep_labels.append(label)

                    # Replace longest paths first to prevent shorter paths from
                    # matching as substrings of longer ones
                    rewritten = content
                    for old in sorted(replacements.keys(), key = len, reverse = True):
                        rewritten = rewritten.replace(old, replacements[old])

                    linkscripts.append((f, rewritten))
                    so_files.remove(f)
                    util.warning(rctx, "detected linker script: {}".format(f))

                # Clean up extracted file
                rctx.execute(["rm", "-f", f])

    linkscript_paths = [path for (path, _) in linkscripts]

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
        rctx.execute(
            ["tar", "-xvf", "data.tar.xz"] + ["./" + pc for pc in pc_files],
        )
        for pc in pc_files:
            if rctx.path(pc).exists:
                pkgconfigs.append(pc)

    build_file_content = """
so_library(
    name = "_so_libs",
    dynamic_libs = {}
)
""".format(so_files)

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

        build_file_content += _CC_LIBRARY_TMPL.format(
            name = target_name,
            hdrs = h_files + hpp_files,
            additional_compiler_inputs = hpp_files_woext,
            additional_linker_inputs = so_files + linkscript_paths + o_files + linkscript_dep_labels,
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
                ] + [
                    "-Wl,-rpath=/" + rp
                    for rp in rpaths
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
            additional_linker_inputs = so_files + linkscript_paths + a_files + o_files + linkscript_dep_labels,
            includes = [],
        )
    else:
        extra_linkopts = []
        if target_name == "libbsd0":
            extra_linkopts = [
                "-Wl,--remap-inputs=/usr/lib/x86_64-linux-gnu/libbsd.so.0.11.7=$(BINDIR)/external/{}/usr/lib/x86_64-linux-gnu/libbsd.so.0.11.7".format(rctx.attr.name),
            ]
        build_file_content += _CC_SYS_LIBRARY_TMPL.format(
            name = target_name,
            hdrs = h_files + hpp_files,
            deps = deps,
            additional_compiler_inputs = hpp_files_woext,
            additional_linker_inputs = so_files + linkscript_paths + o_files + linkscript_dep_labels,
            linkopts = [
                # Required for linker to find .so libraries
                "-L$(BINDIR)/external/{}/{}".format(rctx.attr.name, rp)
                for rp in rpaths
            ] + [
                # # Required for bazel test binary to find its dependencies.
                # "-Wl,-rpath=../{}/{}".format(rctx.attr.name, rp)
                # for rp in rpaths
            ] + [
                # Required for ld to validate rpath entries
                "-Wl,-rpath-link=$(BINDIR)/external/{}/{}".format(rctx.attr.name, rp)
                for rp in rpaths
            ] + [
                # Required for containers to find the dependencies at runtime.
                "-Wl,-rpath=/" + rp
                for rp in rpaths
            ] + extra_linkopts,
            direct_deps = [":_so_libs"],
        )

    return (build_file_content, outs, foreign_symlinks, self_symlinks, linkscripts, linkscript_dep_labels)

def _deb_import_impl(rctx):
    rctx.download_and_extract(
        url = rctx.attr.urls,
        sha256 = rctx.attr.sha256,
    )

    # TODO: only do this if package is -dev or dependent of a -dev pkg.
    cc_import_targets, outs, symlinks, self_symlinks, linkscripts, linkscript_dep_labels = _discover_contents(
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

    # Build linkscripts dict: path -> rewritten content
    linkscripts_dict = {path: content for (path, content) in linkscripts}
    linkscript_outs = [path for (path, _) in linkscripts]

    rctx.file("BUILD.bazel", _DEB_IMPORT_BUILD_TMPL.format(
        mergedusr = rctx.attr.mergedusr,
        depends_on = ["@" + util.sanitize(dep_key) + "//:data" for dep_key in rctx.attr.depends_on],
        target_name = rctx.attr.target_name,
        cc_import_targets = cc_import_targets,
        outs = outs,
        foreign_symlinks = foreign_symlinks,
        self_symlinks = self_symlinks,
        symlink_outs = symlinks.keys() + self_symlinks.keys(),
        linkscripts = linkscripts_dict,
        linkscript_outs = linkscript_outs,
        linkscript_deps = linkscript_dep_labels,
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
