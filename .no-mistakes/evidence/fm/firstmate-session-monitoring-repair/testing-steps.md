# Targeted Pi replacement-session verification

## Automated checks

Ran eight existing executable tests from `tests/fm-pi-watch-extension.test.sh` by copying its definitions to a temporary same-directory runner and invoking only:

- `test_pi_redundant_tool_call_is_owned_noop`
- `test_pi_actionable_close_starts_single_successor_before_delivery`
- `test_pi_actionable_close_rechecks_session_lock`
- `test_pi_arm_distinguishes_session_lock_ownership`
- `test_pi_session_transition_generation_owner`
- `test_pi_session_start_first_cycle_eligibility`
- `test_pi_first_cycle_waits_for_startup_owner`
- `test_pi_process_exit_cleanup_stops_arm_child`

Command: `TMPDIR="$PWD/.test-tmp" bash tests/.local-pi-targeted.test.sh`.
These passed, including real startup-lock acquisition for absent/stale locks in both extension orders and restored resume/continue routes.

Ran `TMPDIR="$PWD/.test-tmp" bash tests/fm-sessionstart-nudge.test.sh`.
The initial attempt failed because NixOS does not supply dirname under this test's default `/usr/bin:/bin` PATH.
Retried successfully with the supported override: `TMPDIR="$PWD/.test-tmp" FM_TEST_BASE_PATH=/run/current-system/sw/bin:/usr/bin:/bin bash tests/fm-sessionstart-nudge.test.sh`.

Ran `TMPDIR="$PWD/.test-tmp" bash tests/fm-supervision-instructions.test.sh` successfully.

Regression check: exported `.pi/extensions/fm-primary-pi-watch.ts` from base commit `dc5ec4cb66aece65f69e5217fc6c9e51c42e5b7b` into `.test-tmp/base-watch.ts`, selected that file through the fixture's EXT variable, and ran only `test_pi_session_start_first_cycle_eligibility` using `TMPDIR="$PWD/.test-tmp" bash tests/.local-pi-base.test.sh`.
It failed as expected because no automatic first cycle appeared; the same selector passed with the target extension.

## Real watcher / inbox evidence

Command: `TMPDIR="$PWD/.test-tmp" bash tests/.local-pi-evidence.test.sh`.
The temporary runner reused `install_pi_watch_extension_fixture` and `fm_test_tmproot` from the existing test, created a disposable git primary under the worktree's `.test-tmp`, copied tracked bin scripts, both Pi extensions and supervision protocols, and replaced only bootstrap and deferred network with no-op scripts to avoid external operations.
It then invoked the attached `pi-real-watcher-check.mjs` with FM_HOME and FM_ROOT_OVERRIDE set to that disposable primary, PI_CODING_AGENT=true, FM_PI_HARNESS=pi, FM_POLL=1, FM_SIGNAL_GRACE=0, FM_CHECK_INTERVAL=999999, and FM_HEARTBEAT=999999.
Pi registration/event dispatch and message rendering dependencies are test doubles, not a live Pi TUI.
The session-start router, session lock, completion receipt, arm child, watcher, inbox CLI, persisted queue and lifecycle ledger are real.

The driver simulated a restored `--continue` session with a stale lock, dispatched session_start then resources_discover, observed automatic watcher startup without a tool call, retained the PID across compaction/discovery, submitted a note through `fm-inbox.sh note`, captured the operational notification only after a live successor existed, inspected the durable queue and lifecycle ledger, read the note through `fm-inbox.sh drain`, and shut down the isolated session.
The final run succeeded.
Two exploratory runs corrected driver assumptions: a preseeded working status legitimately triggered an unrelated successor, and the notification uses `check: rearm-resurface` while the inbox-specific reason remains in the durable queue.
Neither required a product change.

Artifacts: `pi-resume-real-watcher.txt` contains observed notification, CLI output and persisted lifecycle state; `pi-resumed-startup-digest.txt` is the actual emitted startup message.
No screenshot is applicable to this non-visual extension lifecycle change; the agent-facing generated text is captured directly.
No Herdr lifecycle test, live worker action, global configuration change, broad test suite, linter, formatter, static analysis or pipeline control was performed.
Temporary runners and fixtures were removed after verification; no source changes were needed.
