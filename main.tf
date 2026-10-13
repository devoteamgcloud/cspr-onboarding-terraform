# CSPR Enhanced customer-side onboarding module (Cloud Asset Inventory scan).
#
# Mirrors, resource for resource, the IAM plan produced by the CSPR Enhanced
# build_iam_plan() (engine cai_catalog): the same grants a customer admin
# would otherwise paste into Cloud Shell from the CSPR setup page. See
# README.md for what each grant is for.
#
# Not expressed here (see README "What this does not do"):
#   - Domain Restricted Sharing (org policy constraints/iam.allowedPolicyMemberDomains)
#     override: a manual precondition, not an operation in the source plan.
#   - The completion check the gcloud plan runs (verify_access): paste
#     scanner_sa_email into the CSPR setup page instead.
#   - Off-boarding: see README. Revoking the impersonation binding stops new
#     tokens; also disable the scanner SA for an urgent cutoff. The export
#     dataset has delete_contents_on_destroy = false, so a destroy fails once
#     it holds tables; remove it from state first to keep the export.

locals {
  # ---------------------------------------------------------------------
  # Scanner SA account id — mirrors _sa_account_id() in iam_plan.py:
  #   re.sub(r"[^a-z0-9]+", "-", customer_id.lower()).strip("-"),
  #   prefixed "cspr-scanner-", truncated to 30 chars, trailing "-" stripped.
  # The regex substitution already collapses any run of non-alnum chars
  # into a single "-", so a single trimprefix/trimsuffix per step is
  # equivalent to Python's strip("-") (which removes runs of "-" too).
  # ---------------------------------------------------------------------
  sa_slug_collapsed   = replace(lower(var.customer_id), "/[^a-z0-9]+/", "-")
  sa_slug             = trimsuffix(trimprefix(local.sa_slug_collapsed, "-"), "-")
  sa_account_id_full  = "cspr-scanner-${local.sa_slug}"
  sa_account_id_trunc = length(local.sa_account_id_full) > 30 ? substr(local.sa_account_id_full, 0, 30) : local.sa_account_id_full
  sa_account_id       = trimsuffix(local.sa_account_id_trunc, "-")

  scanner_sa_email = google_service_account.scanner.email

  # ---------------------------------------------------------------------
  # Host project: created by this module, or assumed to already exist.
  # local.sa_host_project_id is referenced (not var.sa_host_project
  # directly) everywhere else so Terraform's dependency graph forces
  # project creation to finish first when create_host_project = true.
  # ---------------------------------------------------------------------
  host_project_parent_parts = var.create_host_project && var.host_project_parent != null ? split("/", var.host_project_parent) : []
  host_project_parent_type  = length(local.host_project_parent_parts) == 2 ? local.host_project_parent_parts[0] : null
  host_project_parent_id    = length(local.host_project_parent_parts) == 2 ? local.host_project_parent_parts[1] : null

  sa_host_project_id = var.create_host_project ? google_project.host[0].project_id : var.sa_host_project

  # API enablement — CAI_APIS in iam_plan.py.
  apis_to_enable = toset([
    "serviceusage.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "cloudasset.googleapis.com",
    "bigquery.googleapis.com",
  ])

  # Scan-target (scope-level) role — CAI_SCOPE_ROLES in iam_plan.py.
  scope_roles = toset(["roles/cloudasset.viewer"])

  scope_grants = {
    for pair in setproduct(var.target_ids, local.scope_roles) :
    "${pair[0]}|${pair[1]}" => { target = pair[0], role = pair[1] }
  }

  # Host-project (quota/BigQuery) roles — CAI_PROJECT_ROLES in iam_plan.py.
  host_project_roles = toset([
    "roles/bigquery.jobUser",
    "roles/serviceusage.serviceUsageConsumer",
  ])

  # Fixed dataset id — CAI_DATASET_ID in iam_plan.py.
  cai_dataset_id = "cai_ds"
}

# ---------------------------------------------------------------------------
# Host project (optional)
# ---------------------------------------------------------------------------

resource "google_project" "host" {
  count = var.create_host_project ? 1 : 0

  name            = var.sa_host_project
  project_id      = var.sa_host_project
  org_id          = local.host_project_parent_type == "organizations" ? local.host_project_parent_id : null
  folder_id       = local.host_project_parent_type == "folders" ? local.host_project_parent_id : null
  billing_account = var.host_project_billing_account

  # Off-boarding must never delete the customer's host project (it may
  # hold the CAI export dataset and other workloads). This makes the
  # provider's current default explicit and self-documenting.
  deletion_policy = "PREVENT"
}

# ---------------------------------------------------------------------------
# API enablement
# ---------------------------------------------------------------------------

resource "google_project_service" "apis" {
  for_each = var.enable_apis ? local.apis_to_enable : toset([])

  project = local.sa_host_project_id
  service = each.value

  # Never disable a customer's APIs on destroy/off-boarding — other
  # workloads in sa_host_project may depend on them.
  disable_on_destroy = false
}

# ---------------------------------------------------------------------------
# Scanner service account + Devoteam impersonation
# ---------------------------------------------------------------------------

resource "google_service_account" "scanner" {
  project      = local.sa_host_project_id
  account_id   = local.sa_account_id
  display_name = "CSPR scanner (Devoteam)"

  # On a fresh host project the IAM API may not be enabled yet; without
  # this edge Terraform may try to create the SA before enablement lands.
  depends_on = [google_project_service.apis]

  # Cross-variable rules live here (not in `check` blocks, which only
  # WARN on failure) so a misconfigured plan hard-fails: every other
  # resource in the module depends on this SA, so a failed precondition
  # stops the whole apply.
  lifecycle {
    precondition {
      condition     = !var.create_host_project || (var.host_project_parent != null && var.host_project_billing_account != null)
      error_message = "create_host_project = true requires both host_project_parent and host_project_billing_account to be set."
    }
  }
}

resource "google_service_account_iam_member" "impersonation" {
  service_account_id = google_service_account.scanner.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${var.devoteam_runner_sa}"
}

# ---------------------------------------------------------------------------
# Scan-target (scope-level) role grant: roles/cloudasset.viewer on the target
# ---------------------------------------------------------------------------

resource "google_project_iam_member" "scope_grant" {
  for_each = var.scan_scope == "project" ? local.scope_grants : {}

  project = each.value.target
  role    = each.value.role
  member  = "serviceAccount:${local.scanner_sa_email}"
}

resource "google_folder_iam_member" "scope_grant" {
  for_each = var.scan_scope == "folder" ? local.scope_grants : {}

  folder = "folders/${each.value.target}"
  role   = each.value.role
  member = "serviceAccount:${local.scanner_sa_email}"
}

resource "google_organization_iam_member" "scope_grant" {
  for_each = var.scan_scope == "organization" ? local.scope_grants : {}

  org_id = each.value.target
  role   = each.value.role
  member = "serviceAccount:${local.scanner_sa_email}"
}

# ---------------------------------------------------------------------------
# Host-project (quota/BigQuery) role grants
# ---------------------------------------------------------------------------

resource "google_project_iam_member" "host_project_grant" {
  for_each = local.host_project_roles

  project = local.sa_host_project_id
  role    = each.value
  member  = "serviceAccount:${local.scanner_sa_email}"
}

# ---------------------------------------------------------------------------
# Cloud Asset Inventory export dataset + service-agent grants
# ---------------------------------------------------------------------------

resource "google_bigquery_dataset" "cai_ds" {
  count = var.create_dataset ? 1 : 0

  project     = local.sa_host_project_id
  dataset_id  = local.cai_dataset_id
  location    = var.dataset_location
  description = "CSPR Cloud Asset Inventory export (Devoteam)"

  # Never auto-delete exported data: a destroy removes an EMPTY dataset but
  # fails while it holds tables (see README Off-boarding).
  delete_contents_on_destroy = false

  # BigQuery API must be enabled before the dataset can be created on a
  # fresh host project.
  depends_on = [google_project_service.apis]
}

# Note: a first apply can hit a BigQuery concurrent-modification error on
# the dataset ACL (the two access resources below edit it); re-run apply.
#
# Scanner SA needs bigquery.jobUser (host project, granted above) plus
# dataset-level dataEditor — not dataOwner, and not merely dataViewer.
# Cloud Asset writes no table at all for an asset type you happen not to
# use, so the scanner pre-creates empty stub tables in this dataset for
# those types. Without create rights every control that references a
# missing type silently returns nothing and the review reports a clean
# domain it never actually assessed. Scope stays this one dataset, which
# holds your own inventory export.
#
# The resource name is kept from v0.1.2 so upgrading does not churn state.
resource "google_bigquery_dataset_access" "scanner_sa_editor" {
  project       = local.sa_host_project_id
  dataset_id    = local.cai_dataset_id
  role          = "roles/bigquery.dataEditor"
  user_by_email = local.scanner_sa_email

  # Order after the dataset when this module creates it (count-guarded
  # resource, so the dependency is explicit rather than via an attribute).
  depends_on = [google_bigquery_dataset.cai_ds]
}

# The Cloud Asset service agent is created lazily by Google; it must be
# materialized before it can be granted IAM roles, or the grant 400s. The
# cloudasset API has to be enabled first, hence the depends_on.
resource "google_project_service_identity" "cloudasset" {
  provider = google-beta

  project = local.sa_host_project_id
  service = "cloudasset.googleapis.com"

  depends_on = [google_project_service.apis]
}

resource "google_project_iam_member" "cloudasset_agent_jobuser" {
  project = local.sa_host_project_id
  role    = "roles/bigquery.jobUser"
  member  = google_project_service_identity.cloudasset.member
}

# Service agent needs both dataEditor (dataset) and jobUser (project) for
# cross-project folder/org exports.
resource "google_bigquery_dataset_access" "cloudasset_agent_editor" {
  project       = local.sa_host_project_id
  dataset_id    = local.cai_dataset_id
  role          = "roles/bigquery.dataEditor"
  user_by_email = google_project_service_identity.cloudasset.email

  depends_on = [google_bigquery_dataset.cai_ds]
}

# ---------------------------------------------------------------------------
# State migration from v0.1.x: these resources lost their `count` guard in
# v0.2.0, so move the [0] instances instead of destroying and recreating them.
# ---------------------------------------------------------------------------

moved {
  from = google_bigquery_dataset_access.scanner_sa_editor[0]
  to   = google_bigquery_dataset_access.scanner_sa_editor
}

moved {
  from = google_project_service_identity.cloudasset[0]
  to   = google_project_service_identity.cloudasset
}

moved {
  from = google_project_iam_member.cloudasset_agent_jobuser[0]
  to   = google_project_iam_member.cloudasset_agent_jobuser
}

moved {
  from = google_bigquery_dataset_access.cloudasset_agent_editor[0]
  to   = google_bigquery_dataset_access.cloudasset_agent_editor
}
