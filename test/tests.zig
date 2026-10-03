//!
//! Command line interface tests for Ziglings.
//!
//! Zig 0.17 removed custom build steps, so these tests are expressed with
//! declarative `Run` steps. Two corpora are prepared in temporary directories:
//!
//!   * "broken": the original exercises as they were introduced, taken from
//!     git history.
//!   * "healed": the broken exercises with their patches applied.
//!
//! The `elrond` program is then launched directly to check every healed
//! exercise, the whole healed corpus, and every hint of the broken corpus.
//!
const std = @import("std");
const elrond = @import("../tools/elrond.zig");

const Build = std.Build;
const Step = Build.Step;
const Exercise = elrond.Exercise;

/// Prepares the broken and healed corpora. The first argument is the directory
/// for the original (broken) exercises, the second for the healed ones.
const prepare_script =
    \\set -e
    \\broken_dir="$1"
    \\healed_dir="$2"
    \\mkdir -p "$broken_dir" "$healed_dir"
    \\rm -f .zig-cache/test-progress.txt .zig-cache/test-progress-all.txt .zig-cache/test-progress-hints.txt
    \\for src in exercises/*.zig; do
    \\    name=$(basename "$src" .zig)
    \\    commit=$(git log --diff-filter=A --format=%H -1 -- "$src")
    \\    git show "$commit:$src" > "$broken_dir/$name.zig"
    \\    cp "$broken_dir/$name.zig" "$healed_dir/$name.zig"
    \\    if [ -f "patches/patches/$name.patch" ]; then
    \\        patch -s --no-backup-if-mismatch -N -r - -i "patches/patches/$name.patch" "$healed_dir/$name.zig" || true
    \\    fi
    \\done
;

pub fn addCliTests(b: *Build, exercises: []const Exercise) *Step {
    const step = b.step("test-cli", "Test the command line interface");

    const broken_dir = b.tmpPath();
    const healed_dir = b.tmpPath();

    const prepare = b.addSystemCommand(&.{ "sh", "-c", prepare_script, "prepare" });
    prepare.setCwd(b.path("."));
    prepare.addDirectoryArg(broken_dir);
    prepare.addDirectoryArg(healed_dir);
    prepare.expectExitCode(0);

    const elrond_exe = b.addExecutable(.{
        .name = "elrond",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/elrond.zig"),
            .target = b.graph.host,
        }),
    });

    // case-1: every healed exercise passes on its own, as `zig build -Dhealed
    // -Dn=n` would run it.
    for (exercises[0 .. exercises.len - 1]) |ex| {
        const n = ex.number();

        const run = addHealedRun(b, elrond_exe, healed_dir, ".zig-cache/test-progress.txt");
        run.setName(b.fmt("check -Dn={}", .{n}));
        run.addArg(b.fmt("--only={d}", .{n}));
        run.expectExitCode(0);
        run.expectStdErrMatch(if (ex.skip) "Skipping" else "PASSED");
        run.step.dependOn(&prepare.step);
        step.dependOn(&run.step);
    }

    // case-2: the whole healed corpus passes in order.
    {
        const run = addHealedRun(b, elrond_exe, healed_dir, ".zig-cache/test-progress-all.txt");
        run.setName("check all healed");
        run.expectExitCode(0);
        run.step.dependOn(&prepare.step);
        step.dependOn(&run.step);
    }

    // case-3: an unsolved exercise reports its hint and exits with code 2, as
    // `zig build -Dn=n` would.
    for (exercises[0 .. exercises.len - 1]) |ex| {
        if (ex.skip) continue;

        if (ex.hint) |hint| {
            const n = ex.number();

            const run = addBrokenRun(b, elrond_exe, broken_dir);
            run.setName(b.fmt("hint -Dn={}", .{n}));
            run.addArg(b.fmt("--only={d}", .{n}));
            run.expectExitCode(2);
            run.expectStdErrMatch(hint);
            run.step.dependOn(&prepare.step);
            step.dependOn(&run.step);
        }
    }

    // case-4: `build.zig` forwards its options to the program. The progress
    // file is redirected so the tests cannot clobber `.progress.txt`.
    {
        const run = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "-Dn=1" });
        run.setName("zig build -Dn=1");
        run.setCwd(b.path("."));
        run.setEnvironmentVariable("ZIGLINGS_PROGRESS_FILE", ".zig-cache/test-progress.txt");
        run.expectExitCode(0);
        run.expectStdErrMatch("PASSED");
        run.step.dependOn(&prepare.step);
        step.dependOn(&run.step);
    }
    {
        const run = b.addSystemCommand(&.{
            b.graph.zig_exe,
            "build",
            "-Dhealed",
            "-Dn=2",
        });
        run.setName("zig build -Dhealed -Dn=2");
        run.setCwd(b.path("."));
        run.addPrefixedDirectoryArg("-Dhealed-path=", healed_dir);
        run.setEnvironmentVariable("ZIGLINGS_PROGRESS_FILE", ".zig-cache/test-progress.txt");
        run.expectExitCode(0);
        run.expectStdErrMatch("PASSED");
        run.step.dependOn(&prepare.step);
        step.dependOn(&run.step);
    }

    return step;
}

/// Runs an exercise from a prepared corpus.
fn addCorpusRun(
    b: *Build,
    elrond_exe: *Step.Compile,
    corpus_dir: Build.LazyPath,
    progress_name: []const u8,
) *Step.Run {
    const run = b.addRunArtifact(elrond_exe);
    run.setCwd(b.path("."));
    run.addArg(b.fmt("--zig={s}", .{b.graph.zig_exe}));
    run.addArg(b.fmt("--root-path={s}", .{b.root.root_dir.path.?}));
    run.addPrefixedDirectoryArg("--work-path=", corpus_dir);
    run.addArg(b.fmt("--progress-path={s}", .{progress_name}));
    return run;
}

fn addHealedRun(
    b: *Build,
    elrond_exe: *Step.Compile,
    healed_dir: Build.LazyPath,
    progress_name: []const u8,
) *Step.Run {
    return addCorpusRun(b, elrond_exe, healed_dir, progress_name);
}

fn addBrokenRun(b: *Build, elrond_exe: *Step.Compile, broken_dir: Build.LazyPath) *Step.Run {
    return addCorpusRun(b, elrond_exe, broken_dir, ".zig-cache/test-progress-hints.txt");
}
