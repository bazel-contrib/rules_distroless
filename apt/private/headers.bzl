"""Recognize installed C/C++ include fragments in Debian SDK imports."""

# Match the additional C/C++ header suffixes supported by rules_cc. The
# deb_import caller handles .h and .hpp separately.
_FRAGMENT_SUFFIXES = [".hh", ".ipp", ".hxx", ".h++", ".inc", ".inl", ".tlh", ".tli", ".H", ".tcc"]

def is_include_fragment(path):
    """Whether an installed include file has a supported fragment suffix."""
    return path.startswith("usr/include/") and any([path.endswith(suffix) for suffix in _FRAGMENT_SUFFIXES])
