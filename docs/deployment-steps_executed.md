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
``` Google Cloud SDK 576.0.0
    alpha 2026.07.10
    beta 2026.07.10
    bq 2.1.34
    core 2026.07.10
    gcloud-crc32c 1.0.0
    gke-gcloud-auth-plugin 0.5.17
    gsutil 5.37
    kubectl 1.35.3
    Client Version: v1.35.6-dispatcher
    Kustomize Version: v5.7.1
    Terraform v1.15.8
    on windows_amd64```

# Authenticate
gcloud auth login
gcloud auth application-default login
```You are now logged in as [jchandrasekhar@gmail.com].
Your current project is [project-pubsub-32009].  You can change this setting by running:
  $ gcloud config set project PROJECT_ID```

gcloud config set project project-pubsub-32009
gcloud auth configure-docker us-central1-docker.pkg.dev
``` docker and docker-credential-gcloud need to be in the same PATH in order to work correctly together.
gcloud's Docker credential helper can be configured but it will not work until this is corrected.
Adding credentials for: us-central1-docker.pkg.dev
After update, the following will be written to your Docker config file located at [C:\Users\jchan\.docker\config.json]:
 {
  "credHelpers": {
    "us-central1-docker.pkg.dev": "gcloud"
  }
}

Do you want to continue (Y/n)?  Y

Docker configuration file updated.
```

# Bootstrap APIs required before the FIRST terraform apply. Terraform enables
# the full API set (see terraform/services.tf), but it cannot enable APIs until
# Service Usage + Resource Manager are themselves on, so enable these first.
gcloud services enable `
  serviceusage.googleapis.com `
  cloudresourcemanager.googleapis.com `
  --project=project-pubsub-32009

  ```Operation "operations/acat.p2-974485624368-6623edba-89e6-4a55-b134-4f2e5ddd999c" finished successfully.```
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
  -var='project_id=project-pubsub-32009' `
  -var='region=us-central1' `
  -var='db_password=a-real-db_password' `
  -var='enable_stateful_services=true'
  -var='enable_multicluster_ingress=true'
 
 ```app_secret_name = "webapp-api-token"
bq_dataset = "logs_dataset_us"
cicd_service_account_email = "cicd-sa@project-pubsub-32009.iam.gserviceaccount.com"
cloud_armor_policy = "webapps-waf"
gke_primary_name = "gke-primary"
lb_static_ip = "136.68.78.115"
mci_enabled = false
webapp_b_pubsub_topic = "webapp-b-events"
webapp_b_redis_host = "10.133.4.20"
webapp_b_sql_private_ip = "10.133.0.2"
```

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
  --project=project-pubsub-32009 `
  --service-account=projects/project-pubsub-32009/serviceAccounts/cicd-sa@project-pubsub-32009.iam.gserviceaccount.com `
  --substitutions="_REGION=us-central1,_REPO=webapps,_TAG=latest" .
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
gcloud container clusters get-credentials gke-primary --region us-central1 --project project-pubsub-32009

# Enable the Secret Manager add-on (needed by the CSI SecretProviderClass)
gcloud container clusters update gke-primary --region us-central1 --project project-pubsub-32009 --enable-secret-manager
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

## 5. Expose through the global external HTTPS load balancer

```powershell
# Replace the app.example.com placeholder with your real hostname in both the
# managed cert and the ingress BEFORE applying, otherwise the certificate never
# goes Active and the ingress serves the wrong host.
$HOST="app.yourapp.com"
(Get-Content k8s/managedcertificate.yaml) -replace 'app\.example\.com', $HOST | Set-Content k8s/managedcertificate.yaml
(Get-Content k8s/ingress.yaml)          -replace 'app\.example\.com', $HOST | Set-Content k8s/ingress.yaml

kubectl apply -f k8s/secretproviderclass.yaml
kubectl apply -f k8s/backendconfig.yaml       # Cloud Armor WAF + /healthz health check
kubectl apply -f k8s/frontendconfig.yaml      # HTTP -> HTTPS redirect
kubectl apply -f k8s/managedcertificate.yaml
kubectl apply -f k8s/webapp-a-service.yaml
kubectl apply -f k8s/webapp-b-service.yaml
kubectl apply -f k8s/ingress.yaml

# Point DNS A record at the reserved IP
terraform -chdir=terraform output -raw lb_static_ip
# Watch the ingress get an address + the managed cert go Active (can take 10-20 min)
kubectl describe ingress webapps-ingress
kubectl describe managedcertificate webapps-cert
```

Local test without DNS: see [test-curl-commands.md](test-curl-commands.md).

---

## 6. (Optional) Global Multi-Cluster Ingress across both clusters

Requires `-var='enable_secondary=true' -var='enable_multicluster_ingress=true'`
in step 1. Do NOT run this together with the single-cluster `k8s/ingress.yaml`.

```powershell
# Enable the Secret Manager add-on on the SECOND cluster too (the primary was
# done in step 3); the replicated webapp-a mounts the same CSI secret there.
gcloud container clusters update gke-secondary --region us-east1 --project project-pubsub-32009 --enable-secret-manager

# Fill the placeholders in k8s/multicluster/mci-webapps.yaml first:
#   networking.gke.io/static-ip        -> terraform output -raw lb_static_ip
#   networking.gke.io/pre-shared-certs -> create a cert:
gcloud compute ssl-certificates create webapps-mci-cert --domains=app.example.com --global

# Replicate workloads to BOTH clusters and apply MCS + MCI to the config cluster
./scripts/deploy-multicluster.ps1 -ProjectId project-pubsub-32009

kubectl describe mci webapps-mci -n default
```

---

## 7. Observability: BigQuery + Grafana

```powershell
# 7a. Confirm logs are flowing to BigQuery
gcloud logging sinks describe export-to-bq --project=project-pubsub-32009 --format="value(destination)"
bq ls --project_id=project-pubsub-32009 logs_dataset_us

# 7b. Create the read-only Grafana service account + key
$P="project-pubsub-32009"; $SA="grafana-bq-reader@$P.iam.gserviceaccount.com"
gcloud iam service-accounts create grafana-bq-reader --project=$P --display-name="Grafana BigQuery reader"
gcloud projects add-iam-policy-binding $P --member="serviceAccount:$SA" --role="roles/bigquery.dataViewer"
gcloud projects add-iam-policy-binding $P --member="serviceAccount:$SA" --role="roles/bigquery.jobUser"
gcloud iam service-accounts keys create grafana/grafana-bq-reader-key.json --iam-account=$SA
```

Then in Grafana: add the **Google BigQuery** datasource (JWT file = the key
above) and import `grafana/dashboard-ready.json` (maps to `project-pubsub-32009` /
`logs_dataset_us`). Sample queries live in [bigquery-queries.sql](bigquery-queries.sql).

Full shutdown/startup and Grafana-via-Helm details: [k8s-shutdown-startup.md](k8s-shutdown-startup.md).

---

## 8. Verify app telemetry (Trace / Profiler / Error Reporting)

The apps are instrumented (OpenTelemetry -> Cloud Trace, Cloud Profiler, Error
Reporting) and run as `webapp-sa` via Workload Identity. After sending some
traffic:

```powershell
# Traces
gcloud trace list-traces --project=project-pubsub-32009 --limit=5
```

- Cloud Console -> **Trace** -> Trace explorer (services `vote`, `result`, `worker`)
- Cloud Console -> **Profiler** (services `vote`, `result`, `worker`)
- Cloud Console -> **Error Reporting** (unhandled exceptions)

---

## 9. Teardown

```powershell
# Remove k8s objects first (releases the LB), then the infra
kubectl delete -f k8s/ --ignore-not-found
terraform -chdir=terraform destroy -var='project_id=project-pubsub-32009'
```

---

## 10. Evidence Capture (Grafana Dashboard + Application Hits)

Captured on: 2026-08-04 (UTC)

### 10a. Live application hit evidence (LB endpoint)

Command:

```powershell
$ip = terraform -chdir=terraform output -raw lb_static_ip
1..5 | ForEach-Object {
  curl.exe -s -o NUL -w "webapp-a status=%{http_code} time_total=%{time_total}`n" "https://$ip.sslip.io/"
  curl.exe -s -o NUL -w "webapp-b status=%{http_code} time_total=%{time_total}`n" "https://$ip.sslip.io/b"
}
```

Sample output:

```text
LB_IP=136.68.78.115
webapp-a status=200 time_total=0.304717
webapp-b status=200 time_total=0.132960
webapp-a status=200 time_total=0.088858
webapp-b status=200 time_total=0.124031
webapp-a status=200 time_total=0.133648
webapp-b status=200 time_total=0.116932
webapp-a status=200 time_total=0.100983
webapp-b status=200 time_total=0.141518
webapp-a status=200 time_total=0.108302
webapp-b status=200 time_total=0.123471
```

### 10b. BigQuery request/latency evidence

Command:

```powershell
bq query --use_legacy_sql=false --project_id=project-pubsub-32009 'SELECT timestamp, httpRequest.requestMethod AS method, httpRequest.requestUrl AS url, httpRequest.status AS status, httpRequest.latency AS latency FROM `project-pubsub-32009.logs_dataset_us.requests_20260804` WHERE timestamp > TIMESTAMP_SUB(CURRENT_TIMESTAMP(), INTERVAL 15 MINUTE) ORDER BY timestamp DESC LIMIT 20'
```

Sample output rows:

```text
2026-08-04 21:18:39 | GET | https://136.68.78.115.sslip.io/b | 200 | 0.068558
2026-08-04 21:18:30 | GET | https://136.68.78.115.sslip.io/  | 200 | 0.024261
2026-08-04 21:18:30 | GET | https://136.68.78.115.sslip.io/b | 200 | 0.055672
```

### 10c. Cloud Logging LB evidence

Command:

```powershell
gcloud logging read 'resource.type="http_load_balancer" AND httpRequest.requestUrl:"sslip.io"' --project=project-pubsub-32009 --limit=20 --format='table(timestamp,httpRequest.requestMethod,httpRequest.requestUrl,httpRequest.status,httpRequest.latency,resource.labels.forwarding_rule_name)'
```

Sample output rows:

```text
2026-08-04T21:19:56.621562Z | GET | https://136.68.78.115.sslip.io/b | 200 | 0.061835s
2026-08-04T21:18:30.917736Z | GET | https://136.68.78.115.sslip.io/  | 200 | 0.024261s
```

### 10d. Grafana BigQuery datasource evidence

Command:

```powershell
kubectl logs deployment/grafana -n monitoring --tail=300 | Select-String -Pattern 'grafana-bigquery-datasource|Plugin Request Completed|status=ok'
```

Sample output rows:

```text
logger=plugin.grafana-bigquery-datasource ... msg="Plugin Request Completed" ... endpoint=queryData ... status=ok ...
logger=plugin.grafana-bigquery-datasource ... msg="Plugin Request Completed" ... endpoint=queryData ... status=ok ...
```

Dashboard screenshot evidence:

- [Grafana dashboard screenshot](GrafanaDashboard.png)

Conclusion:

- Application endpoints `/` and `/b` return HTTP 200.
- LB request logs are present in Cloud Logging.
- Request and latency records are present in BigQuery export tables.
- Grafana BigQuery datasource query execution is successful (`status=ok`).
