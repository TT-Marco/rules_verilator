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
    includes = ["includes"],
    #deps = [":alu_lib"],
)

cc_binary(
    name = "alu_bin",
    srcs = ["alu.cpp"],
    deps = [":alu"],
)
