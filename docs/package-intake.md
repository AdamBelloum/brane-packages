# Package intake

This repository accepts package source only through a reviewed migration manifest.
Discovery and migration do not execute package code, build images, install
dependencies, or publish packages.

## Safe intake sequence

1. Discover candidate directories from a local source checkout:

       .venv/bin/brane-package-migrate discover \
         --source /path/to/source-checkout \
         --output intake/source-review.yml

2. Ask the package author, or the responsible team, to complete the
   interactive review. It prompts for missing author identity, classification,
   approval action, and—when migration is approved—the required curation data:

       .venv/bin/brane-package-migrate review \
         --manifest intake/source-review.yml

   The command validates its completed document before overwriting the manifest.
   It does not execute package code or migrate package files.

3. Review the completed `intake/source-review.yml`. Do not approve candidates
   with unresolved blocking findings. Only candidates with explicit
   `action: migrate` are eligible for migration.

4. For every approved candidate, confirm:

   - `author.name` identifies the author or responsible team;
   - `classification` is `reusable` or `fixture`;
   - `target_path` is `packages/<package-name>` or
     `test-fixtures/<fixture-name>`, respectively;
   - curation status, description, maintainers, compatibility, and
     data-handling declarations are accurate.

5. Ensure the source candidate contains `container.yml` with non-empty string
   `name` and `version` values. The name must be a valid Brane package
   identifier and the version must be a valid semantic version. The source
   does not need to contain repository `package.yml`.

   Migration derives destination `package.yml` from the reviewed `curation`
   data, the source `container.yml`, and recorded local-path provenance. It
   validates that generated metadata against
   `schemas/package-metadata.schema.yml`.

6. Validate the reviewed manifest:

       .venv/bin/brane-package-migrate validate \
         --document intake/source-review.yml \
         --schema schemas/migration-manifest.schema.yml

7. Run the migration dry run. This is the default and makes no changes:

       .venv/bin/brane-package-migrate migrate \
         --manifest intake/source-review.yml

8. Execute only after reviewing the dry-run targets:

       .venv/bin/brane-package-migrate migrate \
         --manifest intake/source-review.yml \
         --execute

9. Validate the resulting repository:

       .venv/bin/brane-package-migrate validate-repository

## Migration safeguards

Migration refuses manifests or candidates that are unsafe or incomplete,
including:

- schema-invalid manifests or generated package metadata;
- `unsupported` or `needs-review` candidates marked for migration;
- candidates with blocking discovery findings;
- missing or invalid source `container.yml`;
- absolute or parent-traversal paths;
- symlinks in source candidates or destination ancestors;
- existing destination paths, duplicate migration targets, or duplicate
  package names within one migration;
- target paths that do not match the approved classification and the package
  name derived from `container.yml`.

A successful execution copies the approved source tree, writes generated
`package.yml`, adds a derived catalogue entry, and validates the complete
repository. If post-migration validation fails, copied directories and
catalogue changes are rolled back.

## Scope

Only `local-path` sources are currently supported. Git repository acquisition,
package execution, image building, and publication are deliberately out of
scope. Deterministic generation of destination repository metadata from
reviewed manifest curation is in scope.
