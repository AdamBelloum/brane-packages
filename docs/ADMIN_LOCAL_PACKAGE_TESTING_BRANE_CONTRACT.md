# Brane CLI Contract for Local Administrator Package Testing

## Purpose

`brane-packages` will provide a local administrator acceptance-test workflow.
It must test a submitted package action inside the local package container,
without connecting to Brane deployment infrastructure.

This document defines the minimum Brane release capabilities required before
functional administrator package testing can be enabled.

## Required release assets

The release lock used by the administrator workflow must explicitly provide a
checksum-locked Brane CLI asset for every supported administrator platform.

At minimum:

| Platform | Required asset |
|---|---|
| Linux x86_64 | `brane-linux-x86_64` |
| macOS Apple Silicon | `brane-macos-aarch64`, or an explicitly documented equivalent |

For every asset, the release lock must provide:

- an immutable release-lock commit;
- release tag or version;
- download URL;
- SHA-256 checksum; and
- explicit platform key.

The administrator runner must not guess asset names, use a Linux binary on
macOS, use an unpinned nightly release, or build Brane from source.

## Interactive local action testing

The shared package-test harness uses the approved local Brane CLI and Docker.
It guides a developer or administrator through each required action test.

For each declared package action, the harness must:

1. Display the action name, intended inputs, and expected result.
2. Start the local Brane package test command.
3. Allow the operator to select the required action and provide the stated
   inputs through Brane's normal interactive prompts.
4. Display the result or requested intermediate-result file.
5. Require the operator to confirm `PASSED` or `FAILED`.
6. Record the action, stated inputs, expected result, operator confirmation,
   timestamp, and command log.

The developer runs these cases before submission. The administrator repeats the
same cases against the exact Pull Request commit as an independent acceptance
check.

The harness must read `container.yml` and prevent a passing test result when a
declared action has not been tested. This is coverage of required test cases;
the final result remains an operator-attested review of the displayed package
output.

## Behaviour before this contract is met

When the required matching platform asset, Docker capability, or local Brane
CLI is unavailable, `package_admin_test.sh` must report `INCONCLUSIVE`.

The absence of these administrator-environment capabilities must never be
reported as a failure of the submitted package.

## Evidence requirements

Each acceptance-test report must record:

- resolved release-lock commit;
- CLI version and executable path;
- platform asset URL and SHA-256 checksum;
- selected package action;
- machine-readable supplied test input;
- command exit status;
- actual result or intermediate-result evidence; and
- comparison with the expected test result.
