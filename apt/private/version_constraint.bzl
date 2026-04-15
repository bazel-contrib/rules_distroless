"version constraint utilities"

load(":version.bzl", version_lib = "version")

def _parse_version_constraint(rawv):
    vconst_i = rawv.find(" ")
    if vconst_i == -1:
        fail('invalid version string %s expected a version constraint ">=", "=", ">=", "<<", ">>"' % rawv)
    return (rawv[:vconst_i], rawv[vconst_i + 1:])

def _parse_dep(raw):
    raw = raw.strip()  # remove leading & trailing whitespace
    name = None
    version = None
    archs = None

    sqb_start_i = raw.find("[")
    if sqb_start_i != -1:
        sqb_end_i = raw.find("]")
        if sqb_end_i == -1:
            fail('invalid version string %s expected a closing brackets "]"' % raw)
        archs = raw[sqb_start_i + 1:sqb_end_i].strip().split(" ")
        raw = raw[:sqb_start_i] + raw[sqb_end_i + 1:]

    paren_start_i = raw.find("(")
    if paren_start_i != -1:
        paren_end_i = raw.find(")")
        if paren_end_i == -1:
            fail('invalid version string %s expected a closing paren ")"' % raw)
        name = raw[:paren_start_i].strip()
        version_and_const = raw[paren_start_i + 1:paren_end_i].strip()
        raw = raw[:paren_start_i] + raw[paren_end_i + 1:]
        version = _parse_version_constraint(version_and_const)

    # Depends: python3:any
    # is equivalent to
    # Depends: python3 [any]
    colon_i = raw.find(":")
    if colon_i != -1:
        arch_after_colon = raw[colon_i + 1:]
        raw = raw[:colon_i]
        archs = [arch_after_colon.strip()]

    name = raw.strip()
    return {"name": name, "version": version, "arch": archs}

def _parse_depends(depends_raw):
    depends = []
    for dep in depends_raw.split(","):
        if dep.find("|") != -1:
            depends.append([
                _parse_dep(adep)
                for adep in dep.split("|")
            ])
        else:
            depends.append(_parse_dep(dep))

    return depends

def _version_relop(va, vb, op):
    if op == "<<":
        return version_lib.lt(va, vb)
    elif op == ">>":
        return version_lib.gt(va, vb)
    elif op == "<=":
        return version_lib.lte(va, vb)
    elif op == ">=":
        return version_lib.gte(va, vb)
    elif op == "=":
        return version_lib.eq(va, vb)
    fail("unknown op %s" % op)

def _is_satisfied_by(va, vb):
    if vb[0] != "=":
        fail("Per https://www.debian.org/doc/debian-policy/ch-relationships.html only = is allowed for Provides field.")

    return _version_relop(vb[1], va[1], va[0])

version_constraint = struct(
    relop = _version_relop,
    is_satisfied_by = _is_satisfied_by,
    parse_version_constraint = _parse_version_constraint,
    parse_depends = _parse_depends,
    parse_dep = _parse_dep,
)
