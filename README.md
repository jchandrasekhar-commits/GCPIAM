# GCP End-to-End Project (learning guide)

This workspace contains a scaffold for a GCP project with two GKE clusters, two sample web applications, observability, and CI. It's designed to be educational: run the steps, inspect resources, and learn concepts as you go.

What I added:
- `gcp_end_to_end_writeup.md` — architecture and commands
- `terraform/` — Terraform for VPC, Cloud NAT, firewall rules, GKE primary cluster, optional symmetric secondary cluster (`enable_secondary`), IAM, BigQuery dataset, and logging sink
- `k8s/` — Kubernetes manifests for `webapp-a` and `webapp-b`, HPAs for both, a ConfigMap/Secret, and an ingress
- `cloudbuild.yaml` — sample CI to build/push and deploy `webapp-a`
- `grafana/dashboard.json` — Grafana dashboard with 4 BigQuery-backed panels

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

To also provision the symmetric secondary (DR) cluster, add `-var='enable_secondary=true'`
(defaults: `secondary_region=us-east1`, `secondary_subnet_cidr=10.20.0.0/20`). It is off by
default to stay within the free tier.

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
- Added Cloud NAT (per region) and VPC firewall rules for internal + health-check traffic.
- Expanded Terraform into a multi-cluster setup: symmetric secondary cluster via `enable_secondary`.
- Added HPAs for both apps and a ConfigMap/Secret consumed by `webapp-a`.
- Added Secret Manager secret (`webapp-api-token`) consumed via Workload Identity (`secretAccessor`).
- Hardened clusters with private nodes (`enable_private_nodes`) and master authorized networks.
- Added readiness/liveness probes, preStop hooks, and PodDisruptionBudgets for zero-downtime rollouts.
- Added `terraform/terraform.tfvars.example` documenting all input variables.
- Completed the Grafana dashboard with 4 BigQuery-backed panels.
- Documented the logging sink/BigQuery dataset mismatch and the fix to use a `US` location dataset.

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

---

## GKE Health Recommendations Checklist

Use this loop weekly (or before releases) to keep performance and reliability aligned with GKE best practices.

1) Cluster and node health
- Check node readiness and version skew:
	- `kubectl get nodes -o wide`
- Check pending/failed workloads:
	- `kubectl get pods -A --field-selector=status.phase!=Running`
- Investigate scheduling pressure quickly:
	- `kubectl describe pod <POD_NAME> -n <NAMESPACE>`

2) Capacity and autoscaling
- Verify HPA targets are healthy and scaling correctly:
	- `kubectl get hpa -A`
- Verify requests/limits are set for every app deployment.
- Watch for autoscaler "unhelpable" events and right-size workloads.

3) Reliability guardrails
- Keep readiness/liveness probes on all app containers.
- Keep PodDisruptionBudgets for critical services.
- Confirm rolling update behavior during deploys:
	- `kubectl rollout status deployment/<NAME> -n <NAMESPACE>`

4) Security and access posture
- Use Workload Identity mappings instead of static credentials.
- Keep secret access through Secret Manager IAM roles.
- Restrict control-plane access CIDRs in production (`master_authorized_cidrs`).

5) Observability completeness
- Confirm sink routing includes both workload and LB logs:
	- `resource.type="k8s_container" OR resource.type="http_load_balancer"`
- Verify sink destination and writer identity:
	- `gcloud logging sinks describe export-to-bq --project=<PROJECT_ID> --format="table(name,destination,writerIdentity)"`
- Validate dashboard signal coverage (error rate, restarts, latency, utilization).

6) Validation loop after every infra/app change
- Terraform static check:
	- `terraform validate`
- Runtime health snapshot:
	- `kubectl get deploy,hpa,pdb,ingress -n default -o wide`
	- `kubectl get svc webapp-a webapp-b -n default -o wide`
- Endpoint smoke tests:
	- `curl.exe -sS -m 10 http://<WEBAPP_A_EXTERNAL_IP>`
	- `curl.exe -sS -m 10 http://<WEBAPP_B_EXTERNAL_IP>`

