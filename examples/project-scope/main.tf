# Minimal example: single-project scan scope, Prowler engine.
#
# Replace every "acme-*" placeholder with your own values before running.

terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 7.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = "~> 7.0"
    }
  }
}

provider "google" {
  project = "acme-scanner-host"
  region  = "europe-west1"
}

provider "google-beta" {
  project = "acme-scanner-host"
  region  = "europe-west1"
}

module "cspr_onboarding" {
  source = "../.."

  customer_id     = "acme-corp"
  sa_host_project = "acme-scanner-host"
  scan_scope      = "project"
  target_ids      = ["acme-prod-project"]
  scanner_engine  = "prowler"

  # Uncomment to have this module create sa_host_project instead of
  # assuming it already exists:
  # create_host_project           = true
  # host_project_parent           = "organizations/123456789012"
  # host_project_billing_account  = "000000-AAAAAA-000000"
}

output "scanner_sa_email" {
  description = "Paste this back into the CSPR setup page."
  value       = module.cspr_onboarding.scanner_sa_email
}

output "granted_scope_roles" {
  value = module.cspr_onboarding.granted_scope_roles
}
