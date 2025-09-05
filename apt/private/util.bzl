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

def _get_repo_name(st):
    if st.find("+") != -1:
        return st.split("+")[-1]
    return st.split("~")[-1]

def _warning(rctx, message):
    rctx.execute([
        "echo",
        "\033[0;33mWARNING:\033[0m {}".format(message),
    ], quiet = False)

util = struct(
    sanitize = _sanitize,
    set_dict = _set_dict,
    get_dict = _get_dict,
    warning = _warning,
    get_repo_name = _get_repo_name,
)
