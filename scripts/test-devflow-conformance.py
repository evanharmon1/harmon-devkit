#!/usr/bin/env python3
"""Execute the portable .devflow.toml conformance corpus.

The JSON corpus intentionally contains only data: basis selection, labels,
operator overrides, and partial normalized-result expectations. Consumers in
other languages can run the same vectors without importing this Python
reference resolver. This harness proves the shipped resolver honors them.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import tempfile
from pathlib import Path


SUPPORTED_SCHEMA_VERSION = 1
CASE_KEYS = {
    "adaptive_result",
    "basis",
    "config_replacements",
    "expect",
    "labels",
    "merge_base_replacements",
    "name",
    "overrides",
    "trusted_labels",
    "unattended",
}
EXPECT_KEYS = {"error_diagnostics", "exit", "result", "warning_diagnostics"}
V2_CASE_KEYS = {
    "authorized_labels",
    "basis",
    "config_replacements",
    "expect",
    "issue",
    "merge_base_replacements",
    "name",
    "overrides",
    "pin",
    "policy_entry",
    "registry_replacements",
}


def fail(message: str) -> None:
    print(f"FAIL: {message}", file=sys.stderr)


def matches(actual, expected, path="result") -> list[str]:
    """Partial, recursive match: fixtures specify contract-relevant fields.

    A partial expected result lets v1 reserve room for additive diagnostics
    while still pinning every semantic value consumers must agree on.
    """
    if isinstance(expected, dict):
        if not isinstance(actual, dict):
            return [f"{path}: expected object, got {actual!r}"]
        failures = []
        for key, value in expected.items():
            if key not in actual:
                failures.append(f"{path}.{key}: missing")
            else:
                failures.extend(matches(actual[key], value, f"{path}.{key}"))
        return failures
    if isinstance(expected, list):
        if not isinstance(actual, list):
            return [f"{path}: expected array, got {actual!r}"]
        if len(actual) != len(expected):
            return [f"{path}: expected {len(expected)} item(s), got {len(actual)}"]
        return [
            failure
            for index, value in enumerate(expected)
            for failure in matches(actual[index], value, f"{path}[{index}]")
        ]
    if type(actual) is not type(expected) or actual != expected:
        return [f"{path}: expected {expected!r}, got {actual!r}"]
    return []


def replace(text: str, replacements, case: str, label: str) -> str:
    for pair in replacements:
        if not isinstance(pair, list) or len(pair) != 2 or not all(isinstance(v, str) for v in pair):
            raise ValueError(f"{case}: {label} must contain [old, new] string pairs")
        old, new = pair
        if old not in text:
            raise ValueError(f"{case}: {label} anchor {old!r} was not found")
        text = text.replace(old, new, 1)
    return text


def diagnostics_match(actual, expected, case: str, kind: str) -> list[str]:
    """Require stable diagnostic code/subject pairs without pinning prose."""
    if not isinstance(expected, list):
        return [f"{case}: {kind}_diagnostics must be an array"]
    failures = []
    if not isinstance(actual, list):
        return [f"{case}: output {kind}s must be an array"]
    actual_pairs = set()
    for item in actual:
        if not isinstance(item, dict) or not all(isinstance(item.get(key), str) for key in ("code", "subject")):
            failures.append(f"{case}: output {kind} must contain string code/subject fields")
        else:
            actual_pairs.add((item["code"], item["subject"]))
    expected_pairs = set()
    for item in expected:
        if not isinstance(item, dict) or set(item) != {"code", "subject"} or not all(
            isinstance(item.get(key), str) for key in ("code", "subject")
        ):
            failures.append(f"{case}: every {kind}_diagnostics item must be a code/subject object")
        else:
            expected_pairs.add((item["code"], item["subject"]))
    if actual_pairs != expected_pairs:
        missing = sorted(expected_pairs - actual_pairs)
        unexpected = sorted(actual_pairs - expected_pairs)
        if missing:
            failures.append(f"{case}: missing {kind} diagnostic pairs {missing!r}")
        if unexpected:
            failures.append(f"{case}: unexpected {kind} diagnostic pairs {unexpected!r}")
    return failures


V2_ROLES = ("orchestrator", "implementer", "challenger", "reviewer", "integrator")
V2_LADDER = ("local", "economy", "standard", "frontier", "apex")
# Reader role-tier sources that all mean "the resolved profile supplied it".
V2_PROFILE_SOURCES = {"rigor-profile", "role-baseline", "builtin-default"}


def v2_case_inputs(name: str, case: dict) -> tuple[dict, list[str]]:
    """Translate one case's consumer-side inputs into reader flags.

    This is the consumer half of the trust boundary: `overrides` are operator
    instructions and `authorized_labels` are labels whose provenance the
    consumer already verified. Label parsing and conflict reconciliation live
    here, never in the reader (docs/guides/devflow.md).

    Only role-scoped `tier:<role>:<value>` labels are role overrides. An
    unqualified `tier:<value>` label is the issue's stored Tier (ADR 2026-09-30)
    — a cache of the derived Tier, which maps to the stored-Tier input, or,
    with `tier:pinned` also present, the pinned Tier. This corpus expresses a
    pin with the `pin` input (marker and value provenance), so a `tier:pinned`
    label is refused here.
    """
    overrides = case.get("overrides", [])
    if not isinstance(overrides, list) or not all(isinstance(value, str) for value in overrides):
        raise ValueError(f"{name}: overrides must be an array of strings")
    labels = case.get("authorized_labels", [])
    if not isinstance(labels, list) or not all(isinstance(value, str) for value in labels):
        raise ValueError(f"{name}: authorized_labels must be an array of strings")
    selections: dict[str, tuple[str, str]] = {}
    operator_tiers: dict[str, str] = {}
    for override in overrides:
        axis, _, value = override.partition("=")
        if not value:
            raise ValueError(f"{name}: override {override!r} must be <axis>=<value>")
        if axis in {"rigor", "strategy"}:
            if axis in selections:
                raise ValueError(f"{name}: duplicate {axis} override")
            selections[axis] = (value, "explicit")
        elif axis == "tier" or (axis.startswith("tier.") and axis[5:] in V2_ROLES):
            role = "implementer" if axis == "tier" else axis[5:]
            if role in operator_tiers:
                raise ValueError(f"{name}: duplicate tier override for {role}")
            operator_tiers[role] = value
        else:
            raise ValueError(
                f"{name}: v2 overrides support rigor=, strategy=, tier=, or tier.<role>= only"
            )
    label_selections: dict[str, list[str]] = {}
    label_tiers: dict[str, list[str]] = {}
    stored_tier_labels: list[str] = []
    for label in labels:
        parts = label.split(":")
        if len(parts) == 2 and parts[0] in {"rigor", "strategy"} and parts[1]:
            label_selections.setdefault(parts[0], []).append(parts[1])
        elif label == "tier:pinned":
            raise ValueError(f"{name}: express a pin with the pin input, not a tier:pinned label")
        elif len(parts) == 2 and parts[0] == "tier" and parts[1]:
            stored_tier_labels.append(parts[1])
        elif len(parts) == 3 and parts[0] == "tier" and parts[1] in V2_ROLES and parts[2]:
            label_tiers.setdefault(parts[1], []).append(parts[2])
        else:
            raise ValueError(f"{name}: unsupported authorized label {label!r}")
    for axis, values in label_selections.items():
        if len(values) != 1:
            raise ValueError(f"{name}: the corpus does not exercise {axis} label conflicts")
        if axis not in selections:
            selections[axis] = (values[0], "label")
    for role, values in label_tiers.items():
        if len(values) != 1:
            raise ValueError(f"{name}: the corpus does not exercise tier label conflicts")
    flags: list[str] = []
    for axis, (value, source) in selections.items():
        flags.extend([f"--{axis}", value])
        if axis == "rigor":
            flags.extend(["--rigor-source", "operator" if source == "explicit" else "label"])
    if operator_tiers:
        flags.extend(["--tier-overrides", ",".join(f"{r}={t}" for r, t in operator_tiers.items())])
    if label_tiers:
        flags.extend(["--tier-labels", ",".join(f"{r}={v[0]}" for r, v in label_tiers.items())])
    issue = case.get("issue")
    if stored_tier_labels:
        if len(stored_tier_labels) != 1:
            raise ValueError(f"{name}: an issue carries at most one unqualified tier label")
        if issue is not None and "tier" in issue:
            raise ValueError(f"{name}: give the stored Tier as issue.tier or a tier label, not both")
        issue = {**(issue or {}), "tier": stored_tier_labels[0]}
    if issue is not None:
        if not isinstance(issue, dict) or set(issue) - {"risk", "complexity", "tier"}:
            raise ValueError(f"{name}: issue must be an object of risk/complexity/tier")
        for key, flag in (("risk", "--risk"), ("complexity", "--complexity"), ("tier", "--stored-tier")):
            if key in issue:
                if not isinstance(issue[key], str):
                    raise ValueError(f"{name}: issue.{key} must be a string")
                flags.extend([flag, issue[key]])
    pin = case.get("pin")
    if pin is not None:
        if (
            not isinstance(pin, dict)
            or set(pin) != {"tier", "marker_trusted", "value_trusted"}
            or not isinstance(pin["tier"], str)
            or not all(isinstance(pin[key], bool) for key in ("marker_trusted", "value_trusted"))
        ):
            raise ValueError(f"{name}: pin must be {{tier, marker_trusted, value_trusted}}")
        flags.extend(["--pinned-tier", pin["tier"]])
        if pin["marker_trusted"]:
            flags.append("--pin-marker-trusted")
        if pin["value_trusted"]:
            flags.append("--pin-value-trusted")
    return {axis: source for axis, (_, source) in selections.items()}, flags


def v2_normalize(resolved: dict, sources: dict, basis: str) -> dict:
    default_source = "builtin" if basis == "absent" else "default"
    issue = resolved["issue_tier"]
    return {
        "config_schema_version": 2,
        "config_source": resolved["source"],
        "selections": {
            "rigor": {
                "value": resolved["rigor"]["level"],
                "source": sources.get("rigor", default_source),
                "chosen_by": resolved["rigor"]["chosen_by"],
            },
            "strategy": {
                "value": resolved["strategy"]["name"],
                "source": sources.get("strategy", default_source),
            },
        },
        "tiers": {
            role: {
                "value": entry["tier"],
                "source": "profile" if entry["source"] in V2_PROFILE_SOURCES else entry["source"],
            }
            for role, entry in resolved["roles"].items()
        },
        "issue_tier": {
            "status": issue["status"],
            "value": issue.get("tier"),
            "cache": issue.get("cache"),
        },
        "pin": {"status": resolved["pin"]["status"]},
        "disclosures": sorted(
            ({"code": item["code"], "role": item["role"]} for item in resolved["disclosures"]),
            key=lambda item: (item["code"], V2_ROLES.index(item["role"])),
        ),
    }


def run_v2(repo: Path, fixture: dict, config: Path) -> int:
    """Run the v2 corpus against the shared JavaScript policy reader."""
    source = config.read_text()
    failures: list[str] = []
    names: list[str] = []
    for case in fixture.get("cases", []):
        name = case.get("name") if isinstance(case, dict) else None
        if not isinstance(name, str) or not name:
            failures.append("every fixture case needs a non-empty name")
            continue
        names.append(name)
        unsupported = sorted(set(case) - V2_CASE_KEYS)
        if unsupported:
            failures.append(
                f"{name}: v2 reader does not support case input(s): {', '.join(unsupported)}"
            )
            continue
        basis = case.get("basis")
        if basis not in {"absent", "branch", "merge-base"}:
            failures.append(f"{name}: basis must be absent, branch, or merge-base")
            continue
        try:
            sources, flags = v2_case_inputs(name, case)
        except ValueError as exc:
            failures.append(str(exc))
            continue
        expected = case.get("expect")
        if not isinstance(expected, dict):
            failures.append(f"{name}: expect must be an object")
            continue
        unknown_expect_keys = sorted(set(expected) - EXPECT_KEYS)
        if unknown_expect_keys:
            failures.append(f"{name}: unknown expect key(s): {', '.join(unknown_expect_keys)}")
            continue
        expected_exit = expected.get("exit")
        if (
            not isinstance(expected_exit, int)
            or isinstance(expected_exit, bool)
            or expected_exit not in (0, 1, 2, 3)
        ):
            failures.append(f"{name}: expect.exit must be the integer 0, 1, 2, or 3")
            continue
        try:
            with tempfile.TemporaryDirectory() as tmp:
                tmp_path = Path(tmp)
                policy = tmp_path / "policy.toml"
                branch_text = (
                    replace(source, case.get("config_replacements", []), name, "config_replacements")
                )
                policy_entry = case.get("policy_entry")
                if policy_entry is not None and basis != "absent":
                    raise ValueError(f"{name}: policy_entry requires absent basis")
                if policy_entry == "dangling-symlink":
                    policy.symlink_to(tmp_path / "missing.toml")
                elif policy_entry == "dangling-parent-symlink":
                    parent = tmp_path / "current"
                    parent.symlink_to(tmp_path / "missing", target_is_directory=True)
                    policy = parent / "policy.toml"
                elif policy_entry == "directory":
                    policy.mkdir()
                elif policy_entry is not None:
                    raise ValueError(f"{name}: unsupported policy_entry {policy_entry!r}")
                elif basis != "absent":
                    policy.write_text(branch_text)
                registry = tmp_path / "registry.json"
                registry.write_text(
                    replace(
                        (repo / "agent-registry.json").read_text(),
                        case.get("registry_replacements", []),
                        name,
                        "registry_replacements",
                    )
                )
                command = [
                    "node",
                    str(repo / "scripts" / "devflow-policy.mjs"),
                    "resolve",
                    "--policy",
                    str(policy),
                    "--registry",
                    str(registry),
                    "--taskfile-dir",
                    str(repo),
                    "--json",
                ]
                if basis == "merge-base":
                    merge_base = tmp_path / "merge-base.toml"
                    merge_base.write_text(
                        replace(
                            source,
                            case.get("merge_base_replacements", []),
                            name,
                            "merge_base_replacements",
                        )
                    )
                    command.extend(
                        [
                            "--merge-base-policy",
                            str(merge_base),
                            "--merge-base-registry",
                            str(repo / "agent-registry.json"),
                        ]
                    )
                command.extend(flags)
                result = subprocess.run(command, capture_output=True, text=True)
        except (OSError, ValueError) as exc:
            failures.append(f"{name}: harness failure: {exc}")
            continue

        errors: list[dict[str, str]] = []
        warnings: list[dict[str, str]] = []
        normalized: dict = {"config_schema_version": 2}
        if result.returncode in (0, 3):
            try:
                resolved = json.loads(result.stdout)
            except json.JSONDecodeError as exc:
                failures.append(f"{name}: invalid reader JSON: {exc}")
                continue
            normalized = v2_normalize(resolved, sources, basis)
            warnings = resolved["warnings"]
            if result.returncode == 3:
                errors.extend(
                    {"code": "indeterminate", "subject": "issue_tier"}
                    for item in resolved["cross_validation"]["indeterminate"]
                    if "derived Tier" in item
                )
        elif result.returncode == 2 and "could not read/parse --policy:" in result.stderr:
            errors.append({"code": "policy_unreadable", "subject": "policy"})
        elif "schema_version" in result.stderr and (
            "legacy" in result.stderr
            or "v1" in result.stderr
            or "migrate to schema_version" in result.stderr
        ):
            errors.append({"code": "migration_required", "subject": "schema_version"})
        elif "is retired (ADR 2026-09-30 D8)" in result.stderr and "operator tier instruction" in result.stderr:
            errors.append({"code": "tier_retired", "subject": "override"})
        else:
            failures.append(f"{name}: unclassified reader failure: {result.stderr.strip()}")

        if result.returncode != expected.get("exit"):
            failures.append(f"{name}: expected exit {expected.get('exit')!r}, got {result.returncode}")
        failures.extend(f"{name}: {item}" for item in matches(normalized, expected.get("result", {})))
        failures.extend(
            diagnostics_match(errors, expected.get("error_diagnostics", []), name, "error")
        )
        failures.extend(
            diagnostics_match(warnings, expected.get("warning_diagnostics", []), name, "warning")
        )

    if len(names) != len(set(names)):
        failures.append("fixture case names must be unique")
    if failures:
        for item in failures:
            fail(item)
        return 1
    print(f"devflow conformance v2 OK: {len(fixture['cases'])} cases")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    parser.add_argument("--fixture", type=Path)
    parser.add_argument("--config", type=Path)
    args = parser.parse_args()
    repo = args.repo.resolve()
    fixture_path = args.fixture or repo / ".devflow-conformance-v2.json"
    resolver = repo / "scripts" / "devflow-resolve.py"
    config = args.config or repo / ".devflow.toml"
    if not config.is_absolute():
        config = repo / config

    try:
        fixture = json.loads(fixture_path.read_text())
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"cannot read fixture {fixture_path}: {exc}")
        return 1
    if not isinstance(fixture, dict):
        fail("fixture root must be an object")
        return 1
    if fixture.get("kind") != "harmon-init.devflow.conformance":
        fail("fixture kind must be 'harmon-init.devflow.conformance'")
        return 1
    schema_version = fixture.get("schema_version")
    if schema_version == 2:
        if fixture.get("result_schema_version") != 2:
            fail("fixture result_schema_version must be 2")
            return 1
        if not isinstance(fixture.get("cases"), list) or not fixture["cases"]:
            fail("fixture cases must be a non-empty array")
            return 1
        return run_v2(repo, fixture, config)
    if (
        not isinstance(schema_version, int)
        or isinstance(schema_version, bool)
        or schema_version != SUPPORTED_SCHEMA_VERSION
    ):
        fail(f"fixture schema_version must be {SUPPORTED_SCHEMA_VERSION}")
        return 1
    result_schema_version = fixture.get("result_schema_version")
    if (
        not isinstance(result_schema_version, int)
        or isinstance(result_schema_version, bool)
        or result_schema_version != SUPPORTED_SCHEMA_VERSION
    ):
        fail(f"fixture result_schema_version must be {SUPPORTED_SCHEMA_VERSION}")
        return 1
    if not isinstance(fixture.get("cases"), list) or not fixture["cases"]:
        fail("fixture cases must be a non-empty array")
        return 1

    names = []
    for case in fixture["cases"]:
        name = case.get("name") if isinstance(case, dict) else None
        if not isinstance(name, str) or not name:
            fail("every fixture case needs a non-empty name")
            return 1
        names.append(name)
        unknown_case_keys = sorted(set(case) - CASE_KEYS)
        if unknown_case_keys:
            fail(f"{name}: unknown case key(s): {', '.join(unknown_case_keys)}")
            return 1
        if not isinstance(case.get("expect"), dict):
            fail(f"{name}: expect must be an object")
            return 1
        unknown_expect_keys = sorted(set(case["expect"]) - EXPECT_KEYS)
        if unknown_expect_keys:
            fail(f"{name}: unknown expect key(s): {', '.join(unknown_expect_keys)}")
            return 1
        expected_exit = case["expect"].get("exit")
        if not isinstance(expected_exit, int) or isinstance(expected_exit, bool) or expected_exit not in (0, 1):
            fail(f"{name}: expect.exit must be the integer 0 or 1")
            return 1
        for field in ("labels", "trusted_labels", "overrides"):
            values = case.get(field, [])
            if not isinstance(values, list) or not all(isinstance(value, str) for value in values):
                fail(f"{name}: {field} must be an array of strings")
                return 1
        if "unattended" in case and not isinstance(case["unattended"], bool):
            fail(f"{name}: unattended must be a boolean")
            return 1
    if len(names) != len(set(names)):
        fail("fixture case names must be unique")
        return 1

    source = config.read_text()
    failures = []
    for case in fixture["cases"]:
        name = case.get("name") if isinstance(case, dict) else None
        if not isinstance(name, str) or not name:
            failures.append("every fixture case needs a non-empty name")
            continue
        try:
            with tempfile.TemporaryDirectory() as tmp:
                tmp_path = Path(tmp)
                branch_text = replace(source, case.get("config_replacements", []), name, "config_replacements")
                branch_config = tmp_path / "branch.toml"
                branch_config.write_text(branch_text)
                command = [sys.executable, str(resolver), "--config", str(branch_config)]
                basis = case.get("basis")
                if basis == "branch":
                    command.append("--config-unchanged")
                elif basis == "absent":
                    command.extend(["--config", str(tmp_path / "absent.toml"), "--config-unchanged"])
                elif basis == "merge-base":
                    merge_base_text = replace(source, case.get("merge_base_replacements", []), name,
                                              "merge_base_replacements")
                    merge_base_config = tmp_path / "merge-base.toml"
                    merge_base_config.write_text(merge_base_text)
                    command.extend(["--merge-base-config", str(merge_base_config)])
                else:
                    raise ValueError(f"{name}: basis must be branch, absent, or merge-base")
                for label in case.get("labels", []):
                    command.extend(["--label", label])
                for label in case.get("trusted_labels", []):
                    command.extend(["--trusted-label", label])
                for override in case.get("overrides", []):
                    command.extend(["--override", override])
                if case.get("unattended") is True:
                    command.append("--unattended")
                if "adaptive_result" in case:
                    adaptive_result = case["adaptive_result"]
                    if not isinstance(adaptive_result, str):
                        raise ValueError(f"{name}: adaptive_result must be a string")
                    command.extend(["--adaptive-result", adaptive_result])
                result = subprocess.run(command, capture_output=True, text=True)
                output = json.loads(result.stdout)
        except (OSError, ValueError, json.JSONDecodeError) as exc:
            failures.append(f"{name}: harness failure: {exc}")
            continue

        expected = case.get("expect")
        if not isinstance(expected, dict):
            failures.append(f"{name}: expect must be an object")
            continue
        if result.returncode != expected.get("exit"):
            failures.append(f"{name}: expected exit {expected.get('exit')!r}, got {result.returncode}")
        failures.extend(f"{name}: {item}" for item in matches(output, expected.get("result", {})))
        failures.extend(
            diagnostics_match(output.get("warnings", []), expected.get("warning_diagnostics", []), name, "warning")
        )
        failures.extend(
            diagnostics_match(output.get("errors", []), expected.get("error_diagnostics", []), name, "error")
        )
        if output.get("result_schema_version") != SUPPORTED_SCHEMA_VERSION:
            failures.append(f"{name}: output missing result_schema_version {SUPPORTED_SCHEMA_VERSION}")

    if failures:
        for item in failures:
            fail(item)
        return 1
    print(f"devflow conformance v{SUPPORTED_SCHEMA_VERSION} OK: {len(fixture['cases'])} cases")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
