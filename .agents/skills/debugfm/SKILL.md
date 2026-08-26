---
name: debugfm
description: >-
  Diagnose and safely recover Firstmate fork, remote, default-branch, worktree, branch-base, pull-request, validation, and push-target conflicts.
  Use when the captain invokes /debugFM or /debugfm, or asks to debug a Firstmate fork/worktree branch conflict like the Handy helper incident.
user-invocable: true
metadata:
  internal: true
---

# debugFM

Use `/debugfm` as the portable lowercase invocation.
Treat `/debugFM` as the captain-facing alias whenever the active harness accepts mixed-case skill names.
This skill is the single owner of Firstmate fork, worktree, branch-base, validation, and push-target recovery.

## Non-negotiable boundaries

- Never force push.
- Never discard unlanded work.
- Never stash, clean, reset, or work around a safety refusal.
- Never merge a pull request without the captain's explicit instruction.
- Never modify a project worktree from firstmate except through a path authorized by `AGENTS.md` hard rule 1.
- Never treat a successful fetch, diagnosis, or validation as authority to write a remote or move the primary Firstmate checkout.
- Never change a shared remote configuration without first accounting for every linked worktree that uses that repository.
- Preserve every existing branch and dirty worktree until the intended changes are safely represented on a separate branch or landed remote.

## Start an isolated diagnosis

1. Load `diagnostic-reasoning` before scoping the incident.
2. Load `harness-adapters` before dispatching the diagnostic worker.
3. Start the worker in a clean isolated Firstmate worktree and require it to prove that its physical top-level path differs from the primary Firstmate checkout before it makes any change.
4. Prefer Codex `gpt-5.5-sol` at medium effort when the Codex catalog for the active account proves that model is supported.
   If the catalog rejects or omits that model, stop and report the exact unsupported-model evidence, recommend `gpt-5.6-sol` at medium effort, and continue only after the captain accepts that fallback.
   Never silently substitute a model.
5. Give the worker the primary Firstmate checkout path, the affected task worktree path, the expected fork, the expected upstream repository, the affected branch, the expected base branch, any pull request URL, and the current validation run identity when known.
6. Keep diagnosis read-only until the worker has inventoried both checkouts and classified the conflict.

## Inspect both sides

Inspect the primary Firstmate checkout and the affected task worktree separately.
For each, record its physical top level, cleanliness, current branch or detached state, HEAD, default branch, branch upstream, and linked-worktree identity.
Then inspect the repository-wide facts shared by those worktrees:

- every remote's fetch URL and push URL;
- the intended fork and upstream repository identities;
- the fetched fork default branch and upstream default branch tips;
- the local default branch tip and its configured upstream;
- the affected branch tip, merge base with the intended fork default branch, and commits unique to each side;
- the exact commit and file diff that the pull request would contain against its declared base;
- the pull request's head repository, head branch, base repository, and base branch through `gh-axi`;
- no-mistakes initialization, structured branch ownership, configured fork or push target, current run state, and the last validation or push failure;
- whether another live worker or validation run still owns the branch.

Fetch the named remotes without pruning before comparing remote-tracking refs.
A fetch updates evidence only and does not make a local branch current.
Do not infer repository identity from a remote name such as `origin` or `upstream`.
Use the actual fetch URL, push URL, and pull-request repositories.

## Classify the conflict

State which of these conditions is proven, which is ruled out, and what remains uncertain:

- **Fork drift** - the intended fork default branch and upstream default branch differ.
  Direction matters: behind, ahead with intentional commits, or diverged are different recovery cases.
- **Wrong remote** - a fetch URL, push URL, branch upstream, pull-request head, or no-mistakes push target names a repository other than the intended one.
- **Stale local default branch** - the intended remote default branch is ahead of the local default branch while the local branch has no unique commits.
- **Branch based on the wrong default branch** - the affected branch's merge base is not the intended fork default branch tip or expected ancestor.
- **Unrelated commits bundled into the pull request** - the base-to-head commit set or diff includes changes outside the task's accepted intent.
- **Validation or push-target failure** - the branch and base are correct, but branch custody, a stopped shared validation service, credentials, target configuration, a non-fast-forward remote, or a rejected push prevents delivery.

Do not collapse these into one generic divergence diagnosis.
Several can be true at once, and each needs separate evidence and recovery.

## Choose the safe recovery

Before any write, present the diagnosis, the exact local and remote refs that would move, the preserved work, and the captain authority required.

### Fork or default-branch drift

- If the fork is only behind upstream and upstream is the intended source, ask for explicit authority to fast-forward the fork default branch.
- If the fork is ahead with intentional commits, do not replace it with upstream.
  Treat the fork as the branch source after verifying the captain intends those commits to be canonical there.
- If fork and upstream diverged, stop for a repository-history decision.
  A merge, rebase, force push, or history replacement is never an automatic recovery.
- Advance a clean local default branch only by fast-forward.
  If it is dirty, has unique commits, is detached with unique work, or cannot fast-forward, leave it untouched and report the evidence.

### Wrong remote or push target

- Correct only the misconfigured layer that evidence identifies: remote URL, push URL, branch upstream, pull-request head, or no-mistakes fork target.
- Remember that linked worktrees normally share repository configuration.
  Prefer an explicit intended destination for a one-time authorized push over casually rewriting a shared remote.
- Re-read structured validation status after correcting the target.
  If a validation run owns the branch, follow its published custody or retry action rather than editing around it.

### Wrong-base branch or bundled commits

- Preserve the affected branch exactly as evidence.
- Create a new clean isolated worktree and a new recovery branch from the current intended fork default branch.
- Replay only the task's intended commits or changes onto that recovery branch.
  Verify the resulting base-to-head commit list and diff contain no unrelated work before validation.
- Do not rebase, reset, or rewrite the preserved affected branch as a shortcut.
- If the affected worktree is dirty, first account for every uncommitted change and leave it in place.
  Recovery proceeds in the separate worktree without borrowing or deleting those files.

### Validation or delivery failure

- Separate repository correctness from service availability.
  A stopped shared validation service can block a correct branch without proving any Git problem.
- Do not start a competing run, bypass the gate, or hand-edit while no-mistakes owns the branch.
- Follow the version-matched `no-mistakes axi` status and help output for retry or custody recovery.
- A credential or permission failure requires the named credential or target correction, not a different remote chosen by guesswork.

## Authorized fork sync and branch retry

Push a fork default-branch sync only after the captain explicitly authorizes that exact repository and branch.
Before the push, prove the local source tip is the intended history, the remote destination is the intended fork, the update is fast-forward, and no unlanded work is being moved or discarded.
Use an ordinary non-forced push and let a non-fast-forward refusal stop the operation.
Fetch the destination afterward and verify its default-branch tip matches the intended commit.

Retry the affected work only from the verified current fork default branch.
Use a new isolated recovery branch when the old branch carried the wrong base or unrelated commits.
Run validation against the corrected branch and intended fork target, then open or update the pull request only when its head, base, commit set, and diff are correct.
Never merge it without a separate explicit captain instruction.

## Restore the primary Firstmate checkout

When recovery is complete, inspect the primary Firstmate checkout again.
Return it to the repository's default branch only when it is clean and switching branches cannot strand a detached commit or uncommitted change.
Verify the completed recovery branch remains named and reachable before switching.
If the primary checkout is dirty or contains unreferenced work, leave it untouched and report that restoration is incomplete rather than forcing the requested end state.

## NixOS or VM clone decision

The NixOS or VM clone only needs to fetch and fast-forward from the updated fork when all of these are true:

- the fork default branch already contains the intended canonical history;
- the clone's configured source is that fork;
- its local default branch is clean, has no unique commits, and can fast-forward;
- no upstream-only commit is required for the affected task.

Upstream-to-fork synchronization is needed first when upstream contains intended commits absent from the fork and the captain wants the fork to incorporate them.
If the fork contains intentional commits absent from upstream, the clone should pull the fork rather than overwrite it from upstream.
If fork and upstream diverged, stop for a history decision before changing either one.

## Historical example pattern

The Handy helper incident is example evidence, not a claim about current repository state.
Its worker branch was based on a local Firstmate default branch that held 35 commits absent from the intended `podledges/firstmate` fork default branch, while the push destination was wrong or ambiguous between `kunchenguid/firstmate` and `podledges/firstmate`.
Once the intended fork default branch received that local history through an explicitly authorized ordinary push, future work needed to fetch that fork and branch from its current default branch.
The Handy retry could still fail independently if the shared validation service was stopped, which illustrates why repository diagnosis and validation-service diagnosis remain separate.

## Report

Report the proven classification, the evidence for each relevant ref and repository, the work preserved, every authorized ref movement, the corrected branch and pull request, validation status, and whether the primary checkout returned safely to its default branch.
End with one plain NixOS or VM instruction: either pull the updated fork, sync upstream into the fork first with explicit authority, or stop because the histories diverged.
