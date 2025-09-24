# Copyright thesayyn 2025
# Taken from https://github.com/thesayyn/pkgconfig/blob/main/extensions.bzl
def _expand_value(value, variables):
    # fast path
    if value.find("$") == -1:
        return value

    expanded_value = ""
    key = ""
    in_subs = False

    def assert_in_subs():
        if not in_subs:
            fail("corrupted pc file")

    for c in value.elems():
        if c == "$":
            in_subs = True
        elif c == "{":
            assert_in_subs()
        elif c == "}":
            assert_in_subs()
            value_of_key = variables[key]

            # reset subs state
            key = ""
            in_subs = False
            if not value_of_key:
                fail("corrupted pc file")
            expanded_value += value_of_key
        elif in_subs:
            key += c
        else:
            expanded_value += c

    return expanded_value

def parse_pc(pc):
    variables = {}
    directives = {}
    for l in pc.splitlines():
        if l.startswith("#"):
            continue
        if not l.strip():
            continue
        if l.find(": ") != -1:
            (k, v) = _split_once(l, ":")
            directives[k] = _expand_value(v.removeprefix(" "), variables)
        elif l.find("=") != -1:
            (k, v) = _split_once(l, "=")
            variables[k] = _expand_value(v, variables)

    return (directives, variables)

def _split_once(l, sep):
    values = l.split(sep, 1)
    if len(values) < 2:
        fail("corrupted pc config")
    return (values[0], values[1])

def _parse_requires(re):
    if not re:
        return []
    deps = re.split(",")
    return [dep.strip(" ") for dep in deps if dep.strip(" ")]
