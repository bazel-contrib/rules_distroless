"""Utilities to parse ld linker scripts.

Example:

```
/* GNU ld script
 * The MD5 functions are provided by the libmd library. */
OUTPUT_FORMAT(elf64-x86-64)
GROUP(/usr/lib/x86_64-linux-gnu/libbsd.so.0.11.7 AS_NEEDED(-lmd))
```

Parsing the above should return:
```
["/usr/lib/x86_64-linux-gnu/libbsd.so.0.11.7"]
```

"""

_ITERATION_LIMIT = 2147483646
_TOKEN_DELIMITERS = ["(", ")", ","]

# Map of <command name> -> <whether they take a file list>
_COMMANDS = {
    "GROUP": True,
    "INPUT": True,
    "AS_NEEDED": True,
    "OUTPUT_FORMAT": False,
}

def _command_takes_a_file_list(command):
    command_value = _COMMANDS.get(command)
    if command_value == None:
        fail("Unrecognized linker script command: {}. Supported commands: {}".format(
            command,
            _COMMANDS.keys(),
        ))
    return command_value

def _is_library(token):
    base = token.rsplit("/", 1)[-1]
    return base.endswith(".a") or ".so" in base

def _is_file_to_remap(token):
    return token.startswith("/") and _is_library(token)

def _strip_comments(content):
    ret = ""
    rest = content
    in_comment = False
    for _ in range(_ITERATION_LIMIT):
        if rest == "":
            return ret

        if in_comment:
            (_comment_content, _comment_end_marker, rest) = rest.partition("*/")
            in_comment = False
        else:
            (pre_comment, _comment_start_marker, rest) = rest.partition("/*")
            ret += pre_comment
            in_comment = True

    fail("End of iterations reached without emptying the string. More than {} comments are not supported".format(_ITERATION_LIMIT))

def _tokenize(content):
    content = _strip_comments(content)
    for ch in _TOKEN_DELIMITERS:
        content = content.replace(ch, " " + ch + " ")

    # Normalize all whitespace to spaces and drop the empty fields that runs of spaces produce.
    for ws in ["\n", "\t", "\r"]:
        content = content.replace(ws, " ")
    return [token for token in content.split(" ") if token != ""]

def _files_to_remap(content):
    tokens = _tokenize(content)

    # At this point we have a flat token stream, e.g.:
    #   ["GROUP", "(", "<file>", "AS_NEEDED", "(", "<file>", ")", ")",
    #    "OUTPUT_FORMAT", "(", ..., ")"]
    files_to_remap = []
    current_commands = []  # stack of commands, from _COMMANDS

    token_idx = 0
    for _ in range(_ITERATION_LIMIT):
        if token_idx >= len(tokens):
            return files_to_remap

        token = tokens[token_idx]
        if len(current_commands) == 0 and token not in _COMMANDS:
            fail("Unrecongized token {} was not a command, while we expected it to be a command. Commands: {}".format(
                token,
                _COMMANDS.keys(),
            ))

        if token in _COMMANDS:
            current_commands.append(token)
            token_idx += 2  # Consume the command and the leading '('
        elif token == ")":
            current_commands.pop()
            token_idx += 1
        elif token == ",":
            # Ignore. Since we have tokenized, this is irrelevant.
            # TODO: Consider stripping these commans at the tokenizing stage.
            token_idx += 1
        else:
            # We are inside a command, and we need to interpret the value.
            current_command = current_commands[-1]
            if (_command_takes_a_file_list(current_command) and
                _is_file_to_remap(token)):
                files_to_remap.append(token)

            # else: Some command inputs are not files (e.g. `OUTPUT_FORMAT`).
            token_idx += 1

    fail("End of iterations reached without successfully parsing linker script. More than {} tokens are not supported".format(_ITERATION_LIMIT))

linker_script = struct(
    files_to_remap = _files_to_remap,
)
