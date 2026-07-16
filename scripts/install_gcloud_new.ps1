<#
Simple installer script for Google Cloud SDK on Windows.
Run as Administrator in PowerShell: `./install_gcloud.ps1` or right-click Run as Administrator.

This script will:
- check for `gcloud`
- try to install/upgrade via winget
- discover the installed SDK and Terraform directories from the environment and common install paths
- add those directories to the user PATH if needed
- run `gcloud --version` and prompt to authenticate and set project
- enable required APIs and install kubectl

Note: This script cannot complete interactive OAuth automatically; you'll be prompted by `gcloud auth login`.
#>

function Write-Log($m) { Write-Host "[install_gcloud] $m" }

function Add-PathEntry {
  param([string]$Folder)

  if ([string]::IsNullOrWhiteSpace($Folder) -or -not (Test-Path $Folder)) {
    return $false
  }

  $segments = @()
  if (-not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('Path', 'User'))) {
    $segments = [Environment]::GetEnvironmentVariable('Path', 'User') -split ';' | Where-Object { $_ }
  }

  if ($segments -contains $Folder) {
    return $true
  }

  $newUserPath = if ([string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('Path', 'User'))) {
    $Folder
  } else {
    "{0};{1}" -f [Environment]::GetEnvironmentVariable('Path', 'User'), $Folder
  }

  [Environment]::SetEnvironmentVariable('Path', $newUserPath, 'User')
  $env:Path = "$env:Path;$Folder"
  return $true
}

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
$gcloudCandidates = @(
  "$env:ProgramFiles\Google\Cloud SDK\google-cloud-sdk\bin",
  "$env:ProgramFiles(x86)\Google\Cloud SDK\google-cloud-sdk\bin",
  "$env:LOCALAPPDATA\Google\Cloud SDK\google-cloud-sdk\bin",
  "$env:USERPROFILE\AppData\Local\Google\Cloud SDK\google-cloud-sdk\bin"
)

$foundGcloudDir = $null
foreach ($p in $gcloudCandidates) {
  if (Test-Path (Join-Path $p 'gcloud.cmd')) { $foundGcloudDir = $p; break }
}

if (-not $foundGcloudDir) {
  $resolvedGcloud = (Get-Command gcloud -ErrorAction SilentlyContinue | Select-Object -First 1).Source
  if ($resolvedGcloud) { $foundGcloudDir = Split-Path -Parent $resolvedGcloud }
}

if ($foundGcloudDir) {
  Write-Log "gcloud appears installed in: $foundGcloudDir"
  Add-PathEntry -Folder $foundGcloudDir | Out-Null
} else {
  Write-Log "gcloud not found after install attempts. Please run the MSI installer from: https://cloud.google.com/sdk/docs/install#windows and re-run this script."
  exit 1
}

Write-Log "Searching for Terraform..."
$terraformDir = $null
$terraformCommand = Get-Command terraform -ErrorAction SilentlyContinue | Select-Object -First 1
if ($terraformCommand) {
  $terraformDir = Split-Path -Parent $terraformCommand.Source
} else {
  $terraformCandidates = @(
    "$env:ProgramFiles\HashiCorp\Terraform",
    "$env:LOCALAPPDATA\Microsoft\WinGet\Packages\Hashicorp.Terraform_Microsoft.Winget.Source_8wekyb3d8bbwe"
  )
  foreach ($d in $terraformCandidates) {
    if (Test-Path (Join-Path $d 'terraform.exe')) { $terraformDir = $d; break }
  }
}

if (-not $terraformDir) {
  Write-Log "Terraform not found. Attempting winget install..."
  if (Get-Command winget -ErrorAction SilentlyContinue) {
    winget install --id Hashicorp.Terraform -e
    $terraformCommand = Get-Command terraform -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($terraformCommand) { $terraformDir = Split-Path -Parent $terraformCommand.Source }
  }
}

if ($terraformDir) {
  Write-Log "Terraform appears installed in: $terraformDir"
  Add-PathEntry -Folder $terraformDir | Out-Null
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
  $chromePath = "C:\Program Files\Google\Chrome\Application\chrome.exe"
  if (Test-Path $chromePath) {
    $env:BROWSER = $chromePath
    Write-Log "Using Chrome at $chromePath"
  } else {
    Write-Log "Chrome not found at the default path; gcloud will use the OS default browser."
  }
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
