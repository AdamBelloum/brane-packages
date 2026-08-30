# Example test data

This folder contains small, fixed example data used to check that packages work
as expected.

For example, the `minmax` package test uses `minmax/numbers.csv`. Because its
values are known in advance, the test can confirm that the package returns the
correct minimum and maximum.

## For package authors

You normally do not need to change anything in this folder.

- Put a reusable Brane package in `packages/`.
- Put the package's own repeatable check in `packages/<package-name>/test.sh`.
- Use small, non-sensitive example data when a test needs input data.

The files here remain available after each test. A test may temporarily register
them with Brane as local data, but it does not delete these source files.

## Related folders

- `test-fixtures/` contains example **packages** used to test repository tools.
- `tests/fixtures/` contains example **data** used while testing packages.

They have different purposes.
