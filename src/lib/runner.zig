const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const read_reserve = 4096;

pub fn run(
    allocator: Allocator,
    io: Io,
    argv: []const []const u8,
    working_directory: []const u8,
    timeout: Io.Timeout,
    stdin_data: ?[]const u8,
    description: []const u8,
) !void {
    var child = std.process.spawn(io, .{
        .argv = argv,
        .cwd = .{ .path = working_directory },
        .stdin = if (stdin_data == null) .ignore else .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch |err| {
        if (err == error.Canceled) return err;
        std.debug.print("{s}: could not start command ({s})\n", .{ description, @errorName(err) });
        return error.CommandFailed;
    };
    defer child.kill(io);

    if (stdin_data) |data| {
        const stdin = child.stdin orelse return error.MissingChildStdin;
        var stdin_buffer: [1024]u8 = undefined;
        var stdin_writer = stdin.writer(io, &stdin_buffer);
        stdin_writer.interface.writeAll(data) catch |err| {
            if (err == error.Canceled) return err;
            std.debug.print("{s}: could not provide command input ({s})\n", .{ description, @errorName(err) });
            return error.CommandFailed;
        };
        stdin_writer.interface.flush() catch |err| {
            if (err == error.Canceled) return err;
            std.debug.print("{s}: could not flush command input ({s})\n", .{ description, @errorName(err) });
            return error.CommandFailed;
        };
        stdin.close(io);
        child.stdin = null;
    }

    var multi_reader_buffer: Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const stdout_reader = multi_reader.reader(0);
    const stderr_reader = multi_reader.reader(1);
    while (multi_reader.fill(read_reserve, timeout)) |_| {
        try discardBuffered(stdout_reader);
        try discardBuffered(stderr_reader);
    } else |err| switch (err) {
        error.EndOfStream => {},
        error.Canceled => return error.Canceled,
        else => {
            std.debug.print("{s}: command did not complete successfully ({s})\n", .{ description, @errorName(err) });
            return error.CommandFailed;
        },
    }

    multi_reader.checkAnyError() catch |err| {
        if (err == error.Canceled) return err;
        std.debug.print("{s}: could not read command output ({s})\n", .{ description, @errorName(err) });
        return error.CommandFailed;
    };

    const term = child.wait(io) catch |err| {
        if (err == error.Canceled) return err;
        std.debug.print("{s}: could not wait for command ({s})\n", .{ description, @errorName(err) });
        return error.CommandFailed;
    };
    if (!term.success()) {
        switch (term) {
            .exited => |status| std.debug.print("{s}: command exited with status {d}\n", .{ description, status }),
            else => std.debug.print("{s}: command terminated abnormally\n", .{description}),
        }
        return error.CommandFailed;
    }
}

fn discardBuffered(reader: *Io.Reader) !void {
    const buffered = reader.buffered().len;
    if (buffered > 0) try reader.discardAll(buffered);
}
