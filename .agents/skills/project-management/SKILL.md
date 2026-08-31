---
name: project-management
description: >-
  Agent-only procedure for Firstmate project management.
  Use before adding, creating, removing, or initializing a project, or configuring a repository's no-CI declaration.
  Cloning or registering a project is add intake and uses the same trigger.
  Owns project add, create, clone, remove, initialization, no-CI declaration, registry, delivery-mode, autonomy, and outward-consent decisions.
user-invocable: false
metadata:
  internal: true
---

# project-management

Use this procedure before adding, creating, removing, or initializing a project, or configuring a repository's no-CI declaration.
Cloning or registering a project is add intake and uses the same trigger.
This skill is the single owner of Firstmate's project-management procedure.
It does not replace `secondmate-provisioning`, which owns project clones inside persistent secondmate homes.

## Preconditions and registry

Projects live flat under `projects/`, and `data/projects.md` is the private fleet registry.
Use the registry format and parser contract owned by the header of `bin/fm-project-mode.sh`.
Keep each registry description useful for identifying the project, but keep delivery posture, captain-private state, and detailed project knowledge in their existing designated homes.
Do not turn the registry into project documentation.

Before adding, cloning, creating, or registering any project in the main home, inspect the authoritative `data/secondmates.md` routing table and judge every existing natural-language `scope:` against the proposed project or domain.
Apply `AGENTS.md` section 7's authoritative secondmate routing rules; if an existing scope owns that domain, route the new-project operation or work there instead of creating or registering a duplicate main-home clone.
Absence from the main `data/projects.md` registry is never evidence that no second mate owns the domain.
If the owning second mate cannot accept the route, report that concrete blocker or obtain an explicit captain redirection rather than silently duplicating the project in the main home.

Resolve the project name, destination, delivery posture, and autonomy posture before changing local or remote state.
Keep a newly added clone and its registry entry consistent, and roll back only artifacts created by the incomplete operation when a later initialization step fails and that rollback is safe.
Do not overwrite or repurpose an existing path.

After resolving the local project name, run `bin/fm-handy-custom-words.sh <project-name>` before completing an add, create, clone, or register operation when the Handy settings file exists or the captain explicitly configured an alternate path.
Use `--settings <path>` for an explicit nonstandard path, or `HANDY_SETTINGS_PATH` when invoking the helper.
If the settings file is unavailable, record a concise non-blocking note and complete the project operation; a malformed or incompatible file should be reported as a Handy integration problem without rolling back an otherwise successful project add.

## Delivery posture

The registry records the project's standing posture, which is the captain's default for the work rather than any task's answer; `AGENTS.md` section 7 owns how each task's concrete mode and yolo are resolved at intake and passed explicitly to the brief, the spawn, and any promotion.
Choose that posture when adding or creating the project:

- `no-mistakes` runs the full validation pipeline before a PR.
- `direct-PR` pushes and opens a PR without the no-mistakes pipeline.
- `local-only` has no required remote or PR and lands only through the approved local fast-forward path.
- `no-mistakes-prod-only` is a conditional policy rather than one flat mode: genuinely internal-only tooling, automation, contributor or operator process, and release or submission work ships `direct-PR`, while product-facing, mixed, and uncertain work ships `no-mistakes`.

`no-mistakes-prod-only` is the default for a newly added or created remote-backed project when the captain specifies nothing, and a project with no remote defaults to `local-only`.
State that resolved default while confirming the source, local name, and posture instead of asking the captain to choose from scratch, and record a flat mode instead whenever they ask for one.
Existing registry entries keep the meaning they already have and are never migrated or reinterpreted, so a legacy entry with no bracket stays `no-mistakes`.
Registering a conditional policy is a one-time choice and never requires classifying any change; the per-task surface classification happens at each task's intake, and internal-only is never inferred from file location or project name.

The optional `+yolo` posture changes merge authority only and does not change the delivery mode.
Default it off for every project and every posture, and enable it only on the captain's explicit instruction.
`AGENTS.md` section 7 owns the merge-authority contract.

## Add or clone an existing project

Confirm the source URL, local project name, delivery posture, and autonomy posture, stating the resolved default for each rather than asking the captain to invent one.
Clone into `projects/<name>` and add the registry entry only after the destination is known to be unused.
Run the Handy custom-words helper described in Preconditions for the resolved local project name as part of the add flow.
A `no-mistakes` or `no-mistakes-prod-only` project must have an `origin` remote and must complete the initialization procedure below, because a conditional policy's product-facing work runs the pipeline while its internal-only work still takes the direct PR.
A `direct-PR` project needs an `origin` remote but skips no-mistakes initialization.
A `local-only` project may have no remote and skips no-mistakes initialization.

## Create a project

Creating a GitHub repository is outward-facing.
Before making that remote change, propose the repository name, owner or organization, visibility, and delivery posture, defaulting visibility to private and the posture to `no-mistakes-prod-only`, then obtain the captain's explicit consent for those exact values; a stated default never replaces that consent.
Use `gh-axi` for the approved GitHub operation and consult its current help rather than relying on remembered flags.
After remote creation succeeds, clone it locally, add the registry entry, apply the Preconditions helper step, and initialize it according to its delivery posture.

For a purely `local-only` project, create a local Git repository under its unused `projects/<name>` path, add the registry entry, apply the Preconditions helper step, and make no GitHub call.
The captain's request to create that local project authorizes this local initialization, but it does not authorize an unmentioned remote repository.

## Initialize

Run no-mistakes initialization only for `no-mistakes` and `no-mistakes-prod-only` projects:

```sh
cd projects/<name> && no-mistakes init && no-mistakes doctor
```

Initialization configures the local gate and does not vendor a no-mistakes skill into the project.
Do not create a commit merely because initialization ran.
If doctor reports an environment, authentication, or daemon problem, resolve that blocker before dispatching work and never restart the shared daemon from a project operation.

## Repository no-CI declaration

A no-CI declaration is a narrow repository configuration for a repository that genuinely has no hosted workflow or whose provider cannot register checks during a declared outage.
It is not a task flag, a delivery mode, a registry annotation, or permission to skip the CI step.
Never use `--skip ci` as a substitute.

Obtain the captain's explicit approval for the named repository, the concrete reason, and whether the declaration is temporary before proposing the project change.
The project's tracked `.no-mistakes.yaml` on its trusted default branch is the sole owner of the declaration, using the upstream `no_ci: true` field.
Do not copy it into `data/projects.md`, task metadata, a feature-branch-only configuration, or a global no-mistakes configuration.
A declaration introduced on a feature branch cannot authorize that branch's own empty check result, so never report it as active before the configuration change lands on the default branch.
If unavailable hosted CI prevents that configuration PR from completing its ordinary path, escalate that one concrete bootstrap decision to the captain rather than silently skipping CI or weakening the project's standing policy.

After the declaration is active, ship ordinary work through the unchanged `no-mistakes` path without a skip flag.
Review, targeted tests, documentation, lint, push, and PR creation still run, and any checks the forge does report must still pass.
Only a zero-check result backed by the trusted declaration is ready for captain review.
Resolve yolo off for every task using the declaration, regardless of the registry's standing posture, because the captain must approve each no-CI merge.
For a temporary provider outage, ship removal of `no_ci: true` as soon as check registration is restored.

## Remove

Project removal is destructive.
First obtain the captain's explicit removal decision, then inspect the current digest and authoritative repositories for in-flight or queued work, registered secondmate clones, linked worktrees, dirty files, unpushed commits, and any other unlanded work.
If any dependency or unlanded work exists, stop and report it before changing anything.
Never issue a raw removal command from Firstmate.
Once that preflight confirms none of the above and the captain's approval is concrete, AGENTS.md hard rule 1's captain-approved project operation exception authorizes firstmate to remove the clone directly and update its registry entry to match.
When a clone has already been removed through an approved removal, or the registry is provably stale because no clone exists, remove its registry line so navigation matches reality.
