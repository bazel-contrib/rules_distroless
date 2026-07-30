"unit tests for lockfile.bzl"

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//apt/private:lockfile.bzl", "lockfile")

_TEST_SUITE_PREFIX = "lockfile/"

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

def lockfile_tests():
    add_source_merges_architectures_test(name = _TEST_SUITE_PREFIX + "add_source_merges_architectures")
