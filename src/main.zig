const std = @import("std");
const zig_hyve_cli = @import("zig_hyve_cli");

pub fn main(init: std.process.Init) void {
    run(init) catch |err| {
        std.debug.print("Error: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
}

fn run(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);

    var config_path: ?[]const u8 = null;
    var stages: zig_hyve_cli.config.Stages = .{};
    var dry_run = false;
    var show_help = false;
    var index: usize = 1;
    while (index < args.len) : (index += 1) {
        const argument = args[index];
        if (std.mem.eql(u8, argument, "--help") or std.mem.eql(u8, argument, "-h")) {
            show_help = true;
        } else if (std.mem.eql(u8, argument, "--dry-run")) {
            dry_run = true;
        } else if (std.mem.eql(u8, argument, "--config")) {
            index += 1;
            if (index >= args.len) return error.MissingConfigPath;
            if (config_path != null) return error.ConfigSpecifiedMoreThanOnce;
            config_path = args[index];
        } else if (std.mem.eql(u8, argument, "--stage")) {
            index += 1;
            if (index >= args.len) return error.MissingStage;
            try addStages(&stages, args[index]);
        } else {
            std.debug.print("Unknown argument: {s}\n", .{argument});
            return error.UnknownArgument;
        }
    }

    if (show_help) {
        printUsage();
        return;
    }

    const selected_config = config_path orelse return error.MissingConfigPath;
    const selected_config_value = zig_hyve_cli.config.load(init.io, allocator, selected_config) catch |err| {
        std.debug.print("Could not load configuration file ({s}).\n", .{@errorName(err)});
        return error.InvalidConfiguration;
    };
    zig_hyve_cli.config.validate(init.io, selected_config_value, stages) catch |err| {
        std.debug.print("Configuration validation failed ({s}).\n", .{@errorName(err)});
        return error.InvalidConfiguration;
    };

    try zig_hyve_cli.pipeline.execute(init, allocator, selected_config_value, stages, dry_run);
}

fn addStages(stages: *zig_hyve_cli.config.Stages, value: []const u8) !void {
    var names = std.mem.tokenizeScalar(u8, value, ',');
    var found = false;
    while (names.next()) |name| {
        found = true;
        if (std.mem.eql(u8, name, "login")) {
            stages.login = true;
        } else if (std.mem.eql(u8, name, "build")) {
            stages.build = true;
        } else if (std.mem.eql(u8, name, "push")) {
            stages.push = true;
        } else if (std.mem.eql(u8, name, "deploy")) {
            stages.deploy = true;
        } else {
            std.debug.print("Unknown pipeline stage: {s}\n", .{name});
            return error.UnknownStage;
        }
    }
    if (!found) return error.EmptyStageList;
}

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  zig_hyve_cli --config <path> --stage <stage[,stage...]> [--dry-run]
        \\
        \\Stages:
        \\  login   Authenticate to the configured registry (credentials mode only)
        \\  build   Run configured npm build steps and build both container images
        \\  push    Push both images; requires build in the same invocation
        \\  deploy  Deploy both pushed images and wait for rollouts
        \\
        \\Options:
        \\  --config <path>  Read the JSON configuration file
        \\  --stage <list>  Select one or more stages; may be repeated
        \\  --dry-run       Print planned commands without executing them
        \\  -h, --help      Show this help
        \\
        \\Push requires build. Deploy requires build and push. If registry auth
        \\mode is "credentials", push also requires the login stage.
        \\
    , .{});
}
