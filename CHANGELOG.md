# Changelog

All notable changes to this module are documented here.

## [0.2.0] - 2026-10-13

**Breaking.** The module is now CAI-only and mirrors the `cai_catalog`
engine of the CSPR Enhanced IAM plan (`build_iam_plan()`) grant for grant.

- Removed the `scanner_engine` and `folder_project_ids` variables.
- Removed the `CSPRBucketIamViewer` custom role (all three scope variants),
  the Prowler roles (`roles/viewer`, `roles/browser`) and the Prowler-only
  API list (`storage.googleapis.com`).
- `target_ids` must now contain exactly one id.
- `cai_dataset_id` is always set (never `null`).
- Fix: `google_project_service_identity.cloudasset` now has
  `depends_on = [google_project_service.apis]`, so the Cloud Asset service
  agent is not requested before the API is enabled on a fresh project.
- The scanner service account display name is now `CSPR scanner (Devoteam)`
  (it no longer claims read-only); this updates the display name in place.
- README rewritten without blanket "read-only" claims: the scanner writes
  the inventory export and stub tables into `cai_ds`. It now documents
  prerequisites, the non-idempotency note (409 on a pre-existing SA or
  dataset) and how to report completion on the setup page.
- Examples are all CAI; CI pins Terraform 1.14.8; `.DS_Store` is ignored.

Migration: Prowler and hybrid users stay on `v0.1.2`. For CAI users, drop
`scanner_engine` and `folder_project_ids` from your module block and pin
`?ref=v0.2.0`. Four CAI resources lost their `count` guard; `moved` blocks
carry their `[0]` instances over, so they are not replaced. A v0.1.x state
that held custom-role or Prowler grants will show those being removed.

## [0.1.2] - 2026-08-07

- Scanner dataset grant changed from `roles/bigquery.dataViewer` to
  `roles/bigquery.dataEditor` (`efce79b`), so the scanner can pre-create
  stub tables for asset types the Cloud Asset export omits.
- The resource was renamed from `scanner_sa_viewer` to `scanner_sa_editor`.
  On upgrade, state replaces the dataset access entry.

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
