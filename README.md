# GCP End-to-End Project (learning guide)

This workspace contains a scaffold for a GCP project with two GKE clusters, two sample web applications, observability, and CI. It's designed to be educational: run the steps, inspect resources, and learn concepts as you go.

What I added:
- `gcp_end_to_end_writeup.md` — architecture and commands
- `terraform/` — Terraform skeleton (VPC, GKE primary cluster, BigQuery dataset, logging sink)
- `k8s/` — Kubernetes manifests for `webapp-a` and `webapp-b` and an HPA
- `cloudbuild.yaml` — sample CI to build/push and deploy `webapp-a`
- `grafana/dashboard.json` — skeleton Grafana dashboard

Quick start checklist (local):

1. Install and authenticate:

```powershell
gcloud auth login
gcloud config set project <PROJECT_ID>
gcloud auth configure-docker
```

2. Initialize Terraform (edit `terraform/variables.tf` or provide `-var` values):

```powershell
cd terraform
terraform init
terraform apply -var='project_id=<PROJECT_ID>' -var='region=us-central1'
```

3. Configure kubectl for the created cluster:

```powershell
gcloud container clusters get-credentials gke-primary --region us-central1 --project <PROJECT_ID>
kubectl apply -f ../k8s/webapp-a-deployment.yaml
kubectl apply -f ../k8s/webapp-a-service.yaml
kubectl apply -f ../k8s/webapp-a-hpa.yaml
kubectl apply -f ../k8s/webapp-b-deployment.yaml
kubectl apply -f ../k8s/webapp-b-service.yaml
```

4. To test locally (port-forward):

```powershell
kubectl port-forward svc/webapp-a 8080:80
# open http://localhost:8080
```

## IAM Roles
This repo includes role mappings for Dev, Ops, SRE, and CI/CD access.

- Dev: `roles/container.developer`, `roles/iam.serviceAccountUser` on `webapp-sa`, `roles/logging.viewer`, `roles/monitoring.viewer`
- Ops: `roles/container.clusterAdmin`, `roles/compute.networkAdmin`, dataset-level `roles/bigquery.dataOwner`, `roles/logging.configWriter`, `roles/monitoring.editor`
- SRE: `roles/logging.viewer`, `roles/monitoring.viewer`, `roles/container.clusterViewer`, dataset-level `roles/bigquery.dataViewer`
- CI/CD: `cicd-sa` service account with `roles/cloudbuild.builds.builder`, `roles/artifactregistry.writer`, `roles/container.developer`, `roles/logging.logWriter`, `roles/monitoring.metricWriter`, and `roles/iam.serviceAccountUser` on `webapp-sa`

Set the actual principals using `terraform/variables.tf` before applying.

Learning notes (next actions):
- Review `terraform/main.tf` to see how resources connect (network → cluster → sink).
- Inspect `k8s` manifests to learn about requests/limits and HPA triggers.
- Open `grafana/dashboard.json` and replace placeholders with actual BigQuery queries in Grafana UI.
- To learn CI/CD, inspect `cloudbuild.yaml`, then trigger a build in Cloud Build.
## Memory Bank
A repo memory bank has been created at `/memories/repo/memory_bank.md` to capture key changes, troubleshooting findings, and infrastructure state.

## Recent Changes
- Updated Terraform to retry GKE provisioning in alternate zones: `us-central1-a`, `us-central1-b`, and `us-central1-e`.
- Added enterprise Workload Identity support for app workloads and logging/metrics IAM bindings.
- Documented the logging sink/BigQuery dataset mismatch and the fix to use a `US` location dataset.
If you want, I'll now:
1) Expand the Terraform into a multi-cluster (add secondary) and parameterize node pools, or
2) Generate a complete Grafana JSON with embedded BigQuery queries, or
3) Walk through each step interactively and run commands with you.

Tell me which option to do next.

---

## Commands run (diagnostics)

During a recent troubleshooting session I ran diagnostics for a failing logging sink. Keep these as a quick reference.

1) Describe sink and list sinks:

```powershell
gcloud logging sinks describe export-to-bq --project=project-80744ff2-3e39-47f5-a73 --format=json
gcloud logging sinks list --project=project-80744ff2-3e39-47f5-a73 --format="table(name,destination,writerIdentity)"
```

2) Inspect BigQuery dataset metadata and ACLs:

```powershell
bq show --format=prettyjson --project_id=project-80744ff2-3e39-47f5-a73 logs_dataset
```

Outcome summary:
- Sink `export-to-bq` existed and its `writerIdentity` was `serviceAccount:service-11856948072@gcp-sa-logging.iam.gserviceaccount.com`.
- The dataset `logs_dataset` existed but was in location `us-central1` (regional). This caused routing failures; Logging exports to BigQuery typically require a multi-region dataset like `US` or `EU`.

Recommended quick fixes:
- Create a multi-region dataset (`US`) and update the sink destination, or
- Recreate the sink pointing to an existing multi-region dataset.

If you want, I can run these fixes now and update Terraform to keep IaC consistent.

