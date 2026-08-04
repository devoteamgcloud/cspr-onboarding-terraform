# Changelog

All notable changes to this module are documented here.

## [0.1.1] - 2026-08-04

- README: the Quickstart now leads with the GitHub module-source block
  (`?ref=` pinned) and clarifies that the `examples/` directories need a
  full clone because they reference the repo root via `source = "../.."`.
- Removed the redundant root-level `.terraform.lock.hcl` — provider
  locking belongs to the consuming configuration; each example keeps its
  own lock file.

No changes to module resources or the variable interface.

## [0.1.0] - 2026-08-04

Initial release. Mirrors the CSPR Enhanced onboarding IAM plan
(`build_iam_plan()`) as a self-service Terraform module:

- Scanner service account creation + Devoteam runner impersonation binding.
- Scope-level role grants (project/folder/organization) for the `prowler`,
  `cai_catalog`, and `hybrid` scan engines, with the hybrid role overlap
  deduplicated.
- Host-project quota and BigQuery role grants.
- The `CSPRBucketIamViewer` custom role, scope-aware (project / org / the
  per-project folder loop).
- Cloud Asset Inventory export dataset + service-agent grants for the
  `cai_catalog` and `hybrid` engines.
- Optional host-project creation and billing-account linking.
- Examples for project, folder, and organization scan scope.
