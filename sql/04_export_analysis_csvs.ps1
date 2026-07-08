<#
Export analysis aggregates from the dw views/facts to data\analysis\*.csv.
These feed the charts, Excel workbook and the data-story ebook.
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

function Export-Query([string]$name, [string]$sql) {
    $cmd = $cn.CreateCommand()
    $cmd.CommandText = $sql
    $cmd.CommandTimeout = 900
    $da = New-Object System.Data.SqlClient.SqlDataAdapter $cmd
    $dt = New-Object System.Data.DataTable
    [void]$da.Fill($dt)
    $path = Join-Path $OutDir "$name.csv"
    $sb = New-Object Text.StringBuilder
    [void]$sb.AppendLine(($dt.Columns.ColumnName -join ","))
    foreach ($row in $dt.Rows) {
        $vals = foreach ($c in $dt.Columns) {
            $v = $row[$c]
            if ($v -is [DBNull]) { "" }
            elseif ($v -is [string] -and ($v.Contains(",") -or $v.Contains('"'))) { '"' + $v.Replace('"','""') + '"' }
            else { [string]$v -replace ',', '.' }   # invariant decimals
        }
        [void]$sb.AppendLine(($vals -join ","))
    }
    [IO.File]::WriteAllText($path, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
    Write-Host "$name.csv: $($dt.Rows.Count) rows"
}

Export-Query "refund_by_month" "SELECT ClaimYearMonth, UsageTypeName, TotalLitres, NonEligibleLitres, EligibleLitres, QualifyingClaimLitres, RefundRateCentsPerLitre, RefundAmountRand, RateMissingFlag FROM dw.vw_DieselRefundByMonth ORDER BY ClaimYearMonth"

Export-Query "monthly_fuel" "SELECT YearMonth, [Year], FiscalYearSA, LocationDescription, ProductName, EligibilityStatus, CAST(LitresIssued AS decimal(18,2)) AS LitresIssued, TransactionCount FROM dw.vw_MonthlyFuelSummary ORDER BY YearMonth"

Export-Query "yearly_fuel" "SELECT d.[Year], CAST(SUM(f.Litres) AS decimal(18,0)) AS LitresIssued, COUNT_BIG(*) AS Transactions FROM dw.FactFuelTransaction f JOIN dw.DimDate d ON d.DateKey = f.DateKey GROUP BY d.[Year] ORDER BY d.[Year]"

Export-Query "top_equipment" "SELECT TOP 25 e.FleetId, e.RegNumber, e.MakeName, e.ModelName, e.VehicleTypeName, e.ConsumptionTypeName, e.EligibilityClass, CAST(SUM(f.Litres) AS decimal(18,0)) AS TotalLitres, COUNT_BIG(*) AS Transactions FROM dw.FactFuelTransaction f JOIN dw.DimEquipment e ON e.EquipmentKey = f.EquipmentKey GROUP BY e.FleetId, e.RegNumber, e.MakeName, e.ModelName, e.VehicleTypeName, e.ConsumptionTypeName, e.EligibilityClass ORDER BY SUM(f.Litres) DESC"

Export-Query "fuel_by_location" "SELECT l.LocationDescription, CAST(SUM(f.Litres) AS decimal(18,0)) AS LitresIssued, COUNT_BIG(*) AS Transactions FROM dw.FactFuelTransaction f JOIN dw.DimLocation l ON l.LocationKey = f.LocationKey GROUP BY l.LocationDescription ORDER BY SUM(f.Litres) DESC"

Export-Query "material_movement" "SELECT ISNULL(NULLIF(LTRIM(RTRIM(MaterialType)),''),'(unspecified)') AS MaterialType, COUNT_BIG(*) AS Trips, CAST(AVG(CAST(TripDurationInMinutes AS float)) AS decimal(18,1)) AS AvgTripMinutes FROM dw.FactEquipmentTrip GROUP BY ISNULL(NULLIF(LTRIM(RTRIM(MaterialType)),''),'(unspecified)') ORDER BY COUNT_BIG(*) DESC"

Export-Query "trips_by_month" "SELECT d.YearMonth, COUNT_BIG(*) AS Trips, CAST(SUM(CAST(t.TripDurationInMinutes AS bigint)) / 60.0 AS decimal(18,0)) AS TripHours FROM dw.FactEquipmentTrip t JOIN dw.DimDate d ON d.DateKey = t.SourceDateKey GROUP BY d.YearMonth ORDER BY d.YearMonth"

Export-Query "seasonal_fuel" "SELECT d.SeasonSouthernAfrica, d.[Year], CAST(SUM(f.Litres) AS decimal(18,0)) AS LitresIssued FROM dw.FactFuelTransaction f JOIN dw.DimDate d ON d.DateKey = f.DateKey GROUP BY d.SeasonSouthernAfrica, d.[Year] ORDER BY d.[Year], d.SeasonSouthernAfrica"

Export-Query "vehicle_type_fuel" "SELECT TOP 15 e.VehicleTypeName, CAST(SUM(f.Litres) AS decimal(18,0)) AS LitresIssued, COUNT(DISTINCT e.EquipmentKey) AS EquipmentCount FROM dw.FactFuelTransaction f JOIN dw.DimEquipment e ON e.EquipmentKey = f.EquipmentKey WHERE e.VehicleTypeName IS NOT NULL GROUP BY e.VehicleTypeName ORDER BY SUM(f.Litres) DESC"

Export-Query "tank_reconciliation" "SELECT LocationDescription, YearMonth, CAST(DeliveredLitres AS decimal(18,0)) AS DeliveredLitres, CAST(IssuedLitres AS decimal(18,0)) AS IssuedLitres, CAST(NetLitres AS decimal(18,0)) AS NetLitres FROM dw.vw_TankReconciliation WHERE YearMonth >= '2019-11' ORDER BY YearMonth, LocationDescription"

Export-Query "data_quality" "SELECT issue, row_count FROM dw.vw_DataQuality ORDER BY row_count DESC"

Export-Query "dq_over_tank" "SELECT TOP 15 e.FleetId, e.RegNumber, e.TankSize, CAST(MAX(f.Litres) AS decimal(18,1)) AS MaxSingleIssueLitres, COUNT_BIG(*) AS OverTankIssues FROM dw.FactFuelTransaction f JOIN dw.DimEquipment e ON e.EquipmentKey = f.EquipmentKey WHERE e.TankSize > 0 AND f.Litres > e.TankSize * 1.5 GROUP BY e.FleetId, e.RegNumber, e.TankSize ORDER BY COUNT_BIG(*) DESC"

$cn.Close()
Write-Host "Analysis CSVs complete: $OutDir"
