//
// Elrond owns the Ziglings logic: the exercise list, the .progress.txt file and
// the compile/run/output-check loop.
//
// Zig 0.17 split the build system into a cached configure phase and a make
// phase, and removed custom build steps (the `makeFn` mechanism that Ziglings
// used to implement `ZiglingStep` and friends). build.zig therefore only builds
// this program and forwards the chosen options as command line flags.
//
const std = @import("std");
const builtin = @import("builtin");

const Io = std.Io;
const File = Io.File;
const Process = std.process;
const print = std.debug.print;
const cutPrefix = std.mem.cutPrefix;

const progress_filename = ".progress.txt";

const Kind = enum {
    /// Run the artifact as a normal executable.
    exe,
    /// Run the artifact as a test.
    @"test",
};

pub const Exercise = struct {
    /// main_file must have the format key_name.zig.
    /// The key will be used as a shorthand to build just one example.
    main_file: []const u8,

    /// This is the desired output of the program.
    /// A program passes if its output, excluding trailing whitespace, is equal
    /// to this string.
    output: []const u8,

    /// This is an optional hint to give if the program does not succeed.
    hint: ?[]const u8 = null,

    /// By default, we verify output against stderr.
    /// Set this to true to check stdout instead.
    check_stdout: bool = false,

    /// This exercise makes use of C functions.
    /// We need to keep track of this, so we compile with libc.
    link_libc: bool = false,

    /// This exercise kind.
    kind: Kind = .exe,

    /// This exercise is not supported by the current Zig compiler.
    skip: bool = false,

    /// Hint to the user, why this has been skipped
    skip_hint: ?[]const u8 = null,

    timestamp: bool = false,

    /// Returns the name of the main file with .zig stripped.
    pub fn name(self: Exercise) []const u8 {
        return std.fs.path.stem(self.main_file);
    }

    /// Returns the key of the main file, the string before the '_' with
    /// "zero padding" removed.
    /// For example, "001_hello.zig" has the key "1".
    pub fn key(self: Exercise) []const u8 {
        // Main file must be key_description.zig.
        const end_index = std.mem.indexOfScalar(u8, self.main_file, '_') orelse
            unreachable;

        // Remove zero padding by advancing index past '0's.
        var start_index: usize = 0;
        while (self.main_file[start_index] == '0') start_index += 1;
        return self.main_file[start_index..end_index];
    }

    /// Returns the exercise key as an integer.
    pub fn number(self: Exercise) usize {
        return std.fmt.parseInt(usize, self.key(), 10) catch unreachable;
    }
};

/// Build mode.
const Mode = enum {
    /// Normal build mode: `zig build`
    normal,
    /// Named build mode: `zig build -Dn=n`
    named,
    /// Random build mode: `zig build -Drandom`
    random,
    /// Start build mode: `zig build -Ds=n`
    start,
};

const Context = struct {
    io: Io,
    arena: std.mem.Allocator,
    zig_exe: []const u8,
    work_path: []const u8,
    root_path: []const u8,
    progress_path: []const u8,
    /// Healed runs are corpus checks: they must not clobber the learner's
    /// progress file.
    write_progress: bool = true,
};

const Error = error{Failed};

const logo =
    \\                                            
    \\ 7MM"""YMM' 7MMF'   `7MF  .g8"""bg   7MMF' `YMM'   OO 
    \\  MM    `7   MM       M .dP'     `M   MM   .M'     88 
    \\  MM   d     MM       M dM'       `   MM .d"       88 
    \\  MM""MM     MM       M MM            MMMMM.       OO 
    \\  MM   Y     MM       M MM.           MM  VMA         
    \\  MM         YM.     ,M `Mb.     ,'   MM   `MM.    bd
    \\.JMML.        `bmmmmd"'   `"bmmmd'  .JMML.   MMb.  db 
    \\
    \\        "Look out! Broken programs below!"
    \\
;

var use_color_escapes = false;
var red_text: []const u8 = "";
var red_bold_text: []const u8 = "";
var red_dim_text: []const u8 = "";
var green_text: []const u8 = "";
var bold_text: []const u8 = "";
var reset_text: []const u8 = "";

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    var args_it = try init.minimal.args.iterateAllocator(arena);
    if (!args_it.skip()) @panic("expected self arg");

    const stderr = File.stderr();
    if (try stderr.supportsAnsiEscapeCodes(io)) {
        use_color_escapes = true;
    } else if (builtin.os.tag == .windows) {
        if (stderr.enableAnsiEscapeCodes(io)) {
            use_color_escapes = true;
        } else |_| {}
    }

    if (use_color_escapes) {
        red_text = "\x1b[31m";
        red_bold_text = "\x1b[31;1m";
        red_dim_text = "\x1b[31;2m";
        green_text = "\x1b[32m";
        bold_text = "\x1b[1m";
        reset_text = "\x1b[0m";
    }

    if (!validateExercises()) std.process.exit(2);

    var zig_exe: []const u8 = "zig";
    var work_path: []const u8 = "exercises";
    var root_path: []const u8 = ".";
    var mode: Mode = .normal;
    var only_n: ?usize = null;
    var start_n: ?usize = null;
    var progress_path: []const u8 = init.minimal.environ.getAlloc(arena, "ZIGLINGS_PROGRESS_FILE") catch null orelse progress_filename;
    var write_progress = true;

    while (args_it.next()) |arg| {
        if (cutPrefix(u8, arg, "--zig=")) |v| {
            zig_exe = v;
        } else if (cutPrefix(u8, arg, "--work-path=")) |v| {
            work_path = v;
        } else if (cutPrefix(u8, arg, "--root-path=")) |v| {
            root_path = v;
        } else if (cutPrefix(u8, arg, "--progress-path=")) |v| {
            progress_path = v;
        } else if (cutPrefix(u8, arg, "--only=")) |v| {
            only_n = std.fmt.parseInt(usize, v, 10) catch {
                print("invalid --only value: {s}\n", .{v});
                std.process.exit(2);
            };
            mode = .named;
        } else if (cutPrefix(u8, arg, "--start=")) |v| {
            start_n = std.fmt.parseInt(usize, v, 10) catch {
                print("invalid --start value: {s}\n", .{v});
                std.process.exit(2);
            };
            mode = .start;
        } else if (std.mem.eql(u8, arg, "--random")) {
            mode = .random;
        } else if (std.mem.eql(u8, arg, "--no-progress-write")) {
            write_progress = false;
        } else {
            print("unknown argument: {s}\n", .{arg});
            std.process.exit(2);
        }
    }

    print("{s}", .{logo});

    const ctx: Context = .{
        .io = io,
        .arena = arena,
        .zig_exe = zig_exe,
        .work_path = work_path,
        .root_path = root_path,
        .progress_path = progress_path,
        .write_progress = write_progress,
    };

    switch (mode) {
        .named => {
            const n = only_n.?;
            if (n == 0 or n > exercises.len - 1) {
                print("unknown exercise number: {}\n", .{n});
                std.process.exit(2);
            }
            runOne(ctx, exercises[n - 1], .named) catch std.process.exit(2);
        },
        .random => {
            var prng = std.Random.DefaultPrng.init(blk: {
                var seed: u64 = undefined;
                io.random(std.mem.asBytes(&seed));
                break :blk seed;
            });
            const rnd = prng.random();
            const num = rnd.intRangeLessThan(usize, 0, exercises.len);
            const ex = exercises[num];

            print("random exercise: {s}\n", .{ex.main_file});
            runOne(ctx, ex, .random) catch std.process.exit(2);
        },
        .start => {
            const s = start_n.?;
            if (s == 0 or s > exercises.len - 1) {
                print("unknown exercise number: {}\n", .{s});
                std.process.exit(2);
            }
            iterateFrom(ctx, s - 1) catch std.process.exit(2);
        },
        .normal => {
            // Healed runs are full corpus checks, so they start at the first
            // exercise instead of resuming from .progress.txt.
            const starting_exercise = if (write_progress)
                try readProgress(io, arena, progress_path)
            else
                0;
            var start_index: usize = 0;
            for (exercises, 0..) |ex, idx| {
                if (starting_exercise < ex.number()) {
                    start_index = idx;
                    break;
                }
            } else {
                print("{s}All exercises completed!{s}\n", .{ green_text, reset_text });
                return;
            }
            iterateFrom(ctx, start_index) catch std.process.exit(2);
        },
    }
}

/// Iterates exercises from `start_index` to the end, stopping at the first
/// failure.
fn iterateFrom(ctx: Context, start_index: usize) Error!void {
    for (exercises[start_index..]) |ex| {
        try runOne(ctx, ex, .normal);
    }
}

fn runOne(ctx: Context, ex: Exercise, mode: Mode) Error!void {
    if (ex.skip) {
        print("Skipping {s}", .{ex.main_file});

        if (ex.skip_hint) |hint|
            print("\n{s}Reason: {s}{s}\n", .{ bold_text, hint, reset_text });

        print("\n\n", .{});
        return;
    }

    printProgress(ex.number(), exercises.len - 1);

    switch (ex.kind) {
        .exe => runExe(ctx, ex) catch {
            hintAndHelp(ctx, ex, mode);
            return Error.Failed;
        },
        .@"test" => runTest(ctx, ex) catch {
            hintAndHelp(ctx, ex, mode);
            return Error.Failed;
        },
    }

    if (ctx.write_progress) writeProgress(ctx.io, ctx.progress_path, ex.number()) catch {};
}

fn hintAndHelp(ctx: Context, ex: Exercise, mode: Mode) void {
    if (ex.hint) |hint|
        print("\n{s}Ziglings hint: {s}{s}", .{ bold_text, hint, reset_text });

    help(ctx, ex, mode);
}

fn printProgress(num: usize, max: usize) void {
    const bar_width: u32 = 60;

    const filled_len_u64 = (@as(u64, num) * bar_width) / max;
    const filled_len = @as(u32, @intCast(filled_len_u64));

    var bar_buf: [bar_width]u8 = undefined;

    for (0..bar_width) |n| {
        const ord = std.math.order(n, filled_len);
        bar_buf[n] = switch (ord) {
            .lt => '#',
            .eq => '>',
            .gt => '-',
        };
    }

    print("\rProgress: [{s}]  {d}/{d}\n\n", .{ &bar_buf, num, max });
}

fn runExe(ctx: Context, ex: Exercise) !void {
    print("Compiling {s}...\n", .{ex.main_file});

    const path = try exercisePath(ctx, ex);

    var argv = std.ArrayList([]const u8).initCapacity(ctx.arena, 8) catch @panic("OOM");
    argv.append(ctx.arena, ctx.zig_exe) catch @panic("OOM");
    argv.append(ctx.arena, "run") catch @panic("OOM");

    if (ex.link_libc) {
        argv.append(ctx.arena, "-lc") catch @panic("OOM");
        argv.append(ctx.arena, "-fllvm") catch @panic("OOM");
    }

    argv.append(ctx.arena, path) catch @panic("OOM");

    const result = Process.run(ctx.arena, ctx.io, .{
        .argv = argv.items,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch |err| {
        return fail(ctx, ex, "unable to spawn {s}: {s}", .{ ctx.zig_exe, @errorName(err) });
    };

    print("Checking {s}...\n", .{ex.main_file});

    return checkOutput(ctx, ex, result);
}

fn runTest(ctx: Context, ex: Exercise) !void {
    print("Compiling {s}...\n", .{ex.main_file});

    const path = try exercisePath(ctx, ex);

    var argv = std.ArrayList([]const u8).initCapacity(ctx.arena, 8) catch @panic("OOM");
    argv.append(ctx.arena, ctx.zig_exe) catch @panic("OOM");
    argv.append(ctx.arena, "test") catch @panic("OOM");

    if (ex.link_libc) {
        argv.append(ctx.arena, "-lc") catch @panic("OOM");
        argv.append(ctx.arena, "-fllvm") catch @panic("OOM");
    }

    argv.append(ctx.arena, path) catch @panic("OOM");

    const result = Process.run(ctx.arena, ctx.io, .{
        .argv = argv.items,
        .stdout_limit = .limited(1024 * 1024),
        .stderr_limit = .limited(1024 * 1024),
    }) catch |err| {
        return fail(ctx, ex, "unable to spawn {s}: {s}", .{ ctx.zig_exe, @errorName(err) });
    };

    print("Checking {s}...\n", .{ex.main_file});

    return checkTest(ctx, ex, result);
}

fn checkOutput(ctx: Context, ex: Exercise, result: Process.RunResult) !void {
    // Make sure it exited cleanly.
    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                // Compile errors and runtime panics are both reported on
                // stderr by `zig run`.
                const diag = std.mem.trimEnd(u8, result.stderr, " \r\n");
                if (diag.len > 0) print("{s}\n", .{diag});
                return Error.Failed;
            }
        },
        else => {
            return fail(ctx, ex, "{s} terminated unexpectedly", .{ex.main_file});
        },
    }

    const raw_output = if (ex.check_stdout)
        result.stdout
    else
        result.stderr;

    // NOTE: exercise.output can never contain a CR character.
    // See https://ziglang.org/documentation/master/#Source-Encoding.
    const output = trimLines(ctx.arena, raw_output) catch @panic("OOM");

    // Validate the output.
    var exercise_output = ex.output;

    // Insert timestamp for exercise 85
    if (ex.timestamp) {
        // Compare timestamp from exercise with now, diff < 5 seconds is valid
        var ts_buf: [20]u8 = undefined;
        const ts_slice = output[14..24];
        const ts_value = try std.fmt.parseInt(i64, ts_slice, 10);
        const ts_build = Io.Timestamp.now(ctx.io, .real).toSeconds();
        const ts_diff = @abs(ts_build - ts_value);
        const timestamp = std.fmt.bufPrint(&ts_buf, "{}", .{if (ts_diff < 5) ts_value else ts_build}) catch unreachable;

        // Insert timestamp into check string
        var buf: [100]u8 = undefined;
        const prefix_len = 14;
        const placeholder_len = 11;

        @memcpy(buf[0..prefix_len], exercise_output[0..prefix_len]);
        @memcpy(buf[prefix_len..][0..timestamp.len], timestamp);
        const suffix = exercise_output[prefix_len + placeholder_len ..];
        const suffix_dest_start = prefix_len + timestamp.len;
        @memcpy(buf[suffix_dest_start..][0..suffix.len], suffix);

        const total_len = prefix_len + timestamp.len + suffix.len;
        exercise_output = buf[0..total_len];
    }

    if (!std.mem.eql(u8, output, exercise_output)) {
        const red = red_bold_text;
        const reset = reset_text;

        print(
            \\
            \\{s}========= expected this output: =========={s}
            \\{s}
            \\{s}========= but found: ====================={s}
            \\{s}
            \\{s}=========================================={s}
        ++ "\n", .{ red, reset, exercise_output, red, reset, output, red, reset });
        return Error.Failed;
    }

    print("{s}PASSED:\n{s}{s}\n\n", .{ green_text, output, reset_text });
}

fn checkTest(ctx: Context, ex: Exercise, result: Process.RunResult) !void {
    switch (result.term) {
        .exited => |code| {
            if (code != 0) {
                // The test failed.
                const stderr = std.mem.trimEnd(u8, result.stderr, " \r\n");
                if (stderr.len > 0) print("\n{s}\n", .{stderr});
                return Error.Failed;
            }
        },
        else => {
            return fail(ctx, ex, "{s} terminated unexpectedly", .{ex.main_file});
        },
    }

    print("{s}PASSED{s}\n\n", .{ green_text, reset_text });
}

fn help(ctx: Context, ex: Exercise, mode: Mode) void {
    const key = ex.key();
    const path = ex.main_file;

    const cmd = switch (mode) {
        .normal, .start => "zig build",
        .named => std.fmt.allocPrint(ctx.arena, "zig build -Dn={s}", .{key}) catch @panic("OOM"),
        .random => "zig build -Drandom",
    };

    print("\n{s}Edit exercises/{s} and run '{s}' again.{s}\n", .{
        red_bold_text, path, cmd, reset_text,
    });
}

/// Prints an error message for the step.
fn fail(ctx: Context, ex: Exercise, comptime format: []const u8, args: anytype) Error {
    print("{s}error: {s}", .{ red_bold_text, red_dim_text });
    print(format, args);
    print("{s}\n", .{reset_text});
    _ = ex;
    _ = ctx;
    return Error.Failed;
}

fn exercisePath(ctx: Context, ex: Exercise) ![]const u8 {
    if (std.fs.path.isAbsolute(ctx.work_path))
        return std.fs.path.join(ctx.arena, &.{ ctx.work_path, ex.main_file });
    return std.fs.path.join(ctx.arena, &.{ ctx.root_path, ctx.work_path, ex.main_file });
}

/// Removes trailing whitespace for each line in buf, also ensuring that there
/// are no trailing LF characters at the end.
fn trimLines(gpa: std.mem.Allocator, buf: []const u8) ![]const u8 {
    var list = try std.ArrayList(u8).initCapacity(gpa, buf.len);
    errdefer list.deinit(gpa);

    var iter = std.mem.splitSequence(u8, buf, " \n");
    while (iter.next()) |line| {
        // TODO: trimming CR characters is probably not necessary.
        const data = std.mem.trimEnd(u8, line, " \r");
        try list.appendSlice(gpa, data);
        try list.append(gpa, '\n');
    }

    // Calls deinit()
    const result = try list.toOwnedSlice(gpa);

    // Remove the trailing LF character, that is always present in the exercise output.
    return std.mem.trimEnd(u8, result, "\n");
}

/// Checks that each exercise number, excluding the last, forms the sequence
/// `[1, exercise.len)`.
///
/// Additionally check that the output field lines doesn't have trailing whitespace.
fn validateExercises() bool {
    // Don't use the "multi-object for loop" syntax, in order to avoid a syntax
    // error with old Zig compilers.
    var i: usize = 0;
    for (exercises[0..]) |ex| {
        const exno = ex.number();
        const last = 999;
        i += 1;

        if (exno != i and exno != last) {
            print("exercise {s} has an incorrect number: expected {}, got {s}\n", .{
                ex.main_file, i, ex.key(),
            });

            return false;
        }

        var iter = std.mem.splitScalar(u8, ex.output, '\n');
        while (iter.next()) |line| {
            const output = std.mem.trimEnd(u8, line, " \r");
            if (output.len != line.len) {
                print("exercise {s} output field lines have trailing whitespace\n", .{
                    ex.main_file,
                });

                return false;
            }
        }

        if (!std.mem.endsWith(u8, ex.main_file, ".zig")) {
            print("exercise {s} is not a zig source file\n", .{ex.main_file});

            return false;
        }
    }

    return true;
}

/// Reads the last solved exercise number from the progress file; 0 if absent.
fn readProgress(io: Io, arena: std.mem.Allocator, progress_path: []const u8) !u32 {
    const file = std.Io.Dir.cwd().openFile(io, progress_path, .{}) catch |err| switch (err) {
        Io.File.OpenError.FileNotFound => return 0,
        else => {
            print("Unable to open {s}: {}\n", .{ progress_path, err });
            return err;
        },
    };
    defer file.close(io);

    const size = try file.length(io);
    if (size == 0) return 0;

    const contents = try arena.alloc(u8, size);
    var file_buffer: [1024]u8 = undefined;
    var file_reader = file.reader(io, &file_buffer);
    const bytes_read = try file_reader.interface.readSliceShort(contents);
    if (bytes_read != size) return error.UnexpectedEOF;

    const trimmed_contents = std.mem.trim(u8, contents, "\r\n");
    return std.fmt.parseInt(u32, trimmed_contents, 10) catch 0;
}

fn writeProgress(io: Io, progress_path: []const u8, number: usize) !void {
    const progress = try std.fmt.allocPrint(std.heap.page_allocator, "{d}", .{number});
    defer std.heap.page_allocator.free(progress);

    const file = try std.Io.Dir.cwd().createFile(
        io,
        progress_path,
        .{ .read = true, .truncate = true },
    );
    defer file.close(io);

    try file.writeStreamingAll(io, progress);
    try file.sync(io);
}

pub const exercises = [_]Exercise{
    .{
        .main_file = "001_hello.zig",
        .output = "Hello world!",
        .hint =
        \\DON'T PANIC!
        \\Read the compiler messages above. (Something about 'main'?)
        \\Open up the source file as noted below and read the comments.
        \\
        \\(Hints like these will occasionally show up, but for the
        \\most part, you'll be taking directions from the Zig
        \\compiler itself.)
        \\
        , // pay attention to the comma
    },
    .{
        .main_file = "002_std.zig",
        .output = "Standard Library.",
    },
    .{
        .main_file = "003_assignment.zig",
        .output = "55 314159 -11",
        .hint = "There are three mistakes in this one!",
    },
    .{
        .main_file = "004_arrays.zig",
        .output = "First: 2, Fourth: 7, Length: 8",
        .hint = "There are two things to complete here.",
    },
    .{
        .main_file = "005_arrays2.zig",
        .output = "LEET: 1337, Bits: 100110011001",
        .hint = "Fill in the two arrays.",
    },
    .{
        .main_file = "006_strings.zig",
        .output = "d=d ha ha ha Major Tom",
        .hint = "Each '???' needs something filled in.",
    },
    .{
        .main_file = "007_strings2.zig",
        .output =
        \\Ziggy played guitar
        \\Jamming good with Andrew Kelley
        \\And the Spiders from Mars
        , // pay attention to the comma
        .hint = "Please fix the lyrics!",
    },
    .{
        .main_file = "008_quiz.zig",
        .output = "Program in Zig!",
        .hint = "See if you can fix the program!",
    },
    .{
        .main_file = "009_if.zig",
        .output = "Foo is 42!",
    },
    .{
        .main_file = "010_if2.zig",
        .output = "With the discount, the price is $17.",
    },
    .{
        .main_file = "011_while.zig",
        .output = "2 4 8 16 32 64 128 256 512 n=1024",
        .hint = "You probably want a 'less than' condition.",
    },
    .{
        .main_file = "012_while2.zig",
        .output = "2 4 8 16 32 64 128 256 512 n=1024",
        .hint = "It might help to look back at the previous exercise.",
    },
    .{
        .main_file = "013_while3.zig",
        .output = "1 2 4 7 8 11 13 14 16 17 19",
    },
    .{
        .main_file = "014_while4.zig",
        .output = "n=4",
    },
    .{
        .main_file = "015_for.zig",
        .output = "A Dramatic Story: :-)  :-)  :-(  :-|  :-)  The End.",
    },
    .{
        .main_file = "016_for2.zig",
        .output = "The value of bits '1101': 13.",
    },
    .{
        .main_file = "017_quiz2.zig",
        .output = "1, 2, Fizz, 4, Buzz, Fizz, 7, 8, Fizz, Buzz, 11, Fizz, 13, 14, FizzBuzz, 16,",
        .hint = "This is a famous game!",
    },
    .{
        .main_file = "018_functions.zig",
        .output = "Answer to the Ultimate Question: 42",
        .hint = "Can you help write the function?",
    },
    .{
        .main_file = "019_functions2.zig",
        .output = "Powers of two: 2 4 8 16",
    },
    .{
        .main_file = "020_quiz3.zig",
        .output = "32 64 128 256",
        .hint = "Unexpected pop quiz! Help!",
    },
    .{
        .main_file = "021_errors.zig",
        .output = "2<4. 3<4. 4=4. 5>4. 6>4.",
        .hint = "What's the deal with fours?",
    },
    .{
        .main_file = "022_errors2.zig",
        .output = "I compiled!",
        .hint = "Get the error union type right to allow this to compile.",
    },
    .{
        .main_file = "023_errors3.zig",
        .output = "a=64, b=22",
    },
    .{
        .main_file = "024_errors4.zig",
        .output = "a=20, b=14, c=10",
    },
    .{
        .main_file = "025_errors5.zig",
        .output = "a=0, b=19, c=0",
    },
    .{
        .main_file = "026_hello2.zig",
        .output = "Hello world!",
        .hint = "Try using a try!",
        .check_stdout = true,
    },
    .{
        .main_file = "027_defer.zig",
        .output = "One Two",
    },
    .{
        .main_file = "028_defer2.zig",
        .output = "(Goat) (Cat) (Dog) (Dog) (Goat) (Unknown) done.",
    },
    .{
        .main_file = "029_errdefer.zig",
        .output = "Getting number...got 5. Getting number...failed!",
    },
    .{
        .main_file = "030_switch.zig",
        .output = "ZIG?",
    },
    .{
        .main_file = "031_switch2.zig",
        .output = "ZIG!",
    },
    .{
        .main_file = "032_unreachable.zig",
        .output = "1 2 3 9 8 7",
    },
    .{
        .main_file = "033_iferror.zig",
        .output = "2<4. 3<4. 4=4. 5>4. 6>4.",
        .hint = "Seriously, what's the deal with fours?",
    },
    .{
        .main_file = "034_quiz4.zig",
        .output = "my_num=42",
        .hint = "Can you make this work?",
        .check_stdout = true,
    },
    .{
        .main_file = "035_enums.zig",
        .output = "1 2 3 9 8 7",
        .hint = "This problem seems familiar...",
    },
    .{
        .main_file = "036_enums2.zig",
        .output =
        \\<p>
        \\  <span style="color: #ff0000">Red</span>
        \\  <span style="color: #00ff00">Green</span>
        \\  <span style="color: #0000ff">Blue</span>
        \\</p>
        , // pay attention to the comma
        .hint = "I'm feeling blue about this.",
    },
    .{
        .main_file = "037_structs.zig",
        .output = "Your wizard has 90 health and 25 gold.",
    },
    .{
        .main_file = "038_structs2.zig",
        .output =
        \\Character 1 - G:20 H:100 XP:10
        \\Character 2 - G:10 H:100 XP:20
        , // pay attention to the comma
    },
    .{
        .main_file = "039_pointers.zig",
        .output = "num1: 5, num2: 5",
        .hint = "Pointers aren't so bad.",
    },
    .{
        .main_file = "040_pointers2.zig",
        .output = "a: 12, b: 12",
    },
    .{
        .main_file = "041_pointers3.zig",
        .output = "foo=6, bar=11",
    },
    .{
        .main_file = "042_pointers4.zig",
        .output = "num: 5, more_nums: 1 1 5 1",
    },
    .{
        .main_file = "043_pointers5.zig",
        .output =
        \\Wizard (G:10 H:100 XP:20)
        \\  Mentor: Wizard (G:10000 H:100 XP:2340)
        , // pay attention to the comma
    },
    .{
        .main_file = "044_quiz5.zig",
        .output = "Elephant A. Elephant B. Elephant C.",
        .hint = "Oh no! We forgot Elephant B!",
    },
    .{
        .main_file = "045_optionals.zig",
        .output = "The Ultimate Answer: 42.",
    },
    .{
        .main_file = "046_optionals2.zig",
        .output = "Elephant A. Elephant B. Elephant C.",
        .hint = "Elephants again!",
    },
    .{
        .main_file = "047_methods.zig",
        .output = "5 aliens. 4 aliens. 1 aliens. 0 aliens. Earth is saved!",
        .hint = "Use the heat ray. And the method!",
    },
    .{
        .main_file = "048_methods2.zig",
        .output = "A  B  C",
        .hint = "This just needs one little fix.",
    },
    .{
        .main_file = "049_quiz6.zig",
        .output = "A  B  C  Cv Bv Av",
        .hint = "Now you're writing Zig!",
    },
    .{
        .main_file = "050_no_value.zig",
        .output = "That is not dead which can eternal lie / And with strange aeons even death may die.",
    },
    .{
        .main_file = "051_values.zig",
        .output = "1:false!. 2:true!. 3:true!. XP before:0, after:200.",
    },
    .{
        .main_file = "052_slices.zig",
        .output =
        \\Hand1: A 4 K 8
        \\Hand2: 5 2 Q J
        , // pay attention to the comma
    },
    .{
        .main_file = "053_slices2.zig",
        .output = "'all your base are belong to us.' 'for great justice.'",
    },
    .{
        .main_file = "054_manypointers.zig",
        .output = "Memory is a resource.",
    },
    .{
        .main_file = "055_unions.zig",
        .output = "Insect report! Ant alive is: true. Bee visited 15 flowers.",
    },
    .{
        .main_file = "056_unions2.zig",
        .output = "Insect report! Ant alive is: true. Bee visited 16 flowers.",
    },
    .{
        .main_file = "057_unions3.zig",
        .output = "Insect report! Ant alive is: true. Bee visited 17 flowers.",
    },
    .{
        .main_file = "058_quiz7.zig",
        .output = "Archer's Point--2->Bridge--1->Dogwood Grove--3->Cottage--2->East Pond--1->Fox Pond",
        .hint = "This is the biggest program we've seen yet. But you can do it!",
    },
    .{
        .main_file = "059_integers.zig",
        .output = "Zig is cool.",
    },
    .{
        .main_file = "060_floats.zig",
        .output = "Shuttle liftoff weight: 2.032e3 metric tons",
    },
    .{
        .main_file = "061_coercions.zig",
        .output = "Letter: A",
    },
    .{
        .main_file = "062_loop_expressions.zig",
        .output = "Current language: Zig",
        .hint = "Surely the current language is 'Zig'!",
    },
    .{
        .main_file = "063_labels.zig",
        .output = "Enjoy your Cheesy Chili!",
    },
    .{
        .main_file = "064_builtins.zig",
        .output = "1101 + 0101 = 0010 (true). Without overflow: 00010010. Furthermore, 11110000 backwards is 00001111.",
    },
    .{
        .main_file = "065_builtins2.zig",
        .output = "A Narcissus loves all Narcissuses. He has room in his heart for: me myself.",
    },
    .{
        .main_file = "066_comptime.zig",
        .output = "Immutable: 12345, 987.654; Mutable: 54321, 456.789; Types: comptime_int, comptime_float, u32, f32",
        .hint = "It may help to read this one out loud to your favorite stuffed animal until it sinks in completely.",
    },
    .{
        .main_file = "067_comptime2.zig",
        .output = "A BB CCC DDDD",
    },
    .{
        .main_file = "068_comptime3.zig",
        .output =
        \\Minnow (1:32, 4 x 2)
        \\Shark (1:16, 8 x 5)
        \\Whale (1:1, 143 x 95)
        ,
    },
    .{
        .main_file = "069_comptime4.zig",
        .output = "s1={ 1, 2, 3 }, s2={ 1, 2, 3, 4, 5 }, s3={ 1, 2, 3, 4, 5, 6, 7 }",
    },
    .{
        .main_file = "070_comptime5.zig",
        .output =
        \\"Quack." ducky1: true, "Squeek!" ducky2: true, ducky3: false
        ,
        .hint = "Have you kept the wizard hat on?",
    },
    .{
        .main_file = "071_comptime6.zig",
        .output = "Narcissus has room in his heart for: me myself.",
    },
    .{
        .main_file = "072_comptime7.zig",
        .output = "26",
    },
    .{
        .main_file = "073_comptime8.zig",
        .output = "My llama value is 25.",
    },
    .{
        .main_file = "074_comptime9.zig",
        .output = "MouseLlama joins the crew!",
    },
    .{
        .main_file = "075_quiz8.zig",
        .output = "Archer's Point--2->Bridge--1->Dogwood Grove--3->Cottage--2->East Pond--1->Fox Pond",
        .hint = "Roll up those sleeves. You get to WRITE some code for this one.",
    },
    .{
        .main_file = "076_sentinels.zig",
        .output = "Array:123056. Many-item pointer:123.",
    },
    .{
        .main_file = "077_sentinels2.zig",
        .output = "Weird Data!",
    },
    .{
        .main_file = "078_sentinels3.zig",
        .output = "Weird Data!",
    },
    .{
        .main_file = "079_quoted_identifiers.zig",
        .output = "Sweet freedom: 55, false.",
        .hint = "Help us, Zig Programmer, you're our only hope!",
    },
    .{
        .main_file = "080_anonymous_structs.zig",
        .output = "[Circle(i32): 25,70,15] [Circle(f32): 25.2,71.0,15.7]",
    },
    .{
        .main_file = "081_anonymous_structs2.zig",
        .output = "x:205 y:187 radius:12",
    },
    .{
        .main_file = "082_anonymous_structs3.zig",
        .output =
        \\"0"(bool):true "1"(bool):false "2"(i32):42 "3"(f32):3.141592
        , // pay attention to the comma
        .hint = "This one is a challenge! But you have everything you need.",
    },
    .{
        .main_file = "083_anonymous_lists.zig",
        .output = "I say hello!",
    },
    .{
        .main_file = "084_interfaces.zig",
        .output =
        \\=== Doctor Zoraptera's Insect Report ===
        \\Ant is alive.
        \\Bee visited 17 flowers.
        \\Grasshopper hopped 32 meters.
        , // pay attention to the comma
    },

    // Skipped because of https://github.com/ratfactor/ziglings/issues/163
    // direct link: https://github.com/ziglang/zig/issues/6025
    .{
        .main_file = "085_async.zig",
        .output = "Current time: <timestamp>s since epoch",
        .timestamp = true,
    },
    .{
        .main_file = "086_async2.zig",
        .output = "Computing... The answer is: 42",
    },
    .{
        .main_file = "087_async3.zig",
        .output =
        \\1 + 2 = 3
        \\6 * 7 = 42
        \\Total: 45
        , // pay attention to the comma
    },
    .{
        .main_file = "088_async4.zig",
        .output =
        \\Task 1 done.
        \\Task 2 done.
        \\Task 3 done.
        \\All tasks finished!
        , // pay attention to the comma
    },
    .{
        .main_file = "089_async5.zig",
        .output =
        \\Starting long computation...
        \\Canceling slow task...
        \\Task was canceled, cleaning up.
        \\Task returned: 0
        , // pay attention to the comma
    },
    .{
        .main_file = "090_async6.zig",
        .output = "Hare: I'm fast!",
    },
    .{
        .main_file = "091_async7.zig",
        .output = "Counter: 400",
    },
    .{
        .main_file = "092_async8.zig",
        .output = "Sum of 1..10 = 55",
    },
    .{
        .main_file = "093_async9.zig",
        .output = "Worker 1 found signal start over threshold at index 12!",
    },
    .{
        .main_file = "094_async10.zig",
        .output =
        \\Starting critical section...
        \\Critical section completed safely.
        \\Task result: All data saved.
        , // pay attention to the comma
    },
    .{
        .main_file = "095_quiz_async.zig",
        .output =
        \\=== Doctor Zoraptera's Garden Report ===
        \\Temperature : 23C
        \\Humidity    : 63%
        \\Wind        : 13 km/h
        \\Readings    : 9
        \\Bee-friendly conditions! Expect high pollination.
        , // pay attention to the comma
    },
    .{
        .main_file = "096_hello_c.zig",
        .output = "Hello C from Zig! - C result is 17 chars written.",
        .link_libc = true,
        // @cImport() was removed from the language.
        .skip = true,
        .skip_hint = "Skipped until we have found a solution for the removed '@cImport'",
    },
    .{
        .main_file = "097_c_math.zig",
        .output = "The normalized angle of 765.2 degrees is 45.2 degrees.",
        .link_libc = true,
        // @cImport() was removed from the language.
        .skip = true,
        .skip_hint = "Skipped until we have found a solution for the removed '@cImport'",
    },
    .{
        .main_file = "098_for3.zig",
        .output = "1 2 4 7 8 11 13 14 16 17 19\n1 2 3 4 5 6 7 8 9 10 11 12 13 14 15",
    },
    .{
        .main_file = "099_memory_allocation.zig",
        .output = "Running Average: 0.30 0.25 0.20 0.18 0.22",
    },
    .{
        .main_file = "100_bit_manipulation.zig",
        .output = "x = 1011; y = 1101",
    },
    .{
        .main_file = "101_bit_manipulation2.zig",
        .output = "Is this a pangram? true!",
    },
    .{
        .main_file = "102_formatting.zig",
        .output =
        \\
        \\ X |  1   2   3   4   5   6   7   8   9  10  11  12  13  14  15
        \\---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+---+
        \\ 1 |  1   2   3   4   5   6   7   8   9  10  11  12  13  14  15
        \\
        \\ 2 |  2   4   6   8  10  12  14  16  18  20  22  24  26  28  30
        \\
        \\ 3 |  3   6   9  12  15  18  21  24  27  30  33  36  39  42  45
        \\
        \\ 4 |  4   8  12  16  20  24  28  32  36  40  44  48  52  56  60
        \\
        \\ 5 |  5  10  15  20  25  30  35  40  45  50  55  60  65  70  75
        \\
        \\ 6 |  6  12  18  24  30  36  42  48  54  60  66  72  78  84  90
        \\
        \\ 7 |  7  14  21  28  35  42  49  56  63  70  77  84  91  98 105
        \\
        \\ 8 |  8  16  24  32  40  48  56  64  72  80  88  96 104 112 120
        \\
        \\ 9 |  9  18  27  36  45  54  63  72  81  90  99 108 117 126 135
        \\
        \\10 | 10  20  30  40  50  60  70  80  90 100 110 120 130 140 150
        \\
        \\11 | 11  22  33  44  55  66  77  88  99 110 121 132 143 154 165
        \\
        \\12 | 12  24  36  48  60  72  84  96 108 120 132 144 156 168 180
        \\
        \\13 | 13  26  39  52  65  78  91 104 117 130 143 156 169 182 195
        \\
        \\14 | 14  28  42  56  70  84  98 112 126 140 154 168 182 196 210
        \\
        \\15 | 15  30  45  60  75  90 105 120 135 150 165 180 195 210 225
        ,
    },
    .{
        .main_file = "103_for4.zig",
        .output = "Arrays match!",
    },
    .{
        .main_file = "104_for5.zig",
        .output =
        \\1. Wizard (Gold: 25, XP: 40)
        \\2. Bard (Gold: 11, XP: 17)
        \\3. Bard (Gold: 5, XP: 55)
        \\4. Warrior (Gold: 7392, XP: 21)
        , // pay attention to the comma
    },
    .{
        .main_file = "105_testing.zig",
        .output = "",
        .kind = .@"test",
    },
    .{
        .main_file = "106_tokenization.zig",
        .output =
        \\My
        \\name
        \\is
        \\Ozymandias
        \\King
        \\of
        \\Kings
        \\Look
        \\on
        \\my
        \\Works
        \\ye
        \\Mighty
        \\and
        \\despair
        \\This little poem has 15 words!
        , // pay attention to the comma
    },
    .{
        .main_file = "107_threading.zig",
        .output =
        \\Starting work...
        \\thread 1: started.
        \\thread 2: started.
        \\thread 3: started.
        \\Some weird stuff, after starting the threads.
        \\thread 2: finished.
        \\thread 1: finished.
        \\thread 3: finished.
        \\Zig is cool!
        , // pay attention to the comma
    },
    .{
        .main_file = "108_threading2.zig",
        .output = "PI ≈ 3.14159265",
    },
    .{
        .main_file = "109_files.zig",
        .output = "Successfully wrote 18 bytes.",
    },
    .{
        .main_file = "110_files2.zig",
        .output =
        \\AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA
        \\Successfully Read 18 bytes: It's zigling time!
        , // pay attention to the comma
    },
    .{
        .main_file = "111_labeled_switch.zig",
        .output = "The pull request has been merged.",
    },
    .{
        .main_file = "112_vectors.zig",
        .output =
        \\Max difference (old fn): 0.014
        \\Max difference (new fn): 0.014
        , // pay attention to the comma
    },
    .{ .main_file = "113_quiz9.zig", .output =
    \\Toggle pins with XOR on PORTB
    \\-----------------------------
    \\  1100 // (initial state of PORTB)
    \\^ 0101 // (bitmask)
    \\= 1001
    \\
    \\  1100 // (initial state of PORTB)
    \\^ 0011 // (bitmask)
    \\= 1111
    \\
    \\Set pins with OR on PORTB
    \\-------------------------
    \\  1001 // (initial state of PORTB)
    \\| 0100 // (bitmask)
    \\= 1101
    \\
    \\  1001 // (reset state)
    \\| 0100 // (bitmask)
    \\= 1101
    \\
    \\Clear pins with AND and NOT on PORTB
    \\------------------------------------
    \\  1110 // (initial state of PORTB)
    \\& 1011 // (bitmask)
    \\= 1010
    \\
    \\  0111 // (reset state)
    \\& 1110 // (bitmask)
    \\= 0110
    },
    .{
        .main_file = "114_packed.zig",
        .output = "",
    },
    .{
        .main_file = "115_packed2.zig",
        .output = "",
    },
    .{
        .main_file = "999_the_end.zig",
        .output =
        \\
        \\This is the end for now!
        \\We hope you had fun and were able to learn a lot, so visit us again when the next exercises are available.
        , // pay attention to the comma
    },
};
