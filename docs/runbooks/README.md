# Runbooks

Named-incident, step-by-step procedures read *under pressure* when prod breaks
(the calm counterpart is [guides/](../guides/)).

A runbook is one specific operational procedure — e.g. "rotate the API key",
"restore from backup", "roll back a bad deploy" — written so someone can follow
it mid-incident without thinking. **Add one when** a real production procedure
exists.

## Index

Add a row here whenever you add a runbook. An index is consulted at exactly the
moment there is no time to go looking, and a runbook nobody can find is a
runbook nobody reads.

| Runbook | Use it when |
| --- | --- |
| *(none yet)* | |

Two rules for the "use it when" column:

- **Say what the runbook does *not* cover** when a neighbouring procedure could
  be confused with it. Scoping is often the half someone needs while scanning.
- **Never advertise coverage you have not verified.** A wrong pointer is worse
  than a missing one — it costs time under pressure and can walk someone
  through a procedure that leaves the system half-changed.
