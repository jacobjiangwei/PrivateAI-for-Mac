# PrivateAI Terminal Execution Design

- Status: Non-interactive Phase 1 accepted; PTY and coding-file operations pending
- Date: 2026-08-30
- Revised: 2026-09-04
- Scope: General-purpose local terminal execution for the PrivateAI macOS Agent
- Model-facing name: `terminal`
- Swift adapter: `PrivateAITools.TerminalTool` (`TerminalTool.swift`)

## Implementation Status

The first production proof is a real repository-development loop in this repository:

```text
inspect files -> edit files -> run a real build or test command
-> inspect the result -> correct the implementation -> verify the outcome
```

During development and end-to-end acceptance, a test may select the current
`PrivateAI-for-Mac` checkout or another isolated fixture. These paths are test
configuration, not product configuration. The shipped App starts in
`~/.privateAI/workspaces/default`; a user-selected folder replaces that filesystem root
for tasks that need broader local access.

The implementation is divided into these independently testable phases. Items 1, 2,
3, and the non-interactive portions of item 5 are implemented and verified. Items 4
and 6 remain pending.

1. Add an `ExecutionKit` Swift package containing versioned job contracts, a real
   pipe executor, persistent bounded logs, timeout, and process-tree cancellation.
   Use `swiftlang/swift-subprocess` for the pipe backend because it directly provides
   Swift Concurrency output sequences, explicit environment and working directory,
   process-group/session options, and cancellation teardown.
2. Add a separately executable worker using a versioned local protocol. The worker,
   not `LLMCore`, owns subprocess and file-descriptor lifecycle. Phase 1 is not
   accepted until cancellation kills descendants and a worker interruption produces
   an explicit terminal state.
3. Add `PrivateAITools.TerminalTool` with strict `run`, `wait`, and `stop` argument
  validation and structured results. Register it for ordinary conversations using the
  managed default workspace, or a user-selected replacement root, whenever privacy
  policy permits execution.
4. Add code-oriented local-resource operations for bounded repository discovery,
   range reads, search, and atomic structured edits. Shell commands remain available,
   but shell text replacement is not the primary file-editing contract.
5. Connect execution checkpoints and job cancellation to `AgentRuntime` and the App.
   The App shows the command, working directory, elapsed time, latest checkpoint,
   terminal status, and an immediate Stop control.
6. Add the PTY backend and App-owned interactive input channel. Secret input remains
   outside model messages, Tool arguments, conversation storage, and execution logs.

Phase 1 intentionally targets non-interactive repository work such as Git inspection,
builds, tests, scripts, package managers, and generated artifacts. PTY interaction and
protected input do not block that first usable loop, but the job and worker contracts
must leave room for them without changing model-facing job identity or lifecycle.

### Decided Behavior

- The first model checkpoint defaults to 60 seconds.
- A command that finishes before the checkpoint returns immediately.
- The execution layer continuously drains stdout and stderr and writes them to local
  logs. The 60-second interval limits model observation; it never pauses pipe reads.
- A running checkpoint returns bounded output produced since the prior observation,
  bounded stream tails, byte counts, elapsed time, and the stable job identifier.
- After a running checkpoint the process continues while the model decides whether to
  wait again, stop the job, or perform another action.
- A later wait may request 60, 120, or 300 seconds. Every job also has an independent
  wall-clock deadline.
- Tool completion, failure, timeout, worker interruption, and user cancellation bypass
  the checkpoint interval and become observable immediately.
- The user's Stop control terminates the process tree immediately; it never waits for
  the next model checkpoint.
- An absence of output is not treated as proof that a job is stuck and does not cause
  automatic termination.
- Checkpoint observations have their own bounded lifecycle budget. They do not consume
  the ordinary eight-call Tool budget in a way that abandons a still-running process.

### Phase 1 Policy

- Terminal is available in ordinary conversations whenever the signed worker is
  present. Its default filesystem root is `~/.privateAI/workspaces/default`.
- Choosing a folder changes the authorized filesystem root and allows autonomous
  commands in that folder without per-command confirmation. It does not enable or
  disable the terminal capability; returning to the managed workspace remains possible.
- The workspace is App-session state in Phase 1. Persisted per-conversation workspace
  binding remains part of the coding-agent phase.
- Document privacy mode does not advertise terminal, web, or Apple service Tools.
- The default wall-clock deadline is 1,800 seconds. Each stdout and stderr log is
  capped at 64 MiB, truncation is explicit, and completed job logs are retained for
  seven days by default.
- The worker permits at most one active job and retains at most 128 in-memory job
  handles. Worker transport requests have bounded response deadlines.
- Phase 1 commands must remain attached to the supervisor job. Commands that
  deliberately daemonize, call `setsid`, close inherited supervision handles, or are
  intended to persist after the Agent run are unsupported and are not advertised as a
  capability. Ordinary foreground commands and background descendants that remain in
  the supervised job are terminated on Stop, timeout, shell exit, worker interruption,
  and cold-start recovery. Persistent servers require a future explicit lifecycle and
  stronger isolation boundary.

### Phase 1 Acceptance Evidence

On 2026-09-04, an Apple Development-signed App build using the production
`ChatCoordinator.send()` path and the real `qwen3.8:27b-mlx` Ollama model received a
natural-language request to find the largest top-level item in the user-authorized
`~/Documents` workspace and suggest cleanup options without cleaning anything. The
model selected the production `terminal` Tool, the bundled signed worker executed a
real `du -sk` command, and the final persisted assistant answer reported the
independently measured ground truth:

```text
RESULT_PATH=/Users/jacob/Documents/Bitcomet
RESULT_BYTES=370280419328
```

The answer also contained separate read-only inspection and backup-only options. The
pre-run and post-run filesystem snapshots contained 937 records and were byte-for-byte
identical across path, type, logical size, allocated blocks, modification time, POSIX
mode, inode, and symbolic-link destination. This acceptance proves the current safe,
non-interactive path; it does not prove PTY or secret-input behavior.

A separate isolated coding demo used the same signed App, production natural-language
entry point, real Ollama model, Tool catalog, and bundled worker. Starting from an
empty temporary workspace, the Agent created `number_summary.py`,
`test_number_summary.py`, and `README.md`, ran six real terminal calls, and reported
all shell observations as succeeded. Independent validation then ran three `unittest`
cases successfully and verified this exact CLI output:

```text
count=3 total=6 min=-1 max=4
```

The repository worktree status was byte-for-byte unchanged by the demo. This proves a
minimal create-code-test loop through general terminal execution. It does not replace
the pending structured coding-file operations or establish full Claude Code/Copilot
feature parity.

## Product Contract

PrivateAI is a local Agent with real terminal capability. It can run the commands and command-line runtimes available to the user, including `zsh`, Git, Homebrew, Python, Node.js, Swift, package managers, builds, tests, scripts, pipelines, redirections, installers, and long-running processes.

Terminal execution is not a reduced code sandbox, a language-specific evaluator, or an executable allowlist. The model-facing name `terminal` is a gateway into a general-purpose local execution subsystem.

Local means that inference, orchestration, execution state, logs, and artifacts remain on the user's Mac without requiring a hosted PrivateAI service. Commands may use network services when the user and operating environment permit them.

## Capability and Evaluation Matrix

The terminal contract is organized around execution semantics rather than one example:

| Scenario family | Representative real operation | Required evidence |
|---|---|---|
| Filesystem inspection | enumerate and measure files | real paths and measurements; no unrequested mutation |
| File and code creation | create source and documentation | exact artifacts, independent content checks |
| Build and test | compile Swift or run a test suite | real compiler/test exit and expected output |
| Network diagnostics | DNS, ping, route tracing | host-level stdout/stderr, packet loss, visible hops, explicit blocked probes |
| Process inspection | inspect a live local process | real process output from the host |
| Failure | missing executable or nonzero command | structured failed status, exit code, bounded stderr |
| Long-running work | output before and after a checkpoint | continuous drain, stable job ID, successful wait or Stop |
| Lifecycle | timeout, cancellation, worker interruption | verified descendant cleanup and explicit terminal state |

Tool routing is evidence-based, not keyword-based. A network question can require
terminal evidence from this Mac, public information from `web`, native network state,
or a combination. Model eval prompts describe the user's goal without naming a Tool;
assertions judge whether the selected evidence and final answer satisfy that goal.

## Managed Execution Root

PrivateAI creates this directory on first execution:

```text
~/.privateAI/
    workspaces/
    jobs/
    logs/
    artifacts/
    state/
```

- `workspaces/` contains repositories, generated projects, and durable working trees managed by PrivateAI.
- `jobs/` contains request metadata and non-secret lifecycle state for active and completed executions.
- `logs/` contains complete bounded-by-storage execution logs. Model context receives only selected output tails and summaries.
- `artifacts/` contains retained outputs linked to conversations and execution receipts.
- `state/` contains versioned execution-service state needed for interruption recovery.

Every command defaults to a workspace or job directory beneath `~/.privateAI`. Relative paths resolve from that working directory. A caller may select another user-authorized working directory when product policy permits it.

`~/.privateAI` is the managed ownership and lifecycle root, not a security claim that a general-purpose shell cannot address paths outside it. Actual filesystem authority is determined by the execution process, App Sandbox or direct-distribution configuration, security-scoped bookmarks, macOS permissions, and explicit user authorization.

## Component Ownership

| Component | Responsibility |
| --- | --- |
| `LLMCore` | Provider-neutral model loop, tool proposal handling, execution events, cancellation propagation, and final tool-result delivery |
| `PrivateAITools.TerminalTool` | Model-facing schema, strict argument validation, and conversion between model calls and execution requests/results |
| `ExecutionKit` | Job lifecycle, pipe execution, process-tree cancellation, timeout, bounded logs, interruption recovery, and the planned PTY boundary |
| Execution worker | Runs commands outside the model process and reports versioned events over local IPC |
| macOS App | Command and progress UI, Stop control, workspace authorization, policy settings, and secure interactive input |

`LLMCore` must not import process, PTY, shell, AppKit, or authorization implementations. `TerminalTool` must not duplicate the execution engine.

## Model-facing Request

The primary operation accepts a complete shell command rather than a language-specific program:

```json
{
  "action": "run",
  "command": "brew install ffmpeg && ffmpeg -version",
  "working_directory": "~/.privateAI/workspaces/media-task",
  "checkpoint_seconds": 60,
  "timeout_seconds": 1800
}
```

The current non-interactive executor runs general shell work through `/bin/zsh -dfc` in
pipe mode. Disabling global and user startup files keeps the command environment bounded
to the explicit execution allowlist. Direct executable invocation may be added as an
optimization, but it must not replace or weaken full shell capability. PTY selection is
not yet advertised to the model.

The schema must not expose passwords, passphrases, tokens, private keys, or other secret values.

## Long-running Jobs and Checkpoints

Execution is a job, not a single `async throws -> String` function. Each job has a stable identifier and emits ordered events:

```swift
public enum ExecutionEvent: Sendable {
    case started(ExecutionStarted)
    case stdout(ExecutionOutputChunk)
    case stderr(ExecutionOutputChunk)
    case progress(ExecutionProgress)
    case artifact(ExecutionArtifact)
    case userInputRequired(ExecutionInputRequest)
    case finished(ExecutionResult)
}
```

The worker and service must preserve ordering within each output stream, drain stdout and stderr concurrently, and avoid blocking when a child process fills a pipe.

High-frequency output is drained into the local log without waking the model. The App
may coalesce presentation updates, but UI rendering must never control pipe drainage.
The `terminal` Tool returns information to the model at these boundaries:

- the process finishes, fails, times out, or is cancelled;
- the initial 60-second checkpoint is reached while the process is still running;
- a later model-requested wait checkpoint is reached;
- a meaningful artifact is produced;
- the user supplies a non-secret decision that changes execution.

At a running checkpoint the model receives a bounded observation and chooses a later
checkpoint or termination:

```json
{
  "action": "wait",
  "job_id": "01J...",
  "checkpoint_seconds": 120
}
```

```json
{
  "action": "stop",
  "job_id": "01J..."
}
```

The job continues while the model reasons after a running checkpoint. `wait` and
`stop` therefore re-check current job state before acting. A stop request that races
normal completion returns the observed completed result rather than claiming that a
finished process was cancelled.

The final model-visible result is structured and bounded:

```json
{
  "status": "succeeded",
  "job_id": "01J...",
  "command": "swift test",
  "working_directory": "/Users/user/.privateAI/workspaces/project",
  "exit_code": 0,
  "duration_seconds": 42.8,
  "stdout_tail": "Test run with 38 tests passed",
  "stderr_tail": "",
  "output_truncated": true,
  "log_artifact": "artifact://execution/01J/log"
}
```

The retained bounded log is not copied into the model context. Model-output and local
log truncation are explicit, and the local log directory remains inspectable by the
user.

## Pipe and PTY Modes

- Pipe mode is preferred for non-interactive automation because stdout and stderr remain distinct and structured.
- PTY mode is used for commands that require terminal semantics, interactive prompts, progress rendering, or user input.
- Automatic mode begins with the execution strategy selected by the service and may report that user interaction is required.

The UI must always show the command, current working directory, execution status, elapsed time, recent output, and a Stop control.

## Passwords and Secret Input

Secret input is owned by the App, not the model or Tool protocol.

When an interactive job needs protected input:

1. The execution service emits `userInputRequired` without the secret value.
2. The App presents a secure input control.
3. The App sends the value through an ephemeral in-memory channel directly to PTY stdin.
4. The value is not echoed, persisted, added to an `AgentEvent`, encoded in a tool result, or sent to Ollama.
5. The App and execution service discard their temporary references after the write completes.

Prompt-text matching such as searching for `Password:` is not a complete security mechanism and must not be the sole detector. Users must be able to provide interactive input explicitly when a PTY job is waiting.

PrivateAI must not implement privileged execution by passing a model-visible or logged password to `sudo`. System-level privileged operations require a separately designed macOS Authorization Services and privileged-helper boundary. Until that boundary exists, unsupported privileged operations are reported accurately.

## Cancellation and Recovery

- Cancelling an Agent run cancels its active execution jobs.
- Cancellation terminates the process group or equivalent descendant tree, not only the immediate shell.
- A graceful termination period may precede forced termination.
- App or worker termination records an unfinished job as `interrupted` or `unknownOutcome` according to observed side effects.
- An interrupted command is never silently replayed.
- Long-running servers are unsupported in Phase 1. They may remain active in a future
  phase only when the execution request and product policy explicitly select a
  persistent job lifecycle and the process boundary can enforce ownership.

## Authority and Policy

PrivateAI does not classify intent by command keywords and does not use a command allowlist as its primary safety boundary. Users choose an execution policy such as autonomous execution or confirmation, and macOS determines the process's actual authority.

The execution worker must not inherit PrivateAI service credentials or unrelated sensitive environment variables by default. Environment construction is explicit and inspectable. Commands execute as the current user unless a future privileged-helper design states otherwise.

## Definition of Done

Terminal execution is not implemented until all of the following exist:

1. A real process and PTY executor runs general shell commands beneath `~/.privateAI` by default.
2. stdout and stderr are continuously and concurrently drained while the job is active,
   retained in a local log, and exposed to the App in bounded coalesced updates.
3. Completion, nonzero exit, timeout, cancellation, process-tree termination, and interruption are directly tested.
4. A long-running integration test proves incremental output arrives before completion.
5. A real external command or package installation test proves the command is not a fixture-only executor.
6. Secret input bypasses model messages, execution logs, and persistent storage in direct tests.
7. A model-driven E2E test proves the real Ollama model chooses terminal execution, the real command runs, and the model uses its result.
8. The macOS App displays live progress and can stop the process tree.

For the first non-interactive implementation phase, the pipe-execution portions of
items 1 through 5 must be proven, item 7 must prove a real repository build or test
loop in the current checkout, and item 8 must prove immediate Stop behavior. PTY and
secret-input gates remain required before interactive terminal execution is described
as complete.

Until these gates pass, documentation and UI must describe terminal execution as planned or partially implemented rather than available.
