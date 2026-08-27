# brane-packages

A private, curated repository for shared Brane packages, safe package intake, and reproducible migration records.

This repository is separate from deployment infrastructure:

- **`brane-deployment`** remains the source of truth for deployment behaviour, test baselines, and operational configuration.
- **`brane-packages`** contains reusable package source, package metadata, catalogue records, and the tooling used to assess and migrate package candidates.

## Repository contracts

- `packages/` contains reviewed shared packages only.
- `test-fixtures/` contains synthetic or non-production package fixtures only.
- Every tracked package or fixture has a `package.yml` that conforms to `schemas/package-metadata.schema.yml`.
- `catalogue/packages.yml` indexes all tracked packages and fixtures.
- Intake is manifest-driven: discovery creates a proposed manifest; migration requires explicit reviewed `action: migrate` entries.
- No credentials, private keys, client certificate bundles, tokens, production datasets, or generated Brane build artefacts may be committed.

## Layout

```text
catalogue/       Machine-readable package index
docs/            Contributor, intake, review, and security guidance
intake/          Reviewed migration manifests
packages/        Curated reusable Brane packages
schemas/         Versioned YAML/JSON Schema contracts
scripts/         Validation and developer automation
test-fixtures/   Synthetic fixtures for tooling tests
tools/           The package discovery and migration utility
```
## Initial workflow

1. Run the discovery command against a source directory or repository checkout.
1. Review the generated migration manifest and its findings.
1. Mark only approved candidates with action: migrate.
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
