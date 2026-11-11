const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

pub const Stage = enum {
    login,
    build,
    push,
    deploy,
};

pub const Stages = struct {
    login: bool = false,
    build: bool = false,
    push: bool = false,
    deploy: bool = false,

    pub fn contains(stages: Stages, stage: Stage) bool {
        return switch (stage) {
            .login => stages.login,
            .build => stages.build,
            .push => stages.push,
            .deploy => stages.deploy,
        };
    }

    pub fn any(stages: Stages) bool {
        return stages.login or stages.build or stages.push or stages.deploy;
    }
};

pub const Config = struct {
    monorepo: []const u8,
    command_timeout_seconds: u32,
    registry: Registry,
    openshift: OpenShift,
    cms: Application,
    webapp: Application,
};

pub const Registry = struct {
    server: []const u8,
    auth: AuthMode,
    username_env: ?[]const u8 = null,
    password_env: ?[]const u8 = null,
};

pub const AuthMode = enum {
    existing,
    credentials,
};

pub const OpenShift = struct {
    context: []const u8,
    namespace: []const u8,
    rollout_timeout_seconds: u32,
};

pub const Application = struct {
    directory: []const u8,
    build_context: []const u8,
    dockerfile: []const u8,
    image: []const u8,
    next_build: BuildMode,
    npm_working_directory: ?[]const u8 = null,
    npm_workspace: ?[]const u8 = null,
    npm_ci: bool = false,
    npm_script: ?[]const u8 = null,
    deployment: Deployment,
};

pub const BuildMode = enum {
    npm,
    dockerfile,
};

pub const Deployment = struct {
    resource_kind: []const u8,
    resource_name: []const u8,
    container_name: []const u8,
};

pub fn load(io: Io, allocator: Allocator, path: []const u8) !Config {
    const file = try Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);

    var buffer: [4096]u8 = undefined;
    var file_reader = file.reader(io, &buffer);
    const contents = try file_reader.interface.allocRemaining(allocator, .limited(1024 * 1024));
    return std.json.parseFromSliceLeaky(Config, allocator, contents, .{});
}

pub fn validate(io: Io, config: Config, stages: Stages) !void {
    if (!stages.any()) return error.NoStagesSelected;
    if (config.command_timeout_seconds == 0) return error.InvalidCommandTimeout;
    if (config.openshift.rollout_timeout_seconds == 0) return error.InvalidRolloutTimeout;
    if (config.command_timeout_seconds < config.openshift.rollout_timeout_seconds) {
        return error.CommandTimeoutShorterThanRolloutTimeout;
    }
    if (!std.fs.path.isAbsolute(config.monorepo)) return error.MonorepoPathMustBeAbsolute;

    if (stages.push and !stages.build) return error.PushRequiresBuild;
    if (stages.deploy and (!stages.push or !stages.build)) return error.DeployRequiresBuildAndPush;

    if (stages.login and config.registry.auth != .credentials) return error.LoginRequiresCredentials;
    if (stages.push and config.registry.auth == .credentials and !stages.login) {
        return error.PushRequiresLogin;
    }

    try validateRegistry(config.registry);
    try validateApplication(config.registry.server, config.cms);
    try validateApplication(config.registry.server, config.webapp);
    if (std.mem.eql(u8, config.cms.image, config.webapp.image)) return error.ImagesMustBeDistinct;
    try validateText(config.openshift.context);
    try validateText(config.openshift.namespace);

    var root_dir = try Io.Dir.openDirAbsolute(io, config.monorepo, .{});
    defer root_dir.close(io);
    try validateApplicationPaths(io, root_dir, config.cms);
    try validateApplicationPaths(io, root_dir, config.webapp);
}

fn validateRegistry(registry: Registry) !void {
    try validateText(registry.server);
    if (std.mem.indexOfAny(u8, registry.server, " /\t\r\n") != null) return error.InvalidRegistryServer;

    switch (registry.auth) {
        .existing => {
            if (registry.username_env != null or registry.password_env != null) {
                return error.UnexpectedCredentialEnvironment;
            }
        },
        .credentials => {
            const username_env = registry.username_env orelse return error.MissingUsernameEnvironment;
            const password_env = registry.password_env orelse return error.MissingPasswordEnvironment;
            try validateEnvironmentName(username_env);
            try validateEnvironmentName(password_env);
        },
    }
}

fn validateApplication(registry_server: []const u8, app: Application) !void {
    if (!isSafeRelativePath(app.directory) or
        !isSafeRelativePath(app.build_context) or
        !isSafeRelativePath(app.dockerfile))
    {
        return error.InvalidApplicationPath;
    }
    try validateText(app.directory);
    try validateText(app.build_context);
    try validateText(app.dockerfile);
    if (!std.mem.startsWith(u8, app.image, registry_server) or
        app.image.len <= registry_server.len or
        app.image[registry_server.len] != '/')
    {
        return error.ImageMustUseConfiguredRegistry;
    }
    if (std.mem.indexOfAny(u8, app.image, " \t\r\n") != null) return error.InvalidImageReference;
    if (!hasImmutableImageSelector(app.image[registry_server.len + 1 ..])) {
        return error.ImageMustHaveImmutableSelector;
    }

    switch (app.next_build) {
        .npm => {
            const script = app.npm_script orelse return error.MissingNpmBuildScript;
            try validateText(script);
            if (script[0] == '-') return error.InvalidNpmBuildScript;
            if (app.npm_working_directory) |path| {
                if (!isSafeRelativePath(path)) return error.InvalidNpmWorkingDirectory;
                try validateText(path);
            }
            if (app.npm_workspace) |workspace| {
                try validateText(workspace);
                if (std.mem.indexOfAny(u8, workspace, " \t\r\n") != null) {
                    return error.InvalidNpmWorkspace;
                }
            }
        },
        .dockerfile => {
            if (app.npm_ci or
                app.npm_script != null or
                app.npm_working_directory != null or
                app.npm_workspace != null)
            {
                return error.NpmOptionsConflictWithDockerfileBuild;
            }
        },
    }

    try validateText(app.deployment.resource_kind);
    try validateText(app.deployment.resource_name);
    try validateText(app.deployment.container_name);
    if (std.mem.indexOfAny(u8, app.deployment.resource_kind, "/ \t\r\n") != null or
        std.mem.indexOfAny(u8, app.deployment.resource_name, "/ \t\r\n") != null or
        std.mem.indexOfAny(u8, app.deployment.container_name, " \t\r\n") != null)
    {
        return error.InvalidDeploymentResource;
    }
    if (!std.mem.eql(u8, app.deployment.resource_kind, "deployment") and
        !std.mem.eql(u8, app.deployment.resource_kind, "deploymentconfig") and
        !std.mem.eql(u8, app.deployment.resource_kind, "dc"))
    {
        return error.UnsupportedDeploymentResourceKind;
    }
}

fn validateApplicationPaths(io: Io, root: Io.Dir, app: Application) !void {
    var app_dir = try root.openDir(io, app.directory, .{});
    defer app_dir.close(io);

    var context_dir = try root.openDir(io, app.build_context, .{});
    defer context_dir.close(io);

    const dockerfile = try root.openFile(io, app.dockerfile, .{});
    defer dockerfile.close(io);

    if (app.next_build == .npm) {
        const npm_path = app.npm_working_directory orelse app.directory;
        var npm_dir = try root.openDir(io, npm_path, .{});
        defer npm_dir.close(io);
        if (app.npm_ci and
            !try lockfileExists(io, npm_dir, "package-lock.json") and
            !try lockfileExists(io, npm_dir, "npm-shrinkwrap.json"))
        {
            return error.NpmCiRequiresLockfile;
        }
    }
}

fn lockfileExists(io: Io, dir: Io.Dir, name: []const u8) !bool {
    const file = dir.openFile(io, name, .{}) catch |err| switch (err) {
        error.FileNotFound => return false,
        else => return err,
    };
    file.close(io);
    return true;
}

fn hasImmutableImageSelector(reference: []const u8) bool {
    const selector = std.mem.indexOfAny(u8, reference, ":@") orelse return false;
    const repository = reference[0..selector];
    if (repository.len == 0 or repository[0] == '/' or
        repository[repository.len - 1] == '/' or std.mem.indexOf(u8, repository, "//") != null)
    {
        return false;
    }

    if (reference[selector] == '@') {
        const digest = reference[selector + 1 ..];
        if (!std.mem.startsWith(u8, digest, "sha256:") or digest.len != "sha256:".len + 64) return false;
        for (digest["sha256:".len..]) |character| {
            if (!std.ascii.isHex(character)) return false;
        }
        return true;
    }

    const tag = reference[selector + 1 ..];
    if (tag.len == 0 or tag.len > 128 or std.mem.eql(u8, tag, "latest")) return false;
    return std.mem.indexOfAny(u8, tag, ":@ \t\r\n") == null;
}

fn isSafeRelativePath(path: []const u8) bool {
    if (path.len == 0 or std.fs.path.isAbsolute(path)) return false;
    var components = std.mem.tokenizeAny(u8, path, "/\\");
    while (components.next()) |component| {
        if (std.mem.eql(u8, component, "..")) return false;
    }
    return true;
}

fn validateEnvironmentName(name: []const u8) !void {
    try validateText(name);
    for (name, 0..) |character, index| {
        const valid = if (index == 0)
            std.ascii.isAlphabetic(character) or character == '_'
        else
            std.ascii.isAlphanumeric(character) or character == '_';
        if (!valid) return error.InvalidEnvironmentName;
    }
}

fn validateText(value: []const u8) !void {
    if (value.len == 0 or std.mem.indexOfAny(u8, value, "\x00\r\n") != null) return error.InvalidTextValue;
}
