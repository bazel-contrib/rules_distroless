"unit tests for lockfile.bzl"

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//apt/private:lockfile.bzl", "lockfile")

_TEST_SUITE_PREFIX = "lockfile/"

def _package(name, version, dist, architecture = "amd64"):
    return {
        "Architecture": architecture,
        "Dist": dist,
        "Filename": "pool/{}/{}_{}_{}.deb".format(name, name, version, architecture),
        "Package": name,
        "SHA256": "0" * 64,
        "Section": "libs",
        "Size": "1",
        "Version": version,
    }

# Regression test for `_add_source`: previously, calling `add_source` twice
# for the same suite (e.g. once per architecture, as `apt_deb_repository`
# does when resolving multiple architectures for the same suite) made the
# second call clobber the first, so the lockfile's `sources` entry only ever
# recorded the architectures from the *last* call. This test proves that
# architectures accumulate across calls instead of being overwritten, while
# still deduplicating repeated architectures.
def _add_source_merges_architectures_test(ctx):
    env = unittest.begin(ctx)

    lock = lockfile.empty(struct())

    lock.add_source(
        suite = "bookworm",
        types = ["deb"],
        uris = ["https://deb.debian.org/debian"],
        components = ["main"],
        architectures = ["amd64"],
    )
    lock.add_source(
        suite = "bookworm",
        types = ["deb"],
        uris = ["https://deb.debian.org/debian"],
        components = ["main"],
        architectures = ["arm64"],
    )

    source = lock.sources()["bookworm"]
    asserts.equals(env, ["amd64", "arm64"], source["architectures"])

    # Re-adding an architecture that's already recorded must not duplicate it.
    lock.add_source(
        suite = "bookworm",
        types = ["deb"],
        uris = ["https://deb.debian.org/debian"],
        components = ["main"],
        architectures = ["amd64", "arm64"],
    )

    source = lock.sources()["bookworm"]
    asserts.equals(env, ["amd64", "arm64"], source["architectures"])

    # A different suite must not be affected by other suites' architectures.
    lock.add_source(
        suite = "sid",
        types = ["deb"],
        uris = ["https://deb.debian.org/debian"],
        components = ["main"],
        architectures = ["riscv64"],
    )
    asserts.equals(env, ["riscv64"], lock.sources()["sid"]["architectures"])
    asserts.equals(env, ["amd64", "arm64"], lock.sources()["bookworm"]["architectures"])

    return unittest.end(env)

add_source_merges_architectures_test = unittest.make(_add_source_merges_architectures_test)

def _add_package_reuses_name_and_architecture_test(ctx):
    env = unittest.begin(ctx)

    lock = lockfile.empty(struct())
    updated_libssl = _package(
        name = "libssl3t64",
        version = "3.0.13-0ubuntu3.9",
        dist = "noble-updates",
    )
    release_libssl = _package(
        name = "libssl3t64",
        version = "3.0.13-0ubuntu3",
        dist = "noble",
    )
    librabbitmq = _package(
        name = "librabbitmq4",
        version = "0.11.0-1build2",
        dist = "noble",
    )

    lock.add_package(updated_libssl)
    lock.add_package(release_libssl)
    lock.add_package(librabbitmq)
    lock.add_package_dependency(librabbitmq, release_libssl)

    updated_libssl_key = lockfile.package_key(updated_libssl)
    release_libssl_key = lockfile.package_key(release_libssl)
    librabbitmq_key = lockfile.package_key(librabbitmq)
    packages = lock.packages()

    asserts.equals(env, 2, len(packages))
    asserts.true(env, updated_libssl_key in packages)
    asserts.false(env, release_libssl_key in packages)
    asserts.equals(env, [updated_libssl_key], packages[librabbitmq_key]["depends_on"])

    return unittest.end(env)

add_package_reuses_name_and_architecture_test = unittest.make(_add_package_reuses_name_and_architecture_test)

def lockfile_tests():
    add_source_merges_architectures_test(name = _TEST_SUITE_PREFIX + "add_source_merges_architectures")
    add_package_reuses_name_and_architecture_test(name = _TEST_SUITE_PREFIX + "add_package_reuses_name_and_architecture")
