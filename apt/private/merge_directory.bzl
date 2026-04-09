"Rule to merge multiple directory/export targets into a single unified directory structure."

load("@bazel_skylib//rules/directory:providers.bzl", "DirectoryInfo", "create_directory_info")

def _merge_directory_impl(ctx):
    # Collect all input files
    all_files = []
    for src in ctx.attr.srcs:
        all_files.extend(src[DefaultInfo].files.to_list())
    
    # Build entries map
    entries = {}
    for f in all_files:
        path = f.short_path
        if path.startswith("../"):
            second_slash = path.find("/", len("../"))
            if second_slash != -1:
                canonical_path = path[second_slash + 1:]
                entries[canonical_path] = f
    
    # Create a directory artifact
    output_dir = ctx.actions.declare_directory(ctx.label.name)
    
    # Create a manifest file
    manifest_content = "\n".join([
        "%s\t%s" % (f.path, f.short_path)
        for f in all_files
    ])
    manifest_file = ctx.actions.declare_file(ctx.label.name + ".manifest")
    ctx.actions.write(manifest_file, manifest_content)
    
    # Use Python for reliable path handling
    ctx.actions.run_shell(
        outputs = [output_dir],
        inputs = [manifest_file] + all_files,
        command = """
python3 -c '
import os
import sys

output_dir = sys.argv[1]
manifest_file = sys.argv[2]

os.makedirs(output_dir, exist_ok=True)

with open(manifest_file, "r") as f:
    for line in f:
        line = line.strip()
        if not line:
            continue
        full_path, short_path = line.split("\\t", 1)
        
        # Strip ../repo_name/ prefix from short_path
        if short_path.startswith("../"):
            second_slash = short_path.find("/", len("../"))
            if second_slash != -1:
                rel_path = short_path[second_slash + 1:]
            else:
                continue
        elif short_path.startswith("external/"):
            second_slash = short_path.find("/", len("external/"))
            if second_slash != -1:
                rel_path = short_path[second_slash + 1:]
            else:
                continue
        else:
            rel_path = short_path
        
        dest = os.path.join(output_dir, rel_path)
        dest_dir = os.path.dirname(dest)
        os.makedirs(dest_dir, exist_ok=True)
        
        # Skip if destination already exists
        if os.path.exists(dest) or os.path.islink(dest):
            continue
        
        # Check if source is a symlink
        if os.path.islink(full_path):
            link_target = os.readlink(full_path)
            
            # Resolve symlink target
            if not os.path.isabs(link_target):
                source_dir = os.path.dirname(full_path)
                resolved_target = os.path.normpath(os.path.join(source_dir, link_target))
            else:
                resolved_target = link_target
            
            # Skip dangling symlinks
            if not os.path.exists(resolved_target):
                continue
            
            try:
                os.symlink(link_target, dest)
            except OSError:
                continue
        else:
            abs_full_path = os.path.abspath(full_path)
            try:
                os.symlink(abs_full_path, dest)
            except OSError:
                continue
' {output_dir} {manifest}
""".format(output_dir=output_dir.path, manifest=manifest_file.path),
        progress_message = "Merging %d package exports into directory" % len(all_files),
    )
    
    # CRITICAL: Use output_dir.path for DirectoryInfo
    # This is the actual path in the sandbox: bazel-out/k8-opt/bin/external/.../directory
    # cc_args format mechanism will use this path for --sysroot
    directory_info = create_directory_info(
        entries = entries,
        transitive_files = depset([output_dir]),
        path = output_dir.path,  # THIS IS THE FIX!
        human_readable = str(ctx.label),
    )
    
    return [
        directory_info,
        DefaultInfo(
            files = depset([output_dir]),
            runfiles = ctx.runfiles(files = [output_dir]),
        ),
    ]

merge_directory = rule(
    implementation = _merge_directory_impl,
    attrs = {
        "srcs": attr.label_list(
            doc = "List of directory or export targets to merge",
            mandatory = True,
        ),
    },
    provides = [DirectoryInfo],
)
