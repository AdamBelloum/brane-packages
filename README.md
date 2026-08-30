# brane-packages

A private, curated repository for shared Brane packages, safe package intake, and reproducible migration records.

This repository is separate from deployment infrastructure:

- **`brane-deployment`** remains the source of truth for deployment behaviour, test baselines, and operational configuration.
- **`brane-packages`** contains reusable package source, package metadata, catalogue records, and the tooling used to assess and migrate package candidates.

## Start here: package authors

If you want to submit a new Brane package, start the guided package-author
workflow:

    ./scripts/developer/package_dev_wizard.sh

The wizard guides you through five steps:

1. Select your package folder.
2. Provide a short description and contact details.
3. Check that the package files are complete.
4. Run the package's repeatable `test.sh` check.
5. Create a branch and submit the package for review.

You do not need to understand repository migration, schemas, or catalogue files
to use the wizard. A successful local test means that your package is ready for
review. It does not yet mean that the package is approved or published.

For an explanation of fixed example data used during tests, see
[`tests/fixtures/README.md`](tests/fixtures/README.md).

## Repository contracts

- `packages/` contains reviewed shared packages only.
- `test-fixtures/` contains synthetic or non-production package fixtures only.
- Every tracked package or fixture has a `package.yml` that conforms to `schemas/package-metadata.schema.yml`.
- `catalogue/packages.yml` indexes all tracked packages and fixtures.
- Intake is manifest-driven: discovery creates a proposed manifest; migration requires explicit reviewed `action: migrate` entries with curation metadata.
- Migration derives and validates destination `package.yml` from reviewed curation, source `container.yml`, and recorded provenance.
- No credentials, private keys, client certificate bundles, tokens, production datasets, or generated Brane build artefacts may be committed.

## Layout

```text
catalogue/       Machine-readable package index
docs/            Contributor, intake, review, and security guidance
intake/          Reviewed migration manifests
packages/        Curated reusable Brane packages
schemas/         Versioned YAML/JSON Schema contracts
scripts/
  admin/         Administrator-operated review workflows
  developer/     Package-author development workflows
test-fixtures/   Example packages used to test repository tooling
tests/           Automated regression tests
  fixtures/      Fixed example data used while testing packages
tools/           The package discovery and migration utility
```

## Script entry points

- Administrator package lifecycle:
  `./scripts/admin/package_admin.sh`
- Package developer workflow:
  `./scripts/developer/package_dev_wizard.sh`

## Administrator package lifecycle

Start the administrator interface with `./scripts/admin/package_admin.sh`.

It exposes only enabled curated-package operations:

1. view all catalogue-backed shared packages and test fixtures;
2. request removal of a selected catalogue entry.

Removal requires an exact-name confirmation and always displays the package name,
classification, and repository path first. The operation is performed in an isolated
worktree: it validates the proposed change, removes the package directory and
catalogue entry atomically, runs the applicable repository migration regression tests,
pushes a dedicated branch, and creates a Pull Request automatically.

Removal is evidence-aware. The selected catalogue path must match exactly one
candidate in `intake/*-review.yml`. A one-candidate review manifest is removed with
the package; in a shared manifest, only the selected candidate is removed and
unrelated review evidence remains. The transaction rolls back package, catalogue,
and manifest changes if validation fails.

The lower-level `package_admin_review.sh` remains an implementation-level review
workflow and is not the normal administrator entry point.

## Maintainer intake workflow

This advanced procedure is for repository maintainers reviewing package
submissions. Package authors should normally use the developer wizard above.

1. Run the discovery command against a source directory or repository checkout.
1. Have the package author or responsible team run the interactive review command to supply missing author and curation information.
1. Review the completed manifest and its findings; approve only candidates with `action: migrate`, required `curation`, and a target matching the source `container.yml` name.
1. Validate the reviewed manifest against its schema.
1. Run the controlled migration command in dry-run mode, then execute it only after review.
1. Validate metadata, catalogue entries, and repository safety checks.
1. Open a pull request; merge only after review and required checks pass.
1. Follow the detailed command sequence in [docs/package-intake.md](docs/package-intake.md).

## Development principles

- Prefer deterministic, reviewable transformations over heuristic copying.
- Preserve provenance: migrated package metadata records source location and revision.
- Keep the shared catalogue small, explicit, and compatible with the pinned Brane deployment baseline.
- Treat package source as potentially unsafe until reviewed.
