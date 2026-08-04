# End-to-End Deployment Steps

Complete, ordered runbook to stand up the whole project: two GKE clusters, the
three apps (vote / result / worker), the global HTTPS load balancer + Cloud Armor,
observability (BigQuery + Grafana + Trace/Profiler/Error Reporting), and the
optional Multi-Cluster Ingress. Commands are PowerShell.

> Replace `<PROJECT_ID>` throughout (example project: `project-pubsub-32009`).

---

## 0. Prerequisites

```powershell
# Tools: gcloud, kubectl, terraform, docker, helm
gcloud version ; kubectl version --client ; terraform version

# Authenticate
gcloud auth login
gcloud auth application-default login
gcloud config set project <PROJECT_ID>
gcloud auth configure-docker us-central1-docker.pkg.dev

# Bootstrap APIs required before the FIRST terraform apply. Terraform enables
# the full API set (see terraform/services.tf), but it cannot enable APIs until
# Service Usage + Resource Manager are themselves on, so enable these first.
gcloud services enable `
  serviceusage.googleapis.com `
  cloudresourcemanager.googleapis.com `
  --project=<PROJECT_ID>
```

---

## 1. Provision infrastructure with Terraform

```powershell
cd terraform
terraform init

# Two clusters are created by default (enable_secondary = true).
# Add optional features as needed:
#   -var='enable_stateful_services=true'     # Cloud SQL HA + Memorystore + Pub/Sub (Web App B)
#   -var='enable_multicluster_ingress=true'  # global MCI/MCS across both clusters
#   -var='enable_cloud_dns=true' -var='dns_domain=yourapp.com.' -var='app_hostname=app.yourapp.com'
terraform apply `
  -var='project_id=<PROJECT_ID>' `
  -var='region=us-central1' `
  -var='db_password=<STRONG_DB_PASSWORD>' `
  -var='app_secret_value=<REAL_SECRET>'

# Save the useful outputs
terraform output
terraform output -raw lb_static_ip
cd ..
```

> To run a single (cheaper) cluster instead, add `-var='enable_secondary=false'`.

---

## 2. Build and push the container images

```powershell
# Builds vote, worker, result and pushes to Artifact Registry (repo: webapps)
gcloud builds submit --config cloudbuild.yaml `
  --substitutions=_REGION=us-central1,_REPO=webapps,_TAG=latest .
```

The Cloud Build config also deploys the workloads to `gke-primary`. To deploy
manually instead, use steps 3–6.

> Order matters: `webapp-a` mounts a Secret Manager volume via the CSI driver,
> so the Secret Manager add-on (step 3) and `secretproviderclass.yaml` (step 5)
> must exist **before** the apps are deployed. If you rely on Cloud Build here,
> run step 3 first, or the vote pods stay in `ContainerCreating` on the missing
> `gcp-secrets-provider` SecretProviderClass.

---

## 3. Connect kubectl to the primary cluster

```powershell
gcloud container clusters get-credentials gke-primary --region us-central1 --project <PROJECT_ID>

# Enable the Secret Manager add-on (needed by the CSI SecretProviderClass)
gcloud container clusters update gke-primary --region us-central1 --project <PROJECT_ID> --enable-secret-manager
```

---

## 4. Deploy configuration, service account, and apps

```powershell
# Render project-specific values and apply the KSA + config
./scripts/deploy.ps1

kubectl apply -f k8s/webapp-config.yaml
kubectl apply -f k8s/webapp-a-deployment.yaml
kubectl apply -f k8s/webapp-a-service.yaml
kubectl apply -f k8s/webapp-a-hpa.yaml
kubectl apply -f k8s/webapp-b-deployment.yaml
kubectl apply -f k8s/webapp-b-service.yaml
kubectl apply -f k8s/webapp-b-hpa.yaml
kubectl apply -f k8s/worker-deployment.yaml
kubectl apply -f k8s/pdb.yaml

kubectl get pods -o wide
```

> Default path (`enable_stateful_services=false`): there is no Redis/Cloud SQL,
> so `worker` and `webapp-b` stay in `CrashLoopBackOff` and `webapp-a` cannot
> record votes — this is expected. `webapp-a` still serves the ballot page and
> passes health checks, so the endpoint is usable for the demo. For a fully
> working vote path, apply with `-var='enable_stateful_services=true'` in step 1
> and run the patch below.

If the worker logs `waiting for redis/postgres`, inject the backing-service
connection details (requires `enable_stateful_services=true`):

```powershell
$redis = terraform -chdir=terraform output -raw webapp_b_redis_host
$sql   = terraform -chdir=terraform output -raw webapp_b_sql_private_ip
kubectl patch configmap webapp-config --type merge -p "{""data"":{""REDIS_HOST"":""$redis"",""DB_HOST"":""$sql""}}"
kubectl patch secret    webapp-db-secret --type merge -p "{""stringData"":{""DB_PASSWORD"":""<STRONG_DB_PASSWORD>""}}"
kubectl rollout restart deployment/worker deployment/webapp-a deployment/webapp-b
```

---

## 5. Expose through the global external load balancer (no domain)

You don't need a domain. **Pick ONE of the two options below** — both create the
same `webapps-ingress`, so running both at once conflicts. Both are kept in this
doc so you can choose per test.

| | **Option A** | **Option B** |
|---|---|---|
| Protocol | HTTP (no TLS) | HTTPS (TLS) |
| Domain needed | No | No (uses `sslip.io`) |
| TLS certificate | None | Google-managed, auto-issued |
| Ready in | ~5–10 min | ~10–30 min (cert must go Active) |
| App URL | `http://<IP>/` | `https://<IP>.sslip.io/` |
| Manifest | `k8s/ingress-http.yaml` | `k8s/rendered-ingress-project-pubsub-32009.yaml` |
| Best for | Quick smoke test | Demo that shows working HTTPS |

> Why the difference? A Google-managed TLS cert must be issued to a **hostname**,
> never a bare IP. Option A skips TLS entirely. Option B borrows a free hostname
> from `sslip.io` (the host `<ip>.sslip.io` simply resolves back to `<ip>`), which
> gives the cert something to attach to — no domain purchase required.

### Option A — HTTP, IP only (simplest)

Serves the apps over plain **HTTP** on the reserved global static IP
`webapps-lb-ip`. There is no TLS. Cloud Armor WAF + the `/healthz` check still
apply (they come from the BackendConfig on the Services).
Manifest: [k8s/ingress-http.yaml](../k8s/ingress-http.yaml).

```powershell
kubectl apply -f k8s/secretproviderclass.yaml
kubectl apply -f k8s/backendconfig.yaml       # Cloud Armor WAF + /healthz health check
kubectl apply -f k8s/webapp-a-service.yaml
kubectl apply -f k8s/webapp-b-service.yaml
kubectl apply -f k8s/ingress-http.yaml

# Get the LB IP and browse to it (provisioning the LB can take 5-10 min)
$ip = terraform -chdir=terraform output -raw lb_static_ip
kubectl describe ingress webapps-ingress
Write-Host "http://$ip/     (webapp-a)"
Write-Host "http://$ip/b    (webapp-b)"
```

### Option B — HTTPS via `sslip.io` (no domain purchase)

Serves the apps over **HTTPS** at `https://<IP>.sslip.io/` with a Google-managed
certificate. Apply [k8s/rendered-ingress-project-pubsub-32009.yaml](../k8s/rendered-ingress-project-pubsub-32009.yaml)
with `LB_IP` replaced by the static IP. Do **not** also apply
`ingress-http.yaml` — both create the same `webapps-ingress`.

```powershell
# 0. Point kubectl at the primary cluster
gcloud container clusters get-credentials gke-primary --region us-central1 --project <PROJECT_ID>

# 1. Prereqs the rendered manifest references
kubectl apply -f k8s/secretproviderclass.yaml
kubectl apply -f k8s/webapp-a-service.yaml
kubectl apply -f k8s/webapp-b-service.yaml

# 2. Grab the reserved static IP
$ip = terraform -chdir=terraform output -raw lb_static_ip
Write-Host "LB IP = $ip   ->   host will be $ip.sslip.io"

# 3. Render LB_IP -> the real IP and apply the ingress bundle
#    (BackendConfig + FrontendConfig + ManagedCertificate + Ingress)
(Get-Content k8s/rendered-ingress-project-pubsub-32009.yaml) `
  -replace 'LB_IP', $ip | kubectl apply -f -

# 4. Wait for the LB address + managed cert to go Active (10-30 min)
kubectl describe ingress webapps-ingress
kubectl get managedcertificate webapps-cert -w    # Ctrl+C once Status = Active

# 5. Test
Write-Host "https://$ip.sslip.io/     (webapp-a / vote)"
Write-Host "https://$ip.sslip.io/b    (webapp-b / result)"
curl.exe -ik "https://$ip.sslip.io/"
curl.exe -ik "https://$ip.sslip.io/b"
```

> The cert stays `Provisioning` until the ingress has its IP and the backends are
> `HEALTHY`; `curl` returns TLS errors until then. `-k` skips cert validation so
> you can test early — drop it once Status = Active.

Local test without DNS: see [test-curl-commands.md](test-curl-commands.md).

---

## 6. (Optional) Global Multi-Cluster Ingress across both clusters

Requires `-var='enable_secondary=true' -var='enable_multicluster_ingress=true'`
in step 1. Do NOT run this together with the single-cluster `k8s/ingress.yaml`.

```powershell
# Enable the Secret Manager add-on on the SECOND cluster too (the primary was
# done in step 3); the replicated webapp-a mounts the same CSI secret there.
gcloud container clusters update gke-secondary --region us-east1 --project <PROJECT_ID> --enable-secret-manager

# Fill the placeholders in k8s/multicluster/mci-webapps.yaml first:
#   networking.gke.io/static-ip        -> terraform output -raw lb_static_ip
#   networking.gke.io/pre-shared-certs -> create a cert:
gcloud compute ssl-certificates create webapps-mci-cert --domains=app.example.com --global

# Replicate workloads to BOTH clusters and apply MCS + MCI to the config cluster
./scripts/deploy-multicluster.ps1 -ProjectId <PROJECT_ID>

kubectl describe mci webapps-mci -n default
```

---

## 7. Observability: BigQuery + Grafana

```powershell
# 7a. Confirm logs are flowing to BigQuery
gcloud logging sinks describe export-to-bq --project=<PROJECT_ID> --format="value(destination)"
bq ls --project_id=<PROJECT_ID> logs_dataset_us

# 7b. Create the read-only Grafana service account + key
$P="<PROJECT_ID>"; $SA="grafana-bq-reader@$P.iam.gserviceaccount.com"
gcloud iam service-accounts create grafana-bq-reader --project=$P --display-name="Grafana BigQuery reader"
gcloud projects add-iam-policy-binding $P --member="serviceAccount:$SA" --role="roles/bigquery.dataViewer"
gcloud projects add-iam-policy-binding $P --member="serviceAccount:$SA" --role="roles/bigquery.jobUser"
gcloud iam service-accounts keys create grafana/grafana-bq-reader-key.json --iam-account=$SA
```

If key creation fails with `constraints/iam.disableServiceAccountKeyCreation`,
use keyless auth (Workload Identity) instead:

```powershell
# Ensure cluster credentials are active first.
gcloud container clusters get-credentials gke-primary --region us-central1 --project <PROJECT_ID>

# Map Grafana KSA -> GSA (no JSON key file required).
kubectl create namespace monitoring --dry-run=client -o yaml | kubectl apply -f -
kubectl create serviceaccount grafana -n monitoring --dry-run=client -o yaml | kubectl apply -f -
gcloud iam service-accounts add-iam-policy-binding $SA `
  --project=<PROJECT_ID> `
  --role="roles/iam.workloadIdentityUser" `
  --member="serviceAccount:<PROJECT_ID>.svc.id.goog[monitoring/grafana]"
kubectl annotate serviceaccount grafana -n monitoring `
  iam.gke.io/gcp-service-account=$SA --overwrite
```

### 7c. Install/access Grafana

If Grafana is not running yet, install it once in the cluster:

```powershell
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm upgrade --install grafana grafana/grafana -n monitoring --create-namespace `
  --set serviceAccount.create=false `
  --set serviceAccount.name=grafana

# Get initial admin password
kubectl get secret -n monitoring grafana -o jsonpath="{.data.admin-password}" | ForEach-Object { [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($_)) }

# Local access (recommended)
kubectl port-forward -n monitoring svc/grafana 3000:80
```

Open http://localhost:3000 and sign in with user `admin` and the password from
the secret command above.

### 7d. Add the BigQuery datasource in Grafana

In Grafana UI:

1. Go to **Connections -> Data sources -> Add data source**.
2. Choose **Google BigQuery**.
3. Authentication:
  - **JWT file** when `grafana/grafana-bq-reader-key.json` was created successfully, or
  - **GCE metadata server** when using Workload Identity (recommended if key creation is blocked).
4. For JWT mode, upload key file: `grafana/grafana-bq-reader-key.json`.
5. Default project: `<PROJECT_ID>`.
6. Click **Save & test** (must show success).

### 7e. Import dashboard

Import this dashboard first (it is aligned with current logs and latency fields):

- `grafana/dashboard-ready.json`

Optional advanced board (includes additional infra panels):

- `grafana/dashboard-full.json`

When importing, select the BigQuery datasource you created above.

### 7f. Verify panels are returning data

Use these checks if a panel is empty:

1. Dashboard time range: set to **Last 1 hour**.
2. Dashboard variables:
  - `project = <PROJECT_ID>`
  - `dataset = logs_dataset_us`
3. Confirm request logs exist:

```powershell
bq query --use_legacy_sql=false --project_id=<PROJECT_ID> 'SELECT timestamp, httpRequest.requestUrl, httpRequest.status, httpRequest.latency FROM `<PROJECT_ID>.logs_dataset_us.requests_20260804` ORDER BY timestamp DESC LIMIT 5'
```

4. Latency panel should populate from `requests_*` and `httpRequest.latency`.

Sample ad-hoc queries live in [bigquery-queries.sql](bigquery-queries.sql).

Full shutdown/startup and Grafana-via-Helm details: [k8s-shutdown-startup.md](k8s-shutdown-startup.md).

---

## 8. Verify app telemetry (Trace / Profiler / Error Reporting)

The apps are instrumented (OpenTelemetry -> Cloud Trace, Cloud Profiler, Error
Reporting) and run as `webapp-sa` via Workload Identity. After sending some
traffic:

```powershell
# Traces
gcloud trace list-traces --project=<PROJECT_ID> --limit=5
```

- Cloud Console -> **Trace** -> Trace explorer (services `vote`, `result`, `worker`)
- Cloud Console -> **Profiler** (services `vote`, `result`, `worker`)
- Cloud Console -> **Error Reporting** (unhandled exceptions)

---

## 9. Teardown

```powershell
# Remove k8s objects first (releases the LB), then the infra
kubectl delete -f k8s/ --ignore-not-found
terraform -chdir=terraform destroy -var='project_id=<PROJECT_ID>'
```
