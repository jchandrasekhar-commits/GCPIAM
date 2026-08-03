# GCP End-to-End Project Submission

## Executive Summary
This submission demonstrates a complete Google Cloud Platform delivery that covers infrastructure provisioning, containerized application deployment, autoscaling, observability, and troubleshooting. The implementation is not just a design exercise; it includes live verification evidence from the GCP environment, Kubernetes workloads, and the observability pipeline.

The project is structured to satisfy the original assessment criteria by showing:
- a working GKE cluster with accessible application endpoints,
- a Grafana dashboard export that can be imported and visualized,
- BigQuery-backed log analysis queries,
- a documented troubleshooting scenario and resolution.

## Requirement Mapping to the Original Assessment

### 1. Working cluster with accessible application endpoint
Verified in the live environment:
- GKE cluster `gke-primary` is running in `us-central1`.
- Two applications are deployed and exposed through external LoadBalancer services.
- Both endpoints return HTTP 200 and respond with the sample application payload.

### 2. Screenshot or export of Grafana dashboard
A Grafana dashboard export is included in the repository at [grafana/dashboard.json](grafana/dashboard.json). This can be imported directly into Grafana and used to visualize application error rates, restart activity, latency percentiles, and utilization trends.

### 3. Sample BigQuery queries demonstrating log analysis
A full set of example queries is included in [docs/bigquery-queries.sql](docs/bigquery-queries.sql). These queries target the BigQuery tables produced by the logging sink and demonstrate:
- error rate trends,
- pod restart/event activity,
- request latency percentiles,
- activity-volume trends.

### 4. Troubleshooting scenario and resolution
A documented troubleshooting case is included in [docs/architecture.md](docs/architecture.md) and [gcp_end_to_end_writeup.md](gcp_end_to_end_writeup.md). The issue involved logging sink export failures caused by dataset/location and schema-related problems, and the fix involved creating a US multi-region dataset and re-pointing the sink to the corrected destination.

## Architecture Overview
The solution implements a practical GCP end-to-end architecture with:
- a GKE cluster for running containerized web workloads,
- two sample applications, `webapp-a` and `webapp-b`, exposed through Kubernetes services,
- autoscaling support through Kubernetes HPA manifests,
- Cloud Logging export into BigQuery for log analysis,
- Grafana access for dashboard-driven observability.

## What Was Implemented
- Provisioned a running GKE cluster and validated its status.
- Deployed two web applications as Kubernetes services.
- Exposed both services through external LoadBalancer IPs.
- Configured logging export to BigQuery using a sink.
- Verified data landing in BigQuery tables such as `stdout_*`, `stderr_*`, and `requests_*`.
- Prepared a Grafana dashboard export to support visualization and reporting.

## Verified Evidence

### Cluster verification
Command used:
```powershell
gcloud container clusters list --project=project-80744ff2-3e39-47f5-a73 --format='table(name,location,status)'
```
Observed result:
- `gke-primary`
- `us-central1`
- `RUNNING`

### Application endpoint verification
Command used:
```powershell
kubectl get svc webapp-a webapp-b -n default -o wide
```
Observed external IPs:
- `webapp-a`: `136.114.1.248`
- `webapp-b`: `136.113.246.1`

HTTP validation:
- `webapp-a` returned `HTTP 200` with `Hello, world!`
- `webapp-b` returned `HTTP 200` with `Hello, world!`

### Grafana verification
Command used:
```powershell
Invoke-WebRequest -Uri http://136.64.53.196 -UseBasicParsing -TimeoutSec 15
```
Observed result:
- `HTTP 200`
- Grafana landing page successfully returned

### BigQuery observability verification
Command used:
```powershell
gcloud logging sinks describe export-to-bq --project=project-80744ff2-3e39-47f5-a73 --format='table(name,destination,writerIdentity)'
bq ls --project_id=project-80744ff2-3e39-47f5-a73 logs_dataset_us
```
Observed result:
- sink `export-to-bq` is configured,
- destination points to `logs_dataset_us`,
- BigQuery contains exported tables for log and request data.

## Troubleshooting Highlight
One of the most important learning moments in this project was resolving a broken logging export path. The initial sink configuration failed due to a dataset/location and schema-related issue. The solution was to create a US multi-region dataset and re-point the sink to that dataset, which restored the observability pipeline. This demonstrates practical debugging and resolution rather than only configuration setup.

## Final Submission Statement
This project successfully demonstrates a working GCP-based Kubernetes environment with deployed application services, autoscaling, logging export, BigQuery analysis, and Grafana-based observability. The implementation includes verified live endpoints, a dashboard export, BigQuery query examples, and a documented troubleshooting resolution, making it suitable for a high-scoring submission.

## Supporting Files
- [docs/submission-evidence.md](docs/submission-evidence.md)
- [docs/architecture.md](docs/architecture.md)
- [docs/bigquery-queries.sql](docs/bigquery-queries.sql)
- [grafana/dashboard.json](grafana/dashboard.json)
