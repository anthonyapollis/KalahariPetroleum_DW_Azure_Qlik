<#
.SYNOPSIS
    Builds the complete "Kalahari Petroleum - Fuel & Diesel Refund" Qlik Sense Cloud app
    from the files in this folder: data upload, load script, reload, master measures,
    and the full visual layer (6 sheets, 27 objects).

.DESCRIPTION
    One-shot, idempotent rebuild. Re-running overwrites measures/objects in place
    (same qIds), so it doubles as a "reset the app design" script.

    Prerequisites:
      1. qlik-cli installed (https://github.com/qlik-oss/qlik-cli/releases) and on PATH,
         or pass -QlikExe with the full path to qlik.exe.
      2. An authenticated context:
           qlik context create kalahari --server https://<tenant>.qlikcloud.com --api-key <key>
           qlik context use kalahari
         (API key: tenant -> profile -> Settings -> API keys -> Generate new key.)
      3. An existing (can be empty) app in the tenant; pass its ID as -AppId.
      4. The 12 exported DW .tsv files (see ..\sql\02_export_dw_to_tsv.ps1) if you are
         loading data for the first time (-UploadData).

.EXAMPLE
    .\build_qlik_app.ps1 -AppId 9c13b9e4-e393-4d9a-9f8b-3d62e3a28719
    # measures + objects only (data already loaded)

.EXAMPLE
    .\build_qlik_app.ps1 -AppId <id> -UploadData -DataDir ..\data_export
    # full build: upload TSVs to DataFiles, set + run load script, then measures + objects

.NOTES
    Hard-won gotchas baked into this script (details in QLIK_APP_GUIDE.md):
      - qlik.exe misdetects stdin on Windows: every call is wrapped in cmd /c "... < NUL".
      - DataFiles rejects .tsv extensions: files are uploaded as .txt (content unchanged).
      - Sheets and the objects they reference MUST be posted in ONE object set call,
        or the CLI silently spawns unlinked duplicates. qlik_app_objects.json is that
        single combined payload - never split it.
      - Measures need qUseThou:1 + explicit qDec/qThou or formats render literally.
      - Chart columns need qDef.cId or the client renders blank panels.
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$AppId,

    [string]$QlikExe = "qlik",

    [switch]$UploadData,

    [string]$DataDir = "..\data_export",

    [switch]$VerifyOnly
)

$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

function Invoke-Qlik {
    # NOTE: parameter must not be called $Args - that is a PowerShell automatic
    # variable and silently arrives empty, making qlik print its help text.
    param([string]$CommandLine)
    # cmd /c with < NUL works around qlik.exe's stdin-vs-file misdetection on Windows
    $out = cmd /c "`"$QlikExe`" $CommandLine < NUL" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "qlik $CommandLine failed:`n$out" }
    return $out
}

Write-Host "== Context check =="
Invoke-Qlik "context ls" | Write-Host

if (-not $VerifyOnly) {

    if ($UploadData) {
        Write-Host "== Uploading DW exports to DataFiles (as .txt - DataFiles rejects .tsv) =="
        Get-ChildItem (Join-Path $here $DataDir) -Filter *.tsv | ForEach-Object {
            $target = $_.BaseName + ".txt"
            Write-Host "  $($_.Name) -> lib://DataFiles/$target"
            Invoke-Qlik "data-file create --name $target --file `"$($_.FullName)`""
        }

        Write-Host "== Setting load script and reloading =="
        Invoke-Qlik "app script set `"$(Join-Path $here 'kalahari_petroleum_fuel_load_script.qvs')`" --app $AppId"
        Invoke-Qlik "app reload --app $AppId" | Write-Host
    }

    Write-Host "== Master measures (14) =="
    Invoke-Qlik "app measure set `"$(Join-Path $here 'qlik_master_measures.json')`" --app $AppId"

    Write-Host "== Visual layer: 6 sheets + 27 objects, ONE call (linking gotcha) =="
    Invoke-Qlik "app object set `"$(Join-Path $here 'qlik_app_objects.json')`" --app $AppId"
}

Write-Host "== Verification =="

# 1. Known-good total: Litres Issued must reconcile with the DW validation figure
$kpi = Invoke-Qlik "app object data --app $AppId kpi-litres-issued"
Write-Host "  Litres Issued KPI -> $($kpi | Select-Object -Last 1)"
if (-not ($kpi -match "290,557,288")) {
    Write-Warning "  Expected 290,557,288 (DW-reconciled total). Check the reload."
}

# 2. Sheet linking: cells[].name must still reference the named objects,
#    not short random strings (the silent-duplication failure mode)
foreach ($sheet in @("sheet-1-overview","sheet-2-refund","sheet-3-equipment",
                     "sheet-4-eligibility","sheet-5-tank","sheet-6-dq")) {
    $props = Invoke-Qlik "app object properties --app $AppId $sheet" | Out-String
    $names = ([regex]::Matches($props, '"name":\s*"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
    $orphans = $names | Where-Object { $_ -notmatch '^(kpi|bar|line|combo|scatter|table|filter|note)-' }
    if ($orphans) {
        Write-Warning "  $sheet has unlinked cells: $($orphans -join ', ') - repost qlik_app_objects.json in ONE call"
    } else {
        Write-Host "  $sheet : $($names.Count) cells linked OK"
    }
}

# 3. Render prerequisites: every chart column needs a cId or the client shows a blank panel
$chartIds = @("line-litres-by-month","bar-litres-by-location","combo-refund-by-month",
              "scatter-equip-efficiency","bar-eligible-vs-non","bar-eligibilitystatus-litres",
              "bar-tank-net-by-location","table-refund-claims","table-litres-per-hrkm",
              "table-activity-detail","table-deliveries-by-doc")
foreach ($id in $chartIds) {
    $props = Invoke-Qlik "app object properties --app $AppId $id" | Out-String
    if ($props -notmatch '"cId"') {
        Write-Warning "  $id has no cId on its columns - it will render as a blank panel"
    }
}
Write-Host "  cId render check done ($($chartIds.Count) charts/tables)"

Write-Host ""
Write-Host "Build complete. Open the app and hard-refresh (Ctrl+F5) any tab that was already open."
