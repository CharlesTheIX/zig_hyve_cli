# Agent guidance

## Project purpose and current state

Build `zig_hyve_cli`, a Zig executable for Ubuntu Linux that automates pipeline
stages for a separate monorepo containing a CMS and a web application, both built
with TypeScript and Next.js. The CLI orchestrates external tools; it does not
reimplement Docker, npm, or the Red Hat OpenShift CLI (`oc`).

The repository currently contains a Zig scaffold, not a working pipeline runner.
Treat the workflow below as the intended direction, not existing functionality.
Do not assume application paths, npm scripts, registry details, or deployment
resources that have not been configured or supplied.

## Repository and toolchain

- [build.zig](./build.zig) defines the executable, library module, run step, and tests.
- [build.zig.zon](./build.zig.zon) declares a minimum Zig version of `0.17.0`
  and currently has no external dependencies.
- [src/main.zig](./src/main.zig) is the CLI entry point.
- [src/root.zig](./src/root.zig) is the reusable library module.
- Check the installed Zig version and use APIs supported by the actual compiler.
  Do not copy older Zig process or I/O APIs without checking compatibility.
- Keep orchestration logic testable outside the CLI entry point. Prefer the
  standard library and small modules over new dependencies or frameworks.
- Ubuntu Linux is the deployment target; the development host may be macOS.
  Confirm CPU architecture and libc requirements before selecting a Linux target.
  Do not assume a host-native build is a Linux artifact.

## Intended pipeline

Support explicit stages for registry login, application/container builds, image
pushes, and OpenShift deployment. Preserve dependency order: build before push,
push before deployment, and authentication before operations that require it.
If stages can run independently, validate their prerequisites explicitly.

- Execute npm commands in the configured monorepo or application working
  directory. Inspect its workspace layout, lockfile, and package scripts first.
  Use `npm ci` for reproducible CI installs when a compatible lockfile exists;
  do not invent script names or assume both apps have identical build steps.
- Determine whether Next.js builds occur inside Dockerfiles or through npm before
  invoking Docker. Avoid inadvertently building each application twice.
- Build and push separate, fully qualified CMS and webapp image references.
  Prefer immutable version tags or digests and deploy the exact images pushed.
- Use `oc` for configured OpenShift operations. Make the cluster/context,
  namespace/project, resource names, and deployment strategy explicit.
- Check rollout completion with a bounded timeout. A successful command submission
  alone is not deployment success.
- Stop dependent stages on failure. Report partial completion when one application
  succeeds and the other fails; do not imply atomic deployment or automatic rollback.

## External command execution

- Invoke `docker`, `npm`, and `oc` with executable/argument arrays and explicit
  working directories. Do not construct shell command strings or use `sh -c`
  for ordinary command execution.
- Keep command construction separate from process execution so tests can inspect
  arguments, working directories, environment, and stdin without running tools.
- Check required tools and stage configuration before mutating external state.
  Do not install tools, change cluster context, or log in implicitly.
- Stream or safely bound process output; drain stdout and stderr without deadlocks.
  Close stdin after writing, wait for children, and release owned resources.
- Treat spawn errors, nonzero exits, signals, and timeouts as failures. Identify
  the failing stage and return a nonzero CLI exit status without exposing secrets.
- Propagate cancellation and clean up children. Do not automatically retry pushes
  or deployment mutations without establishing that repetition is safe.

## Configuration and operational safety

- Keep monorepo paths, app locations, Dockerfiles/build contexts, registry,
  image names/tags, and OpenShift targets configurable. Validate required values
  before execution; do not hardcode environment-specific defaults.
- Never commit credentials or include secrets in arguments, logs, errors, or
  dry-run output. Send registry credentials through `docker login --password-stdin`;
  use approved secret/environment sources or existing authentication contexts.
- Do not print full environments or credential-bearing command output. Redact
  sensitive values before displaying diagnostics.
- A dry run must not log in, build, push, deploy, or otherwise mutate state.
- Do not execute live logins, pushes, deployments, resource deletion, or other
  external mutations while developing or testing without explicit user approval.
- Do not add destructive cleanup, automatic rollback, or production defaults
  unless requested and designed with explicit safeguards.

## Validation and documentation

- Build: `zig build`
- Run the current entry point: `zig build run -- <args>`
- Test: `zig build test`
- Check formatting after Zig changes: `zig fmt --check build.zig src`
- Use these commands for the current scaffold; do not document proposed CLI flags
  as supported until they are implemented.
- Add unit tests for command construction, configuration validation, stage order,
  failure propagation, redaction, and dry-run behavior as those features are added.
  Use a fake command runner for pipeline tests; ordinary tests must not require
  Docker, registry credentials, a cluster, or network access.
- Verify Linux cross-compilation once the target is agreed. Cross-compilation alone
  does not verify runtime behavior; exercise process execution on Ubuntu as well.
- Update usage documentation alongside implemented stages and options, including
  prerequisites, configuration, exit behavior, and safe examples without secrets.
