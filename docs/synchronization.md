# Synchronization design and API constraints

## API verification (2026-11-01)

Source: [TickTick Open API reference](https://developer.ticktick.com/docs/index.html#/openapi), read from the rendered official reference. This is documentation verification, not a live account experiment.

- Tasks can be fetched individually with `GET /open/v1/project/{projectId}/task/{taskId}`. The documented responses distinguish 404 from authorization errors.
- Project data contains a task list but does not promise a complete history of completed or deleted tasks. `POST /open/v1/task/completed` returns at most 200 tasks. Absence from a project list or a bounded query alone is insufficient evidence of deletion. Individually check known missing IDs in an accessible project; abort on transport, authorization, or malformed-response failures.
- Update uses `POST /open/v1/task/{taskId}` with task and project IDs. The documented parameters do not specify `If-Match`, an expected etag, or another conditional-write contract. An observed etag is not proof of compare-and-swap support.
- Creation has no documented idempotency key. A timeout or an empty success response can leave creation outcome uncertain. Persist that intent and require explicit reconciliation instead of submitting it again.
- Completion has a dedicated endpoint, `POST /open/v1/project/{projectId}/task/{taskId}/complete`. The update parameters do not document reopening completed tasks. Refuse unsupported status transitions rather than recording an unverified success.
- Deletion uses `DELETE /open/v1/project/{projectId}/task/{taskId}` and can return success without a body. Project moves use `POST /open/v1/task/move` with source and destination project IDs.

## Consequences

Reconciliation reads every project before planning writes. Known tasks missing from project data are checked individually, including completed tasks. An inaccessible or removed project is held for review rather than treated as evidence that all its tasks were deleted.

Before a write, refetch the affected task and compare it with the planned version. This narrows the race window; it cannot eliminate concurrent writes without a documented conditional-write guarantee. Do not claim atomic synchronization.

A task baseline advances only after the local file is saved and the remote state is verified. Persist pending operations before mutation and preserve uncertain creations for explicit review. Do not test these guarantees by modifying a user's live TickTick account.

## Deletion policies

Unambiguous deletions follow `ticktick-delete-behavior`. `delete` applies them automatically; `archive` archives local removals (and requires review if `ticktick-confirm-deletions` is non-nil); `ask` queues them in the conflict review instead of prompting during background work. `sync-only` leaves them pending review and preserves their baselines. An explicit review choice can authorize a deletion.

Delete-versus-edit cases always require review. The legacy `ticktick-deletion-conflict-policy` variable is retained for configuration compatibility, but is not used to guess the newest action: the API provides no reliable deletion timestamp. Keeping a locally edited task after remote deletion creates a new remote task and replaces its old ID only after verification. Archived headings retain their metadata and are excluded from active synchronization.


## Baselines, merging, and recovery

Version 2 state stores normalized per-task baselines, pending operations, and review records. Legacy state retains its ID history but does not invent snapshots. Equal copies can establish a baseline; differing copies require review.

For each field, choose the changed side if the other still matches the baseline, accept identical edits, and record conflicting fields if both changed differently. Project, title, content, status, priority, deadline details, and tags participate in this comparison. Descriptions and tag lists are not text-merged. Hold the entire task when any field conflicts. Pull-only and push-only commands defer merges that require writing both sides.

Before each mutation, check local and remote versions again and save intent atomically. Preserve remote recurrence, reminders, start dates, and checklist data when updating supported fields. Verify remote results, save the Org task, and only then advance its baseline. A journal entry with a returned creation ID remains paired with its original Org heading, even if verification fails, so it cannot become a duplicate import.

Recovery completes operations only when their observed state matches the intended result and the local task is unchanged or already reconciled. Changed sources remain available for explicit review. Baseline writes roll back in memory if state persistence fails. An uncertain creation without a returned ID must be linked or explicitly released after manual verification; never guess by matching a title.
