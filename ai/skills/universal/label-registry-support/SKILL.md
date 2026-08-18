---
name: label-registry-support
description: >-
  Internal runtime support for universal skills that validate and render
  label-registry.json. Do not invoke directly.
disable-model-invocation: true
---

# Label registry support

This package gives `track-work` and `triage` one strict interpreter for the
v1 label registry. It is a `SKILL.md`-bearing package only so both current and
legacy category-sync engines vendor it with the universal category; it has no
user-facing workflow.
