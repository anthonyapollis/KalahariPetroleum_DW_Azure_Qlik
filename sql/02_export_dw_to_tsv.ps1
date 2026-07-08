<#
Export the dw star schema (and dbo.CoordRef) from AngloData_QA_20220825_1820
to tab-delimited files with header rows, ready for upload to ADLS Gen2.

Usage: .\02_export_dw_to_tsv.ps1 [-OutDir <path>]
Requires: bcp (SQL Server tools), Windows auth to localhost.
#>
param(
    [string]$OutDir = "$PSScriptRoot\..\data_export",
    [string]$Server = "localhost",
    [string]$Database = "AngloData_QA_20220825_1820",
    # dbo.CoordRef is 21.9M rows; at this box's bcp throughput (~3,700 rows/s)
    # it takes ~100 minutes, so it is opt-in.
    [switch]$IncludeCoordRef
)

$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force $OutDir | Out-Null

$cn = New-Object System.Data.SqlClient.SqlConnection "Server=$Server;Database=$Database;Integrated Security=True"
$cn.Open()

function Get-Columns([string]$schema, [string]$table) {
    $cmd = $cn.CreateCommand()
    $cmd.CommandText = "SELECT c.name FROM sys.columns c WHERE c.object_id = OBJECT_ID('$schema.$table') ORDER BY c.column_id"
    $r = $cmd.ExecuteReader()
    $cols = @(); while ($r.Read()) { $cols += $r.GetString(0) }
    $r.Close()
    return $cols
}

# dw star schema tables + the large geo reference table
$tables = @(
    @{s='dw';  t='DimDate'},
    @{s='dw';  t='DimEquipment'},
    @{s='dw';  t='DimLocation'},
    @{s='dw';  t='DimProduct'},
    @{s='dw';  t='DimCostCentre'},
    @{s='dw';  t='DimEligibleActivity'},
    @{s='dw';  t='DimSARSUsageType'},
    @{s='dw';  t='DimRefundRate'},
    @{s='dw';  t='FactFuelTransaction'},
    @{s='dw';  t='FactFuelDelivery'},
    @{s='dw';  t='FactMeterReading'},
    @{s='dw';  t='FactEquipmentTrip'},
    @{s='dw';  t='FactLocationVolume'},
    @{s='dw';  t='FactStorageLogbook'},
    @{s='dw';  t='FactFuelUsageClassification'},
    @{s='dw';  t='FactDieselRefundClaim'}
)
if ($IncludeCoordRef) { $tables += @{s='dbo'; t='CoordRef'} }

foreach ($tb in $tables) {
    $name = $tb.t
    $full = "$($tb.s).$($tb.t)"
    Write-Host "Exporting $full ..."
    $cols = Get-Columns $tb.s $tb.t
    $headerFile = Join-Path $OutDir "$name.header"
    $dataFile   = Join-Path $OutDir "$name.dat"
    $outFile    = Join-Path $OutDir "$name.tsv"
    [IO.File]::WriteAllText($headerFile, ($cols -join "`t") + "`r`n")

    # -c char mode, tab delimiter (default), UTF-8 (-C 65001).
    # Use -r "\n": bcp char mode expands it to CRLF; passing "\r\n" yields \r\r\n.
    & bcp $full out $dataFile -S $Server -d $Database -T -c -C 65001 -r "\n" | Select-Object -Last 3
    if ($LASTEXITCODE -ne 0) { throw "bcp failed for $full" }

    $out = [IO.File]::Create($outFile)
    foreach ($part in @($headerFile, $dataFile)) {
        $in = [IO.File]::OpenRead($part)
        $in.CopyTo($out)
        $in.Close()
    }
    $out.Close()
    Remove-Item $headerFile, $dataFile -Force
    $mb = [Math]::Round((Get-Item $outFile).Length / 1MB, 1)
    Write-Host "  -> $outFile ($mb MB)"
}
$cn.Close()
Write-Host "Export complete: $OutDir"
