<#
Export haulage-site and route aggregates for the interactive map.
Note: source columns FactEquipmentTrip.LatStart/LongStart (and *End) are
TRANSPOSED in the source system - "Lat" holds longitude-shaped values
(~28.9, positive) and "Long" holds latitude-shaped values (~-23.9, negative).
Corrected here (aliased Latitude/Longitude) - see data-quality note in the map.
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
            else { [string]$v -replace ',', '.' }
        }
        [void]$sb.AppendLine(($vals -join ","))
    }
    [IO.File]::WriteAllText($path, $sb.ToString(), (New-Object Text.UTF8Encoding($false)))
    Write-Host "$name.csv: $($dt.Rows.Count) rows"
}

# Site-level aggregate: one row per named haulage site (source location of a trip)
Export-Query "map_sites" @"
SELECT
    LTRIM(RTRIM(SourceLocationDescription)) AS SiteName,
    CAST(AVG(LongStart) AS decimal(9,6)) AS Latitude,
    CAST(AVG(LatStart) AS decimal(9,6)) AS Longitude,
    COUNT_BIG(*) AS TripCount,
    COUNT(DISTINCT EquipmentKey) AS EquipmentCount,
    CAST(AVG(CAST(TripDurationInMinutes AS float)) AS decimal(10,1)) AS AvgTripMinutes,
    (SELECT TOP 1 LTRIM(RTRIM(t2.MaterialType)) FROM dw.FactEquipmentTrip t2
     WHERE LTRIM(RTRIM(t2.SourceLocationDescription)) = LTRIM(RTRIM(t.SourceLocationDescription))
       AND t2.MaterialType IS NOT NULL AND LTRIM(RTRIM(t2.MaterialType)) <> ''
     GROUP BY LTRIM(RTRIM(t2.MaterialType))
     ORDER BY COUNT(*) DESC) AS TopMaterialType,
    (SELECT TOP 1 LTRIM(RTRIM(t3.EligibleActivityPerformed)) FROM dw.FactEquipmentTrip t3
     WHERE LTRIM(RTRIM(t3.SourceLocationDescription)) = LTRIM(RTRIM(t.SourceLocationDescription))
       AND t3.EligibleActivityPerformed IS NOT NULL AND LTRIM(RTRIM(t3.EligibleActivityPerformed)) <> ''
     GROUP BY LTRIM(RTRIM(t3.EligibleActivityPerformed))
     ORDER BY COUNT(*) DESC) AS TopEligibleActivity
FROM dw.FactEquipmentTrip t
WHERE LatStart IS NOT NULL AND LatStart <> 0
  AND SourceLocationDescription IS NOT NULL AND LTRIM(RTRIM(SourceLocationDescription)) <> ''
GROUP BY LTRIM(RTRIM(SourceLocationDescription))
HAVING COUNT_BIG(*) >= 20
ORDER BY COUNT_BIG(*) DESC;
"@

# Top routes: source -> destination pairs by trip volume (for route lines)
Export-Query "map_routes" @"
SELECT TOP 40
    LTRIM(RTRIM(SourceLocationDescription)) AS SourceSite,
    LTRIM(RTRIM(DestinationLocation)) AS DestSite,
    CAST(AVG(LongStart) AS decimal(9,6)) AS SourceLat,
    CAST(AVG(LatStart) AS decimal(9,6)) AS SourceLong,
    CAST(AVG(LongEnd) AS decimal(9,6)) AS DestLat,
    CAST(AVG(LatEnd) AS decimal(9,6)) AS DestLong,
    COUNT_BIG(*) AS TripCount
FROM dw.FactEquipmentTrip
WHERE LatStart IS NOT NULL AND LatStart <> 0
  AND LatEnd IS NOT NULL AND LatEnd <> 0
  AND SourceLocationDescription IS NOT NULL AND LTRIM(RTRIM(SourceLocationDescription)) <> ''
  AND DestinationLocation IS NOT NULL AND LTRIM(RTRIM(DestinationLocation)) <> ''
GROUP BY LTRIM(RTRIM(SourceLocationDescription)), LTRIM(RTRIM(DestinationLocation))
HAVING COUNT_BIG(*) >= 10
ORDER BY COUNT_BIG(*) DESC;
"@

$cn.Close()
Write-Host "Map data export complete: $OutDir"
