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

def _warning(rctx, message):
    rctx.execute([
        "echo",
        "\033[0;33mWARNING:\033[0m {}".format(message),
    ], quiet = False)

def _mergedusr_rewrite_script(bsdtar_bin, dollar = "$"):
    """Returns the bash script body that rewrites merged-/usr paths.

    The caller must set shell variables 'data_file' (input archive) and
    'layer' (output normalized .tar.gz path) before the returned script runs.

    This implements the same path hoisting logic as deb_postfix:
    - Files under ./bin/, ./sbin/, ./lib/, ./lib32/, ./lib64/, ./libx32/
      are moved to their ./usr/ counterparts.
    - The bare directory entries (./bin/, ./lib/, etc.) are dropped so no
      plain skeleton directory is written into the output archive.

    For more info on merged-/usr see:
      https://www.freedesktop.org/wiki/Software/systemd/TheCaseForTheUsrMerge/

    Args:
        bsdtar_bin: Path or Make-variable reference to bsdtar binary.
            Use "$(BSDTAR_BIN)" for genrule context,
            or a concrete path (str(rctx.which("bsdtar"))) for rctx.execute.
        dollar: "$" for rctx.execute (normal bash), "$$" for Bazel genrule cmd.
    """
    d = dollar
    return """\
            repeat_confirmation() {{
                local answer="{d}1"

                for ((j = 0; j < 31; j++)); do
                    printf '%s' "{d}answer"
                done
            }}

            answers_file={d}(mktemp)
            trap 'rm -f "{d}answers_file"' EXIT

            while IFS= read -r path; do
                keep="y"
                case "{d}path" in
                    ./bin/|./sbin/|./lib/|./lib32/|./lib64/|./libx32/)
                        keep="n"
                    ;;
                esac

                repeat_confirmation "{d}keep"
            done > "{d}answers_file" < <({bsdtar_bin} -tf "{d}data_file")

            {bsdtar_bin} --confirmation --gzip --options 'gzip:!timestamp' -cf "{d}layer" \
            -s "#^\\./bin/\\(.\\)#./usr/bin/\\1#" \
            -s "#^\\./sbin/\\(.\\)#./usr/sbin/\\1#" \
            -s "#^\\./lib/\\(.\\)#./usr/lib/\\1#" \
            -s "#^\\./lib32/\\(.\\)#./usr/lib32/\\1#" \
            -s "#^\\./lib64/\\(.\\)#./usr/lib64/\\1#" \
            -s "#^\\./libx32/\\(.\\)#./usr/libx32/\\1#" \
            "@{d}data_file" 2< "{d}answers_file"
""".format(d = d, bsdtar_bin = bsdtar_bin)

util = struct(
    sanitize = _sanitize,
    package_repo_name = _package_repo_name,
    set_dict = _set_dict,
    get_dict = _get_dict,
    warning = _warning,
    get_repo_name = _get_repo_name,
    is_snapshot_uri = _is_snapshot_uri,
    mergedusr_rewrite_script = _mergedusr_rewrite_script,
)
