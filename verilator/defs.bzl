load(
    "@rules_verilator//verilator/internal:cc_actions.bzl",
    "cc_compile_and_link_static_library",
)
load(
    "@rules_verilator//verilator/internal:toolchain.bzl",
    _TOOLCHAIN_TYPE = "TOOLCHAIN_TYPE",
)

# Provider for verilog libraries
VerilogInfo = provider(fields = ["transitive_sources"])

def get_transitive_sources(srcs, deps):
    """Obtain the underlying source files for a target and it's transitive
    dependencies.

    Args:
      srcs: a list of source files
      deps: a list of targets that are the direct dependencies
    Returns:
      a collection of the transitive sources
    """
    return depset(
        direct = srcs,
        transitive = [dep[VerilogInfo].transitive_sources for dep in deps],
    )

def _sv_library(ctx):
    transitive_sources = get_transitive_sources(ctx.files.srcs, ctx.attr.deps)
    return [VerilogInfo(transitive_sources = transitive_sources)]

sv_library = rule(
    attrs = {
        "srcs": attr.label_list(
            allow_files = [".v", ".sv"],
        ),
        "deps": attr.label_list(providers = [VerilogInfo]),
    },
    implementation = _sv_library,
)

_CPP_SRC = ["cc", "cpp", "cxx", "c++"]
_HPP_SRC = ["h", "hh", "hpp"]

def _only_cpp_slow(f):
    """Filter out slow files"""
    if "Slow" in f.path or f.extension in _HPP_SRC:
        return f.path
    return None

def _only_cpp(f):
    """Filter for just non-slow C++ source/headers"""
    if f.extension in _CPP_SRC + _HPP_SRC and "Slow" not in f.path:
        return f.path
    return None

def _only_hpp(f):
    """Filter for just C++ headers"""
    if f.extension in _HPP_SRC:
        return f.path
    return None

_COPY_TREE_SH = """
OUT=$1; shift && mkdir -p "$OUT" && cp $* "$OUT"
"""

def _copy_tree(ctx, idir, odir, map_each = None, progress_message = None):
    """Copy files from a TreeArtifact to a new directory"""
    args = ctx.actions.args()
    args.add(odir.path)
    args.add_all([idir], map_each = map_each)
    ctx.actions.run_shell(
        arguments = [args],
        command = _COPY_TREE_SH,
        inputs = [idir],
        outputs = [odir],
        execution_requirements = {
            "no-remote": "1",
        },
        progress_message = progress_message,
    )

    return odir

def _verilator_cc_library(ctx):
    """Produce a static library and C++ header files from a Verilog library"""

    # Get the verilator toolchain
    verilator_toolchain = ctx.toolchains[_TOOLCHAIN_TYPE].verilator_toolchain

    # Gather all the Verilog source files, including transitive dependencies
    inputs = get_transitive_sources(
        ctx.files.hdrs + ctx.files.srcs,
        ctx.attr.deps,
    )
    srcs = get_transitive_sources(
        ctx.files.srcs,
        ctx.attr.deps,
    )

    # Default Verilator output prefix (e.g. "Vtop")
    mtop = ctx.label.name if ctx.attr.mtop == None else ctx.attr.mtop

    cflags = ctx.attr.cflags
    ldflags = ctx.attr.ldflags

    if ctx.attr.prefix != "V":
        prefix = ctx.attr.prefix
    else:
        prefix = ctx.attr.prefix + ctx.attr.mtop

    # Output directories/files
    verilator_output = ctx.actions.declare_directory(prefix + "-gen")
    verilator_output_cpp = ctx.actions.declare_directory(prefix + ".cpp")
    verilator_output_slow = ctx.actions.declare_directory(prefix + "__Slow.cpp")
    verilator_output_hpp = ctx.actions.declare_directory(prefix + ".h")

    # Run Verilator
    args = ctx.actions.args()
    if ctx.attr.sysc:
        args.add("--sc")
    else:
        args.add("--cc")
    args.add("--Mdir", verilator_output.path)
    args.add("--prefix", prefix)
    args.add("--top-module", mtop)
    if ctx.attr.includes:
        args.add("-I" + " -I".join(ctx.attr.includes))
    if ctx.attr.trace:
        args.add("--trace")
    if ctx.attr.cflags:
        args.add_all(cflags, before_each = "-CFLAGS")
    if ctx.attr.ldflags:
        args.add_all(ldflags, before_each = "-LDFLAGS")
    args.add_all(srcs)
    args.add_all(ctx.attr.vopts, expand_directories = False)
    if ctx.attr.prebuilt_verilator:
        ctx.actions.run_shell(
          arguments = [args],
          command = verilator_toolchain.verilator_executable.path + " $*",
          inputs = inputs,
          outputs = [verilator_output],
          progress_message = "[Verilator] Compiling {}".format(ctx.label),
          execution_requirements = {
              "no-sandbox": "1",
          },

        ) 
    else:
        ctx.actions.run(
          arguments = [args],
          executable = verilator_toolchain.verilator_executable,
          inputs = inputs,
          unused_inputs_list = verilator_toolchain.verilator_executable,
          outputs = [verilator_output],
          progress_message = "[Verilator] Compiling {}".format(ctx.label),
        )

    # Extract out just C++ files
    # Work around for https://github.com/bazelbuild/bazel/pull/8269
    _copy_tree(
        ctx,
        verilator_output,
        verilator_output_slow,
        map_each = _only_cpp_slow,
        progress_message = "[Verilator] Extracting Slow C++ source files",
    )

    _copy_tree(
        ctx,
        verilator_output,
        verilator_output_cpp,
        map_each = _only_cpp,
        progress_message = "[Verilator] Extracting C++ source files",
    )

    _copy_tree(
        ctx,
        verilator_output,
        verilator_output_hpp,
        map_each = _only_hpp,
        progress_message = "[Verilator] Extracting C++ header files",
    )

    # Collect the verilator ouput and, if needed, generate a driver program
    srcs = [verilator_output_cpp]
    hdrs = [verilator_output_hpp]

    # Do actual compile
    defines = ["VM_TRACE"] if ctx.attr.trace else []
    fast_opt = ctx.attr.fast_copts if ctx.attr.fast_copts else []
    slow_opt = ctx.attr.slow_copts if ctx.attr.slow_copts else []
    deps = list(verilator_toolchain.libs)
    if ctx.attr.ccdeps:
        deps = deps + ctx.attr.ccdeps
    if ctx.attr.cpp_defines:
        defines = defines + ctx.attr.cpp_defines

    #if ctx.attr.sysc:
    #    deps.append(ctx.attr._systemc)

    return cc_compile_and_link_static_library(
        ctx,
        srcs = srcs,
        slow_srcs = [verilator_output_slow],
        hdrs = hdrs,
        defines = defines,
        deps = deps,
        cflags = cflags,
        ldflags = ldflags,
        fast_opt = fast_opt,
        slow_opt = slow_opt,
    )

verilator_cc_library = rule(
    _verilator_cc_library,
    output_to_genfiles = True,
    attrs = {
        "srcs": attr.label_list(
            doc = "List of verilog source files",
            mandatory = False,
            allow_files = [".v", ".sv"],
        ),
        "hdrs": attr.label_list(
            doc = "List of verilog header files",
            allow_files = [".v", ".sv", ".vh", ".svh", ".h"],
        ),
        "deps": attr.label_list(
            doc = "List of verilog dependencies",
        ),
        "ccdeps": attr.label_list(
            doc = "List of C++ dependencies",
        ),
        "mtop": attr.string(
            doc = "Top level module. Defaults to the rule name if not specified",
            mandatory = False,
        ),
        "includes": attr.string_list(
            doc = "Include paths for verilator",
            mandatory = False,
        ),
        "trace": attr.bool(
            doc = "Enable tracing for Verilator",
            default = False,
        ),
        "prefix": attr.string(
            doc = "Prefix for generated C++ headers and classes",
            default = "V",
        ),
        "cflags": attr.string_list(
            doc = "C flags for the compiled verilated library",
            mandatory = False,
        ),
        "ldflags": attr.string_list(
            doc = "LD flags for the compiled verilated library",
            mandatory = False,
        ),
        "cpp_defines": attr.string_list(
            doc = "Defines to be passed to verilator output",
            mandatory = False,
        ),
        "fast_copts": attr.string_list(
            doc = "compiler flags for fast verilator output",
            mandatory = False,
        ),
        "slow_copts": attr.string_list(
            doc = "compiler flags for slow verilator output",
            mandatory = False,
        ),
        "sysc": attr.bool(
            doc = "Generate SystemC using the --sc Verilator option",
            default = False,
        ),
        "vopts": attr.string_list(
            doc = "Additional command line options to pass to Verilator",
            default = ["-Wall"],
        ),
        "prebuilt_verilator" : attr.bool(
            doc = "Removes dependency on verilator executable -- use for remote caching",
            default = True, #TODO: if merged into original verilator rules, set to false
        ),
        "_cc_toolchain": attr.label(
            default = Label("@bazel_tools//tools/cpp:current_cc_toolchain"),
        ),
    },
    provides = [
        CcInfo,
        DefaultInfo,
    ],
    toolchains = [
        "@bazel_tools//tools/cpp:toolchain_type",
        "@rules_verilator//verilator:toolchain_type",
    ],
    fragments = ["cpp"],
)
