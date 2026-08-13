---
name: mo-feature-test-design
description: Use when designing or reviewing test coverage for a new or changed MatrixOne feature, mapping a user-facing capability to UT/BVT/MOTR/big-data/stability/chaos/GPU/recovery layers, identifying cross-feature risks, or deciding whether scale and fault-injection coverage are required.
---

# MatrixOne Feature Test Design

## Purpose

Generate an evidence-backed test design from MatrixOne's formally supported user contract, capability invariants, architecture interactions, and existing regression assets. The catalog is a living baseline for the latest official `main`; it is not a substitute for checking current documentation and code.

Do not start from a generic test checklist. First establish what users are promised, then derive the smallest complete matrix that can prove that promise and protect its high-risk interactions.

## Required Reading

Before producing a design, read these files in order:

1. `references/formal-support-policy.md`
2. `references/capability-index.md`
3. The selected `references/capability-*.md` files for the primary and interacting capabilities
4. `references/universal-test-dimensions.md`
5. `references/interaction-map.md`
6. `references/test-routing.md`
7. `references/test-plan-template.md`

Read `references/capability-entry-contract.md` when adding or updating catalog entries.

## Workflow

### 1. Establish the Feature contract

Describe the public entry point, supported syntax or API, user-visible result, supported deployment forms, configuration, lifecycle, documented limitations, and explicit non-goals.

Use the support hierarchy in `formal-support-policy.md`. A parser branch, merged implementation, hidden setting, internal UT, or issue comment is not sufficient on its own to declare a product capability supported.

If public sources conflict, use the narrower contract and record the conflict as a product question. Do not silently broaden the scope.

### 2. Run the freshness gate

Resolve the full SHA of official MatrixOne `main` and compare it with the catalog SHA in `formal-support-policy.md` and `capability-index.md`.

- If unchanged, use the catalog normally.
- If changed, inspect the target capability's documentation, public entry, implementation, and test paths between the two SHAs.
- If relevant paths changed, update the affected capability entries, support evidence, conditions, limitations, interactions, catalog SHA, and date before designing tests.
- If only unrelated paths changed, record that audit in the design; do not rewrite unrelated entries.

Never claim “latest main” with a short or unverified SHA.

### 3. Select capabilities

Choose one primary `capability_id`, then expand its `Interactions`:

- `required`: always include.
- `high-risk`: include unless the Feature contract demonstrably cannot reach it.
- `common`: include when the public workflow uses it.
- `conditional`: include only when the stated condition applies.

Record excluded common, high-risk, or conditional interactions and the reason. Capability IDs provide traceability; internal component names provide architecture context, not acceptance criteria.

### 4. Model the system under test

Map:

- public entry points and client/protocol variants;
- data and control flow;
- state objects such as rows, catalog metadata, indexes, transactions, sessions, locks, background tasks, checkpoints, objects, caches, and files;
- topology and ownership boundaries such as CN, TN, Log Service, Proxy, object storage, account, tenant, role, or GPU worker;
- synchronous and asynchronous completion signals.

This model determines which outcomes must be observed immediately, after commit, after polling, after reconnect, and after restart or recovery.

### 5. Define risks and invariants

Turn the user contract into observable invariants. At minimum consider:

- result and metadata correctness;
- atomicity and no partial mutation after rejection;
- transaction visibility, isolation, lock release, and retry behavior;
- durability and recovery;
- tenant and privilege isolation;
- deterministic error classification and post-error reuse;
- resource, task, session, schema, lock, file, and port cleanup;
- optimizer equivalence across eligible plans;
- compatibility only where MatrixOne documents the compatible behavior.

Each important invariant must map to one or more test cases and a concrete oracle.

### 6. Build the functional matrix

Apply `universal-test-dimensions.md` by relevance, not mechanically:

- Happy Path proves each supported entry and meaningful variant.
- Boundary Path covers legal limits such as NULL, empty input, precision, dimensions, time zones, identifiers, and batch boundaries.
- Unhappy Path covers invalid input, conflicts, permissions, cancellation, disconnect, timeout, and failure atomicity.
- Lifecycle covers create, use, alter, rebuild, drop, recreate, repeat, reconnect, and cleanup where available.
- State-changing and error cases must verify state immediately before another successful operation can hide corruption.

Use literal expected results or an independent oracle. “No panic” or “query succeeded” alone is not a correctness assertion.

### 7. Decide scale, concurrency, and fault coverage

Do not add big-data merely because more rows look stronger. Require it when the defect or contract depends on at least one of:

- crossing a memory, disk, batch, partition, block, object, or admission threshold;
- exercising spill or external execution;
- changing the optimizer plan or physical algorithm only at scale;
- exposing a low-probability race through many fresh generations;
- proving throughput, latency, resource ceiling, or long-soak behavior.

When small data can force the identical path through a supported configuration, use that deterministic case in regular regression and reserve production-scale validation for nightly evidence.

Use multi-client or multi-CN coverage when correctness depends on locks, visibility, cache invalidation, routing, session migration, or distributed ownership. Use Chaos only when the contract includes node, network, storage, process, or rolling-upgrade failure. Use GPU only for a formally supported GPU path. Explain every specialized environment gate.

### 8. Route tests to the correct layer

Follow `test-routing.md`:

- UT for internal pure logic, ownership, error mapping, and deterministic fault injection.
- BVT for fast, deterministic public SQL and metadata contracts.
- MOTR for black-box protocol, multi-session, lifecycle, cross-feature, or environment-aware scenarios.
- big-data/nightly for scale thresholds, spill, plan switches, performance, soak, and rare generations.
- stability/Chaos/recovery/GPU for their explicit environmental contracts.

Prefer extending an existing authoritative test. Do not duplicate a stable regression in a new PR unless the new layer proves a distinct contract.

### 9. Define execution and evidence

For every case specify prerequisites, operation, oracle, immediate state assertions, cleanup, repeat policy, timeout, and environment. For asynchronous features, poll a product-visible readiness signal with a bounded deadline; fixed sleeps are not readiness proof.

Separate:

- product result;
- fixture or environment failures;
- unrelated suite failures;
- untested conditions.

Do not convert partial coverage into a full pass.

### 10. Write and validate the design

Use every heading, in order, from `references/test-plan-template.md`. Every “不适用” item needs a specific reason. Include the full official `main` SHA, formal support URL, selected capability IDs, regression routing, existing asset paths, entry/exit criteria, remaining risks, and product questions.

Run:

```bash
python3 scripts/validate_test_design.py <design.md>
```

Fix every error before handing off the design.

## Catalog Maintenance

When a formally announced capability is added, changed, restricted, deprecated, or removed:

1. Update the relevant domain file using `capability-entry-contract.md`.
2. Update cross-capability relations and existing test assets.
3. Update catalog SHA and verification date only after auditing the affected paths.
4. Run:

```bash
python3 scripts/audit_capability_catalog.py --repo-root /path/to/matrixone
python3 -m unittest discover -s scripts -p 'test_*.py' -v
```

Do not retain unsupported, preview, internal, debug-only, deprecated, or removed behavior in the current supported index. Preserve historical/version-specific information only as an explicit condition or maintenance record.

## Handoff Checklist

Before stating that a test design is complete, verify:

- support evidence and current full `main` SHA are recorded;
- primary and interacting capability IDs are traceable;
- every acceptance goal maps to an invariant, case, oracle, and test layer;
- Happy, Boundary, and Unhappy coverage are substantive;
- transaction, concurrency, security, recovery, scale, compatibility, and observability are either covered or explicitly inapplicable with reasons;
- big-data and Chaos decisions are justified by a concrete trigger;
- existing tests and coverage gaps are named;
- cleanup and post-failure state checks are explicit;
- the design validator passes without secrets or credentials.
