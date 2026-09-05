# PrivateAI Repository Instructions

## Product truth

- Inspect the current implementation before describing a capability as available.
- Do not infer behavior from target architecture, schemas, protocols, test fixtures, or placeholder types.
- Report failed, skipped, blocked, and unexecuted checks exactly as they occurred.
- Describe schema, registration, adapter, argument-validation, and framework-call checks only as contract or integration-wiring evidence. Do not say a capability "passed", "works", or is "available" based on those checks.
- Reserve capability-passed language for a successful real executor result and, for model-facing behavior, a real model-driven E2E whose final user-visible outcome is verified against ground truth.

## Epistemic independence

- Treat the user's factual, causal, predictive, diagnostic, and evaluative judgments as claims to assess, not premises to adopt. Treat the user's stated preferences, goals, constraints, and firsthand observations as user-owned inputs, while keeping any explanation of those observations open to verification.
- Do not agree merely to be cooperative, and do not disagree merely to appear independent. Optimize for accuracy and usefulness. Challenge only claims that materially affect the answer or implementation, and identify the exact evidence or reasoning at issue without becoming argumentative.
- Keep rapport separate from assent. Acknowledge the user's goal, concern, or experience without echoing an unsupported conclusion. Do not use confidence, repetition, urgency, status, or phrasing as a substitute for evidence.
- Before accepting a material conclusion or proposed diagnosis, actively identify the strongest plausible counterexample, alternative explanation, or failure mode. Run the cheapest available check that could falsify it when the result would affect the work. Scale this effort to the stakes and do not invent objections solely to create artificial balance.
- Treat external evidence as bounded by its sources, coverage, independence, and recency. State material limits. An unsuccessful search does not prove absence, and a small or correlated sample does not establish prevalence, consensus, or causation.
- Distinguish verified facts, direct observations, user-provided claims, evidence-supported inferences, assumptions, and unknowns whenever confusing them could change the decision. Do not fill evidence gaps with plausible detail; say what is unknown and what would resolve it.
- Do not change a conclusion merely because the user disputes it, repeats a claim, reframes the request, or asks for agreement. Update the conclusion or its confidence only when there is new evidence, a corrected premise, a relevant test result, or an identified error in the prior reasoning, and state what changed.
- Keep conclusions proportional to the evidence. When evidence is insufficient, give a provisional assessment or say that the answer is unknown. If disagreement remains, state the current conclusion, its basis, and the specific evidence that would confirm or overturn it, then continue with the user's goal where possible.

## Root-cause-first engineering

- Do not edit code, propose a fix, add a workaround, or retry a failed operation until you can state: the observed failure, the evidence gathered, one falsifiable root-cause hypothesis, the controlling code path, and the cheapest check that could disprove the hypothesis.
- Distinguish the symptom, immediate trigger, and root cause. A nearby failing line, error message, timeout, or permission denial is not automatically the root cause.
- Trace behavior to the component that owns the violated invariant. Fix that invariant at its owning abstraction instead of adding downstream conditionals, retries, fallback branches, duplicated logic, or example-specific exceptions.
- If the evidence does not yet explain why a proposed change should fix the failure, continue investigating. Do not use code edits as undirected experiments when a read, trace, focused test, debugger observation, or runtime value can discriminate between hypotheses more cheaply.
- Never repeat an unchanged command merely hoping for a different result. Retry only when testing an identified source of nondeterminism, and state what new evidence the retry can produce. Otherwise, change the hypothesis, inputs, instrumentation, implementation, or environment first.
- Implement a workaround only when the user explicitly requests one or the root fix is demonstrably blocked. Label it as a workaround and record the blocking constraint, tradeoff, and removal condition; do not present it as the completed root fix.
- After a failed validation, do not stack another speculative patch on top. First decide whether the result supports or falsifies the current hypothesis, then revise the hypothesis or make the smallest evidence-backed correction.
- Judge elegance and efficiency concretely: preserve one clear invariant, minimize states and special cases, use the owning abstraction, and maximize information gained per command or edit. Fewer investigative steps are not efficient if they create rework or conceal uncertainty.

## Tool implementation definition of done

A PrivateAI Tool is not complete when it only defines an `LLMTool`, JSON Schema, request enum, backend protocol, fixture, registry entry, or mocked result. Those pieces are contracts and test seams, not the capability.

A Tool may be described as implemented only when all of the following exist:

1. The model-facing schema and strict runtime argument validation.
2. A real executor that performs the claimed operation through the appropriate macOS framework, bounded network client, filesystem API, or isolated worker.
3. Structured success, unavailable, denied, cancelled, timeout, and failure results where applicable.
4. Explicit resource scope, output limits, cancellation, and concurrency behavior.
5. A deterministic contract test for schema, validation, and result encoding.
6. A direct integration test that executes the real framework/API/filesystem/worker behavior. Fixtures cannot satisfy this gate.
7. A model-driven E2E test in which the real Ollama model receives the Tool schema, chooses the Tool from a natural-language request, the real executor runs, and assertions prove the final user-visible answer uses the executor's real result as ground truth.

Tool selection, action selection, intermediate JSON fields, request counts, and non-empty model output are diagnostic evidence, not proof that the user request succeeded. A model-driven E2E test must assert the requested facts, values, state change, or artifact in the final observable outcome.

If an external service or protected macOS capability prevents integration testing, report the Tool as blocked or partially implemented. Do not convert service failure, permission denial, skipped tests, or fixture output into a successful capability claim.

Protected macOS capability success belongs in a signed App-hosted E2E scenario with the real bundle identity, entitlements, usage descriptions, and explicit authorization preconditions. Swift Package tests may verify argument contracts and denied/unavailable error mapping, but a branch that accepts denial or unavailability must not be named or reported as a successful capability test.

## Real user acceptance gate

- Before reporting any user-facing capability as complete, available, working, or passed, run at least one realistic safe task from the same natural-language entry point the user will use in the production App. Exercise the production model, Tool catalog, runtime, executor, persistence, and final UI-visible answer. Do not substitute a direct executor call, protocol smoke test, fixture backend, mock model, schema check, registration check, or manually forced Tool call.
- Establish deterministic ground truth independently before the model-driven run, then assert the final user-visible outcome contains the requested real facts, values, state change, or artifact. Tool selection, argument selection, request counts, intermediate output, and non-empty final text remain diagnostic evidence only.
- Use a non-destructive acceptance task unless the capability itself requires a mutation. Record and compare relevant preconditions and postconditions so the test proves no unrequested deletion, write, move, rename, installation, or other side effect occurred.
- If the production route cannot be exercised because integration, signing, authorization, a real model, or an external dependency is missing, report the capability as partial, blocked, or untested. Never lower the acceptance boundary or describe lower-level passing tests as completion.
- For terminal execution, the mandatory acceptance scenario is a natural-language, read-only filesystem request through the signed App and a real Ollama model, such as: find the largest file or directory in the user-authorized Documents directory, report its measured path and size, and suggest cleanup options without cleaning anything. Independently compute the ground truth, assert the final answer identifies the real largest item and offers only non-destructive recommendations, and verify the filesystem snapshot is unchanged. Also retain focused real-executor tests for completion, nonzero exit, incremental drain, checkpoint observation, timeout, descendant cancellation, interruption, PTY, output truncation, and secret-input redaction as applicable.

## Capability boundaries

- Keep `LLMCore` provider- and capability-neutral. It owns model contracts, the package system prompt, warmup, `ToolRuntime`, and the model/tool loop.
- Put real built-in Tool implementations in `Packages/PrivateAITools`.
- Keep the model-facing catalog small and capability-oriented. Do not create domain Tools for weather, YouTube, restaurants, news, or similar tasks when an existing capability gateway can perform them.
- Treat general-purpose local terminal execution as a primary Agent capability. Do not weaken it into a language-specific evaluator, fixed action list, executable allowlist, or keyword-based command classifier.
- Use `~/.privateAI` as the default managed execution root. Create workspaces, jobs, logs, artifacts, and execution state beneath it; do not describe it as a security sandbox unless the process boundary actually enforces confinement.
- Keep dedicated file, PDF, web, and native macOS capabilities because they provide structured semantics and permission states, not because terminal execution is a restricted fallback.
- Stream long-running command output to the App and local logs. Send bounded milestones and final structured results to the model instead of placing every output line in model context.
- Never put passwords, passphrases, tokens, private keys, or other secret interactive input in tool arguments, model messages, Agent events, conversation storage, or execution logs. Secure App input must travel directly to PTY stdin through an ephemeral channel.
- Local resource Tools must operate only within App-authorized roots, resolve symlinks before access, use format-aware binary readers such as PDFKit when applicable, and preserve raw bounded text formats such as HTML and Markdown unless the product explicitly requests a derived representation.
- A Tool is serial by default. It may opt into concurrency only when the concrete action and implementation are safe to run concurrently.

## Capability design discipline

- Before implementing or extending a capability, define its matrix of input categories, real executors/parsers, permission requirements, limits, failure states, and direct tests. Do not build capabilities one user example at a time.
- Treat a named example such as PDF, Markdown, weather, or location as evidence of a broader category to analyze, not as the complete requested scope.
- Prefer a controlling abstraction such as document-format routing or capability actions over accumulating unrelated extension checks and special cases.
- Do not claim support for an input category until a real fixture or integration test covers it.
- For terminal execution, direct tests must cover real commands, incremental output before completion, nonzero exit, timeout, cancellation of descendants, interruption state, PTY interaction, output truncation, and secret-input redaction. A mocked runner cannot satisfy the integration gate.

## Generalization and scenario coverage

- A user example is an acceptance sample, never the capability boundary. Before editing code, translate examples into a capability matrix and identify unrelated scenario families that exercise the same abstraction. Do not optimize registration, permissions, schemas, prompts, or tests around the first example.
- For a general terminal capability, the minimum scenario matrix includes filesystem inspection, file creation and code editing, build and test commands, network diagnostics, nonzero exits, missing executables, long-running output, timeout, cancellation, and cleanup. Add platform or permission variants when they materially change execution.
- General terminal availability must not depend on a user selecting a filesystem folder. When the signed worker is available, ordinary non-document conversations receive terminal execution rooted at the managed `~/.privateAI` workspace by default. Selecting a folder changes the authorized filesystem root; it does not enable the terminal capability itself. Document privacy mode remains a deliberate exception.
- Validate model routing with ordinary natural-language prompts that describe the task, not prompts that name or force the Tool. Include at least two semantically unrelated model-driven scenarios before claiming a general capability is complete. For terminal work, one scenario must be filesystem or coding work and another must be non-filesystem work such as network or process diagnostics.
- Design routing evals around the evidence source rather than domain keywords. A network request may require local terminal evidence such as ping or traceroute, public web evidence, native macOS network state, or a justified combination. Do not encode a one-domain-to-one-Tool rule, and do not grade a valid route as wrong merely because another Tool could also contribute.
- Evaluate each model-driven scenario against its own ground truth and requested final outcome. Tool presence, Tool selection, command text, intermediate output, or success in a different scenario cannot substitute for the scenario's final user-visible result.
- A user's real App transcript showing missing tools, wrong routing, failed execution, or an incorrect final answer is sufficient evidence that the observed build/session failed. Do not rerun the unchanged failure merely to prove it again. Diagnose the controlling path, implement an evidence-backed fix, and reserve repetition for post-fix verification or a stated nondeterminism hypothesis.

## Validation

- After every substantive edit, run the narrowest test that can falsify the change before editing another module.
- Build each Swift Package independently and run its focused tests.
- Before handoff, build the macOS app and report every warning and error.
