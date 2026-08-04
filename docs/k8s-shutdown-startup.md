# K8s Shutdown & Start Runbook — Voting App (project-pubsub-32009)

Operational steps to **stop** (save cost) and **start** the voting app on GKE.
Project `project-pubsub-32009`, region `us-central1`, cluster `gke-primary`.

Manifests:
- App: [k8s/rendered-project-pubsub-32009.yaml](../k8s/rendered-project-pubsub-32009.yaml)
- Ingress/LB/WAF/cert: [k8s/rendered-ingress-project-pubsub-32009.yaml](../k8s/rendered-ingress-project-pubsub-32009.yaml)
- Reserved LB IP `webapps-lb-ip` = `136.68.78.115` (`<ip>.sslip.io` host)

---

## 0. Connect to the cluster (every session)

Terraform grants **your user** (`jchandrasekhar@gmail.com`) `roles/container.developer`
(see [terraform/roles.tf](../terraform/roles.tf)), so connect directly — no impersonation:

```powershell
gcloud config set project project-pubsub-32009
gcloud auth login          # sign in as jchandrasekhar@gmail.com
gcloud container clusters get-credentials gke-primary --region us-central1 --project project-pubsub-32009
kubectl get nodes
```

> Do NOT use `--impersonate-service-account=cicd-sa@...`: the `cicd-sa` SA is
> only granted build/registry/logging roles, not `container.developer`, so
> impersonating it fails with 403. If your user still gets 403, the cluster IAM
> hasn't propagated yet — re-run `terraform apply` and retry, or grant yourself:
> `gcloud projects add-iam-policy-binding project-pubsub-32009 --member="user:$(gcloud config get-value account)" --role="roles/container.developer"`

---

## 1. SHUTDOWN

> Order matters: delete the Ingress first (releases the global LB), then the
> workloads. HPAs are deleted with the app manifest, so pods stay down (a bare
> `kubectl scale ... --replicas=0` would be undone by the HPA `minReplicas`).

### 1a. Application-level shutdown (keeps the cluster)

```powershell
# 1) Delete the ingress -> tears down the external HTTPS LB, cert, forwarding rules
kubectl delete -f k8s/rendered-ingress-project-pubsub-32009.yaml --ignore-not-found

# 2) Delete the app (deployments, services, HPAs, configmap, secret, SA, SPC)
kubectl delete -f k8s/rendered-project-pubsub-32009.yaml --ignore-not-found

# 3) Confirm nothing is left
kubectl get deploy,po,svc,ingress,hpa
```

### 1b. Stop paying for nodes (optional, bigger saving)

The node pool autoscales `0..3`, so nodes drain automatically once workloads are
gone. To force it immediately:

```powershell
gcloud container clusters resize gke-primary `
  --node-pool default-pool --num-nodes 0 `
  --region us-central1 --project project-pubsub-32009 --quiet
```

> The regional **control plane still incurs the GKE management fee** while the
> cluster exists. To stop that too, tear down infra with Terraform (section 3).

### 1c. What is intentionally NOT deleted

- Terraform-managed infra: VPC, cluster, Cloud SQL, Memorystore, Artifact
  Registry, BigQuery dataset, Cloud Armor policy, the reserved IP.
- Container images in Artifact Registry.
- Cloud SQL data (the vote tally persists).

---

## 2. START

```powershell
# 0) Ensure nodes exist (only needed if you resized to 0 in 1b)
gcloud container clusters resize gke-primary `
  --node-pool default-pool --num-nodes 1 `
  --region us-central1 --project project-pubsub-32009 --quiet

# 1) Fill in the 3 runtime values in the app manifest BEFORE applying:
#      REDIS_HOST  = terraform -chdir=terraform output -raw webapp_b_redis_host
#      DB_HOST     = terraform -chdir=terraform output -raw webapp_b_sql_private_ip
#      DB_PASSWORD = your var.db_password
#    Edit k8s/rendered-project-pubsub-32009.yaml (ConfigMap webapp-config + Secret webapp-db-secret).

# 2) Deploy the app
kubectl apply -f k8s/rendered-project-pubsub-32009.yaml

# 3) Expose publicly (LB + Cloud Armor + managed cert); substitute the static IP
(Get-Content k8s/rendered-ingress-project-pubsub-32009.yaml) -replace 'LB_IP','136.68.78.115' | kubectl apply -f -

# 4) Watch it come up
kubectl get pods -w
kubectl get ingress webapps-ingress
kubectl get managedcertificate webapps-cert -w   # wait for Status: Active (10-30 min first time)
```

### 2a. Verify

```powershell
kubectl logs deploy/worker --tail=20        # expect: worker: syncing redis -> postgres
curl.exe -sSI https://136.68.78.115.sslip.io/a   # vote   -> 200
curl.exe -sSI https://136.68.78.115.sslip.io/b   # result -> 200
curl.exe -sSI http://136.68.78.115.sslip.io/     # 301 -> https
gcloud compute backend-services list --format="table(name,securityPolicy)"  # webapps-waf attached
```

---

## 3. FULL INFRA TEARDOWN / REBUILD (Terraform) — optional

Use only to stop **all** cost (control plane, Cloud SQL, Memorystore, LB IP).
This destroys data (Cloud SQL votes, BigQuery log tables — allowed by
`delete_contents_on_destroy`).

```powershell
# Tear everything down
terraform -chdir=terraform destroy -var project_id=project-pubsub-32009

# Rebuild everything
terraform -chdir=terraform init -upgrade
terraform -chdir=terraform apply  -var project_id=project-pubsub-32009
# then re-run section 2 (START), and rebuild images if needed:
#   gcloud builds submit --config cloudbuild.yaml .
```

---

## 4. Grafana: BigQuery datasource + dashboard import

The dashboard panels query BigQuery, so Grafana needs a **GCP service account**
with read access. The intended account is `grafana-bq-reader` (matches the
placeholder key file `grafana/grafana-bq-reader-key.json`).

### 4a0. Verify logs are flowing to BigQuery (do this first)

```powershell
# Where does the log sink write? (expect ...datasets/logs_dataset_us)
gcloud logging sinks describe export-to-bq --project=project-pubsub-32009 --format="value(destination)"

# Date-sharded tables show up a few minutes after pods log
# (expect stdout_* for logs and requests_* for HTTP(S) load balancer request logs)
bq ls --project_id=project-pubsub-32009 logs_dataset_us

# Sanity query - proves the error-rate / log-volume panels will return rows
bq query --use_legacy_sql=false --project_id=project-pubsub-32009 `
  "SELECT COUNT(1) AS lines FROM \`project-pubsub-32009.logs_dataset_us.stdout_*\` WHERE _TABLE_SUFFIX = FORMAT_DATE('%Y%m%d', CURRENT_DATE())"

# Sanity query - proves the latency panel will return rows (LB request logs, httpRequest.latency)
bq query --use_legacy_sql=false --project_id=project-pubsub-32009 `
  "SELECT COUNT(1) AS lines FROM \`project-pubsub-32009.logs_dataset_us.requests_*\` WHERE _TABLE_SUFFIX = FORMAT_DATE('%Y%m%d', CURRENT_DATE()) AND httpRequest.latency IS NOT NULL"
```

### 4a. Create the read-only service account + key

```powershell
$P = "project-pubsub-32009"
$SA = "grafana-bq-reader@$P.iam.gserviceaccount.com"

gcloud iam service-accounts create grafana-bq-reader `
  --project=$P --display-name="Grafana BigQuery reader"

# Read data + run query jobs (least privilege)
gcloud projects add-iam-policy-binding $P --member="serviceAccount:$SA" --role="roles/bigquery.dataViewer"
gcloud projects add-iam-policy-binding $P --member="serviceAccount:$SA" --role="roles/bigquery.jobUser"

# Key file for the Grafana datasource (do NOT commit it)
gcloud iam service-accounts keys create grafana/grafana-bq-reader-key.json --iam-account=$SA
```

> Security: `grafana/grafana-bq-reader-key.json` is a real credential — add it to
> `.gitignore` and never commit it. The tracked copy in the repo is an empty
> placeholder only.

### 4b. Add the BigQuery datasource in Grafana

Grafana → **Connections → Data sources → Add data source → Google BigQuery**:
- Authentication: **Google JWT File** → upload `grafana-bq-reader-key.json`
- Default project: `project-pubsub-32009`
- Save & test.

### 4c. Import the dashboard

Grafana → **Dashboards → New → Import → Upload JSON** → `grafana/dashboard-ready.json`
→ map the **DS_BQ** input to the BigQuery datasource → **Import**. It is preset to
`project-pubsub-32009` / `logs_dataset_us`; set the time range to **Last 6h**.

> `dashboard-full.json` additionally needs a **Google Cloud Monitoring** datasource
> (for the CPU/mem/LB metric panels). The 4 required log panels are in
> `dashboard-ready.json`.

---

## 5. Troubleshooting

### Worker: "waiting for redis ... Name or service not known"
`REDIS_HOST`/`DB_HOST` are unset placeholders or the backing services don't exist.

```powershell
# Do the backing services exist? (null = not provisioned -> apply with enable_stateful_services=true)
terraform -chdir=terraform output webapp_b_redis_host
terraform -chdir=terraform output webapp_b_sql_private_ip

# What did the pods actually get?
kubectl get configmap webapp-config -o jsonpath='{.data.REDIS_HOST}{"  "}{.data.DB_HOST}{"\n"}'

# Fix: inject the real private IPs and restart
$redis = terraform -chdir=terraform output -raw webapp_b_redis_host
$sql   = terraform -chdir=terraform output -raw webapp_b_sql_private_ip
kubectl patch configmap webapp-config --type merge -p "{""data"":{""REDIS_HOST"":""$redis"",""DB_HOST"":""$sql""}}"
kubectl patch secret    webapp-db-secret --type merge -p "{""stringData"":{""DB_PASSWORD"":""<var.db_password>""}}"
kubectl rollout restart deployment/worker deployment/webapp-a deployment/webapp-b
kubectl logs deploy/worker --tail=20   # expect: connected to redis / connected to postgres / syncing
```

### Result page shows 0 votes
The worker isn't writing, or vote/result point at different Redis/DB. Compare env:
```powershell
kubectl exec deploy/webapp-a -- printenv REDIS_HOST
kubectl exec deploy/worker   -- printenv REDIS_HOST DB_HOST DB_NAME
kubectl exec deploy/webapp-b -- printenv DB_HOST DB_NAME
# Query the worker's own DB directly:
kubectl exec deploy/worker -- python -c "import os,psycopg2;c=psycopg2.connect(host=os.getenv('DB_HOST'),dbname=os.getenv('DB_NAME'),user=os.getenv('DB_USER'),password=os.getenv('DB_PASSWORD'));cur=c.cursor();cur.execute('SELECT vote,COUNT(id) FROM votes GROUP BY vote');print(cur.fetchall())"
```

### `/a` or `/b` returns 404
GCE ingress does not strip the path prefix; the apps must serve those prefixes
(already handled in `apps/vote` and `apps/result`). Rebuild if you changed them:
`gcloud builds submit --config cloudbuild.yaml .`

---

## Quick reference

| Goal | Command |
|------|---------|
| Stop app, keep cluster | `kubectl delete -f k8s/rendered-ingress-...yaml; kubectl delete -f k8s/rendered-project-...yaml` |
| Stop node cost | `gcloud container clusters resize gke-primary --node-pool default-pool --num-nodes 0 --region us-central1` |
| Start app | `kubectl apply -f k8s/rendered-project-...yaml` then apply the ingress bundle |
| Stop ALL cost | `terraform -chdir=terraform destroy -var project_id=project-pubsub-32009` |
| Grafana BQ reader SA | `gcloud iam service-accounts create grafana-bq-reader ...` (roles: bigquery.dataViewer + jobUser) |
