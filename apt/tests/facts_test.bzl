"unit tests for snapshot fact cache keys"

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//apt/private:util.bzl", "util")

_TEST_SUITE_PREFIX = "facts/"

_TEST_SNAPSHOT_1 = ["https://snapshot.debian.org/archive/debian/20251001T023456Z"]
_TEST_SNAPSHOT_2 = ["https://snapshot.debian.org/archive/debian/20240210T223313Z"]

def _url_scoped_fact_key_test(ctx):
    env = unittest.begin(ctx)

    k1 = util.index_fact_key("bookworm", "main", "amd64", "Packages", _TEST_SNAPSHOT_1)
    k2 = util.index_fact_key("bookworm", "main", "amd64", "Packages", _TEST_SNAPSHOT_2)

    asserts.true(env, k1 != k2, "changing the snapshot URL must change the fact key")

    # The suite (dist) must stay first so we can still recover the suite with `key.split("/")[0]`
    asserts.equals(env, "bookworm", k1.split("/")[0])

    # Same source is stable across calls.
    asserts.equals(env, k1, util.index_fact_key("bookworm", "main", "amd64", "Packages", _TEST_SNAPSHOT_1))

    # Mirror URL order and duplicates must not change the key (because the contents are the same)
    a = _TEST_SNAPSHOT_1[0]
    b = "https://deb.debian.org/debian"
    asserts.equals(
        env,
        util.index_fact_key("bookworm", "main", "amd64", "Packages", [a, b]),
        util.index_fact_key("bookworm", "main", "amd64", "Packages", [b, a, a]),
    )

    # Packages and Contents for the same source must not collide.
    asserts.true(
        env,
        k1 != util.index_fact_key("bookworm", "main", "amd64", "Contents", _TEST_SNAPSHOT_1),
        "Packages and Contents keys must differ",
    )

    return unittest.end(env)

def _prune_facts_test(ctx):
    env = unittest.begin(ctx)

    old_key = util.index_fact_key("bookworm", "main", "amd64", "Packages", _TEST_SNAPSHOT_1)
    new_key = util.index_fact_key("bookworm", "main", "amd64", "Packages", _TEST_SNAPSHOT_2)
    rolling_key = util.index_fact_key("sid", "main", "amd64", "Packages", ["https://deb.debian.org/debian"])

    indices = {old_key: "sha256-OLD", new_key: "sha256-NEW", rolling_key: "sha256-ROLLING"}
    formats = {old_key: ".xz", new_key: ".xz", rolling_key: ".xz"}

    # Only the current sources' keys are used this run.
    used_keys = {new_key: True, rolling_key: True}
    snapshot_suites = {"bookworm": True}

    (cacheable_indices, cacheable_formats) = util.prune_uncacheable_facts(indices, formats, used_keys, snapshot_suites)

    # The stale previous-URL entry is dropped, and indices from rolling indexes are not cached.
    asserts.equals(env, {new_key: "sha256-NEW"}, cacheable_indices)
    asserts.equals(env, {new_key: ".xz", rolling_key: ".xz"}, cacheable_formats)

    return unittest.end(env)

url_scoped_fact_key_test = unittest.make(_url_scoped_fact_key_test)
prune_facts_test = unittest.make(_prune_facts_test)

def facts_tests():
    url_scoped_fact_key_test(name = _TEST_SUITE_PREFIX + "url_scoped_fact_key")
    prune_facts_test(name = _TEST_SUITE_PREFIX + "prune_facts")
