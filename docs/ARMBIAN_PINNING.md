# Armbian Build Framework Pinning

## Policy

The Armbian Build Framework is used as an upstream build dependency.
It is pinned to a specific commit SHA and treated as read-only.

No tablet-specific changes are committed into the upstream worktree.

## Current Pin

```
Repository: armbian/build
Commit:     (to be set after initialization)
Date:       (to be set)
Verified:   prepare-armbian-worktree.sh
```

## Lockfile Location

`platform/armbian/source-lock/armbian-build.lock`

## Update Procedure

1. Review Armbian changelog for the target commit range
2. Update the lockfile with the new commit SHA
3. Run `prepare-armbian-worktree.sh --clean --profile samwise-minimal`
4. Build and verify: `build-image.sh --profile samwise-minimal`
5. Run full hardware test matrix
6. If passing, commit the lockfile update with rationale
7. If failing, revert to previous pin

## Integration Method

The project uses one of:
- **Git submodule** at `third_party/armbian-build` (preferred for reproducibility)
- **Pinned clone** managed by `prepare-armbian-worktree.sh`

The preparation script verifies the checkout matches the lockfile before any build.

## Validation Against Pinned Source

All Armbian configuration conventions (board definitions, family names, extension hooks, userpatch paths) must be validated against the pinned source revision.

Internet examples, blog posts, and documentation for other Armbian versions may not match the pinned revision's behavior.
