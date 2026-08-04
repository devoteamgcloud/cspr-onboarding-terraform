# CSPR Enhanced — customer onboarding Terraform module

This module grants Devoteam's CSPR Enhanced scanner read-only access to
your GCP environment, without ever creating or handing over a service
account key. It mirrors the same IAM plan the CSPR setup page renders as a
copy-paste `gcloud`/`bq` script — this is the same access, just applied
with `terraform apply` instead of pasting commands into Cloud Shell.

## What this grants, and why

Everything below is granted to one service account that lives in your own
project (`sa_host_project`). Devoteam never gets a key for it — Devoteam's
runner service account is only allowed to *impersonate* it, and you can
revoke that at any time.

| Grant | Why |
|---|---|
| `roles/iam.serviceAccountTokenCreator` on the scanner SA, for Devoteam's runner SA | Lets Devoteam impersonate the scanner SA to run scans. This is the single binding that matters for access control — remove it and Devoteam is cut off instantly. |
| `roles/viewer` at scan scope (Prowler engines) | Read-only visibility into resource configuration, for per-resource checks. |
| `roles/browser` + `roles/cloudasset.viewer` at scan scope, folder/org only (Prowler engines) | Needed to enumerate descendant projects and read asset metadata when scanning more than one project. |
| `roles/cloudasset.viewer` at scan scope (CAI engines) | Lets the scanner query the Cloud Asset Inventory for org/identity/inventory checks. |
| `roles/serviceusage.serviceUsageConsumer` on the host project | Lets the scanner make billed API calls against your project's quota. |
| `roles/bigquery.jobUser` on the host project (CAI engines) | Lets the scanner run BigQuery jobs against the Cloud Asset export. |
| Custom role `CSPRBucketIamViewer` (`storage.buckets.getIamPolicy` only), scope-aware (Prowler engines) | The one Storage IAM-read permission Prowler needs for its bucket-IAM checks, without granting `roles/storage.admin` or a broad ancestor-level security role. |
| BigQuery dataset `cai_ds` + dataset-level `roles/bigquery.dataViewer` for the scanner SA, `roles/bigquery.dataEditor` for the Cloud Asset service agent (CAI engines) | Holds the Cloud Asset Inventory export the scanner queries against. |

Nothing here grants write access to your resources, and no API key or
service account key is ever created. This is the same permission model
used and audited across Devoteam's CSPR Enhanced customer base.

### What this does not do

- **Domain Restricted Sharing.** If your organization enforces the
  `constraints/iam.allowedPolicyMemberDomains` org policy, it will block
  the impersonation grant to Devoteam's external runner SA. This module
  does not touch org policy — if the constraint applies to you, add a
  project-level exception on `sa_host_project` before applying (or ask
  your GCP admin to do so). This mirrors the CSPR setup page, which
  surfaces the same requirement as a manual precondition rather than a
  scripted step.
- **Deleting resources you already have.** This module does not modify
  or delete anything outside of what it creates.

## Quickstart

1. Get your `customer_id`, `scan_scope`, `target_ids`, and `scanner_engine`
   from the CSPR setup page — it tells you exactly which values to use.
2. Copy one of the `examples/` directories that matches your scan scope
   and fill in your own values (replace every `acme-*` placeholder).
3. Run:

   ```sh
   terraform init
   terraform plan
   terraform apply
   ```

4. Copy the `scanner_sa_email` output and paste it back into the CSPR
   setup page to complete onboarding.

```sh
terraform output scanner_sa_email
```

## Variable reference

| Variable | Type | Default | Description |
|---|---|---|---|
| `customer_id` | `string` | — (required) | Your CSPR customer id. Used only to derive the scanner SA name. |
| `sa_host_project` | `string` | — (required) | The GCP project that hosts the scanner SA (and, for CAI engines, the export dataset). |
| `scan_scope` | `string` | — (required) | `project`, `folder`, or `organization`. |
| `target_ids` | `list(string)` | — (required) | The ids to scan, matching `scan_scope`. Bare ids, no `folders/`/`organizations/` prefix. |
| `scanner_engine` | `string` | — (required) | `prowler`, `cai_catalog`, or `hybrid`. The CSPR setup page tells you which to use. |
| `devoteam_runner_sa` | `string` | `cspr-runner@cspr-runner.iam.gserviceaccount.com` | Devoteam's runner SA. Leave at the default unless told otherwise. |
| `folder_project_ids` | `list(string)` | `[]` | Required when `scan_scope = "folder"` and `scanner_engine` is `prowler` or `hybrid`. See below. |
| `create_host_project` | `bool` | `false` | If `true`, this module creates `sa_host_project` instead of assuming it exists. |
| `host_project_parent` | `string` | `null` | Required with `create_host_project = true`: `organizations/<id>` or `folders/<id>`. |
| `host_project_billing_account` | `string` | `null` | Required with `create_host_project = true`. |
| `create_dataset` | `bool` | `true` | CAI engines only. If `false`, a dataset named `cai_ds` must already exist. |
| `dataset_location` | `string` | `europe-west1` | CAI engines only. Suggested default — the scanner detects the dataset's real location at scan time. |
| `enable_apis` | `bool` | `true` | Enables the required Google APIs on `sa_host_project`. |

## Outputs

| Output | Description |
|---|---|
| `scanner_sa_email` | Paste this back into the CSPR setup page. |
| `sa_account_id` | The derived scanner SA account id. |
| `granted_scope_roles` | Map of target id to the roles granted there, for review. |
| `cai_dataset_id` | The Cloud Asset export dataset id, if managed (CAI engines only). |

## Folder scope: the project list

Custom IAM roles cannot be created at folder level in GCP, so when
`scan_scope = "folder"` and you're using the `prowler` or `hybrid` engine,
this module needs the id of every project under the target folder to
create and bind `CSPRBucketIamViewer` in each one. Generate the list with:

```sh
gcloud asset search-all-resources \
  --scope=folders/FOLDER_ID \
  --asset-types=cloudresourcemanager.googleapis.com/Project \
  --format='value(project)'
```

Pass the result as `folder_project_ids`. If you're using `cai_catalog`
alone, this isn't needed — that engine only reads the Cloud Asset
Inventory and never touches bucket IAM policies.

Note that this list is a snapshot. Projects added to the folder later
will not have the bucket-IAM role until you regenerate the list and run
`terraform apply` again. If projects come and go under the folder
regularly, re-run the command above before each scan.

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
is expected and safe — every grant has already been revoked by then.
Delete the project manually if you really want it gone.

One exception: the Cloud Asset export dataset (`cai_ds`) is **not**
deleted by `terraform destroy`, even if this module created it
(`delete_contents_on_destroy = false`). This is deliberate — you may want
to keep your exported inventory data. Delete it yourself if you don't:

```sh
bq rm -r -f --dataset SA_HOST_PROJECT:cai_ds
```

## Security posture

- **Read-only.** Every role granted here is a read/viewer role, plus one
  narrowly-scoped custom role for bucket IAM policy reads. Nothing here
  can modify your resources.
- **No keys.** No service account key is ever created or downloaded.
  Devoteam accesses the scanner SA only via short-lived impersonation
  tokens (`roles/iam.serviceAccountTokenCreator`).
- **You control revocation.** Removing the impersonation binding — or
  running `terraform destroy` — cuts Devoteam off immediately. No action
  on Devoteam's side is needed or possible.
- **Your audit logs, your name.** Because access happens via
  impersonation of a service account you own, every action shows up in
  your own Cloud Audit Logs under your own service account's identity.
- **Same access as the audited manual path.** This module produces
  exactly the same grants as the `gcloud`/`bq` script generated by the
  CSPR setup page, which is the version that has been reviewed and used
  across Devoteam's CSPR Enhanced customer base. This module is just a
  more convenient, repeatable way to apply it.
