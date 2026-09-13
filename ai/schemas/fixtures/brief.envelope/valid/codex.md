# Lane brief — schema

<!-- BEGIN SCHEMA-BOUND ENVELOPE FACTS -->
```json
{
  "run_id": "run-939-schema",
  "branch": "939-brief-envelope-schema",
  "generation": 1,
  "active_state_path": "/tmp/active.json",
  "record_directory": "/nonexistent/run-939-schema",
  "policy_projection": "/tmp/policy.json",
  "default_branch": "main",
  "base_sha": "008138e4a9b9a3f2322fde01bb813c015612f978",
  "worktree_path": "/tmp/schema",
  "report_path": "/tmp/schema-report.md",
  "harness": "Codex CLI",
  "fence": [{"path": "ai/schemas/**"}, {"path": "scripts/validate-result-schemas.mjs", "note": "brief kind only"}],
  "live_lane_overlaps": ["#941 implement paragraph; branch-update before gate"],
  "rigor": "deep",
  "rigor_source": "explicit operator input",
  "caps": {"challenge": 5, "review": 5, "integration": 6, "remediation": 6, "min_rounds": 1, "wall_clock_min": 480},
  "deadline": "2026-09-13T20:04:21Z",
  "breadth": {"max_agent_runs": 20, "max_parallel_agents": 4},
  "strategy": "plan",
  "strategy_source": "default_strategy",
  "role_tiers": {"orchestrator": "apex", "implementer": "frontier", "challenger": "apex", "reviewer": "frontier", "integrator": "economy"},
  "operator_pins": ["Implementer: Codex CLI gpt-5.6-sol @ medium"],
  "issue": {"number": 939, "title": "Brief envelope schema", "url": "https://github.com/evanharmon1/harmon-devkit/issues/939"},
  "claim_handoff": {"comment_id": 5653146625, "author_id": 37220977, "updated_at": "2026-09-13T12:04:25Z", "assignees": ["evanharmon1"], "labels": ["claim:claude"], "branch": "939-brief-envelope-schema"},
  "sentinels": {"ready": "LANE-SCHEMA-READY-a1", "handoff": "LANE-SCHEMA-HANDOFF-a1", "blocked": "LANE-SCHEMA-BLOCKED-a1", "attempt_nonce": "a1"}
}
```
<!-- END SCHEMA-BOUND ENVELOPE FACTS -->

## Scope

This body is opaque Markdown. It may contain any headings or instructions.
