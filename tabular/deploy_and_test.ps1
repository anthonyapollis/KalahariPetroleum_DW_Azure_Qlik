<#
.SYNOPSIS
  Deploy the Kalahari tabular model to SQL Server Analysis Services, process it, and prove
  the DAX measures and row-level security against the SQL warehouse.

.DESCRIPTION
  1. createOrReplace the KalahariFuel database from Kalahari.Tabular\Model.bim (TMSL)
  2. full refresh
  3. DAX checks: model totals must equal SQL totals from KalahariDW_SSIS
  4. RLS check: querying through the "Site Managers" role returns only the caller's mapped
     locations (sec.UserLocation), and the litres match SQL for those locations

  Run in Windows PowerShell 5.1 (the AMO/ADOMD client libraries target .NET Framework).
  Prerequisites: ssis\ packages loaded KalahariDW_SSIS; tabular\sql\01_rls_security_table.sql run.

.EXAMPLE
  powershell.exe -File .\deploy_and_test.ps1
#>
param(
    [string]$Server = 'localhost',
    [string]$Database = 'KalahariFuel',
    [string]$SqlServer = 'localhost'
)
$ErrorActionPreference = 'Stop'
[void][Reflection.Assembly]::LoadWithPartialName('Microsoft.AnalysisServices')
[void][Reflection.Assembly]::LoadWithPartialName('Microsoft.AnalysisServices.AdomdClient')

$bim = Get-Content (Join-Path $PSScriptRoot 'Kalahari.Tabular\Model.bim') -Raw | ConvertFrom-Json
$tmsl = @{ createOrReplace = @{ object = @{ database = $Database }; database = @{ name = $Database; compatibilityLevel = $bim.compatibilityLevel; model = $bim.model } } } | ConvertTo-Json -Depth 50
$refresh = @{ refresh = @{ type = 'full'; objects = @(@{ database = $Database }) } } | ConvertTo-Json -Depth 5

$as = New-Object Microsoft.AnalysisServices.Server
$as.Connect($Server)
foreach ($step in @(@('Deploy', $tmsl), @('Process', $refresh))) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $results = $as.Execute($step[1])
    $errors = @($results | ForEach-Object { $_.Messages } | Where-Object { $_ -is [Microsoft.AnalysisServices.XmlaError] })
    if ($errors.Count) { $as.Disconnect(); throw ("$($step[0]) failed: " + (($errors | ForEach-Object Description) -join ' | ')) }
    Write-Host ("{0,-8} ok ({1:n1}s)" -f $step[0], $sw.Elapsed.TotalSeconds)
}
$as.Disconnect()

function Invoke-Dax([string]$dax, [string]$role) {
    $cs = "Data Source=$Server;Catalog=$Database" + $(if ($role) { ";Roles=$role" } else { '' })
    $c = New-Object Microsoft.AnalysisServices.AdomdClient.AdomdConnection $cs
    $c.Open()
    try {
        $cmd = $c.CreateCommand(); $cmd.CommandText = $dax
        # read row by row: DataTable.Load applies key constraints inferred from the DAX result schema
        $r = $cmd.ExecuteReader(); $t = New-Object System.Data.DataTable
        for ($i = 0; $i -lt $r.FieldCount; $i++) { [void]$t.Columns.Add($r.GetName($i), [object]) }
        while ($r.Read()) { $row = $t.NewRow(); for ($i = 0; $i -lt $r.FieldCount; $i++) { $row[$i] = $r.GetValue($i) }; $t.Rows.Add($row) }
        $r.Close(); return ,$t
    } finally { $c.Close() }
}
function Invoke-SqlScalar([string]$sql) {
    $c = New-Object System.Data.SqlClient.SqlConnection "Server=$SqlServer;Database=KalahariDW_SSIS;Integrated Security=SSPI"
    $c.Open(); try { $cmd = $c.CreateCommand(); $cmd.CommandText = $sql; return $cmd.ExecuteScalar() } finally { $c.Close() }
}

$failures = 0
function Check([string]$name, $model, $sql, [double]$tolerance = 0.5) {
    $ok = [math]::Abs([double]$model - [double]$sql) -le $tolerance
    if (-not $ok) { $script:failures++ }
    $inv = [Globalization.CultureInfo]::InvariantCulture
    Write-Host ([string]::Format($inv, "{0} {1,-44} model {2,18:n1}   sql {3,18:n1}", $(if ($ok) { 'PASS' } else { 'FAIL' }), $name, [double]$model, [double]$sql))
}

Write-Host "`nDAX measures vs SQL warehouse"
$m = (Invoke-Dax @"
EVALUATE ROW (
  "LitresIssued", [Litres Issued], "Transactions", [Fuel Transactions],
  "EligibleLitres", [Eligible Litres], "LitresDelivered", [Litres Delivered],
  "MeterUnits", [Meter Units Recorded], "MissingEquipment", [Transactions Missing Equipment] )
"@).Rows[0]
Check 'Litres Issued'                  $m[0] (Invoke-SqlScalar 'SELECT SUM(Litres) FROM dw.FactFuelTransaction')
Check 'Fuel Transactions'              $m[1] (Invoke-SqlScalar 'SELECT COUNT_BIG(*) FROM dw.FactFuelTransaction')
Check 'Eligible Litres'                $m[2] (Invoke-SqlScalar "SELECT SUM(f.Litres) FROM dw.FactFuelTransaction f JOIN dw.DimEligibleActivity a ON a.EligibleActivityKey = f.EligibleActivityKey WHERE a.EligibilityStatus <> 'Ineligible'")
Check 'Litres Delivered (non-duplicate)' $m[3] (Invoke-SqlScalar 'SELECT SUM(VolumeLitres) FROM dw.FactFuelDelivery WHERE IsDuplicate = 0')
Check 'Meter Units Recorded'           $m[4] (Invoke-SqlScalar 'SELECT SUM(ReadingDiff) FROM dw.FactMeterReading')
Check 'Transactions Missing Equipment' $(if ($m[5] -is [DBNull]) { 0 } else { $m[5] }) (Invoke-SqlScalar 'SELECT COUNT_BIG(*) FROM dw.FactFuelTransaction WHERE EquipmentKey IS NULL')

Write-Host "`nTime intelligence (latest full year in the data)"
$yr = Invoke-SqlScalar 'SELECT MAX(DateKey) / 10000 - 1 FROM dw.FactFuelTransaction'
$ti = (Invoke-Dax "EVALUATE CALCULATETABLE ( ROW ( ""Year"", [Litres Issued], ""PY"", [Litres Issued PY] ), 'Date'[Year] = $yr )").Rows[0]
Check "Litres Issued $yr"      $ti[0] (Invoke-SqlScalar "SELECT SUM(Litres) FROM dw.FactFuelTransaction WHERE DateKey / 10000 = $yr")
Check "Litres Issued PY ($($yr-1))" $ti[1] (Invoke-SqlScalar "SELECT ISNULL(SUM(Litres), 0) FROM dw.FactFuelTransaction WHERE DateKey / 10000 = $($yr - 1)")

Write-Host "`nRow-level security: querying as role 'Site Managers' ($env:USERDOMAIN\$env:USERNAME)"
$me = "$env:USERDOMAIN\$env:USERNAME".Replace("'", "''")
$visible = Invoke-Dax "EVALUATE SUMMARIZECOLUMNS ( Location[Location], ""Litres"", [Litres Issued] )" 'Site Managers'
$visible | Format-Table -AutoSize | Out-String | Write-Host
Check 'Locations visible to role' $visible.Rows.Count (Invoke-SqlScalar "SELECT COUNT(*) FROM sec.UserLocation WHERE UserName = N'$me'") 0
$rlsLitres = (Invoke-Dax 'EVALUATE ROW ( "L", [Litres Issued] )' 'Site Managers').Rows[0][0]
Check 'Litres visible to role' $rlsLitres (Invoke-SqlScalar "SELECT SUM(f.Litres) FROM dw.FactFuelTransaction f JOIN sec.UserLocation u ON u.LocationKey = f.LocationKey WHERE u.UserName = N'$me'")
$allLitres = (Invoke-Dax 'EVALUATE ROW ( "L", [Litres Issued] )' 'Fleet Finance').Rows[0][0]
Check "Role 'Fleet Finance' sees all litres" $allLitres (Invoke-SqlScalar 'SELECT SUM(Litres) FROM dw.FactFuelTransaction')

if ($failures) { Write-Host "`n$failures check(s) failed" -ForegroundColor Red; exit 1 }
Write-Host "`nAll checks passed" -ForegroundColor Green
