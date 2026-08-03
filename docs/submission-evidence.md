# Submission Evidence Pack

This file captures the live evidence that can be used to support the GCP end-to-end project submission. It is structured to directly match the original assessment criteria and to provide concrete proof of implementation.

## 1. Cluster status

Verified with:

```powershell
gcloud container clusters list --project=gke-cluster-504002 --format='table(name,location,status)'
```

Observed result:

- Cluster: `gke-primary`
- Location: `us-central1`
- Status: `RUNNING`

## 2. Application endpoints

As architected, our apps are fronted securely by a **Google Global HTTP(S) Load Balancer** with Cloud Armor WAF integration. The pods are exposed via `NodePort` mapping through Container-Native Network Endpoint Groups (NEGs) directly to the Load Balancer IP.

Verified with:

```powershell
# Get Kubernetes Services mapping NEGs
kubectl get svc webapp-a webapp-b -n default -o wide

# Get Global Static IP assigned to the Load Balancer
gcloud compute addresses describe webapps-lb-ip --global --project=gke-cluster-504002 --format="value(address)"
```

Observed result:

- Global Static IP: `8.233.55.181`
- `webapp-a`: Port 80 (NodePort: 30967)
- `webapp-b`: Port 80 (NodePort: 30725)

HTTP checks:

```powershell
# Bypassing un-provisioned DNS requirements by overriding Host Header and ignoring SSL warnings:
curl -I -H "Host: app.example.com" http://8.233.55.181/
curl -k -H "Host: app.example.com" https://8.233.55.181/
curl -k -H "Host: app.example.com" https://8.233.55.181/b
```

Observed responses:

- HTTP to HTTPS Redirect: HTTP 301 Moved Permanently
- `webapp-a` Root (`/`): HTTP 200 with `Hello, world!`
- `webapp-b` Path (`/b`): HTTP 200 with `Hello, world!`

Internal Pod tests (bypassing LB):

```powershell
kubectl port-forward svc/webapp-b 8080:80
curl http://localhost:8080/
```
Observed response:
```text
Hello, world!
Version: 1.0.0
Hostname: webapp-b-666c7d67b9-vrdvf
```

## 3. Grafana endpoint and dashboard export

Verified with:

```powershell
Invoke-WebRequest -Uri http://136.64.53.196 -UseBasicParsing -TimeoutSec 15
```

Observed result:

- HTTP 200
- Grafana landing page successfully returned

Dashboard export available at:
- [grafana/dashboard.json](grafana/dashboard.json)

This file is suitable as the required dashboard export artifact and can be imported into Grafana directly.

## 4. Logging sink and BigQuery export

Verified with:

```powershell
gcloud logging sinks describe export-to-bq --project=gke-cluster-504002 --format='table(name,destination,writerIdentity)'
bq ls --project_id=gke-cluster-504002 logs_dataset_us
```

Observed result:

- Sink: `export-to-bq`
- Destination: `bigquery.googleapis.com/projects/gke-cluster-504002/datasets/logs_dataset_us`
- Writer identity: `serviceAccount:service-108624680710@gcp-sa-logging.iam.gserviceaccount.com`
- BigQuery dataset actively logging container streams: `stdout_20260802`, `stderr_20260802`

## 5. Troubleshooting evidence

The project includes documented troubleshooting cases in [docs/architecture.md](docs/architecture.md) and [gcp_end_to_end_writeup.md](gcp_end_to_end_writeup.md). 

**Issue 1 (Logging Schema):** A logging export failure caused by the dataset/location and schema-related problem, and the fix was to create a US multi-region dataset and re-point the sink to that destination.

**Issue 2 (GKE Autoscaler Exhaustion):** After creating the Load Balancer, the `webapp-a` and `webapp-b` pods got stuck in a `Pending` state. `kubectl describe pod` revealed: `0/2 nodes are available: 1 Insufficient cpu, 2 Insufficient memory`. Since the backend GKE nodes were `e2-small`, the kube-system logs quickly ate up 85% of memory allocation. I edited `main.tf` to bump the nodes to `e2-medium` and increased the `max_node_count` from 1 to 3 in the autoscaler block. Afterward, `kubectl port-forward` directly into the pod successfully returned HTTP 200 payload responses.

**Issue 3 (Secret Manager Addon Missing):** Applying `secretproviderclass.yaml` caused a failure `no matches for kind "SecretProviderClass" in version "secrets-store.csi.x-k8s.io/v1"`. The fix was using `gcloud container clusters update` to run `--enable-secret-manager` since Terraform didn't explicitly provision the CSI addon, which correctly initialized the underlying custom resource definitions!

## 6. What to include in the final submission

Use the following evidence items in the report or presentation:

1. The live GKE cluster status output.
2. The Kubernetes service output showing both external IPs.
3. The HTTP 200 responses from both application endpoints.
4. The Grafana dashboard export file at [grafana/dashboard.json](grafana/dashboard.json).
5. The BigQuery export evidence showing tables in `logs_dataset_us`.
6. The troubleshooting narrative describing the issue and resolution.
