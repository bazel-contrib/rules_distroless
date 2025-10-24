"repository rule for resolving and generating lockfile"

load("@bazel_lib//lib:repo_utils.bzl", "repo_utils")
load(":apt_deb_repository.bzl", "deb_repository")
load(":apt_dep_resolver.bzl", "dependency_resolver")
load(":lockfile.bzl", "lockfile")
load(":util.bzl", "util")
load(":version_constraint.bzl", "version_constraint")

def _parse_manifest(rctx, yq_toolchain_prefix, manifest):
    is_windows = repo_utils.is_windows(rctx)
    host_yq = Label("@{}_{}//:yq{}".format(yq_toolchain_prefix, repo_utils.platform(rctx), ".exe" if is_windows else ""))

    if hasattr(rctx, "watch"):
        rctx.watch(manifest)

    yq_args = [
        str(rctx.path(host_yq)),
        str(rctx.path(manifest)),
        "-o=json",
    ]
    result = rctx.execute(yq_args)
    if result.return_code:
        fail("failed to parse manifest yq. '{}' exited with {}: \nSTDOUT:\n{}\nSTDERR:\n{}".format(" ".join(yq_args), result.return_code, result.stdout, result.stderr))

    return json.decode(result.stdout if result.stdout != "null" else "{}")

# This function is shared between BZLMOD and WORKSPACE implementations.
# INTERNAL: DO NOT DEPEND!
# buildifier: disable=function-docstring-args
def internal_resolve(rctx, yq_toolchain_prefix, manifest, include_transitive):
    manifest = _parse_manifest(rctx, yq_toolchain_prefix, manifest)

    if manifest["version"] != 1:
        fail("Unsupported manifest version, {}. Please use `version: 1` manifest.".format(manifest["version"]))

    if type(manifest["sources"]) != "list":
        fail("`sources` should be an array")

    if type(manifest["archs"]) != "list":
        fail("`archs` should be an array")

    if type(manifest["packages"]) != "list":
        fail("`packages` should be an array")

    sources = []

    for src in manifest["sources"]:
        distr, components = src["channel"].split(" ", 1)
        for comp in components.split(" "):
            # TODO: only support urls before 1.0
            if "urls" in src:
                urls = src["urls"]
            elif "url" in src:
                urls = [src["url"]]
            else:
                fail("Source missing 'url' or 'urls' field")

            sources.append((
                urls,
                distr,
                comp,
            ))

    repository = deb_repository.new(rctx, sources = sources, archs = manifest["archs"])
    resolver = dependency_resolver.new(repository)
    lockf = lockfile.empty(rctx)

    resolved_count = 0

    for arch in manifest["archs"]:
        resolved_count = 0
        dep_constraint_set = {}
        for dep_constraint in manifest["packages"]:
            if dep_constraint in dep_constraint_set:
                fail("Duplicate package, {}. Please remove it from your manifest".format(dep_constraint))
            dep_constraint_set[dep_constraint] = True

            constraint = version_constraint.parse_depends(dep_constraint).pop()

            rctx.report_progress("Resolving %s for %s" % (dep_constraint, arch))
            (package, dependencies, unmet_dependencies) = resolver.resolve_all(
                name = constraint["name"],
                version = constraint["version"],
                arch = arch,
                include_transitive = include_transitive,
            )

            if not package:
                fail("Unable to locate package `%s` for architecture: %s. It may only exist for specific set of architectures." % (dep_constraint, arch))

            if len(unmet_dependencies):
                # buildifier: disable=print
                util.warning(rctx, "Following dependencies could not be resolved for %s: %s" % (constraint["name"], ",".join([up[0] for up in unmet_dependencies])))

            lockf.add_package(package, arch)

            resolved_count += len(dependencies) + 1

            for dep in dependencies:
                lockf.add_package(dep, arch)
                lockf.add_package_dependency(package, dep, arch)

        rctx.report_progress("Resolved %d packages for %s" % (resolved_count, arch))
    return lockf

_BUILD_TMPL = """
load("@rules_shell//shell:sh_binary.bzl", "sh_binary")

filegroup(
    name = "lockfile",
    srcs = ["lock.json"],
    tags = ["manual"],
    visibility = ["//visibility:public"]
)

sh_binary(
    name = "lock",
    srcs = ["copy.sh"],
    data = ["lock.json"],
    tags = ["manual"],
    args = ["$(location :lock.json)"],
    visibility = ["//visibility:public"]
) 
"""

def _deb_resolve_impl(rctx):
    lockf = internal_resolve(rctx, rctx.attr.yq_toolchain_prefix, rctx.attr.manifest, rctx.attr.resolve_transitive)
    lockf.write("lock.json")

    lock_filename = rctx.attr.manifest.name.replace(".yaml", ".lock.json")
    lock_label = rctx.attr.manifest.relative(lock_filename)
    workspace_relative_path = "{}{}".format(
        ("%s/" % lock_label.package) if lock_label.package else "",
        lock_label.name,
    )

    rctx.file(
        "copy.sh",
        rctx.read(rctx.attr._copy_sh_tmpl).format(
            repo_name = util.get_repo_name(rctx.name).replace("_resolve", ""),
            lock_label = lock_label,
            workspace_relative_path = workspace_relative_path,
        ),
        executable = True,
    )

    rctx.file("BUILD.bazel", _BUILD_TMPL)

deb_resolve = repository_rule(
    implementation = _deb_resolve_impl,
    attrs = {
        "manifest": attr.label(),
        "resolve_transitive": attr.bool(default = True),
        "yq_toolchain_prefix": attr.string(default = "yq"),
        "_copy_sh_tmpl": attr.label(
            default = "//apt/private:copy.sh.tmpl",
            doc = "INTERNAL, DO NOT USE - " +
                  "private attribute label to prevent repo restart",
        ),
    },
)
