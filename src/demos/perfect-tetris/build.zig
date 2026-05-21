const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});

    const perfect_tetris = b.dependency("perfect_tetris", .{}).module("perfect-tetris");

    const exe = b.addExecutable(.{
        .name = "perfect-tetris-demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding }),
            .optimize = optimize,
        }),
    });
    exe.entry = .disabled;
    exe.rdynamic = true;

    exe.root_module.addImport("perfect-tetris", perfect_tetris);
    exe.root_module.addImport("engine", perfect_tetris.import_table.get("engine").?);

    const install = b.addInstallArtifact(exe, .{});
    b.getInstallStep().dependOn(&install.step);
}
