# Variable names in this file are a frozen interface: the CSPR Enhanced
# setup page generates a tfvars file matching these names exactly. Do not
# rename without also updating the generator.

variable "customer_id" {
  description = "Your CSPR customer id, as shown on the CSPR setup page. Used only to derive the scanner service account name (slugified, prefixed 'cspr-scanner-')."
  type        = string

  validation {
    condition     = length(trimspace(var.customer_id)) > 0
    error_message = "customer_id must not be empty."
  }

  validation {
    condition     = can(regex("[a-z0-9]", lower(var.customer_id)))
    error_message = "customer_id must contain at least one letter or digit — it is slugified into the scanner service account name."
  }
}

variable "sa_host_project" {
  description = "The GCP project that will host the read-only scanner service account (and, for the cai_catalog/hybrid engines, the BigQuery export dataset). This is a project you own; it is billed for API calls the scanner makes, not for the resources being scanned."
  type        = string
}

variable "scan_scope" {
  description = "What the scanner reviews: a single project, a folder (and everything under it), or the whole organization."
  type        = string

  validation {
    condition     = contains(["project", "folder", "organization"], var.scan_scope)
    error_message = "scan_scope must be one of: project, folder, organization."
  }
}

variable "target_ids" {
  description = "The ids to scan, matching scan_scope: one or more project ids (scope=project), a folder id (scope=folder), or the organization id (scope=organization). Bare ids only — do not prefix with 'folders/' or 'organizations/'."
  type        = list(string)

  validation {
    condition     = length(var.target_ids) > 0
    error_message = "target_ids must contain at least one id."
  }

  validation {
    condition     = alltrue([for id in var.target_ids : !can(regex("^(projects|folders|organizations)/", id))])
    error_message = "target_ids must be bare ids (e.g. \"123456789\" or \"my-project\"), not prefixed resource names like \"folders/123456789\"."
  }
}

variable "scanner_engine" {
  description = "Which CSPR scan engine to grant access for. The CSPR setup page tells you which value to use for your engagement: prowler (per-resource configuration checks), cai_catalog (Cloud Asset Inventory catalog checks, needs BigQuery), or hybrid (both)."
  type        = string

  validation {
    condition     = contains(["prowler", "cai_catalog", "hybrid"], var.scanner_engine)
    error_message = "scanner_engine must be one of: prowler, cai_catalog, hybrid."
  }
}

variable "devoteam_runner_sa" {
  description = "The Devoteam CSPR runner service account that will be granted permission to impersonate the scanner service account. Leave at the default unless Devoteam tells you otherwise."
  type        = string
  default     = "cspr-runner@cspr-runner.iam.gserviceaccount.com"

  validation {
    condition     = can(regex("^[a-z0-9-]+@[a-z0-9-]+\\.iam\\.gserviceaccount\\.com$", var.devoteam_runner_sa))
    error_message = "devoteam_runner_sa must be a service account email of the form <name>@<project>.iam.gserviceaccount.com — this principal is granted impersonation of the scanner service account."
  }
}

variable "folder_project_ids" {
  description = "Required when scan_scope = \"folder\" and scanner_engine is \"prowler\" or \"hybrid\": the ids of every project under the target folder. Custom IAM roles cannot be created at folder level in GCP, so the CSPRBucketIamViewer role (needed for Prowler's storage-bucket-IAM checks) is created and bound in each of these projects individually. Generate this list with: gcloud asset search-all-resources --scope=folders/FOLDER_ID --asset-types=cloudresourcemanager.googleapis.com/Project --format='value(project)'"
  type        = list(string)
  default     = []
}

variable "create_host_project" {
  description = "If true, this module creates sa_host_project as a new GCP project instead of assuming it already exists. Requires host_project_parent and host_project_billing_account."
  type        = bool
  default     = false
}

variable "host_project_parent" {
  description = "Required when create_host_project = true: the resource-manager parent of the new host project, in the form \"organizations/<id>\" or \"folders/<id>\"."
  type        = string
  default     = null

  validation {
    condition     = var.host_project_parent == null || can(regex("^(organizations|folders)/[^/]+$", var.host_project_parent))
    error_message = "host_project_parent must be in the form organizations/<id> or folders/<id>."
  }
}

variable "host_project_billing_account" {
  description = "Required when create_host_project = true: the billing account id to link to the new host project, e.g. 000000-AAAAAA-000000."
  type        = string
  default     = null
}

variable "create_dataset" {
  description = "CAI engines only (cai_catalog, hybrid). If true, this module creates the 'cai_ds' BigQuery dataset that holds the Cloud Asset Inventory export. If false, a dataset named 'cai_ds' must already exist in sa_host_project and this module only grants access to it. Ignored for the prowler engine."
  type        = bool
  default     = true
}

variable "dataset_location" {
  description = "CAI engines only. The BigQuery location for the 'cai_ds' dataset when create_dataset = true. This is only a suggested default: the scanner detects the dataset's real location at scan time, so any valid BigQuery location works."
  type        = string
  default     = "europe-west1"
}

variable "enable_apis" {
  description = "If true (default), this module enables the required Google APIs on sa_host_project. APIs are never disabled on destroy (see disable_on_destroy in main.tf), so turning this off just skips the enablement step — it does not disable anything already enabled."
  type        = bool
  default     = true
}
