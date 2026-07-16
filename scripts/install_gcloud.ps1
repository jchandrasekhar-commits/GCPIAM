<#
Simple installer script for Google Cloud SDK on Windows.
Run as Administrator in PowerShell: `.
un_as_admin.ps1` or right-click Run as Administrator.

This script will:
- check for `gcloud`
- try to install/upgrade via winget
- add Cloud SDK bin to user PATH if needed
- run `gcloud --version` and prompt to authenticate and set project
- enable required APIs and install kubectl

Note: This script cannot complete interactive OAuth automatically; you'll be prompted by `gcloud auth login`.
#>

function Write-Log($m){ Write-Host "[install_gcloud] $m" }

Write-Log "Checking for existing gcloud..."
$gcloudPath = (& where.exe gcloud 2>$null) -join ";"
if ($gcloudPath) {
  Write-Log "gcloud found at: $gcloudPath"
} else {
  Write-Log "gcloud not found. Attempting to install via winget..."
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    Write-Log "Running: winget install --id Google.CloudSDK -e --include-unknown"
    winget install --id Google.CloudSDK -e --include-unknown
  } elseif (Get-Command choco -ErrorAction SilentlyContinue) {
    Write-Log "winget not found but Chocolatey is available; installing via choco"
    choco install googlecloudsdk -y
  } else {
    Write-Log "No winget or choco detected. Please install Cloud SDK manually from https://cloud.google.com/sdk/docs/install#windows"
    exit 1
  }
}

Start-Sleep -Seconds 2

Write-Log "Searching common install locations for gcloud..."
$possible = @(
  "$env:ProgramFiles\Google\Cloud SDK\google-cloud-sdk\bin",
  "$env:ProgramFiles(x86)\Google\Cloud SDK\google-cloud-sdk\bin",
  "$env:USERPROFILE\AppData\Local\Google\Cloud SDK\google-cloud-sdk\bin"
)

$found = $null
foreach ($p in $possible) {
  if (Test-Path (Join-Path $p 'gcloud.cmd')) { $found = $p; break }
}

if (-not $found) {
  # try where again
  $where = (& where.exe gcloud 2>$null) | Select-Object -First 1
  if ($where) { $found = Split-Path $where }
}

if ($found) {
  Write-Log "gcloud appears installed in: $found"
  if ($env:Path -notlike "*${found}*") {
    Write-Log "Adding $found to user PATH"
    $newPath = [Environment]::GetEnvironmentVariable('Path','User')
    if (-not $newPath) { $newPath = $env:Path }
    if ($newPath -notlike "*${found}*") {
      [Environment]::SetEnvironmentVariable('Path', "$newPath;$found", 'User')
      Write-Log "Added to user PATH. Please restart PowerShell after this script finishes."
    }
  }
} else {
  Write-Log "gcloud not found after install attempts. Please run the MSI installer from: https://cloud.google.com/sdk/docs/install#windows and re-run this script."
  exit 1
}

Write-Log "Checking gcloud availability now..."
try {
  & gcloud --version
} catch {
  Write-Log "gcloud command still not found in current session. Restart PowerShell and run: gcloud --version"
  exit 1
}

# Interactive setup
$project = Read-Host "Enter GCP project id to configure (or leave blank to skip)"
if ($project) {
  Write-Log "Opening browser to authenticate..."
  gcloud auth login
  Write-Log "Setting project to $project"
  gcloud config set project $project
  Write-Log "Enabling required APIs (container, bigquery, logging, compute)"
  gcloud services enable container.googleapis.com bigquery.googleapis.com logging.googleapis.com compute.googleapis.com iam.googleapis.com cloudresourcemanager.googleapis.com
} else {
  Write-Log "Skipping project configuration/authentication. You can run 'gcloud auth login' and 'gcloud config set project <PROJECT>' later."
}

Write-Log "Installing kubectl component via gcloud components (if available)"
try { gcloud components install kubectl -q } catch { Write-Log "components install failed or components manager not present; install kubectl separately." }

Write-Log "Done. If you just added PATH, restart PowerShell and run 'gcloud --version'"
