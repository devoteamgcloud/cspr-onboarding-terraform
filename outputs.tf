output "scanner_sa_email" {
  description = "The scanner service account email. Paste this back into the CSPR setup page to complete onboarding."
  value       = google_service_account.scanner.email
}

output "sa_account_id" {
  description = "The derived (slugified) scanner service account id, e.g. cspr-scanner-<customer-slug>."
  value       = local.sa_account_id
}

output "granted_scope_roles" {
  description = "Map of each target id to the list of IAM roles granted to the scanner SA at that scope, for review/audit."
  value = {
    for target in toset(var.target_ids) :
    target => sort([for grant in local.scope_grants : grant.role if grant.target == target])
  }
}

output "cai_dataset_id" {
  description = "The BigQuery Cloud Asset Inventory export dataset id that this module created or references."
  value       = local.cai_dataset_id
}
