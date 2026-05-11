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
load("@bazel_skylib//rules/directory:glob.bzl", "directory_glob")

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

def resolve_symlink(target_path, relative_symlink):
    target_parts = target_path.split("/")
    symlink_parts = relative_symlink.split("/")
    target_dir_parts = target_parts[:-1]
    result_parts = target_dir_parts[:]
    for part in symlink_parts:
        if part == "..":
            if result_parts:
                result_parts.pop()
        elif part == "." or part == "":
            continue
        else:
            result_parts.append(part)
    return "/".join(result_parts)


def _strip_version_suffix(so_name):
    """Strip version suffix from a library name, e.g. libfoo.so.1.2.3 -> libfoo.so"""
    idx = so_name.find(".so.")
    if idx != -1:
        return so_name[:idx + 3]
    return so_name


def _get_so_basename(so_path):
    """Extract the basename from a so file path, e.g. usr/lib/libfoo.so.1 -> libfoo.so.1"""
    return so_path[so_path.rfind("/") + 1:]


def _get_cc_import_name(so_basename):
    """Get cc_import target name from so basename, e.g. libfoo.so.1.2.3 -> libfoo.so.1.2.3"""
    return so_basename


def _get_library_base_name(so_basename):
    """Strip lib prefix and .so suffix, e.g. libfoo.so -> foo, libfoo.so.1 -> foo.so.1"""
    name = so_basename
    if name.startswith("lib"):
        name = name[3:]
    # Remove .so and anything after
    so_idx = name.find(".so")
    if so_idx != -1:
        name = name[:so_idx]
    return name


def _is_top_level_so(so_path):
    """Check if a .so file is directly in usr/lib/ or usr/lib/x86_64-linux-gnu/.

    Also supports split-usr layouts (e.g. Debian bookworm) where .so files
    reside in lib/x86_64-linux-gnu/ instead of usr/lib/x86_64-linux-gnu/.

    Excludes files in deeper subdirectories like usr/lib/x86_64-linux-gnu/foo/libbar.so.
    """
    for prefix in (
        "usr/lib/x86_64-linux-gnu/",
        "usr/lib/aarch64-linux-gnu/",
        "usr/lib/",
        "lib/x86_64-linux-gnu/",
        "lib/aarch64-linux-gnu/",
        "lib/",
    ):
        if so_path.startswith(prefix):
            remainder = so_path[len(prefix):]
            return "/" not in remainder
    return False


def _run_readelf(rctx, so_path):
    """Run readelf -dW on a .so file and return list of NEEDED libraries."""
    # Force C locale so readelf emits ASCII brackets around library names,
    # regardless of the build host's locale (e.g., zh_CN would produce full-width
    # brackets that our parser below cannot match).
    result = rctx.execute(
        ["readelf", "-dW", so_path],
        environment = {"LC_ALL": "C", "LANG": "C"},
    )
    if result.return_code != 0:
        return []
    needed = []
    for line in result.stdout.splitlines():
        if "(NEEDED)" in line:
            # Extract the library name from the bracket
            start = line.find("[")
            end = line.find("]")
            if start != -1 and end != -1:
                needed.append(line[start + 1:end])
    return needed


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
    linkscript_dep_map = {}  # linkscript path -> list of dep labels
    symlinks = {}

    for line in contents_raw:
        if line.endswith("/"):
            continue

        line = line[line.find(" ./") + 3:]

        if line.startswith("usr/share"):
            continue

        is_symlink_idx = line.find(" -> ")
        resolved_symlink = None
        if is_symlink_idx != -1:
            symlink_target = line[is_symlink_idx + 4:]
            line = line[:is_symlink_idx]
            if line.endswith(".pc"):
                continue
            if symlink_target.startswith("/"):
                resolved_symlink = symlink_target.removeprefix("/")
            else:
                resolved_symlink = resolve_symlink(line, symlink_target).removeprefix("./")

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
        elif line.find("include/c++") != -1 or (line.find("usr/include/") != -1 and line[line.rfind("/") + 1:].find(".") == -1):
            hpp_files_woext.append(line)
        elif line.endswith(".o"):
            o_files.append(line)
        else:
            continue

        if resolved_symlink:
            symlinks[line] = resolved_symlink

    # Resolve symlinks
    unresolved_symlinks = {} | symlinks

    foreign_symlinks = {}

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

    # Detect link scripts
    so_non_symlink = [f for f in so_files if f not in symlinks]
    if so_non_symlink:
        rctx.execute(
            ["tar", "-xvf", "data.tar.xz"] + ["./" + f for f in so_non_symlink],
        )

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
                file_result = rctx.execute(["file", "--mime-type", "-b", f])
                mime_type = file_result.stdout.strip()
                is_text = mime_type.startswith("text/")

                if is_text:
                    content = rctx.read(rctx.path(f))
                    replacements = {}
                    delimiters = [" ", ")", ",", "\n", "\t", "("]
                    for (rel_path, repo) in file_to_repo.items():
                        if rel_path.find(".") == -1 or rel_path.endswith("/"):
                            continue
                        abs_path = "/" + rel_path
                        found = False
                        for delim in delimiters:
                            if (abs_path + delim) in content:
                                found = True
                                break
                        if not found and content.endswith(abs_path):
                            found = True
                        if found:
                            replacements[abs_path] = "$$BINDIR/external/{}/{}".format(repo, rel_path)

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

                    # Track per-linkscript deps
                    ls_deps = []
                    for (abs_path, replacement) in replacements.items():
                        rel_path = abs_path.lstrip("/")
                        if rel_path in file_to_repo:
                            repo = file_to_repo[rel_path]
                            apparent_repo = repo
                            if repo_prefix and repo.startswith(repo_prefix):
                                apparent_repo = repo[len(repo_prefix):]
                            label = "@{}//:{}".format(apparent_repo, rel_path)
                            if label not in linkscript_dep_labels:
                                linkscript_dep_labels.append(label)
                            if label not in ls_deps:
                                ls_deps.append(label)

                    rewritten = content
                    for old in sorted(replacements.keys(), key=len, reverse=True):
                        rewritten = rewritten.replace(old, replacements[old])

                    linkscripts.append((f, rewritten))
                    linkscript_dep_map[f] = ls_deps
                    so_files.remove(f)

                rctx.execute(["rm", "-f", f])

    linkscript_paths = [path for (path, _) in linkscripts]

    outs = []
    for out in so_files + h_files + hpp_files + a_files + hpp_files_woext + o_files:
        if out not in symlinks:
            outs.append(out)

    # Deduplicate so_files to prevent duplicate cc_import targets
    seen_so = set()
    deduped_so_files = []
    for f in so_files:
        if f not in seen_so:
            seen_so.add(f)
            deduped_so_files.append(f)
    so_files = deduped_so_files

    # Build file->repo mapping for NEEDED resolution
    file_to_repo = {}
    repo_prefix = ""
    if rctx.attr.name.endswith(rctx.attr.target_name):
        repo_prefix = rctx.attr.name[:-len(rctx.attr.target_name)]
    for dep in depends_on:
        (suite, name, arch, _) = lockfile.parse_package_key(dep)
        filemap = depends_file_map.get(name, []) or []
        repo_name = repo_prefix + util.sanitize(dep)
        for file in filemap:
            file_to_repo[file] = repo_name

    # Run readelf on all non-symlink .so files to get NEEDED deps
    so_needed_map = {}  # so_path -> [needed_lib_names]
    so_non_symlink_files = [f for f in so_files if f not in symlinks]
    if so_non_symlink_files:
        rctx.execute(
            ["tar", "-xvf", "data.tar.xz"] + ["./" + f for f in so_non_symlink_files],
        )
        for f in so_non_symlink_files:
            if rctx.path(f).exists:
                needed = _run_readelf(rctx, f)
                so_needed_map[f] = needed
        # Cleanup
        for f in so_non_symlink_files:
            if rctx.path(f).exists:
                rctx.execute(["rm", "-f", f])

    # Determine if this is a dev package
    is_dev = rctx.attr.package_name.endswith("-dev")

    if is_dev:
        build_file_content = _generate_dev_package_content(
            rctx, so_files, symlinks, h_files, hpp_files, hpp_files_woext, pc_files,
            file_to_repo, so_needed_map, repo_prefix, depends_on, linkscript_dep_map,
        )
    else:
        build_file_content = _generate_non_dev_package_content(
            rctx, so_files, symlinks, file_to_repo, so_needed_map, repo_prefix, linkscript_dep_map,
        )

    return (build_file_content, outs, foreign_symlinks, self_symlinks, linkscripts, linkscript_dep_labels)


def _resolve_needed_dep(needed_lib, file_to_repo, repo_prefix, package_name):
    """Resolve a NEEDED library to a Bazel target.

    Returns (target, is_found) tuple.
    needed_lib is like 'libm.so.6' or 'libfoo.so.1.2.3'.
    """
    # Try exact match first
    for (file_path, repo) in file_to_repo.items():
        file_basename = file_path[file_path.rfind("/") + 1:]
        if file_basename == needed_lib:
            apparent_repo = repo
            if repo_prefix and repo.startswith(repo_prefix):
                apparent_repo = repo[len(repo_prefix):]
            target_name = _get_cc_import_name(file_basename)
            return "@{}//:{}".format(apparent_repo, target_name), True

    # Try match without version suffix
    needed_base = _strip_version_suffix(needed_lib)
    for (file_path, repo) in file_to_repo.items():
        file_basename = file_path[file_path.rfind("/") + 1:]
        if file_basename == needed_lib:
            apparent_repo = repo
            if repo_prefix and repo.startswith(repo_prefix):
                apparent_repo = repo[len(repo_prefix):]
            target_name = _get_cc_import_name(file_basename)
            return "@{}//:{}".format(apparent_repo, target_name), True
        file_base = _strip_version_suffix(file_basename)
        if file_base == needed_base:
            apparent_repo = repo
            if repo_prefix and repo.startswith(repo_prefix):
                apparent_repo = repo[len(repo_prefix):]
            target_name = _get_cc_import_name(file_basename)
            return "@{}//:{}".format(apparent_repo, target_name), True

    return needed_lib, False


def _generate_non_dev_package_content(rctx, so_files, symlinks, file_to_repo, so_needed_map, repo_prefix, linkscript_dep_map):
    """Generate BUILD content for non-dev packages.

    For each .so (symlink or not): cc_import target named after basename.
    Symlink .so targets have deps pointing to the actual .so's cc_import.
    Non-symlink .so targets have deps from readelf NEEDED resolution.
    Linker script .so targets have deps from the parsed linkscript references.
    """
    lines = []

    # Process non-symlink .so files first
    for so_path in so_files:
        if so_path in symlinks:
            continue
        # Only generate cc_import for .so files directly in usr/lib/ or usr/lib/x86_64-linux-gnu/
        if not _is_top_level_so(so_path):
            continue

        so_basename = _get_so_basename(so_path)
        target_name = _get_cc_import_name(so_basename)

        # Resolve NEEDED deps
        needed = so_needed_map.get(so_path, [])
        deps = []
        seen_dep_targets = set()
        for needed_lib in needed:
            dep_target, found = _resolve_needed_dep(needed_lib, file_to_repo, repo_prefix, rctx.attr.package_name)
            if found and dep_target not in seen_dep_targets:
                deps.append(dep_target)
                seen_dep_targets.add(dep_target)

        deps_str = json.encode_indent(deps) if deps else "[]"

        lines.append('cc_import(')
        lines.append('    name = "{}",'.format(target_name))
        lines.append('    shared_library = ":{}",'.format(so_path))
        if deps:
            lines.append('    deps = {},'.format(deps_str))
        lines.append('    visibility = ["//visibility:public"],')
        lines.append(')')
        lines.append('')

    # Process symlink .so files - cc_import with deps on the actual .so's cc_import
    for so_path in so_files:
        if so_path not in symlinks:
            continue
        if not _is_top_level_so(so_path):
            continue

        so_basename = _get_so_basename(so_path)
        target_name = _get_cc_import_name(so_basename)
        symlink_target = symlinks[so_path]

        # Find the actual cc_import target
        actual_target = None
        if symlink_target in file_to_repo:
            target_repo = file_to_repo[symlink_target]
            apparent_repo = target_repo
            if repo_prefix and target_repo.startswith(repo_prefix):
                apparent_repo = target_repo[len(repo_prefix):]
            target_basename = _get_so_basename(symlink_target)
            actual_target = "@{}//:{}".format(apparent_repo, _get_cc_import_name(target_basename))
        else:
            # Try to find in this package's non-symlink .so files
            for other_path in so_files:
                if other_path in symlinks:
                    continue
                if other_path == symlink_target:
                    actual_target = ":{}".format(_get_cc_import_name(_get_so_basename(other_path)))
                    break

        if actual_target == None:
            continue

        lines.append('cc_import(')
        lines.append('    name = "{}",'.format(target_name))
        lines.append('    shared_library = ":{}",'.format(so_path))
        lines.append('    deps = ["{}"],'.format(actual_target))
        lines.append('    visibility = ["//visibility:public"],')
        lines.append(')')
        lines.append('')

    # Generate cc_import for linker script .so files
    for ls_path, ls_deps in linkscript_dep_map.items():
        if not _is_top_level_so(ls_path):
            continue
        ls_basename = _get_so_basename(ls_path)
        target_name = _get_cc_import_name(ls_basename)
        deps_str = json.encode_indent(ls_deps) if ls_deps else "[]"

        lines.append('cc_import(')
        lines.append('    name = "{}",'.format(target_name))
        lines.append('    shared_library = ":{}",'.format(ls_path))
        if ls_deps:
            lines.append('    deps = {},'.format(deps_str))
        lines.append('    visibility = ["//visibility:public"],')
        lines.append(')')
        lines.append('')

    return "\n".join(lines)


def _resolve_pc_lib_dep(libname, file_to_repo, repo_prefix):
    """Resolve a pkgconfig -l<libname> to a Bazel target.

    libname is like 'libfoo' or 'libfoo.so.1'.
    Returns (target, is_found).
    """
    # Try exact match
    for (file_path, repo) in file_to_repo.items():
        file_basename = file_path[file_path.rfind("/") + 1:]
        if file_basename == libname:
            apparent_repo = repo
            if repo_prefix and repo.startswith(repo_prefix):
                apparent_repo = repo[len(repo_prefix):]
            return "@{}//:{}".format(apparent_repo, _get_cc_import_name(file_basename)), True

    # Try matching by stripping version from both sides
    libname_base = _strip_version_suffix(libname)
    for (file_path, repo) in file_to_repo.items():
        file_basename = file_path[file_path.rfind("/") + 1:]
        file_base = _strip_version_suffix(file_basename)
        if file_base == libname_base:
            apparent_repo = repo
            if repo_prefix and repo.startswith(repo_prefix):
                apparent_repo = repo[len(repo_prefix):]
            return "@{}//:{}".format(apparent_repo, _get_cc_import_name(file_basename)), True

    # Also try libname without "lib" prefix matching
    if libname.startswith("lib"):
        bare_name = libname[3:]
        for (file_path, repo) in file_to_repo.items():
            file_basename = file_path[file_path.rfind("/") + 1:]
            if file_basename.startswith(bare_name + ".so"):
                apparent_repo = repo
                if repo_prefix and repo.startswith(repo_prefix):
                    apparent_repo = repo[len(repo_prefix):]
                return "@{}//:{}".format(apparent_repo, _get_cc_import_name(file_basename)), True

    return libname, False


def _resolve_hdrs_dep(dep_package_name):
    """Get the *_hdrs target for a -dev dependency.

    dep_package_name is a full dependency key like "bookworm_libfoo-dev-amd64_1.0-1".
    e.g. "bookworm_libfoo-dev-amd64_1.0-1" -> "@bookworm_libfoo-dev-amd64_1.0.1//:libfoo_hdrs"
    """
    (suite, name, arch, version) = lockfile.parse_package_key(dep_package_name)
    sanitized = util.sanitize(dep_package_name)
    # name is the raw package name like "libfoo-dev"
    base_name = name.removesuffix("-dev")
    return "@{}//:{}_hdrs".format(sanitized, base_name)


def _generate_dev_package_content(rctx, so_files, symlinks, h_files, hpp_files, hpp_files_woext, pc_files, file_to_repo, so_needed_map, repo_prefix, depends_on, linkscript_dep_map):
    """Generate BUILD content for dev packages.

    1. hdrs via directory_glob
    2. cc_import for each .so
    3. cc_library for the main libname target
    """
    lines = []
    package_name = rctx.attr.package_name
    base_name = package_name.removesuffix("-dev")

    # Parse all .pc files
    pc_data_list = []
    all_pc_includes = []
    all_pc_link_paths = []
    all_pc_defines = []
    all_pc_libnames = []

    if pc_files:
        rctx.execute(
            ["tar", "-xvf", "data.tar.xz"] + ["./" + pc for pc in pc_files],
        )
        for pc_file in pc_files:
            if rctx.path(pc_file).exists:
                pkgc = pkgconfig(rctx, pc_file)
                pc_data_list.append(pkgc)
                all_pc_includes.extend(pkgc.includes)
                all_pc_link_paths.extend(pkgc.link_paths)
                all_pc_defines.extend(pkgc.defines)
                all_pc_libnames.extend(pkgc.libnames)
        # Cleanup
        for pc_file in pc_files:
            if rctx.path(pc_file).exists:
                rctx.execute(["rm", "-f", pc_file])

    # Determine includes from .pc Cflags. `strip_include_prefix = "usr/include"`
    # already exposes `usr/include/*` as top-level virtual includes, but that
    # only enables `#include <subdir/foo.h>`. For `#include <foo.h>` where foo.h
    # lives under `usr/include/<subdir>/`, an additional -I is needed.
    #
    # Bazel's `includes` attr produces `-I<pkg>/<entry>` at the physical layout
    # and does NOT stack with strip_include_prefix, so entries must point at
    # the real on-disk path (e.g. "usr/include/python3.11").
    hdrs_includes = []
    seen = {}
    for inc in all_pc_includes:
        stripped = inc
        if stripped.startswith("/"):
            stripped = stripped[1:]
        if stripped == "usr/include":
            continue  # already covered by strip_include_prefix
        if not stripped.startswith("usr/include/"):
            continue  # outside the package; cannot express cleanly here
        if stripped in seen:
            continue
        seen[stripped] = True
        hdrs_includes.append(stripped)

    # 1. Generate hdrs target: directory_glob + cc_library
    hdrs_deps = []
    for dep in depends_on:
        (_, name, _, _) = lockfile.parse_package_key(dep)
        if name.endswith("-dev"):
            hdrs_dep = _resolve_hdrs_dep(dep)
            hdrs_deps.append(hdrs_dep)

    lines.append('directory_glob(')
    lines.append('    name = "hdrs",')
    lines.append('    srcs = [')
    lines.append('        "usr/include/**/*.h",')
    lines.append('        "usr/include/**/*.hpp",')
    lines.append('    ],')
    lines.append('    allow_empty = True,')
    lines.append('    directory = ":directory",')
    lines.append('    visibility = ["//visibility:public"],')
    lines.append(')')
    lines.append('')

    hdrs_target_name = "{}_hdrs".format(base_name)
    lines.append('cc_library(')
    lines.append('    name = "{}",'.format(hdrs_target_name))
    lines.append('    hdrs = [":hdrs"],')
    lines.append('    strip_include_prefix = "usr/include",')
    if hdrs_includes:
        lines.append('    includes = {},'.format(json.encode_indent(hdrs_includes)))
    if hdrs_deps:
        lines.append('    deps = {},'.format(json.encode_indent(hdrs_deps)))
    lines.append('    visibility = ["//visibility:public"],')
    lines.append(')')
    lines.append('')

    # 2. Generate cc_import for each non-symlink .so
    # Build a mapping from so_path -> cc_import target name for alias resolution
    so_path_to_cc_import_target = {}
    so_import_targets = []
    for so_path in so_files:
        if so_path in symlinks:
            continue
        if not _is_top_level_so(so_path):
            continue
        so_basename = _get_so_basename(so_path)
        target_name = _get_library_base_name(so_basename)
        so_path_to_cc_import_target[so_path] = target_name
        so_import_targets.append(target_name)

        # Build deps list
        deps = []
        seen_dep_targets = set()

        # Add hdrs target
        hdrs_target_name_ref = ":{}_hdrs".format(base_name)
        deps.append(hdrs_target_name_ref)
        seen_dep_targets.add(hdrs_target_name_ref)

        # Resolve -l libs from .pc
        pc_resolved_targets = set()
        for libname in all_pc_libnames:
            dep_target, found = _resolve_pc_lib_dep(libname, file_to_repo, repo_prefix)
            if found:
                if dep_target not in seen_dep_targets:
                    deps.append(dep_target)
                    seen_dep_targets.add(dep_target)
                pc_resolved_targets.add(_strip_version_suffix(libname))

        # Resolve NEEDED deps from readelf (only available for non-symlink .so)
        needed = so_needed_map.get(so_path, [])
        unfound_libs = []
        for needed_lib in needed:
            dep_target, found = _resolve_needed_dep(needed_lib, file_to_repo, repo_prefix, package_name)
            if found:
                needed_base = _strip_version_suffix(needed_lib)
                if needed_base not in pc_resolved_targets:
                    already_covered = False
                    for pc_resolved in pc_resolved_targets:
                        if _strip_version_suffix(pc_resolved) == needed_base:
                            already_covered = True
                            break
                    if not already_covered:
                        if dep_target not in seen_dep_targets:
                            deps.append(dep_target)
                            seen_dep_targets.add(dep_target)
            else:
                unfound_libs.append(needed_lib)

        # Handle unfound libs as linkopts
        linkopts = []
        for unfound in unfound_libs:
            bare = unfound
            if bare.startswith("lib") and bare.find(".so") != -1:
                bare = bare[3:bare.find(".so")]
            elif bare.startswith("lib"):
                bare = bare[3:]
            linkopts.append("-l{}".format(bare))

        # Add defines from .pc
        defines = list(all_pc_defines) if all_pc_defines else []

        # Add linkopts from .pc
        pc_linkopts = []
        for pkgc in pc_data_list:
            pc_linkopts.extend(pkgc.linkopts)

        lines.append('cc_import(')
        lines.append('    name = "{}",'.format(target_name))
        lines.append('    shared_library = ":{}",'.format(so_path))
        if defines:
            lines.append('    defines = {},'.format(json.encode_indent(defines)))
        if deps:
            lines.append('    deps = {},'.format(json.encode_indent(deps)))
        all_linkopts = pc_linkopts + ["-l{}".format(l) for l in linkopts]
        if all_linkopts:
            lines.append('    linkopts = {},'.format(json.encode_indent(all_linkopts)))
        lines.append('    visibility = ["//visibility:public"],')
        lines.append(')')
        lines.append('')

    # Generate cc_import for symlink .so files with deps on the actual .so's cc_import
    for so_path in so_files:
        if so_path not in symlinks:
            continue
        if not _is_top_level_so(so_path):
            continue

        so_basename = _get_so_basename(so_path)
        target_name = _get_library_base_name(so_basename)
        so_import_targets.append(target_name)

        symlink_target = symlinks[so_path]

        # Find the actual cc_import target in the dependency package
        if symlink_target in file_to_repo:
            target_repo = file_to_repo[symlink_target]
            apparent_repo = target_repo
            if repo_prefix and target_repo.startswith(repo_prefix):
                apparent_repo = target_repo[len(repo_prefix):]
            target_basename = _get_so_basename(symlink_target)
            actual_target = "@{}//:{}".format(apparent_repo, _get_cc_import_name(target_basename))
        elif symlink_target in so_path_to_cc_import_target:
            actual_target = ":{}".format(so_path_to_cc_import_target[symlink_target])
        else:
            util.warning(rctx, "symlink target for {} not found: {}".format(so_path, symlink_target))
            continue

        hdrs_dep = ":{}_hdrs".format(base_name)
        symlinks_deps = [actual_target, hdrs_dep]
        lines.append('cc_import(')
        lines.append('    name = "{}",'.format(target_name))
        lines.append('    shared_library = ":{}",'.format(so_path))
        lines.append('    deps = {},'.format(json.encode_indent(symlinks_deps)))
        lines.append('    visibility = ["//visibility:public"],')
        lines.append(')')
        lines.append('')

    # Collect linkscript target names so cc_library can depend on them
    linkscript_target_names = []
    for ls_path in linkscript_dep_map.keys():
        if _is_top_level_so(ls_path):
            ls_basename = _get_so_basename(ls_path)
            linkscript_target_names.append(_get_library_base_name(ls_basename))

    # 3. Generate cc_library for main libname (e.g. libhiredis)
    # Skip if base_name already matches a cc_import target from step 2
    if base_name not in so_import_targets:
        lib_deps = [":{}".format(hdrs_target_name)]
        for t in so_import_targets:
            lib_deps.append(":{}".format(t))
        for t in linkscript_target_names:
            lib_deps.append(":{}".format(t))

        lines.append('cc_library(')
        lines.append('    name = "{}",'.format(base_name))
        lines.append('    deps = {},'.format(json.encode_indent(lib_deps)))
        lines.append('    visibility = ["//visibility:public"],')
        lines.append(')')
        lines.append('')

    # Generate cc_import for linker script .so files
    for ls_path, ls_deps in linkscript_dep_map.items():
        if not _is_top_level_so(ls_path):
            continue
        ls_basename = _get_so_basename(ls_path)
        target_name = _get_library_base_name(ls_basename)
        so_import_targets.append(target_name)
        hdrs_dep = ":{}_hdrs".format(base_name)
        all_deps = [hdrs_dep] + ls_deps

        lines.append('cc_import(')
        lines.append('    name = "{}",'.format(target_name))
        lines.append('    shared_library = ":{}",'.format(ls_path))
        lines.append('    deps = {},'.format(json.encode_indent(all_deps)))
        lines.append('    visibility = ["//visibility:public"],')
        lines.append(')')
        lines.append('')

    return "\n".join(lines)


def _deb_import_impl(rctx):
    rctx.download_and_extract(
        url = rctx.attr.urls,
        sha256 = rctx.attr.sha256,
    )

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
