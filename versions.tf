# Provider requirements for the CSPR Enhanced onboarding module.
#
# The module only declares required_providers. Provider configuration
# (project, region, credentials) is the caller's responsibility — see
# examples/*/main.tf for minimal provider blocks.

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
