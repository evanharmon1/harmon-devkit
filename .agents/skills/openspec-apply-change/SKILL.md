---
name: openspec-apply-change
description: Implement tasks from an OpenSpec change. Use when the user wants to start implementing, continue implementation, or work through tasks.
allowed-tools: Bash(scripts/openspec.sh:*)
license: MIT
compatibility: Requires the repository-pinned scripts/openspec.sh wrapper.
metadata:
  author: openspec
  version: "1.0"
  generatedBy: "1.11.0"
---

Implement tasks from an OpenSpec change.

**Store selection:** If the user names a store (a store is a standalone OpenSpec repo registered on this machine) or the work lives in one, run `scripts/openspec.sh store list --json` to discover registered store ids, then pass `--store <id>` on the commands that read or write specs and changes (`new change`, `status`, `instructions`, `list`, `show`, `validate`, `archive`, `doctor`, `context`, `schemas`, `view`). Once selected, treat `--store <id>` as sticky for the rest of the workflow. Every unscoped example of those commands below is shorthand: before running it, append the flag. For example, run `scripts/openspec.sh status --change "<name>" --json --store "<id>"`, not the unscoped form shown below. Other commands do not take the flag. Hints printed by commands already carry the flag; keep it on follow-ups. Without a store, commands act on the nearest local `openspec/` root.

**Input**: Optionally specify a change name (e.g., `/openspec-apply-change add-auth`). If omitted, check if it can be inferred from conversation context. If vague or ambiguous you MUST prompt for available changes.

**Steps**

1. **Select the change**

   If a name is provided, use it. Otherwise:
   - Infer from conversation context if the user mentioned a change
   - Auto-select if only one active change exists
   - If ambiguous, run `scripts/openspec.sh list --json` to get available changes and ask the user to select one

   Always announce: "Using change: `<name>`" and how to override (e.g., `/openspec-apply-change <other>`).

2. **Check status to understand the schema**

   ```bash
   scripts/openspec.sh status --change "<name>" --json
   ```

   Parse the JSON to understand:
   - `schemaName`: The workflow being used (e.g., "spec-driven")
   - `planningHome`, `changeRoot`, and `actionContext`: planning scope and edit constraints
   - Which artifact contains the tasks (typically "tasks" for spec-driven, check status for others)

3. **Get apply instructions**

   ```bash
   scripts/openspec.sh instructions apply --change "<name>" --json
   ```

   This returns:
   - `contextFiles`: artifact ID -> array of concrete file paths (varies by schema - could be proposal/specs/design/tasks or spec/tests/implementation/docs)
   - Progress (total, complete, remaining)
   - Task list with status
   - Dynamic instruction based on current state
   - Optional `context`: current required project instruction input from the selected root
   - Optional `operationGuidance`: current advisory guidance for apply

   **Handle states:**
   - If `state: "blocked"` (missing artifacts): show message, suggest using `/openspec-continue-change` (if it is not installed, run `scripts/openspec.sh status --change "<name>" --json` to see the next artifact and `scripts/openspec.sh instructions <artifact-id> --change "<name>" --json` for how to create it)
   - If `state: "all_done"`: congratulate, suggest archive
   - Otherwise: proceed to implementation

   Treat `context` as a required prompt-level input. Read and consider it, and
   apply relevant project facts, conventions, and constraints while implementing.
   Treat `operationGuidance` as optional additive advice. Read and consider every
   entry, and follow entries that are applicable and compatible with the built-in
   workflow.

   Keep both fields separate from CLI-returned state, missing artifacts, tasks,
   progress, `contextFiles`, and the built-in `instruction`. They are not
   evidence of task completion, do not replace the built-in instruction, and do
   not permit bypassing a blocked state. If context conflicts with the built-in
   instruction, an explicit user choice, or a CLI-controlled value, report the
   conflict and preserve the controlling value. If guidance is inapplicable or
   conflicts with those controlling inputs, do not follow it and explain why.
   These are prompt-level behavior contracts, not enforceable checks.

4. **Read context files**

   Read every file path listed under `contextFiles` from the apply instructions output.
   The files depend on the schema being used:
   - **spec-driven**: proposal, specs, design, tasks
   - Other schemas: follow the contextFiles from CLI output

   Do not copy `context` or `operationGuidance` verbatim into implementation
   files or planning artifacts unless the user separately asks for that content.

5. **Show current progress**

   Display:
   - Schema being used
   - Progress: "N/M tasks complete"
   - Remaining tasks overview
   - Dynamic instruction from CLI

6. **Select exactly one pending task**

   One apply invocation handles one task only. Each task in this repository maps
   to one milestone issue and owns an independent claim, branch, Dev Loop, and
   ready-for-review PR.

   - If the user named a task or issue, select that pending task.
   - Otherwise, show the pending tasks and ask the user to select one; do not
     infer permission to batch them.
   - Confirm the selected task maps to exactly one milestone issue.
   - Use the repository's `/claim` workflow for that issue before implementation.
   - Create or use the task's dedicated feature branch/worktree as required by
     `AGENTS.md`; never combine another OpenSpec task or milestone issue into it.

7. **Implement the selected task through the repository Dev Loop**

   - Show which task is being worked on.
   - Make only the code and documentation changes required by that task.
   - Drive the task through the repository's complete Dev Loop to its own
     ready-for-review PR; merging remains a human decision.
   - Mark the task complete in the tasks file (`- [ ]` → `- [x]`) only when its
     specified behavior and verification are complete.
   - Stop after that task's PR handoff. Report the remaining tasks, but do not
     select or implement another one in the same apply invocation.

   **Pause if:**
   - Task is unclear → ask for clarification
   - Implementation reveals a design issue → suggest updating artifacts
   - A task needs work beyond what the spec and tasks describe, or you are tempted to drop, narrow, defer, or accept exceptions to specified behavior to make it fit → surface the added scope and ask; do not absorb it silently
   - Error or blocker encountered → report and wait for guidance
   - User interrupts

8. **On completion or pause, show status**

   Display:
   - The single task selected and whether it completed this session
   - Overall progress: "N/M tasks complete"
   - The task's branch and PR handoff state
   - If all tasks are done: suggest archive
   - If tasks remain: stop and name the next apply invocation as the handoff
   - If paused: explain why and wait for guidance

**Output During Implementation**

```text
## Implementing: <change-name> (schema: <schema-name>)

Working on task 3/7: <task description>
[...implementation happening...]
✓ Task complete

Stopping after this task's ready-for-review PR handoff.
```

**Output On Completion**

```text
## Implementation Complete

**Change:** <change-name>
**Schema:** <schema-name>
**Progress:** 3/7 tasks complete

### Completed This Session
- [x] Task 3 — ready-for-review PR <reference>

This apply run is complete. Start a new apply invocation for another task.
```

**Output On Pause (Issue Encountered)**

```text
## Implementation Paused

**Change:** <change-name>
**Schema:** <schema-name>
**Progress:** 4/7 tasks complete

### Issue Encountered
<description of the issue>

**Options:**
1. <option 1>
2. <option 2>
3. Other approach

What would you like to do?
```

**Guardrails**
- Select exactly one task per apply invocation and stop after its PR handoff
- Treat each task as one milestone issue with its own claim, branch, and PR
- Never batch another task into the selected task's branch or PR
- Always read context files before starting (from the apply instructions output)
- If task is ambiguous, pause and ask before implementing
- If implementation reveals issues, pause and suggest artifact updates
- Keep code changes minimal and scoped to the single selected task
- Update task checkbox immediately after completing each task
- Pause on errors, blockers, or unclear requirements - don't guess
- When a task needs work beyond what the spec describes, surface the added scope and pause - never silently narrow, defer, or simplify away specified behavior
- Only mark a task `- [x]` when its specified behavior is fully implemented, not when it is partially done or deferred
- Use contextFiles from CLI output, don't assume specific file names
- Do not use context or operation guidance as proof that a task is complete
- Apply relevant project context; report conflicts with controlling workflow inputs
- Consider every guidance entry; explain any inapplicable or conflicting advice
- Do not copy runtime context or operation guidance into implementation files or planning artifacts
- Preserve CLI-controlled blocked/ready/all-done behavior and completion criteria

**Fluid Workflow Integration**

This skill supports the "actions on a change" model:

- **Can be invoked anytime**: Before all artifacts are done (if tasks exist), after partial implementation, interleaved with other actions
- **Allows artifact updates**: If implementation reveals design issues, suggest updating artifacts - not phase-locked, work fluidly
