const std = @import("std");
const deps = @import("./deps.zig");

const Benchmark = struct {
    name: []const u8,
    path: []const u8,
};

const BENCHMARKS = [_]Benchmark{
    .{ .name = "insert_random_check_balance", .path = "./benchmark/insert_random_check_balance.zig" },
};

const tracy_dummy = std.build.Pkg{
    .name = "tracy",
    .path = .{ .path = "src/tracy_dummy.zig" },
};

pub fn build(b: *std.build.Builder) void {
    // Standard target options allows the person running `zig build` to choose
    // what target to build for. Here we do not override the defaults, which
    // means any target is allowed, and the default is native. Other options
    // for restricting supported target set are available.
    const target = b.standardTargetOptions(.{});

    // Standard release options allow the person running `zig build` to select
    // between Debug, ReleaseSafe, ReleaseFast, and ReleaseSmall.
    const mode = b.standardReleaseOptions();

    const exe = b.addExecutable("fetch-rewards-be-coding-exercise", "src/main.zig");
    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();
    exe.addPackage(deps.pkgs.apple_pie.pkg.?);
    exe.addPackage(deps.pkgs.chrono.pkg.?);
    exe.addPackage(tracy_dummy);

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);

    const tests = b.addTest("src/main.zig");
    tests.setTarget(target);
    tests.addPackage(deps.pkgs.apple_pie.pkg.?);
    tests.addPackage(deps.pkgs.chrono.pkg.?);
    tests.addPackage(tracy_dummy);
    const test_step = b.step("test", "Run the apps tests");
    test_step.dependOn(&tests.step);

    const benchmark_target = if (!target.isGnuLibC()) target else glib_2_18_target: {
        var b_target = target;
        b_target.glibc_version = std.builtin.Version{ .major = 2, .minor = 18 };
        break :glib_2_18_target b_target;
    };
    inline for (BENCHMARKS) |benchmark| {
        const bench_exe = b.addExecutable(benchmark.name, benchmark.path);
        bench_exe.setTarget(benchmark_target);
        bench_exe.setBuildMode(mode);
        deps.addAllTo(bench_exe);
        bench_exe.addPackage(.{
            .name = "fetch-rewards-be-coding-exercise",
            .path = .{ .path = "src/main.zig" },
            .dependencies = &[_]std.build.Pkg{
                deps.pkgs.apple_pie.pkg.?,
                deps.pkgs.chrono.pkg.?,
                deps.pkgs.tracy.pkg.?,
            },
        });

        const bench_run_cmd = bench_exe.run();
        bench_run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            bench_run_cmd.addArgs(args);
        }

        const bench_run_step = b.step("run-" ++ benchmark.name, "Run the " ++ benchmark.name ++ " benchmark");
        bench_run_step.dependOn(&bench_run_cmd.step);
    }
}
