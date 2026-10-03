const std = @import("std");
const builtin = @import("builtin");
const elrond = @import("tools/elrond.zig");
const tests = @import("test/tests.zig");

const Build = std.Build;
const print = std.debug.print;

// When changing this version, be sure to also update README.md in two places:
//     1) Getting Started
//     2) Version Changes
comptime {
    const required_zig = "0.17.0";
    const current_zig = builtin.zig_version;
    const min_zig = std.SemanticVersion.parse(required_zig) catch unreachable;
    if (current_zig.order(min_zig) == .lt) {
        const error_message =
            \\Sorry, it looks like your version of zig is too old. :-(
            \\
            \\Ziglings requires Zig
            \\
            \\{s}
            \\
            \\or higher.
            \\
            \\Please download Zig from
            \\
            \\https://ziglang.org/download/
            \\
            \\
        ;
        @compileError(std.fmt.comptimePrint(error_message, .{required_zig}));
    }
}

/// Zig 0.17 removed custom build steps: the build script is a cached configure
/// phase, and only declarative steps run during the make phase. All of the
/// Ziglings logic therefore lives in the `elrond` program (tools/elrond.zig);
/// this build script only builds it and forwards the options.
pub fn build(b: *Build) !void {
    const io = b.graph.io;

    // Remove the standard install and uninstall steps.
    b.top_level_steps = .{};

    const healed = b.option(bool, "healed", "Run exercises from patches/healed") orelse
        false;
    const override_healed_path = b.option([]const u8, "healed-path", "Override healed path");
    const exno: ?usize = b.option(usize, "n", "Select exercise");
    const rand: ?bool = b.option(bool, "random", "Select random exercise");
    const start: ?usize = b.option(usize, "s", "Start at exercise");
    const reset: ?bool = b.option(bool, "reset", "Reset exercise progress");

    // `-Dreset` is a plain file delete; there is no point launching Elrond.
    if (reset) |_| {
        std.Io.Dir.cwd().deleteFile(io, ".progress.txt") catch |err| switch (err) {
            std.Io.Dir.DeleteFileError.FileNotFound => {},
            else => {
                print("Unable to remove progress file, Error: {}\n", .{err});
                return err;
            },
        };

        print("Progress reset, .progress.txt removed.\n", .{});
        b.default_step = b.step("ziglings", "Reset progress");
        return;
    }

    const sep = std.fs.path.sep_str;
    const healed_path = if (override_healed_path) |path|
        path
    else
        "patches" ++ sep ++ "healed";
    const work_path = if (healed) healed_path else "exercises";

    const run_program = b.addExecutable(.{
        .name = "elrond",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/elrond.zig"),
            .target = b.graph.host,
        }),
    });

    const run = b.addRunArtifact(run_program);
    run.setCwd(b.path("."));
    run.addArg(b.fmt("--zig={s}", .{b.graph.zig_exe}));
    run.addArg(b.fmt("--work-path={s}", .{work_path}));
    run.addArg(b.fmt("--root-path={s}", .{b.root.root_dir.path.?}));

    // Healed runs are corpus checks; keep them from clobbering the learner's
    // progress file.
    if (healed) run.addArg("--no-progress-write");

    if (exno) |n| {
        run.addArg(b.fmt("--only={d}", .{n}));
    } else if (rand) |_| {
        run.addArg("--random");
    } else if (start) |s| {
        run.addArg(b.fmt("--start={d}", .{s}));
    }

    const ziglings_step = b.step("ziglings", "Check all ziglings");
    ziglings_step.dependOn(&run.step);
    b.default_step = ziglings_step;

    const test_step = b.step("test", "Run all the tests");
    test_step.dependOn(tests.addCliTests(b, &elrond.exercises));
}
