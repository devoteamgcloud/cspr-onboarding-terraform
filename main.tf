# CSPR Enhanced customer-side onboarding module.
#
# Mirrors, resource for resource, the IAM plan produced by
# app/src/cspr_core/iam_plan.py (build_iam_plan) in the CSPR Enhanced
# codebase — the same grants a customer admin would otherwise paste into
# Cloud Shell from the CSPR setup page. See README.md for what each grant
# is for.
#
# Not expressed here (see README "What this does not do"):
#   - Domain Restricted Sharing (org policy constraints/iam.allowedPolicyMemberDomains)
#     override: a manual precondition, not an operation in the source plan.
#   - Off-boarding: this module's off-boarding path is `terraform destroy`.
#     Revoking the impersonation binding is the instant cutoff; the CAI
#     export dataset survives destroy by design (delete_contents_on_destroy
#     = false) unless you remove it yourself.

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

  is_prowler = var.scanner_engine == "prowler" || var.scanner_engine == "hybrid"
  is_cai     = var.scanner_engine == "cai_catalog" || var.scanner_engine == "hybrid"

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

  # ---------------------------------------------------------------------
  # API enablement (spec §2b) — union, de-duplicated, for the hybrid engine.
  # ---------------------------------------------------------------------
  prowler_apis = [
    "serviceusage.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "cloudasset.googleapis.com",
    "iam.googleapis.com",
    "storage.googleapis.com",
  ]
  cai_apis = [
    "serviceusage.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "iam.googleapis.com",
    "cloudasset.googleapis.com",
    "bigquery.googleapis.com",
  ]
  apis_to_enable = toset(concat(
    local.is_prowler ? local.prowler_apis : [],
    local.is_cai ? local.cai_apis : [],
  ))

  # ---------------------------------------------------------------------
  # Scan-target (scope-level) role grants (spec §2c). Prowler and CAI each
  # want roles/cloudasset.viewer at folder/org scope; toset() dedupes that
  # overlap for the hybrid engine so it's granted exactly once, matching
  # the seen_scope_grants dedupe in iam_plan.py.
  # ---------------------------------------------------------------------
  prowler_roles_by_scope = {
    project      = ["roles/viewer"]
    folder       = ["roles/viewer", "roles/browser", "roles/cloudasset.viewer"]
    organization = ["roles/viewer", "roles/browser", "roles/cloudasset.viewer"]
  }
  cai_scope_roles = ["roles/cloudasset.viewer"]

  scope_roles = toset(concat(
    local.is_prowler ? local.prowler_roles_by_scope[var.scan_scope] : [],
    local.is_cai ? local.cai_scope_roles : [],
  ))

  scope_grants = {
    for pair in setproduct(var.target_ids, local.scope_roles) :
    "${pair[0]}|${pair[1]}" => { target = pair[0], role = pair[1] }
  }

  # ---------------------------------------------------------------------
  # Host-project (quota/BigQuery) role grants (spec §2d). Hybrid must NOT
  # get serviceusage.serviceUsageConsumer twice — the CAI role set already
  # includes it, so prowler-only adds it separately and cai/hybrid don't.
  # ---------------------------------------------------------------------
  host_project_roles = local.is_cai ? [
    "roles/bigquery.jobUser",
    "roles/serviceusage.serviceUsageConsumer",
  ] : ["roles/serviceusage.serviceUsageConsumer"]

  # ---------------------------------------------------------------------
  # CSPRBucketIamViewer custom role (spec §3) — applies to every engine
  # except cai_catalog-only (prowler needs it, hybrid needs it).
  # ---------------------------------------------------------------------
  create_custom_role = local.is_prowler

  # project scope: one role + binding per target project.
  custom_role_project_targets = local.create_custom_role && var.scan_scope == "project" ? toset(var.target_ids) : toset([])

  # organization scope: one role + binding per target org id (normally exactly one).
  custom_role_org_targets = local.create_custom_role && var.scan_scope == "organization" ? toset(var.target_ids) : toset([])

  # folder scope: custom roles cannot live on folders in GCP, so the role
  # is created and bound in each descendant project the caller supplies
  # via folder_project_ids (see the README for the discovery one-liner).
  custom_role_folder_projects = local.create_custom_role && var.scan_scope == "folder" ? toset(var.folder_project_ids) : toset([])

  # ---------------------------------------------------------------------
  # CAI dataset id — fixed, matches CAI_DATASET_ID in iam_plan.py.
  # ---------------------------------------------------------------------
  cai_dataset_id = local.is_cai ? (var.create_dataset ? google_bigquery_dataset.cai_ds[0].dataset_id : "cai_ds") : null
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
  display_name = "CSPR scanner (Devoteam, read-only)"

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
    precondition {
      condition     = !(var.scan_scope == "folder" && var.scanner_engine != "cai_catalog") || length(var.folder_project_ids) > 0
      error_message = "folder_project_ids must be non-empty when scan_scope = \"folder\" and scanner_engine is \"prowler\" or \"hybrid\" — custom roles can't live on folders, so CSPRBucketIamViewer needs the list of descendant projects. See the README for the discovery command."
    }
  }
}

resource "google_service_account_iam_member" "impersonation" {
  service_account_id = google_service_account.scanner.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${var.devoteam_runner_sa}"
}

# ---------------------------------------------------------------------------
# Scan-target (scope-level) role grants
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
  for_each = toset(local.host_project_roles)

  project = local.sa_host_project_id
  role    = each.value
  member  = "serviceAccount:${local.scanner_sa_email}"
}

# ---------------------------------------------------------------------------
# CSPRBucketIamViewer custom role (prowler, hybrid — not cai_catalog-only)
# ---------------------------------------------------------------------------

resource "google_project_iam_custom_role" "bucket_iam_viewer_project" {
  for_each = local.custom_role_project_targets

  project     = each.value
  role_id     = "CSPRBucketIamViewer"
  title       = "CSPR bucket IAM viewer"
  description = "CSPR scanner: read bucket IAM policies"
  permissions = ["storage.buckets.getIamPolicy"]
  stage       = "GA"
}

resource "google_project_iam_member" "bucket_iam_viewer_project" {
  for_each = local.custom_role_project_targets

  project = each.value
  role    = google_project_iam_custom_role.bucket_iam_viewer_project[each.key].id
  member  = "serviceAccount:${local.scanner_sa_email}"
}

resource "google_organization_iam_custom_role" "bucket_iam_viewer_org" {
  for_each = local.custom_role_org_targets

  org_id      = each.value
  role_id     = "CSPRBucketIamViewer"
  title       = "CSPR bucket IAM viewer"
  description = "CSPR scanner: read bucket IAM policies"
  permissions = ["storage.buckets.getIamPolicy"]
  stage       = "GA"
}

resource "google_organization_iam_member" "bucket_iam_viewer_org" {
  for_each = local.custom_role_org_targets

  org_id = each.value
  role   = google_organization_iam_custom_role.bucket_iam_viewer_org[each.key].id
  member = "serviceAccount:${local.scanner_sa_email}"
}

resource "google_project_iam_custom_role" "bucket_iam_viewer_folder_project" {
  for_each = local.custom_role_folder_projects

  project     = each.value
  role_id     = "CSPRBucketIamViewer"
  title       = "CSPR bucket IAM viewer"
  description = "CSPR scanner: read bucket IAM policies"
  permissions = ["storage.buckets.getIamPolicy"]
  stage       = "GA"
}

resource "google_project_iam_member" "bucket_iam_viewer_folder_project" {
  for_each = local.custom_role_folder_projects

  project = each.value
  role    = google_project_iam_custom_role.bucket_iam_viewer_folder_project[each.key].id
  member  = "serviceAccount:${local.scanner_sa_email}"
}

# ---------------------------------------------------------------------------
# CAI extras (cai_catalog, hybrid) — export dataset + service-agent grants
# ---------------------------------------------------------------------------

resource "google_bigquery_dataset" "cai_ds" {
  count = local.is_cai && var.create_dataset ? 1 : 0

  project     = local.sa_host_project_id
  dataset_id  = "cai_ds"
  location    = var.dataset_location
  description = "CSPR Cloud Asset Inventory export (Devoteam)"

  # Off-boarding keeps the customer's exported inventory unless they
  # explicitly delete the dataset themselves.
  delete_contents_on_destroy = false

  # BigQuery API must be enabled before the dataset can be created on a
  # fresh host project.
  depends_on = [google_project_service.apis]
}

# Scanner SA only needs bigquery.jobUser (host project, granted above) +
# dataset-level dataViewer to run catalog queries — not dataOwner.
resource "google_bigquery_dataset_access" "scanner_sa_viewer" {
  count = local.is_cai ? 1 : 0

  project       = local.sa_host_project_id
  dataset_id    = local.cai_dataset_id
  role          = "roles/bigquery.dataViewer"
  user_by_email = local.scanner_sa_email
}

# The Cloud Asset service agent is created lazily by Google; it must be
# materialized before it can be granted IAM roles, or the grant 400s.
resource "google_project_service_identity" "cloudasset" {
  provider = google-beta
  count    = local.is_cai ? 1 : 0

  project = local.sa_host_project_id
  service = "cloudasset.googleapis.com"
}

resource "google_project_iam_member" "cloudasset_agent_jobuser" {
  count = local.is_cai ? 1 : 0

  project = local.sa_host_project_id
  role    = "roles/bigquery.jobUser"
  member  = google_project_service_identity.cloudasset[0].member
}

# Service agent needs both dataEditor (dataset) and jobUser (project) for
# cross-project folder/org exports.
resource "google_bigquery_dataset_access" "cloudasset_agent_editor" {
  count = local.is_cai ? 1 : 0

  project       = local.sa_host_project_id
  dataset_id    = local.cai_dataset_id
  role          = "roles/bigquery.dataEditor"
  user_by_email = google_project_service_identity.cloudasset[0].email
}
