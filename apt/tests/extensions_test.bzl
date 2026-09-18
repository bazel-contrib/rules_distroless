"unit tests for apt.install mergedusr scoping"

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//apt:extensions.bzl", "compute_package_repo_modes", "filter_package_templates")

_TEST_SUITE_PREFIX = "extensions/"

# Regression test for commit "Add mergedusr support to apt.install()".
#
# Before this fix, mergedusr was tracked as a single global boolean
# (`mergedusr_enabled`) across *all* `apt.install` calls in a module, so a
# single `apt.install(mergedusr = True)` call would force every other
# `apt.install` call (even ones that never asked for mergedusr) to also be
# built in mergedusr mode. `_package_repo_modes` instead computes, per
# package, exactly which modes (mergedusr True/False) are actually needed
# based on which root installs pulled it in transitively.
def _scoped_mergedusr_test(ctx):
    env = unittest.begin(ctx)

    packages = {
        "pkg-a": {"depends_on": []},
        "pkg-b": {"depends_on": []},
        "shared-dep": {"depends_on": []},
    }

    # Two independent apt.install roots: one with mergedusr=True (pkg-a),
    # one without (pkg-b). Both depend on shared-dep.
    roots_by_mode = {
        False: {"pkg-b": True, "shared-dep": True},
        True: {"pkg-a": True, "shared-dep": True},
    }

    modes = compute_package_repo_modes(packages, roots_by_mode)

    # pkg-a only ever needed in mergedusr mode.
    asserts.true(env, True in modes["pkg-a"])
    asserts.false(env, False in modes["pkg-a"])

    # pkg-b only ever needed without mergedusr.
    asserts.true(env, False in modes["pkg-b"])
    asserts.false(env, True in modes["pkg-b"])

    # shared-dep is needed in BOTH modes, since it's pulled in by both roots.
    # This is the crux of the fix: a single global flag could not represent this.
    asserts.true(env, False in modes["shared-dep"])
    asserts.true(env, True in modes["shared-dep"])

    return unittest.end(env)

scoped_mergedusr_test = unittest.make(_scoped_mergedusr_test)

def _filter_package_templates_test(ctx):
    env = unittest.begin(ctx)

    templates = [
        {
            "dependency_sets": ["trixie_java"],
            "packages": ["*"],
            "template": "trixie_template",
        },
        {
            "dependency_sets": [],
            "packages": ["*"],
            "template": "global_template",
        },
        {
            "dependency_sets": ["bullseye", "bookworm"],
            "packages": ["nginx-*"],
            "template": "nginx_template",
        },
    ]

    # Matching trixie_java
    trixie = filter_package_templates(templates, "trixie_java")
    asserts.equals(env, ["trixie_template", "global_template"], [t["template"] for t in trixie])

    # Matching bullseye
    bullseye = filter_package_templates(templates, "bullseye")
    asserts.equals(env, ["global_template", "nginx_template"], [t["template"] for t in bullseye])

    # Matching other set
    other = filter_package_templates(templates, "other_set")
    asserts.equals(env, ["global_template"], [t["template"] for t in other])

    return unittest.end(env)

filter_package_templates_test = unittest.make(_filter_package_templates_test)

def extensions_tests():
    scoped_mergedusr_test(name = _TEST_SUITE_PREFIX + "scoped_mergedusr")
    filter_package_templates_test(name = _TEST_SUITE_PREFIX + "filter_package_templates")
