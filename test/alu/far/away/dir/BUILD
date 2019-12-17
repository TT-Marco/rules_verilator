load("@rules_verilator//verilator:defs.bzl", "sv_library", "verilator_cc_library")

sv_library(
    name = "alu_lib",
    srcs = ["alu.sv"],
)

verilator_cc_library(
    name = "alu",
    mtop = "alu",
    hdrs = ["//:includes"],#"alu.sv", "alu2.sv"], 
    srcs = ["//:srcs" ],
    trace = True,
    includes = ["includes"],
    cpp_defines=["DVL_THREADED"],
    cflags=[ "-std=c++11", "-fPIC"]
    #deps = [":alu_lib"],
)

cc_binary(
    name = "alu_bin",
    srcs = ["alu.cpp"],
    deps = [":alu"],
)
