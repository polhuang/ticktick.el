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
