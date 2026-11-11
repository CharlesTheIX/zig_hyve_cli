const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const config_mod = @import("config.zig");
const Config = config_mod.Config;
const Application = config_mod.Application;
const Stages = config_mod.Stages;
const runner = @import("runner.zig");

pub fn execute(
    init: std.process.Init,
    allocator: Allocator,
    config: Config,
    stages: Stages,
    dry_run: bool,
) !void {
    if (dry_run) {
        std.debug.print("Dry run: no external commands will be executed.\n", .{});
        try printPlannedCommands(allocator, config, stages);
        return;
    }

    try validateCredentialEnvironment(init, config, stages);
    try preflight(init, allocator, config, stages);

    if (stages.login) {
        std.debug.print("Stage: registry login\n", .{});
        try login(init, allocator, config);
    }
    if (stages.build) {
        std.debug.print("Stage: build CMS and webapp\n", .{});
        try buildApplications(init, allocator, config);
    }
    if (stages.push) {
        std.debug.print("Stage: push CMS and webapp images\n", .{});
        try pushApplications(init, allocator, config);
    }
    if (stages.deploy) {
        std.debug.print("Stage: deploy CMS and webapp\n", .{});
        try deployApplications(init, allocator, config);
    }
}

fn validateCredentialEnvironment(init: std.process.Init, config: Config, stages: Stages) !void {
    if (!stages.login) return;
    const username_name = config.registry.username_env.?;
    const password_name = config.registry.password_env.?;
    const username = init.environ_map.get(username_name) orelse {
        std.debug.print("Registry login: environment variable {s} is not set.\n", .{username_name});
        return error.MissingRegistryCredential;
    };
    const password = init.environ_map.get(password_name) orelse {
        std.debug.print("Registry login: environment variable {s} is not set.\n", .{password_name});
        return error.MissingRegistryCredential;
    };
    if (username.len == 0 or password.len == 0) {
        std.debug.print("Registry login: configured credential environment variables must not be empty.\n", .{});
        return error.MissingRegistryCredential;
    }
    if (std.mem.indexOfAny(u8, username, "\x00\r\n") != null or
        std.mem.indexOfAny(u8, password, "\x00\r\n") != null)
    {
        std.debug.print("Registry login: credentials contain unsupported line breaks.\n", .{});
        return error.InvalidRegistryCredential;
    }
}

fn preflight(init: std.process.Init, allocator: Allocator, config: Config, stages: Stages) !void {
    const needs_docker = stages.login or stages.build or stages.push;
    const needs_npm = stages.build and
        (config.cms.next_build == .npm or config.webapp.next_build == .npm);

    if (needs_docker) try checkTool(init, allocator, config, &.{ "docker", "--version" }, "preflight docker");
    if (needs_npm) try checkTool(init, allocator, config, &.{ "npm", "--version" }, "preflight npm");
    if (stages.deploy) try checkTool(init, allocator, config, &.{ "oc", "version", "--client" }, "preflight oc");
}

fn checkTool(
    init: std.process.Init,
    allocator: Allocator,
    config: Config,
    argv: []const []const u8,
    description: []const u8,
) !void {
    try runCommand(init, allocator, config, argv, config.monorepo, null, description);
}

fn login(init: std.process.Init, allocator: Allocator, config: Config) !void {
    const username = init.environ_map.get(config.registry.username_env.?).?;
    const password = init.environ_map.get(config.registry.password_env.?).?;
    const password_line = try std.fmt.allocPrint(init.gpa, "{s}\n", .{password});
    defer {
        std.crypto.secureZero(u8, password_line);
        init.gpa.free(password_line);
    }
    const argv = [_][]const u8{
        "docker",
        "login",
        "--username",
        username,
        "--password-stdin",
        config.registry.server,
    };
    try runCommand(init, allocator, config, &argv, config.monorepo, password_line, "registry login");
    std.debug.print("Registry login completed.\n", .{});
}

fn buildApplications(init: std.process.Init, allocator: Allocator, config: Config) !void {
    buildApplication(init, allocator, config, config.cms, "CMS") catch |err| {
        std.debug.print("CMS build failed; webapp build was not started.\n", .{});
        return err;
    };
    buildApplication(init, allocator, config, config.webapp, "webapp") catch |err| {
        std.debug.print("Build partially completed: CMS succeeded, webapp failed.\n", .{});
        return err;
    };
    std.debug.print("CMS and webapp builds completed.\n", .{});
}

fn buildApplication(
    init: std.process.Init,
    allocator: Allocator,
    config: Config,
    app: Application,
    name: []const u8,
) !void {
    if (app.next_build == .npm) {
        const npm_directory = try applicationNpmDirectory(allocator, config, app);
        if (app.npm_ci) {
            try runCommand(init, allocator, config, &.{ "npm", "ci" }, npm_directory, null, name);
        }
        const npm_argv = try npmBuildArgv(allocator, app);
        try runCommand(init, allocator, config, npm_argv, npm_directory, null, name);
    }

    const docker_argv = [_][]const u8{
        "docker",
        "build",
        "--file",
        app.dockerfile,
        "--tag",
        app.image,
        app.build_context,
    };
    try runCommand(init, allocator, config, &docker_argv, config.monorepo, null, name);
}

fn pushApplications(init: std.process.Init, allocator: Allocator, config: Config) !void {
    const cms_argv = [_][]const u8{ "docker", "push", config.cms.image };
    runCommand(init, allocator, config, &cms_argv, config.monorepo, null, "CMS image push") catch |err| {
        std.debug.print("CMS image push failed; webapp image push was not started.\n", .{});
        return err;
    };

    const webapp_argv = [_][]const u8{ "docker", "push", config.webapp.image };
    runCommand(init, allocator, config, &webapp_argv, config.monorepo, null, "webapp image push") catch |err| {
        std.debug.print("Push partially completed: CMS image succeeded, webapp image failed.\n", .{});
        return err;
    };
    std.debug.print("CMS and webapp image pushes completed.\n", .{});
}

fn deployApplications(init: std.process.Init, allocator: Allocator, config: Config) !void {
    deployApplication(init, allocator, config, config.cms, "CMS") catch |err| {
        std.debug.print("CMS deployment did not complete; cluster state may have changed. Webapp deployment was not started.\n", .{});
        return err;
    };
    deployApplication(init, allocator, config, config.webapp, "webapp") catch |err| {
        std.debug.print("Deployment partially completed: CMS rollout succeeded, webapp deployment did not complete. No rollback was attempted.\n", .{});
        return err;
    };
    std.debug.print("CMS and webapp rollouts completed.\n", .{});
}

fn deployApplication(
    init: std.process.Init,
    allocator: Allocator,
    config: Config,
    app: Application,
    name: []const u8,
) !void {
    const resource = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ app.deployment.resource_kind, app.deployment.resource_name },
    );
    const image_assignment = try std.fmt.allocPrint(
        allocator,
        "{s}={s}",
        .{ app.deployment.container_name, app.image },
    );
    const set_image_argv = [_][]const u8{
        "oc",
        "set",
        "image",
        resource,
        image_assignment,
        "--context",
        config.openshift.context,
        "--namespace",
        config.openshift.namespace,
    };
    const update_description = try std.fmt.allocPrint(allocator, "{s} image update", .{name});
    try runCommand(init, allocator, config, &set_image_argv, config.monorepo, null, update_description);

    const rollout_timeout = try std.fmt.allocPrint(
        allocator,
        "--timeout={d}s",
        .{config.openshift.rollout_timeout_seconds},
    );
    const rollout_argv = [_][]const u8{
        "oc",
        "rollout",
        "status",
        resource,
        rollout_timeout,
        "--context",
        config.openshift.context,
        "--namespace",
        config.openshift.namespace,
    };
    const rollout_description = try std.fmt.allocPrint(allocator, "{s} rollout", .{name});
    try runCommand(init, allocator, config, &rollout_argv, config.monorepo, null, rollout_description);
}

fn applicationNpmDirectory(allocator: Allocator, config: Config, app: Application) ![]const u8 {
    return std.fs.path.join(allocator, &.{
        config.monorepo,
        app.npm_working_directory orelse app.directory,
    });
}

fn npmBuildArgv(allocator: Allocator, app: Application) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.appendSlice(allocator, &.{ "npm", "run", app.npm_script.? });
    if (app.npm_workspace) |workspace| {
        try argv.appendSlice(allocator, &.{ "--workspace", workspace });
    }
    return argv.items;
}

fn runCommand(
    init: std.process.Init,
    allocator: Allocator,
    config: Config,
    argv: []const []const u8,
    working_directory: []const u8,
    stdin_data: ?[]const u8,
    description: []const u8,
) !void {
    const duration = Io.Clock.Duration{
        .raw = Io.Duration.fromSeconds(@intCast(config.command_timeout_seconds)),
        .clock = .awake,
    };
    const timeout: Io.Timeout = .{
        .deadline = Io.Clock.Timestamp.fromNow(init.io, duration),
    };
    try runner.run(allocator, init.io, argv, working_directory, timeout, stdin_data, description);
}

fn printPlannedCommands(allocator: Allocator, config: Config, stages: Stages) !void {
    if (stages.login) {
        std.debug.print("  registry login: docker login --username <{s}> --password-stdin {s}\n", .{
            config.registry.username_env.?,
            config.registry.server,
        });
    }
    if (stages.build) {
        try printPlannedBuild(allocator, config, config.cms, "CMS");
        try printPlannedBuild(allocator, config, config.webapp, "webapp");
    }
    if (stages.push) {
        printPlannedArgv(&.{ "docker", "push", config.cms.image });
        printPlannedArgv(&.{ "docker", "push", config.webapp.image });
    }
    if (stages.deploy) {
        try printPlannedDeploy(allocator, config, config.cms);
        try printPlannedDeploy(allocator, config, config.webapp);
    }
}

fn printPlannedBuild(allocator: Allocator, config: Config, app: Application, name: []const u8) !void {
    if (app.next_build == .npm) {
        const npm_directory = try applicationNpmDirectory(allocator, config, app);
        if (app.npm_ci) printPlannedArgv(&.{ "npm", "ci" });
        const npm_argv = try npmBuildArgv(allocator, app);
        printPlannedArgv(npm_argv);
        std.debug.print("    working directory ({s} npm): {s}\n", .{ name, npm_directory });
    }
    const docker_argv = [_][]const u8{
        "docker",
        "build",
        "--file",
        app.dockerfile,
        "--tag",
        app.image,
        app.build_context,
    };
    printPlannedArgv(&docker_argv);
    std.debug.print("    working directory ({s} docker): {s}\n", .{ name, config.monorepo });
}

fn printPlannedDeploy(allocator: Allocator, config: Config, app: Application) !void {
    const resource = try std.fmt.allocPrint(
        allocator,
        "{s}/{s}",
        .{ app.deployment.resource_kind, app.deployment.resource_name },
    );
    const image_assignment = try std.fmt.allocPrint(
        allocator,
        "{s}={s}",
        .{ app.deployment.container_name, app.image },
    );
    const set_image_argv = [_][]const u8{
        "oc",
        "set",
        "image",
        resource,
        image_assignment,
        "--context",
        config.openshift.context,
        "--namespace",
        config.openshift.namespace,
    };
    printPlannedArgv(&set_image_argv);

    const rollout_timeout = try std.fmt.allocPrint(
        allocator,
        "--timeout={d}s",
        .{config.openshift.rollout_timeout_seconds},
    );
    const rollout_argv = [_][]const u8{
        "oc",
        "rollout",
        "status",
        resource,
        rollout_timeout,
        "--context",
        config.openshift.context,
        "--namespace",
        config.openshift.namespace,
    };
    printPlannedArgv(&rollout_argv);
}

fn printPlannedArgv(argv: []const []const u8) void {
    std.debug.print("  command:", .{});
    for (argv) |argument| std.debug.print(" [{s}]", .{argument});
    std.debug.print("\n", .{});
}
