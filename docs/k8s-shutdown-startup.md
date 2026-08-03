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

## Quick reference

| Goal | Command |
|------|---------|
| Stop app, keep cluster | `kubectl delete -f k8s/rendered-ingress-...yaml; kubectl delete -f k8s/rendered-project-...yaml` |
| Stop node cost | `gcloud container clusters resize gke-primary --node-pool default-pool --num-nodes 0 --region us-central1` |
| Start app | `kubectl apply -f k8s/rendered-project-...yaml` then apply the ingress bundle |
| Stop ALL cost | `terraform -chdir=terraform destroy -var project_id=project-pubsub-32009` |
