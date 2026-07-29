"unit tests for linker script parsing"

load("@bazel_skylib//lib:unittest.bzl", "asserts", "unittest")
load("//apt/private:linker_script.bzl", "linker_script")

_TEST_SUITE_PREFIX = "linker_script/"

def _files_to_remap_test(ctx):
    # (description, linker script content, expected remap targets)
    parameters = [
        (
            "empty input",
            "",
            [],
        ),
        (
            "comment only",
            "/* GNU ld script */",
            [],
        ),
        (
            "libncurses INPUT: relative soname and -l flag are not remapped",
            "INPUT(libncurses.so.6 -ltinfo)",
            [],
        ),
        (
            "libbsd GROUP with comment, OUTPUT_FORMAT and AS_NEEDED(-lmd)",
            """/* GNU ld script
 * The MD5 functions are provided by the libmd library. */
OUTPUT_FORMAT(elf64-x86-64)
GROUP(/usr/lib/x86_64-linux-gnu/libbsd.so.0.12.2 AS_NEEDED(-lmd))
""",
            ["/usr/lib/x86_64-linux-gnu/libbsd.so.0.12.2"],
        ),
        (
            "libc GROUP with nested AS_NEEDED and a .a static lib",
            """/* GNU ld script
   Use the shared library, but some functions are only in
   the static library, so try that secondarily.  */
OUTPUT_FORMAT(elf64-x86-64)
GROUP ( /lib/x86_64-linux-gnu/libc.so.6 /usr/lib/x86_64-linux-gnu/libc_nonshared.a  AS_NEEDED ( /lib64/ld-linux-x86-64.so.2 ) )
""",
            [
                "/lib/x86_64-linux-gnu/libc.so.6",
                "/usr/lib/x86_64-linux-gnu/libc_nonshared.a",
                "/lib64/ld-linux-x86-64.so.2",
            ],
        ),
        (
            "libm GROUP + AS_NEEDED",
            "GROUP ( /lib/x86_64-linux-gnu/libm.so.6  AS_NEEDED ( /lib/x86_64-linux-gnu/libmvec.so.1 ) )",
            [
                "/lib/x86_64-linux-gnu/libm.so.6",
                "/lib/x86_64-linux-gnu/libmvec.so.1",
            ],
        ),
        (
            "OUTPUT_FORMAT with comma-separated multiarch args yields nothing",
            "OUTPUT_FORMAT(elf64-littleaarch64, elf64-bigaarch64, elf64-littleaarch64)",
            [],
        ),
        (
            "multiple comments are all stripped",
            "/* a */ GROUP ( /lib/x86_64-linux-gnu/libc.so.6 ) /* b */",
            ["/lib/x86_64-linux-gnu/libc.so.6"],
        ),
        (
            "unterminated comment drops its body but keeps preceding content",
            "GROUP ( /lib/x86_64-linux-gnu/libc.so.6 ) /* dangling note without a close",
            ["/lib/x86_64-linux-gnu/libc.so.6"],
        ),
    ]

    env = unittest.begin(ctx)

    for description, content, expected in parameters:
        asserts.equals(
            env,
            expected,
            linker_script.files_to_remap(content),
            description,
        )

    return unittest.end(env)

files_to_remap_test = unittest.make(_files_to_remap_test)

def linker_script_tests():
    files_to_remap_test(name = _TEST_SUITE_PREFIX + "files_to_remap")
