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
    package_source_urls_test(name = _TEST_SUITE_PREFIX + "package_source_urls")
    add_source_merges_architectures_test(name = _TEST_SUITE_PREFIX + "add_source_merges_architectures")

def _package_source_urls_test(ctx):
    env = unittest.begin(ctx)
    lock = lockfile.empty(struct())
    package = {
        "Architecture": "amd64",
        "Dist": "noble",
        "Filename": "pool/main/e/example_1_amd64.deb",
        "Package": "example",
        "Roots": ["https://example.org/ppa"],
        "SHA256": "abc",
        "Section": "libs",
        "Size": "1",
        "Version": "1",
    }
    lock.add_source("noble", ["deb"], ["https://example.org/ubuntu"], ["main"], ["amd64"])
    lock.add_package(package)
    key = lockfile.package_key(package)
    expected = ["https://example.org/ppa/" + package["Filename"]]
    asserts.equals(env, expected, lock.packages()[key]["urls"])

    # A v2 lock without per-package URLs remains readable. Resolving its
    # package again must replace the old suite URL with the selected PPA URL.
    legacy = json.decode(lock.as_json())
    legacy["packages"][key].pop("urls")
    restored = lockfile.from_json(struct(), json.encode(legacy))
    asserts.equals(env, ["https://example.org/ubuntu/" + package["Filename"]], restored.packages()[key]["urls"])
    restored.add_package(package)
    asserts.equals(env, expected, restored.packages()[key]["urls"])
    return unittest.end(env)

package_source_urls_test = unittest.make(_package_source_urls_test)
