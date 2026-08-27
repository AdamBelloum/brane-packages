# Package intake

This repository accepts package source only through a reviewed migration manifest.
Discovery and migration do not execute package code, build images, install
dependencies, or publish packages.

## Safe intake sequence

1. Discover candidate directories from a local source checkout:

       .venv/bin/brane-package-migrate discover \
         --source /path/to/source-checkout \
         --output intake/source-review.yml

2. Review `intake/source-review.yml`. Do not approve candidates with unresolved
   blocking findings. Set only approved candidates to `action: migrate`.

3. For every approved candidate, set:

   - `classification` to `reusable` or `fixture`;
   - `target_path` to `packages/<package-name>` or
     `test-fixtures/<fixture-name>`, respectively.

4. Ensure the source candidate already contains `package.yml` conforming to
   `schemas/package-metadata.schema.yml`. Its `name` and `classification` must
   match the intended target.

5. Validate the reviewed manifest:

       .venv/bin/brane-package-migrate validate \
         --document intake/source-review.yml \
         --schema schemas/migration-manifest.schema.yml

6. Run the migration dry run. This is the default and makes no changes:

       .venv/bin/brane-package-migrate migrate \
         --manifest intake/source-review.yml

7. Execute only after reviewing the dry-run targets:

       .venv/bin/brane-package-migrate migrate \
         --manifest intake/source-review.yml \
         --execute

8. Validate the resulting repository:

       .venv/bin/brane-package-migrate validate-repository

## Migration safeguards

Migration refuses manifests or candidates that are unsafe or incomplete,
including:

- schema-invalid manifests or metadata;
- `unsupported` or `needs-review` candidates marked for migration;
- candidates with blocking discovery findings;
- absolute or parent-traversal paths;
- symlinks in source candidates or destination ancestors;
- existing destination paths, duplicate migration targets, or duplicate
  package names within one migration;
- source metadata whose classification or name does not match the approved
  target.

A successful execution copies the approved source tree, adds a derived
catalogue entry, and validates the complete repository. If post-migration
validation fails, copied directories and catalogue changes are rolled back.

## Scope

Only `local-path` sources are currently supported. Git repository acquisition,
automatic metadata generation, package execution, and publication are
deliberately out of scope.
