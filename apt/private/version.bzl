"parse debian version strings"

load("@bazel_lib//lib:strings.bzl", "ord")

# https://www.debian.org/doc/debian-policy/ch-controlfields.html#version
# https://github.com/Debian/apt/blob/main/apt-pkg/deb/debversion.cc
def _parse_version(rv):
    epoch_idx = rv.find(":")
    epoch = None
    if epoch_idx != -1:
        epoch = rv[:epoch_idx]
        rv = rv[epoch_idx + 1:]

    revision_idx = rv.rfind("-")
    revision = None
    if revision_idx != -1:
        revision = rv[revision_idx + 1:]
        rv = rv[:revision_idx]

    upstream = rv

    return (epoch, upstream, revision)

def _cmp(a, b):
    if a < b:
        return -1
    elif a > b:
        return 1
    return 0

def _getdigits(st):
    return "".join([c for c in st.elems() if c.isdigit()])

def _order(char):
    if len(char) > 1:
        fail("expected a single char")
    if char == "~":
        return -1
    elif char.isdigit():
        return int(char) + 1
    elif char.isalpha():
        return ord(char)
    else:
        return ord(char) + 256

def _version_cmp_string(va, vb):
    la = [_order(x) for x in va.elems()]
    lb = [_order(x) for x in vb.elems()]

    for i in range(max(len(la), len(lb))):
        a = 0
        b = 0
        if i < len(la):
            a = la[i]
        if i < len(lb):
            b = lb[i]
        res = _cmp(a, b)
        if res != 0:
            return res
    return 0

# Iterate over the whole string and split it into groups of
# numeric and non numeric portions.
#   a67bhgs89       -> 'a', '67', 'bhgs', '89'.
#   2.7.2-linux-1 -> '2', '.', '7', '.' ,'-linux-','1'
def _split_alpha_and_digit(v):
    v = v.elems()
    parts = []
    current_part = ""
    for (i, c) in enumerate(v):
        # skip the first iteration as we just began grouping
        if i == 0:
            current_part = c
            continue
        p = v[i - 1]
        if c.isdigit() != p.isdigit():
            parts.append(current_part)
            current_part = ""
        current_part += c

    # push leftover if theres any
    if current_part:
        parts.append(current_part)
    return parts

# https://github.com/Debian/apt/blob/2845127968cda30be8423e1d3a24dae0e797bcc8/apt-pkg/deb/debversion.cc#L52
def _version_cmp_part(va, vb):
    la = _split_alpha_and_digit(va)
    lb = _split_alpha_and_digit(vb)

    # compare alpha and digit parts of two strings
    for i in range(max(len(la), len(lb))):
        a = "0"
        b = "0"
        if i < len(la):
            a = la[i]
        if i < len(lb):
            b = lb[i]
        a_digits = _getdigits(a)
        b_digits = _getdigits(b)

        # compare if both parts are digits
        if a_digits and b_digits:
            a = int(a_digits)
            b = int(b_digits)
            res = _cmp(a, b)
            if res != 0:
                return res

            # do string comparison between the parts
        else:
            res = _version_cmp_string(a, b)
            if res != 0:
                return res
    return 0

def _compare_version(va, vb):
    vap = _parse_version(va)
    vbp = _parse_version(vb)

    # compare epoch
    res = _cmp(int(vap[0] or "0"), int(vbp[0] or "0"))
    if res != 0:
        return res

    # compare upstream version
    res = _version_cmp_part(vap[1], vbp[1])
    if res != 0:
        return res

    # compare debian revision
    return _version_cmp_part(vap[2] or "0", vbp[2] or "0")

def _sort(versions, reverse = False):
    vr = versions
    for i in range(len(vr)):
        for j in range(i + 1, len(vr)):
            # if vr[i] is greater than vr[i+1] then swap their indices.
            if _compare_version(vr[i], vr[j]) == 1:
                vri = vr[i]
                vr[i] = vr[j]
                vr[j] = vri
    if reverse:
        vr = reversed(vr)
    return vr

version = struct(
    parse = _parse_version,
    cmp = lambda va, vb: _compare_version(va, vb),
    gt = lambda va, vb: _compare_version(va, vb) == 1,
    gte = lambda va, vb: _compare_version(va, vb) >= 0,
    lt = lambda va, vb: _compare_version(va, vb) == -1,
    lte = lambda va, vb: _compare_version(va, vb) <= 0,
    eq = lambda va, vb: _compare_version(va, vb) == 0,
    sort = lambda versions, reverse = False: _sort(versions, reverse = reverse),
)
