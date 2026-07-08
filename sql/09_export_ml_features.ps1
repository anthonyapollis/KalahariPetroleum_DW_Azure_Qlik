<#
Export per-transaction features for the fuel-anomaly ML model
(theft/leakage/meter-fault candidates).
#>
param(
    [string]$OutDir = "$PSScriptRoot\..\data\analysis",
    [string]$Server = "localhost",
    [string]$Database = "AngloData_QA_20220825_1820"
)
$ErrorActionPreference = "Stop"
New-Item -ItemType Directory -Force $OutDir | Out-Null

$cn = New-Object System.Data.SqlClient.SqlConnection "Server=$Server;Database=$Database;Integrated Security=True"
$cn.Open()
$cmd = $cn.CreateCommand()
$cmd.CommandTimeout = 900
$cmd.CommandText = @"
SELECT
    f.FuelTransactionKey,
    f.TransactionDateTime,
    DATEPART(hour, f.TransactionDateTime) AS HourOfDay,
    DATEPART(weekday, f.TransactionDateTime) AS DayOfWeek,
    f.Litres,
    e.TankSize,
    CASE WHEN e.TankSize > 0 THEN f.Litres / e.TankSize ELSE NULL END AS TankFillRatio,
    e.FleetId,
    e.RegNumber,
    e.MakeName,
    e.VehicleTypeName,
    e.ConsumptionTypeName,
    e.EligibilityClass,
    l.LocationDescription,
    f.VoucherNumber,
    f.FuelEventId
FROM dw.FactFuelTransaction f
JOIN dw.DimEquipment e ON e.EquipmentKey = f.EquipmentKey
LEFT JOIN dw.DimLocation l ON l.LocationKey = f.LocationKey
WHERE e.TankSize > 0 AND f.Litres > 0;
"@
$da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
$dt = New-Object System.Data.DataTable
[void]$da.Fill($dt)

$path = Join-Path $OutDir "ml_fuel_features.csv"
$sb = New-Object Text.StringBuilder
[void]$sb.AppendLine(($dt.Columns.ColumnName -join ","))
foreach ($row in $dt.Rows) {
    $vals = foreach ($c in $dt.Columns) {
        $v = $row[$c]
        if ($v -is [DBNull]) { "" }
        elseif ($v -is [string] -and ($v.Contains(",") -or $v.Contains('"'))) { '"' + $v.Replace('"','""') + '"' }
        else { [string]$v -replace ',', '.' }
    }
    [void]$sb.AppendLine(($vals -join ","))
}
[IO.File]::WriteAllText($path, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
$cn.Close()
Write-Host "ml_fuel_features.csv: $($dt.Rows.Count) rows -> $path"
