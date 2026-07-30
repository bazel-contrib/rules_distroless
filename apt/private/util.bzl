"utilities"

def _set_dict(struct, value = None, keys = []):
    klen = len(keys)
    for i in range(klen - 1):
        k = keys[i]
        if not k in struct:
            struct[k] = {}
        struct = struct[k]

    struct[keys[-1]] = value

def _get_dict(struct, keys = [], default_value = None):
    value = struct
    for k in keys:
        if type(k) != "string":
            fail("Invalid key type: {} {}".format(type(k), k))
        if k in value:
            value = value[k]
        else:
            value = default_value
            break
    return value

def _sanitize(str):
    return str.removeprefix("/").replace("+", "-").replace(":", "-").replace("~", "_").replace("/", "_").replace("=", "_")

def _package_repo_name(package_key, mergedusr = False):
    repo_name = _sanitize(package_key)
    if mergedusr:
        return repo_name + "_mergedusr"
    return repo_name

def _get_repo_name(st):
    if st.find("+") != -1:
        return st.split("+")[-1]
    return st.split("~")[-1]

_SNAPSHOT_DOMAINS = [
    "snapshot.debian.org",
    "snapshot-cloudflare.debian.org",
    "snapshot.ubuntu.com",
]

def _is_snapshot_uri(uri):
    for domain in _SNAPSHOT_DOMAINS:
        if domain in uri:
            return True
    return False

def _index_fact_key(dist, component, architecture, index_type, urls):
    """Cache key for the integrity/format facts of a single package index.

    The key must include the snapshot urls (so that updating a source doesn't leave stale facts),
    as well as dist, component, architecture, and index type.

    The suite (`dist`) stays first so callers relying on `key.split("/")[0]` still recover the suite.
    URLs are deduplicated and sorted so that mirror order / `mirror+` duplicates don't spuriously invalidate the cache.
    """
    sorted_deduplicated_urls = sorted({url: None for url in urls}.keys())
    url_token = "|".join(sorted_deduplicated_urls)
    return "{}/{}/{}/{}/{}".format(dist, component, architecture, index_type, url_token)

def _prune_uncacheable_facts(indices, formats, used_keys, snapshot_suites):
    """Keep only the facts that can be cached.

    `used_keys` holds the fact keys produced for this run's sources (see `index_fact_key`).
    Entries left over from a previous snapshot URL are not in `used_keys`,
    so they get dropped here instead of accumulating across runs.

    `snapshot_suites` holds a list of suites from snapshots,
    because we don't want to cache rolling suites.

    Returns `(cacheable_indices, cacheable_formats)`.
    """
    cacheable_indices = {
        k: v
        for k, v in indices.items()
        if k in used_keys and k.split("/")[0] in snapshot_suites
    }
    cacheable_formats = {
        k: v
        for k, v in formats.items()
        if k in used_keys
    }
    return (cacheable_indices, cacheable_formats)

def _warning(rctx, message):
    rctx.execute([
        "echo",
        "\033[0;33mWARNING:\033[0m {}".format(message),
    ], quiet = False)

util = struct(
    sanitize = _sanitize,
    package_repo_name = _package_repo_name,
    set_dict = _set_dict,
    get_dict = _get_dict,
    warning = _warning,
    get_repo_name = _get_repo_name,
    is_snapshot_uri = _is_snapshot_uri,
    index_fact_key = _index_fact_key,
    prune_uncacheable_facts = _prune_uncacheable_facts,
)
