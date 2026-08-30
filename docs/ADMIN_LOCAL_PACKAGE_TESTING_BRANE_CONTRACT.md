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

## Required non-interactive local action test

The current `brane package test <name> [version]` command is interactive. It
requires terminal selection of one package action and terminal entry or
selection of action inputs. It cannot be used as the automated acceptance-test
interface.

The corrected release must provide a stable non-interactive mechanism that can:

1. Select one explicit package action.
2. Supply every action input without terminal prompts.
3. Execute the action in the local package container.
4. Expose the returned value or requested intermediate-result file for an
   automated assertion.
5. Return a reliable process exit status.
6. Run without Brane central/worker infrastructure, certificates, instances,
   policies, or remote execution.

The exact command syntax is a Brane release decision. A suitable interface
would accept a package, version, action name, machine-readable input, and a
machine-readable result location or format.

## Behaviour before this contract is met

When the required platform asset or non-interactive action-test capability is
unavailable, `package_admin_test.sh` must report `INCONCLUSIVE`.

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
