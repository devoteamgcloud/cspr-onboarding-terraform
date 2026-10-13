# Minimal example: folder scan scope (Cloud Asset Inventory scan).
#
# Replace every "acme-*" placeholder and the folder id with your own values
# before running.

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
  scan_scope      = "folder"
  target_ids      = ["123456789012"]
}

output "scanner_sa_email" {
  description = "Paste this back into the CSPR setup page."
  value       = module.cspr_onboarding.scanner_sa_email
}

output "cai_dataset_id" {
  value = module.cspr_onboarding.cai_dataset_id
}
