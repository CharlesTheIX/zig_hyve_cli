# Project Implementation Plan

## Goal and constraints

Build `zig_hyve_cli` into a configurable Zig CLI that orchestrates builds,
container image publication, and OpenShift deployment for a separate monorepo
containing a CMS and a web application.

- Treat the current repository as a scaffold, not as an existing pipeline.
- Keep orchestration logic reusable outside the CLI entry point.
- Use the Zig version installed in the development environment and APIs it
  supports; the package currently declares a minimum of Zig `0.17.0`.
- Target Ubuntu Linux, but do not assume a CPU architecture or libc choice until
  those are confirmed.
- Do not add tests. Use builds, formatting checks, safe CLI checks, and
  explicitly approved runtime exercises for validation.
- Do not perform live registry logins, image pushes, or cluster mutations during
  development without explicit approval.

## Required inputs before pipeline execution

Collect and confirm these values rather than inventing project-specific
defaults:

- The external monorepo location and CMS/webapp directories.
- Workspace layout, lockfile type, and the actual install/build scripts for
  each application.
- Whether each Next.js build runs in npm or inside its Dockerfile.
- Dockerfiles and build contexts, registry host, image names, and immutable tag
  or digest strategy.
- The approved credential source and whether an existing Docker login context
  is expected.
- OpenShift context/cluster, project or namespace, target resource names, and
  deployment strategy.
- The acceptable rollout timeout and required Linux architecture/libc target.

Do not treat the pipeline as runnable until the inputs needed for the requested
stages are configured and validated.

## Stages

### Stage 1 — Confirm toolchain and baseline

- Inspect the installed Zig version and confirm it can build this package.
- Record the intended Ubuntu architecture and libc requirements before choosing
  a cross-compilation target.
- Run the existing scaffold build and formatting check to establish a baseline.
- Keep the existing package dependency-free unless a concrete requirement
  justifies a dependency.

**Complete when:** The scaffold builds with the installed compiler, the target
requirements are recorded, and baseline issues are understood.

### Stage 2 — Define configuration and CLI contract

- Decide how configuration is supplied and documented before implementing
  options; do not assume application paths, scripts, registries, or OpenShift
  resources.
- Define explicit stage selection for registry login, application/container
  builds, image pushes, and deployment.
- Define validation rules for required and mutually dependent configuration.
- Make dry-run behavior explicit: it may display safe planned operations, but
  must not authenticate or mutate external state.
- Specify exit behavior, partial-completion reporting, and secret-redaction
  requirements.

**Complete when:** Every stage has a documented set of required inputs and
invalid or incomplete configurations are rejected before external mutations.

### Stage 3 — Replace scaffold CLI behavior

- Remove placeholder greeting, argument logging, and sample output.
- Implement argument parsing and help/usage output for the agreed CLI contract.
- Route parsed requests into reusable library code rather than embedding
  pipeline logic in `main.zig`.
- Keep errors actionable and avoid printing credentials or full environments.

**Complete when:** The executable reports its usage and validates CLI-level
input without running external commands.

### Stage 4 — Add configuration model and validation

- Represent monorepo/app paths, Docker build inputs, image references, registry
  authentication source, OpenShift target, selected stages, and timeout in
  typed configuration.
- Validate paths and required values; do not add environment-specific defaults.
- Require fully qualified, separate CMS and webapp image references and a
  consistent immutable tag/digest strategy.
- Validate that requested stages have all prerequisites, including
  authentication where required.
- Ensure deployment references the exact image references that were pushed.

**Complete when:** The configuration layer can produce a validated execution
plan or a clear error without contacting Docker, npm, or OpenShift.

### Stage 5 — Build command planning

- Inspect the configured external monorepo's workspace layout, lockfiles, and
  package scripts before defining npm commands.
- Use `npm ci` only when a compatible lockfile is present and the configured
  workflow calls for an install.
- Determine per application whether Next.js is built by npm or by its
  Dockerfile; prevent duplicate builds.
- Construct commands as executable/argument arrays with explicit working
  directories. Never compose shell strings or invoke `sh -c`.
- Keep CMS and webapp commands and image references distinct.

**Complete when:** A validated request can be translated into ordered commands
with explicit executable, arguments, working directory, and safe environment
inputs.

### Stage 6 — Implement external process execution

- Create a small process runner with a clear interface that can be used by the
  orchestration layer.
- Pass executable and argument arrays and explicit working directories to
  `docker`, `npm`, and `oc`.
- Safely handle stdin, including closing it after writes; drain stdout and
  stderr without deadlocks and bound or stream captured output.
- Wait for child completion, release owned resources, and treat spawn errors,
  nonzero exits, signals, and timeouts as failures.
- Propagate cancellation and clean up child processes.
- Redact sensitive values from diagnostics; never print all environment
  variables or credential-bearing output.

**Complete when:** A command's result or failure is surfaced to the caller
without secret leakage, deadlock, or leaked child-process resources.

### Stage 7 — Implement stage orchestration

- Preflight all requested configuration and required executables before
  mutating external state.
- Preserve the dependency order: authenticate before operations requiring it,
  build before push, and push before deploy.
- Stop dependent stages after a failure and identify the failed stage.
- Track CMS and webapp results separately so a one-app failure is reported as
  partial completion rather than as an atomic pipeline failure or success.
- Do not automatically retry pushes or deployment mutations.
- Keep each stage independently selectable only when its prerequisites are
  satisfied.

**Complete when:** The orchestrator executes only requested, valid stages in
dependency order and reports failures and partial completion accurately.

### Stage 8 — Implement safe registry authentication

- Use the configured credential source or an explicitly approved existing
  authentication context; never log in implicitly.
- When using username/password authentication, provide the password through
  `docker login --password-stdin`, not command arguments.
- Ensure dry-run skips login and does not reveal credentials.
- Avoid printing credential-bearing command output.

**Complete when:** Login is explicit, securely supplied, excluded from dry-run,
and failures identify the authentication stage without exposing secrets.

### Stage 9 — Implement container builds and image pushes

- Build CMS and webapp images separately using their configured Dockerfiles and
  contexts.
- Avoid a second Next.js build when the configured Dockerfile already performs
  it.
- Tag images with the agreed immutable version or digest strategy.
- Push only after successful builds and required authentication.
- Record the exact fully qualified image references for subsequent deployment.

**Complete when:** Each configured app image can be built and pushed in order,
and a failed build prevents its push.

### Stage 10 — Implement OpenShift deployment and rollout checks

- Use `oc` only for the configured context/cluster and project or namespace.
- Make resource names and deployment strategy explicit; do not silently change
  the active cluster context.
- Deploy the exact references pushed in the preceding stage.
- Wait for rollout completion with a bounded, configured timeout.
- Treat rollout timeout or failure as deployment failure; command submission
  alone is not success.
- Do not add deletion, automatic rollback, or production defaults.

**Complete when:** Deployment is limited to the configured target and reports
success only after the rollout completes.

### Stage 11 — Validate locally without tests

- Run `zig build`.
- Run `zig fmt --check build.zig src`.
- Run the CLI's help and configuration-validation paths without external
  mutations.
- Exercise dry-run only after confirming it cannot log in, build, push, deploy,
  or otherwise mutate state.
- Do not add or run tests as part of this plan.
- Do not use live credentials or mutate registry/cluster state without explicit
  approval.

**Complete when:** Build and formatting checks pass and safe CLI paths behave as
documented. Any runtime checks requiring external systems remain gated on
approval.

### Stage 12 — Verify Ubuntu delivery and document usage

- Cross-compile for the confirmed Ubuntu architecture/libc target.
- Treat cross-compilation as an artifact check, not proof of runtime behavior.
- Arrange an Ubuntu runtime exercise for process handling and CLI behavior;
  keep registry and cluster mutations separately approval-gated.
- Document prerequisites, configuration, stage dependencies, dry-run limits,
  exit behavior, partial completion, timeouts, and safe examples without
  secrets.
- Document only options and stages that have actually been implemented.

**Complete when:** The Ubuntu artifact is verified for the agreed target and
usage documentation matches implemented behavior and operational safeguards.

## Dependency overview

1. Toolchain and target confirmation precede implementation and release checks.
2. CLI contract and configuration validation precede command planning.
3. Command planning precedes process execution and orchestration.
4. Authentication precedes authenticated builds/pushes as configured.
5. Builds precede pushes; successful pushes precede deployment.
6. Rollout verification is part of deployment success, not an optional
   postscript.
7. Documentation and Ubuntu delivery checks follow the implemented behavior.
