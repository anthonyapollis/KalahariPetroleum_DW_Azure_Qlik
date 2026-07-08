<#
Trigger pl_raw_to_curated for all exported tables and poll until finished.
#>
param(
    [string]$Rg      = "rg-anglo-mining-dw",
    [string]$Factory = "adf-anglo-mining-dw"
)
$tables = @(
    'DimDate','DimEquipment','DimLocation','DimProduct','DimCostCentre',
    'DimEligibleActivity','DimSARSUsageType','DimRefundRate',
    'FactFuelTransaction','FactFuelDelivery','FactMeterReading',
    'FactEquipmentTrip','FactLocationVolume','FactStorageLogbook',
    'FactFuelUsageClassification','FactDieselRefundClaim','CoordRef'
)
$paramFile = Join-Path $env:TEMP "adf_run_params.json"
@{ tableList = $tables } | ConvertTo-Json -Compress | Set-Content $paramFile

$runId = az datafactory pipeline create-run --factory-name $Factory --resource-group $Rg --name pl_raw_to_curated --parameters "@$paramFile" --query runId -o tsv
Write-Host "Pipeline run started: $runId"

do {
    Start-Sleep -Seconds 20
    $status = az datafactory pipeline-run show --factory-name $Factory --resource-group $Rg --run-id $runId --query status -o tsv
    Write-Host "  status: $status"
} while ($status -in @('Queued','InProgress'))

az datafactory pipeline-run show --factory-name $Factory --resource-group $Rg --run-id $runId --query "{status:status, duration:durationInMs, message:message}" -o json
