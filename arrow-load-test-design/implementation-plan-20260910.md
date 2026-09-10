# Arrow IPC LOAD Gap Closure Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add deterministic MatrixOne regression evidence for each Arrow IPC LOAD acceptance gap in #23684 review 5597540449.

**Architecture:** Extend the existing isolated Go test packages. Real MinIO tests remain in `pkg/tests/arrowload`; reader ownership, identity and metrics remain in `external`, `arrowio`, `arrowbridge`, and `vector`. Test-only fault hooks may be added only at deterministic lifecycle boundaries and are inert by default.

**Tech Stack:** Go, `testing`, `testify/require`, embedded MatrixOne cluster, MinIO Go SDK, MySQL driver, Prometheus test utilities, MatrixOne fault injection.

**Spec:** `arrow-load-test-design/test-execution-plan-20260910.md`

## Global Constraints

- Baseline: official `main` `269d59addd032d20897cc4d86f58de3e387a6d76`; no product contract change.
- Arrow gates stay default-false; all success tests explicitly opt in.
- MinIO credentials are test-local and never emitted by test logs or reports.
- Failed cases immediately check target rows, connection/session state, and leases before their retry control.
- Run deterministic cases 3 times; fault/concurrency cases 10 fresh generations; Nightly only on 3-CN after controller PR #1644 merges.

---

### Task 1: Versioned MinIO identity controls

**Files:**
- Modify: `pkg/tests/arrowload/arrow_load_minio_test.go`
- Modify: `pkg/sql/colexec/external/reader_arrow_test.go`

**Interfaces:** Add `enableBucketVersioning(t, server)` using `SetBucketVersioning`, and `putVersioned(t, server, key, payload) minio.UploadInfo`. Reuse `startArrowMinIOProxy`, `minioLoadSQL`, and the existing unversioned `ObjectChangeFailsClosed` test.

- [ ] Write `TestArrowLoadVersionedMinIOIdentity` with subtests `file-v1-survives-v2`, `deleted-v1-fails-closed`, and `stream-single-get-survives-latest-update`.
- [ ] Run `go test ./pkg/tests/arrowload -run '^TestArrowLoadVersionedMinIOIdentity$' -count=1` before helper implementation; expected compilation failure for the new test/helpers, not a MinIO skip.
- [ ] Enable bucket versioning, capture the `VersionID` returned for v1, open the File reader, write v2 at the same key, and assert only v1 rows are read. Delete exactly v1 with `RemoveObjectOptions{VersionID: v1.VersionID}` and assert `ErrObjectChanged`/no rows. Hold one real Stream GET through the proxy, update latest only after it is admitted, and assert its complete v1 result.
- [ ] Amend the existing non-versioned control to use equal-byte-length payloads and assert its ETag replacement leaves only seed rows after failure.
- [ ] Run `go test ./pkg/sql/colexec/external -run 'TestExternalArrowLoadFromLocalMinIO|TestArrowLoadVersionedMinIOIdentity' -count=3` and `go test ./pkg/tests/arrowload -run '^TestArrowLoadBVT$' -count=3`; expected File v1 pin, deleted-v1 rejection, Stream single-GET control, and SQL rollback.
- [ ] Commit `test: cover Arrow LOAD MinIO version identity`.

### Task 2: Transaction and fixed-connection recovery

**Files:**
- Create: `pkg/tests/arrowload/arrow_load_lifecycle_test.go`
- Modify: `pkg/tests/arrowload/cluster_test.go`
- Modify: `pkg/tests/arrowload/arrow_load_rollout_test.go`

**Interfaces:** Add `openArrowLoadConn(t, db) *sql.Conn` and `waitUntilConnectionGone(t, observer, connID, deadline)`. Reuse `FJ_ArrowLoadRolloutWait`, `waitUntilArrowLoadRolloutHook`, `waitUntilStatementRunning`, and `connection_id()`.

- [ ] Write four focused tests: `TestArrowLoadFailedStatementKeepsEarlierTransactionWrite`, `TestArrowLoadKillQueryRollsBackAndKeepsConnectionUsable`, `TestArrowLoadClientDisconnectRollsBackAndReleasesSession`, and `TestArrowLoadPermissionDeniedDoesNotReadOrWrite`.
- [ ] Run `go test ./pkg/tests/arrowload -run 'TestArrowLoad(FailedStatement|KillQuery|ClientDisconnect|PermissionDenied)' -count=1`; expected failure from missing test declarations/helpers before implementation.
- [ ] For failed transaction, execute `BEGIN`, a successful `INSERT`, a corrupted Arrow LOAD, then explicitly exercise the documented `COMMIT`/`ROLLBACK` result and assert the exact retained rows. Every case begins with a seed row and ends with a valid-load retry control.
- [ ] For KILL/cancel/disconnect, hold the pinned `sql.Conn` at the post-admission/pre-publication hook, observe the exact connection ID from another session, issue `KILL QUERY`, cancel, or close the client connection, then assert error, seed-only durable rows, connection reuse/gone state as applicable, and clean retry.
- [ ] For permissions, create a non-owner user with no INSERT permission, connect through the MySQL protocol, assert LOAD denial before reads/writes, then verify the owner sees only the seed row; cleanup user and grants.
- [ ] Split graceful drain from pre-publish cancellation. Only the latter may assert `rows == 0`; preserve the all-or-nothing graceful-drain contract separately.
- [ ] Run `go test ./pkg/tests/arrowload -run 'TestArrowLoad(FailedStatement|KillQuery|ClientDisconnect|PermissionDenied|Rollout)' -count=10` and `go test ./pkg/tests/arrowload -count=1`; expected no partial rows, no stuck processlist entry, and successful retries.
- [ ] Commit `test: harden Arrow LOAD lifecycle recovery`.

### Task 3: Remote-shard evidence and late failure

**Files:**
- Modify: `pkg/objectio/injects.go`
- Modify: `pkg/sql/colexec/external/reader_arrow.go`
- Modify: `pkg/sql/colexec/external/reader_arrow_test.go`
- Modify: `pkg/tests/arrowload/arrow_load_multicn_test.go`

**Interfaces:** Add test-only `FJ_ArrowLoadRemoteShardLateFail`. At the existing post-conversion/pre-publication point in `ArrowReader.ReadBatch`, activate it only for parameters carrying `ArrowRecordBatchShards`. Record a bounded test-only event `{serviceID, recordBatchStart, recordBatchEnd}` and reset it in test cleanup.

- [ ] Write `TestArrowRemoteShardLateFailureReleasesConvertedBatch`, asserting the second planned shard errors, no unplanned shard event exists, and allocation account/lease usage reaches zero.
- [ ] Run `go test ./pkg/sql/colexec/external -run '^TestArrowRemoteShardLateFailureReleasesConvertedBatch$' -count=1`; expected missing hook/recorder failure.
- [ ] Implement the inert hook so the error occurs after remote reader execution starts but before `replaceArrowBatch`; clean the converted batch before returning error.
- [ ] Add `LateRemoteShardFailureRollsBack` under `TestArrowLoadMultiCN`: require at least two distinct service IDs, exact non-overlapping shard coverage, target seed only after failure, then a valid parallel load control.
- [ ] Run `go test ./pkg/sql/colexec/external ./pkg/sql/compile -run 'TestArrow(RemoteShardLateFailure|LoadRemote)' -count=10` and `go test ./pkg/tests/arrowload -run '^TestArrowLoadMultiCN$' -count=10`; expected full rollback and multi-CN evidence.
- [ ] Commit `test: prove Arrow LOAD remote shard rollback`.

### Task 4: Ownership, boundary, and metric semantics

**Files:**
- Modify: `pkg/sql/colexec/external/reader_arrow_test.go`
- Modify: `pkg/sql/colexec/external/arrowio/reader_test.go`
- Modify: `pkg/container/vector/buffer_lease_test.go`
- Modify: `pkg/container/arrowbridge/bridge_test.go`
- Create: `pkg/sql/colexec/external/testdata/arrow-ipc/` PyArrow File/Stream fixtures and checksums

**Interfaces:** Reuse `meteredArrowCapacityLease`, Arrow rows/batches/errors/pinned metrics, `Vector.MaterializeOwned`, `Vector.HasBorrowedBacking`, `RefCountedBufferLease`, and allocation-account snapshots.

- [ ] Write `TestArrowMetricsPublishBeforeTransactionCommit`, `TestArrowMetricsRejectAndReaderFailureHaveDistinctErrorScope`, `TestArrowBorrowedViewSurvivesReaderAdvanceAndCOW`, and `TestArrowCapacityBoundaryNMinusOneNPlusOne`.
- [ ] Run `go test ./pkg/sql/colexec/external ./pkg/sql/colexec/external/arrowio ./pkg/container/vector ./pkg/container/arrowbridge -run 'TestArrow(Metrics|Borrowed|Capacity)' -count=1`; expected missing-test failure before assertion implementation.
- [ ] Assert rows/batches increment at reader publication even when outer SQL rolls back; gate/planner rejection does not increment reader error counters; read/decode error increments one stable category; leases return to zero after reader close and after restart.
- [ ] Hold an old borrowed view across reader advance/reset/free, force `MaterializeOwned`, assert original bytes remain correct, allocation failure preserves borrowed state, and final owner release fires exactly once.
- [ ] Check every documented cap with named `n-minus-one`, `n`, `n-plus-one` subtests; use independent PyArrow File/Stream fixtures and exact checksums, not only the Go fixture writer.
- [ ] Run `go test ./pkg/sql/colexec/external ./pkg/sql/colexec/external/arrowio -count=3` and `go test -race ./pkg/container/vector ./pkg/container/arrowbridge -run 'Test(Borrowed|FixedExplicitCOW)' -count=1`.
- [ ] Commit `test: verify Arrow LOAD ownership and metrics`.

### Task 5: 3-CN Big Data evidence and reporting

**Files:**
- Modify: `arrow-load-test-design/test-execution-plan-20260910.md`
- External prerequisite: `matrixorigin/mo-nightly-regression#1644` merged to `main`

**Interfaces:** Reuse the merged 100M File/LZ4 COS asset in `matrixorigin/mo-nightly-regression#1643` and its controller registration; do not duplicate the workflow.

- [ ] Check `gh pr view 1644 --repo matrixorigin/mo-nightly-regression --json state,mergeCommit,url`; stop this task as pending if it is not merged.
- [ ] After merge and before a TKE write, obtain authority for one 3-CN Big Data run. Record run URL, SHA, fixture checksum, CN count, timeout, row/distinct/min/max/sum/NULL/cardinality Oracle, peak memory, OOM/restart count, and cleanup.
- [ ] Update the evidence table and issue comment only after validating the comment with `validate_issue_comment.py`; external unavailable state stays pending, never skipped/passed.
- [ ] Commit `docs: record Arrow LOAD acceptance evidence`.

## Plan Self-Review

- Tasks 1–4 cover OBJ, TXN, CONN, DIST, MEM, OBS and remaining TYPE requirements; Task 5 is the required 3-CN big-data evidence.
- Each task modifies its owning test layer; no broad new harness or product behavior is introduced.
- The only external blocker is #1644 merge plus explicit authority for TKE consumption; all local work proceeds independently.
