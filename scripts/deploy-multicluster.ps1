# Deploy the web apps to BOTH GKE clusters and wire up Multi-Cluster Ingress.
#
# Prereqs:
#   - terraform apply with:  enable_secondary=true  enable_multicluster_ingress=true
#   - gcloud + kubectl authenticated to the project
#
# What it does:
#   1. Fetches credentials/contexts for gke-primary and gke-secondary.
#   2. Deploys the identical workloads (config, webapp-a/b, worker, HPAs,
#      BackendConfig) to BOTH clusters -> app replication across clusters.
#   3. Applies the MultiClusterService + MultiClusterIngress objects to the
#      CONFIG cluster only (gke-primary) -> one global LB with cross-cluster
#      failover.
param(
  [string]$ProjectId = (gcloud config get-value project),
  [string]$PrimaryRegion = "us-central1",
  [string]$SecondaryRegion = "us-east1"
)

$ErrorActionPreference = "Stop"
Write-Host "Project: $ProjectId"

# 1. Credentials / contexts -------------------------------------------------
gcloud container clusters get-credentials gke-primary   --region $PrimaryRegion   --project $ProjectId
gcloud container clusters get-credentials gke-secondary --region $SecondaryRegion --project $ProjectId

$primaryCtx   = "gke_${ProjectId}_${PrimaryRegion}_gke-primary"
$secondaryCtx = "gke_${ProjectId}_${SecondaryRegion}_gke-secondary"

# Workloads that must exist in EVERY cluster for MCS to aggregate their pods.
$workloads = @(
  "k8s/webapp-config.yaml",
  "k8s/backendconfig.yaml",
  "k8s/webapp-serviceaccount.yaml",
  "k8s/webapp-a-deployment.yaml",
  "k8s/webapp-a-service.yaml",
  "k8s/webapp-a-hpa.yaml",
  "k8s/webapp-b-deployment.yaml",
  "k8s/webapp-b-service.yaml",
  "k8s/webapp-b-hpa.yaml",
  "k8s/pdb.yaml"
)

# 2. Replicate workloads to BOTH clusters -----------------------------------
# Images live in one Artifact Registry (PrimaryRegion); every cluster pulls from
# it, so REGION -> PrimaryRegion and PROJECT_ID -> ProjectId in each manifest.
foreach ($ctx in @($primaryCtx, $secondaryCtx)) {
  Write-Host "`n=== Deploying workloads to $ctx ===" -ForegroundColor Cyan
  foreach ($f in $workloads) {
    (Get-Content $f -Raw) -replace 'PROJECT_ID', $ProjectId -replace '\bREGION\b', $PrimaryRegion |
      kubectl --context $ctx apply -f -
  }
}

# 3. Multi-Cluster Ingress objects -> CONFIG cluster (gke-primary) only ------
Write-Host "`n=== Applying MCS + MCI to config cluster ($primaryCtx) ===" -ForegroundColor Cyan
kubectl --context $primaryCtx apply -f k8s/multicluster/mcs-webapp-a.yaml
kubectl --context $primaryCtx apply -f k8s/multicluster/mcs-webapp-b.yaml
kubectl --context $primaryCtx apply -f k8s/multicluster/mci-webapps.yaml

Write-Host "`nDone. Check status with:" -ForegroundColor Green
Write-Host "  kubectl --context $primaryCtx describe mci webapps-mci -n default"
