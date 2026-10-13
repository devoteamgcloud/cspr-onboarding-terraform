# CSPR Enhanced — customer onboarding Terraform module

This module gives Devoteam's CSPR Enhanced scanner the access it needs to
review your GCP environment through Cloud Asset Inventory (CAI), without
ever creating or handing over a service account key. It mirrors the IAM
plan the CSPR setup page renders as a copy-paste `gcloud`/`bq` script, so
it is the same access applied with `terraform apply` instead of pasting
commands into Cloud Shell.

Since v0.2.0 the module covers the CAI scan only. The earlier Prowler and
hybrid engines are retired; if you still need them, stay on `v0.1.2`.

## What this grants, and why

Everything below is granted to one service account that lives in your own
project (`sa_host_project`). Devoteam never gets a key for it. Devoteam's
runner service account is only allowed to *impersonate* it, and you can
revoke that at any time.

| Grant | Why |
|---|---|
| `roles/iam.serviceAccountTokenCreator` on the scanner SA, for Devoteam's runner SA | Lets Devoteam impersonate the scanner SA to run scans. This is the single binding that matters for access control: remove it and Devoteam is cut off instantly. |
| `roles/cloudasset.viewer` on the scan target (project, folder or organization) | Lets the scanner read your Cloud Asset Inventory for the org, identity and inventory checks. |
| `roles/serviceusage.serviceUsageConsumer` on the host project | Lets the scanner make billed API calls against your host project's quota. |
| `roles/bigquery.jobUser` on the host project, for the scanner SA | Lets the scanner run BigQuery jobs against the Cloud Asset export. |
| `roles/bigquery.jobUser` on the host project, for the Cloud Asset service agent | Lets Cloud Asset create the BigQuery load job for the export. |
| BigQuery dataset `cai_ds` (location `dataset_location`) | Holds the Cloud Asset Inventory export. |
| `roles/bigquery.dataEditor` on `cai_ds`, for the scanner SA | The scanner reads the export and also pre-creates empty stub tables for asset types your environment does not use. Cloud Asset writes no table for those, and without a stub the matching checks cannot run and would be reported as unassessed. |
| `roles/bigquery.dataEditor` on `cai_ds`, for the Cloud Asset service agent | Lets Cloud Asset write the export into the dataset. |

### What the scanner can and cannot do

The scanner has no write role on your projects, folders or organization.
Its one write path is the `cai_ds` dataset in your host project: it writes
the inventory export and the stub tables there, and nowhere else. The
scan reads your inventory metadata, including IAM policies and
organization policies, because that is what the review assesses. No API
key or service account key is ever created.

### What this does not do

- **Domain Restricted Sharing.** If your organization enforces the
  `constraints/iam.allowedPolicyMemberDomains` org policy, it will block
  the impersonation grant to Devoteam's external runner SA. This module
  does not touch org policy. If the constraint applies to you, add a
  project-level exception on `sa_host_project` before applying (or ask
  your GCP admin to do so).
- **Completion check.** The gcloud plan on the setup page ends with a
  check that the access works. This module does not run it. To report
  completion, paste the `scanner_sa_email` output into the CSPR setup
  page (see Quickstart).
- **Delete anything you already have.** The module only manages the
  resources listed above.

## Prerequisites

These come from the CSPR setup plan. Confirm them before you apply.

- The person running `terraform apply` needs IAM-admin rights on the host
  project and on the scan target.
- At folder or organization scope, the host project is a dedicated
  project, not one of the scan targets. The person applying therefore also
  needs permission to change the IAM policy at folder or organization
  level, to grant `roles/cloudasset.viewer` there.
- The host project must exist and have active billing (or set
  `create_host_project = true`, which needs the right to create projects
  and link billing). Without billing, enabling the APIs fails, often with
  a misleading `AUTH_PERMISSION_DENIED`.
- If Domain Restricted Sharing applies, add the project-level exception
  described above first.
- The inventory export is stored in `cai_ds` in your host project, in
  `dataset_location` (default `europe-west1`). Confirm that you accept
  that project and region for your inventory data.

## Quickstart

1. Get your `customer_id`, `scan_scope` and `target_ids` from the CSPR
   setup page. It tells you exactly which values to use.
2. Reference the module straight from GitHub in your own Terraform
   configuration (the CSPR setup page generates this block for you):

   ```hcl
   module "cspr_onboarding" {
     source = "github.com/devoteamgcloud/cspr-onboarding-terraform?ref=v0.2.0"

     customer_id     = "your-customer-id"
     sa_host_project = "your-host-project"
     scan_scope      = "project"
     target_ids      = ["your-target-project"]
   }
   ```

   Or clone this repository and start from the `examples/` directory
   matching your scan scope (the examples use `source = "../.."`, so they
   need the full clone, not a copy of the example folder alone). Replace
   every `acme-*` placeholder with your own values.
3. Run:

   ```sh
   terraform init
   terraform plan
   terraform apply
   ```

4. Copy the `scanner_sa_email` output and paste it back into the CSPR
   setup page to report that onboarding is complete.

```sh
terraform output scanner_sa_email
```

## Re-running and existing resources

The module is not idempotent against resources that already exist outside
Terraform state. If you ran the setup page's gcloud script first, creating
the scanner SA or the `cai_ds` dataset fails with a 409 "already exists".
Either import them into state (for example
`terraform import module.cspr_onboarding.google_service_account.scanner projects/HOST/serviceAccounts/EMAIL`),
or, for the dataset only, set `create_dataset = false`. With
`create_dataset = false`, a dataset named `cai_ds` must already exist in
the host project and the module only grants access to it.

## Variable reference

| Variable | Type | Default | Description |
|---|---|---|---|
| `customer_id` | `string` | — (required) | Your CSPR customer id. Used only to derive the scanner SA name. |
| `sa_host_project` | `string` | — (required) | The GCP project that hosts the scanner SA and the export dataset. |
| `scan_scope` | `string` | — (required) | `project`, `folder`, or `organization`. |
| `target_ids` | `list(string)` | — (required) | Exactly one id, matching `scan_scope`. Bare id, no `folders/`/`organizations/` prefix. |
| `devoteam_runner_sa` | `string` | `cspr-runner@cspr-runner.iam.gserviceaccount.com` | Devoteam's runner SA. Leave at the default unless told otherwise. |
| `create_host_project` | `bool` | `false` | If `true`, this module creates `sa_host_project` instead of assuming it exists. |
| `host_project_parent` | `string` | `null` | Required with `create_host_project = true`: `organizations/<id>` or `folders/<id>`. |
| `host_project_billing_account` | `string` | `null` | Required with `create_host_project = true`. |
| `create_dataset` | `bool` | `true` | If `false`, a dataset named `cai_ds` must already exist. |
| `dataset_location` | `string` | `europe-west1` | Suggested default. The scanner detects the dataset's real location at scan time. |
| `enable_apis` | `bool` | `true` | Enables the required Google APIs on `sa_host_project`. |

## Outputs

| Output | Description |
|---|---|
| `scanner_sa_email` | Paste this back into the CSPR setup page. |
| `sa_account_id` | The derived scanner SA account id. |
| `granted_scope_roles` | Map of target id to the roles granted there, for review. |
| `cai_dataset_id` | The Cloud Asset export dataset id (`cai_ds`). |

## Upgrading from v0.1.x

v0.2.0 is a breaking change. The `scanner_engine` and `folder_project_ids`
variables are gone, `target_ids` must hold exactly one id, and the
`CSPRBucketIamViewer` custom role and the Prowler roles (`roles/viewer`,
`roles/browser`) are no longer managed. If you used the `prowler` or
`hybrid` engine, stay on `v0.1.2`. See the CHANGELOG for details.

## Off-boarding

Off-boarding is `terraform destroy`.

If you want a guaranteed instant cutoff before the rest of the cleanup,
revoke the impersonation binding on its own first:

```sh
terraform destroy -target=google_service_account_iam_member.impersonation
```

That single binding is the only path Devoteam has into your environment.
Once it's gone, Devoteam has no access, regardless of what other cleanup
is still in flight. A full `terraform destroy` removes it too (typically
early, since nothing else depends on it), the targeted command just makes
it the first and only step.

If this module created the host project (`create_host_project = true`),
the final `terraform destroy` step will stop with an error on the project
itself: the project is protected against deletion (`deletion_policy =
"PREVENT"`) because it may hold your exported inventory data. That error
is expected and safe, since every grant has already been revoked by then.
Delete the project manually if you really want it gone.

One exception: the Cloud Asset export dataset (`cai_ds`) is **not**
deleted by `terraform destroy`, even if this module created it
(`delete_contents_on_destroy = false`). This is deliberate, because you
may want to keep your exported inventory data. Delete it yourself if you
don't:

```sh
bq rm -r -f --dataset SA_HOST_PROJECT:cai_ds
```

## Security posture

- **No keys.** No service account key is ever created or downloaded.
  Devoteam accesses the scanner SA only via short-lived impersonation
  tokens (`roles/iam.serviceAccountTokenCreator`).
- **Narrow write scope.** The only write access is
  `roles/bigquery.dataEditor` on the `cai_ds` dataset, which holds your own
  inventory export. See "What the scanner can and cannot do" above.
- **You control revocation.** Removing the impersonation binding, or
  running `terraform destroy`, cuts Devoteam off immediately. No action
  on Devoteam's side is needed or possible.
- **Your audit logs, your name.** Because access happens via
  impersonation of a service account you own, every action shows up in
  your own Cloud Audit Logs under your own service account's identity.
- **Same grants as the manual path.** This module is written to match the
  `gcloud`/`bq` script generated by the CSPR setup page grant for grant
  (CAI scan). It is a repeatable way to apply that plan, and you should
  still review `terraform plan` before applying.
