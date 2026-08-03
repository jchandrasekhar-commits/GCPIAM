# Requires PowerShell
$PROJECT_ID = gcloud config get-value project
Write-Host "Deploying to project: $PROJECT_ID"
(Get-Content k8s/secretproviderclass.yaml) -replace '\$PROJECT_ID', $PROJECT_ID | kubectl apply -f -
(Get-Content k8s/webapp-serviceaccount.yaml) -replace 'PROJECT_ID', $PROJECT_ID | kubectl apply -f -

# Prepare the Grafana Dashboard for import by replacing the project ID
(Get-Content grafana/dashboard.json) -replace '\$PROJECT_ID', $PROJECT_ID | Set-Content grafana/dashboard-ready.json
Write-Host "Grafana dashboard prepared at grafana/dashboard-ready.json"

