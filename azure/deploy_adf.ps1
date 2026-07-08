<#
Redeploy the ADF artifacts (linked service, datasets, pipeline) for
adf-anglo-mining-dw. Assumes: az CLI logged in, resource group, storage
account and data factory already exist (see AZURE_ARCHITECTURE.md).
#>
param(
    [string]$Rg      = "rg-anglo-mining-dw",
    [string]$Factory = "adf-anglo-mining-dw",
    [string]$Storage = "stanglominingdw01"
)
$ErrorActionPreference = "Stop"
$adfDir = Join-Path $PSScriptRoot "adf"

# Linked service needs the storage key injected
$key = az storage account keys list --account-name $Storage --resource-group $Rg --query "[0].value" -o tsv
$ls = @{
    type = "AzureBlobFS"
    typeProperties = @{
        url        = "https://$Storage.dfs.core.windows.net"
        accountKey = @{ type = "SecureString"; value = $key }
    }
} | ConvertTo-Json -Depth 5
$lsFile = Join-Path $env:TEMP "ls_adls_deploy.json"
[IO.File]::WriteAllText($lsFile, $ls)
az datafactory linked-service create --factory-name $Factory --resource-group $Rg --linked-service-name ls_adls --properties "@$lsFile" --output none
Remove-Item $lsFile

az datafactory dataset create --factory-name $Factory --resource-group $Rg --dataset-name ds_raw_tsv --properties "@$adfDir\ds_raw_tsv.json" --output none
az datafactory dataset create --factory-name $Factory --resource-group $Rg --dataset-name ds_curated_parquet --properties "@$adfDir\ds_curated_parquet.json" --output none
az datafactory pipeline create --factory-name $Factory --resource-group $Rg --pipeline-name pl_raw_to_curated --pipeline "@$adfDir\pl_raw_to_curated.json" --output none

Write-Host "ADF artifacts deployed. Trigger with run_pipeline.ps1 (or az datafactory pipeline create-run)."
