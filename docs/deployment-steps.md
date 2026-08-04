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
kubectl apply -f k8s/secretproviderclass.yaml
kubectl apply -f k8s/backendconfig.yaml       # Cloud Armor WAF + /healthz health check
kubectl apply -f k8s/frontendconfig.yaml      # HTTP -> HTTPS redirect
kubectl apply -f k8s/managedcertificate.yaml  # edit the domain first
kubectl apply -f k8s/webapp-a-service.yaml
kubectl apply -f k8s/webapp-b-service.yaml
kubectl apply -f k8s/ingress.yaml             # edit host first

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

Then in Grafana: add the **Google BigQuery** datasource (JWT file = the key
above) and import `grafana/dashboard-ready.json` (maps to `<PROJECT_ID>` /
`logs_dataset_us`). Sample queries live in [bigquery-queries.sql](bigquery-queries.sql).

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
