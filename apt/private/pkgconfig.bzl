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
            if key not in variables:
                # fail("corrupted pc file")
                value_of_key = ""
            else:
                value_of_key = variables[key]

            # reset subs state
            key = ""
            in_subs = False

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

def _trim(str):
    return str.rstrip(" ").lstrip(" ")

def process_pcconfig(pc):
    (directives, variables) = pc
    includedir = ""
    libdir = ""
    if "includedir" in variables:
        includedir = _trim(variables["includedir"])
    if "libdir" in variables:
        libdir = _trim(variables["libdir"])
    linkopts = []
    includes = []
    defines = []
    libname = None
    if "Libs" in directives:
        libs = _trim(directives["Libs"]).split(" ")
        for arg in libs:
            if arg.startswith("-l"):
                libname = "lib" + arg.removeprefix("-l")
                continue
            if arg.startswith("-L"):
                continue
            linkopts.append(arg)

    # if "Libs.private" in directives:
    #     libs = _trim(directives["Libs.private"]).split(" ")
    #     linkopts.extend([arg for arg in libs if arg.startswith("-l")])

    if "Cflags" in directives:
        cflags = _trim(directives["Cflags"]).split(" ")
        for flag in cflags:
            if flag.startswith("-I"):
                include = flag.removeprefix("-I")
                includes.append(include)

                # If the include is direct include eg $includedir (/usr/include/hiredis)
                # equals to  -I/usr/include/hiredis then we need to add /usr/include into
                # includes array to satify imports as `#include <hiredis/hiredis.h>`
                if include == includedir:
                    includes.append(include.removesuffix("/" + directives["Name"]))
                elif include.startswith(includedir):
                    includes.append(include.removesuffix("/" + directives["Name"]))
            elif flag.startswith("-D"):
                define = flag.removeprefix("-D")
                defines.append(define)

    return (libname, includedir, libdir, linkopts, includes, defines)
