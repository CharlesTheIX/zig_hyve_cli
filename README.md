# zig_hyve_cli

`zig_hyve_cli` orchestrates configured npm builds, Docker image builds and
pushes, and OpenShift image updates. It does not replace npm, Docker, or `oc`.
The CMS and webapp layout, scripts, images, credentials, and deployment targets
must be supplied in a JSON configuration file; no environment-specific values
are built in.

## Requirements

- Zig 0.17.0 or a compatible later version.
- `docker` for login, image builds, and image pushes.
- `npm` only when an application uses `next_build: "npm"`.
- `oc` for deployment.
- An absolute path to the configured monorepo.
- Explicit registry authentication and OpenShift targets.

## Configuration

Paths other than `monorepo` are relative to the monorepo root. The configured
application directory, Docker build context, and Dockerfile must exist.
`npm_working_directory` is also relative to the monorepo; if omitted, npm runs
in the application's `directory`.

The following example is illustrative only. Replace every placeholder with
values verified against the target monorepo and cluster.

```json
{
  "monorepo": "/absolute/path/to/monorepo",
  "command_timeout_seconds": 900,
  "registry": {
    "server": "registry.example.invalid",
    "auth": "existing"
  },
  "openshift": {
    "context": "configured-context",
    "namespace": "configured-project",
    "rollout_timeout_seconds": 300
  },
  "cms": {
    "directory": "apps/cms",
    "build_context": "apps/cms",
    "dockerfile": "apps/cms/Dockerfile",
    "image": "registry.example.invalid/team/cms:1.2.3",
    "next_build": "dockerfile",
    "deployment": {
      "resource_kind": "deployment",
      "resource_name": "cms",
      "container_name": "cms"
    }
  },
  "webapp": {
    "directory": "apps/webapp",
    "build_context": "apps/webapp",
    "dockerfile": "apps/webapp/Dockerfile",
    "image": "registry.example.invalid/team/webapp:1.2.3",
    "next_build": "dockerfile",
    "deployment": {
      "resource_kind": "deployment",
      "resource_name": "webapp",
      "container_name": "webapp"
    }
  }
}
```

Each image must use the configured registry and have a non-`latest` version tag
or a 64-digit `sha256` digest. The registry must enforce tag immutability if
version tags are used. CMS and webapp image references must be different.

Set `next_build` to `"npm"` only when the Next.js build should run outside the
Dockerfile. In that case, provide the exact `npm_script`; optionally configure
`npm_working_directory`, `npm_workspace`, and `npm_ci`. A configured workspace
is passed to the build as `npm run <script> --workspace <workspace>`. When
`npm_ci` is true, the npm working directory must contain `package-lock.json` or
`npm-shrinkwrap.json`. Set `next_build` to `"dockerfile"` when the Dockerfile
performs the Next.js build; npm options are then not accepted.

For registry credentials, set `"auth": "credentials"` and configure
`username_env` and `password_env` to the names of environment variables. Set
the actual credential values in the environment, not in the JSON file. The
password is passed to Docker over stdin. With `"auth": "existing"`, the user
must have an appropriate Docker authentication context already configured.

The command timeout must be at least as long as the rollout timeout. Deployment
resource kinds currently support `deployment`, `deploymentconfig`, and `dc`.
Both application deployment resources and container names must be configured.

## Usage

Build the executable:

```sh
zig build
```

Show supported options:

```sh
zig build run -- --help
```

Validate a configuration and print the commands for a build without executing
them:

```sh
zig build run -- --config ./pipeline.json --stage build --dry-run
```

Stage names are `login`, `build`, `push`, and `deploy`. `--stage` may be
specified more than once or may contain a comma-separated list. `push` requires
`build` in the same invocation; `deploy` requires both `build` and `push`.
Credentials mode additionally requires `login` before `push`. Registry
authentication using an existing Docker context does not require the login
stage.

`--dry-run` reads and validates configuration and local paths, then prints the
planned commands. It does not check tools, read credential values, log in,
build, push, deploy, or otherwise mutate state.

**Mutating invocation:** Once configuration, credentials, and targets have
been reviewed and the operation is approved, run the explicitly selected
stages, for example:

```sh
zig build run -- --config ./pipeline.json --stage login,build,push,deploy
```

Only run a mutating invocation when the configured registry and OpenShift
target are the intended ones. The CLI does not change the active `oc` context,
retry mutations, delete resources, or roll back deployments.

## Execution and failures

Required executables are checked before pipeline mutations. Child processes use
argument arrays and explicit working directories; stdout and stderr are
drained but not printed. Failures report the stage and exit status without
echoing command output that might contain credentials. Commands have a bounded
timeout, and OpenShift rollout status also uses the configured rollout timeout.

The pipeline stops after a failed dependency. CMS and webapp operations are
sequential: if one succeeds and the other fails, the CLI reports partial
completion. A successful image update command is not considered a successful
deployment until its rollout completes. Deployments are not atomic and no
automatic rollback is attempted.

## Validation and target

The local scaffold and implementation can be checked with:

```sh
zig build
zig fmt --check build.zig src
zig build run -- --help
```

No tests are added or run. Cross-compilation and Ubuntu runtime verification
remain pending confirmation of the deployment CPU architecture and libc
requirements.
