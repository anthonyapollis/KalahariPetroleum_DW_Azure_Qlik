"""
Build the self-contained data-story ebook (index.html at project root).
Charts are embedded as base64 so the single file works offline / on GitHub Pages.

Usage: python 06_build_ebook.py
"""
import base64
import os
import pandas as pd

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHARTS = os.path.join(BASE, "data", "charts")
ANA = os.path.join(BASE, "data", "analysis")
MAPDIR = os.path.join(BASE, "map")
OUT = os.path.join(BASE, "index.html")
REPO = "https://github.com/anthonyapollis/KalahariPetroleum_DW_Azure_Qlik"
COMPANY = "Kalahari Petroleum"

with open(os.path.join(MAPDIR, "map_section.html"), encoding="utf-8") as f:
    MAP_SECTION = f.read()

def img(name):
    with open(os.path.join(CHARTS, name), "rb") as f:
        b64 = base64.b64encode(f.read()).decode()
    return f'<img src="data:image/png;base64,{b64}" alt="{name}">'

def fmt(n, dec=0):
    return f"{n:,.{dec}f}".replace(",", " ")

rf = pd.read_csv(os.path.join(ANA, "refund_by_month.csv"))
claimed = rf[rf.RateMissingFlag.astype(str).str.lower().isin(["false", "0"])]
total_refund = claimed.RefundAmountRand.sum()
total_eligible = rf.EligibleLitres.sum()
total_usage = rf.TotalLitres.sum()
dq = pd.read_csv(os.path.join(ANA, "data_quality.csv"))
ml = pd.read_csv(os.path.join(ANA, "ml_review_queue.csv"))
ml_scores = pd.read_csv(os.path.join(ANA, "ml_anomaly_scores.csv"))
ml_n_flagged = int(ml_scores["IsAnomaly"].sum())
ml_pct_flagged = ml_n_flagged / len(ml_scores)
ml_anom = ml_scores[ml_scores["IsAnomaly"]]
ml_extreme = ml_anom[ml_anom.TankFillRatio > 50]
ml_moderate = ml_anom[(ml_anom.TankFillRatio >= 1.5) & (ml_anom.TankFillRatio <= 50)]
ml_behavioural = ml_anom[ml_anom.TankFillRatio < 1.5]
ml_offhours_flagged_pct = ((ml_anom.HourOfDay >= 22) | (ml_anom.HourOfDay <= 5)).mean()
ml_offhours_baseline_pct = ((ml_scores.HourOfDay >= 22) | (ml_scores.HourOfDay <= 5)).mean()
ml_top_location = ml_anom.groupby("LocationDescription").size().sort_values(ascending=False)
ml_top_loc_name = ml_top_location.index[0]
ml_top_loc_count = int(ml_top_location.iloc[0])
ml_top_loc_pct = ml_top_loc_count / len(ml_anom)
ml_top_equip = ml_anom.groupby("FleetId").size().sort_values(ascending=False).head(5)
ml_top_equip_rows = "".join(f"<li><code>{i}</code> — {c} flagged transactions</li>" for i, c in ml_top_equip.items())

refund_rows = "".join(
    f"<tr><td>{r.ClaimYearMonth}</td><td class='num'>{fmt(r.TotalLitres)}</td>"
    f"<td class='num'>{fmt(r.NonEligibleLitres)}</td><td class='num'>{fmt(r.EligibleLitres)}</td>"
    f"<td class='num'>{fmt(r.QualifyingClaimLitres)}</td>"
    f"<td class='num'>{'' if pd.isna(r.RefundAmountRand) else 'R ' + fmt(r.RefundAmountRand, 2)}</td></tr>"
    for r in rf.tail(12).itertuples()
)
dq_rows = "".join(
    f"<tr><td>{r.issue}</td><td class='num'>{fmt(r.row_count)}</td></tr>"
    for r in dq.itertuples() if r.row_count > 0
)
ml_rows = "".join(
    f"<tr><td>{r.TransactionDateTime}</td><td>{r.FleetId}</td><td>{r.MakeName}</td>"
    f"<td class='num'>{fmt(r.Litres, 1)}</td><td class='num'>{fmt(r.TankSize, 0)}</td>"
    f"<td class='num'>{fmt(r.TankFillRatio, 1)}x</td><td class='num'>{fmt(r.AnomalyScore, 3)}</td></tr>"
    for r in ml.head(10).itertuples()
)

html = f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{COMPANY} — A Diesel &amp; Refund Data Story</title>
<style>
:root {{ --navy:#002F6C; --blue:#0072CE; --red:#E4002B; --gold:#FFB81C; --teal:#00A3A1; --grey:#63666A; }}
* {{ box-sizing:border-box; margin:0; padding:0; }}
body {{ font-family:'Segoe UI',system-ui,sans-serif; color:#1a202c; line-height:1.65; background:#f7f8fa; }}
.hero {{ background:linear-gradient(135deg,var(--navy) 0%,#014f86 70%,var(--teal) 100%); color:#fff; padding:64px 24px 56px; text-align:center; }}
.hero h1 {{ font-size:2.3rem; margin-bottom:10px; }}
.hero p {{ opacity:.9; max-width:760px; margin:0 auto; }}
.wrap {{ max-width:1000px; margin:0 auto; padding:24px; }}
.kpis {{ display:grid; grid-template-columns:repeat(auto-fit,minmax(180px,1fr)); gap:14px; margin:-38px auto 30px; max-width:1000px; padding:0 24px; position:relative; z-index:2; }}
.kpi {{ background:#fff; border-radius:10px; padding:18px; box-shadow:0 4px 14px rgba(0,0,0,.08); text-align:center; }}
.kpi .v {{ font-size:1.45rem; font-weight:700; color:var(--navy); }}
.kpi .l {{ font-size:.8rem; color:var(--grey); }}
section {{ background:#fff; border-radius:12px; padding:32px; margin-bottom:26px; box-shadow:0 2px 8px rgba(0,0,0,.05); }}
h2 {{ color:var(--navy); font-size:1.5rem; margin-bottom:12px; border-left:5px solid var(--gold); padding-left:12px; }}
h3 {{ color:var(--blue); margin:18px 0 8px; }}
p {{ margin-bottom:12px; }}
img {{ width:100%; height:auto; border:1px solid #e5e7eb; border-radius:8px; margin:10px 0 18px; }}
table {{ width:100%; border-collapse:collapse; font-size:.86rem; margin:12px 0; }}
th {{ background:var(--navy); color:#fff; padding:8px 10px; text-align:left; }}
td {{ padding:7px 10px; border-bottom:1px solid #e5e7eb; }}
td.num {{ text-align:right; font-variant-numeric:tabular-nums; }}
tr:nth-child(even) {{ background:#f4f6f9; }}
.note {{ background:#FFF7E6; border-left:4px solid var(--gold); padding:12px 16px; border-radius:6px; font-size:.9rem; margin:14px 0; }}
.case-study-note {{ background:var(--gold); color:var(--navy); border:2px solid #B8860B; border-left:6px solid var(--navy); padding:16px 20px; border-radius:8px; font-size:.92rem; box-shadow:0 4px 14px rgba(0,0,0,.25); }}
.case-study-note strong {{ color:var(--navy); }}
.flow {{ background:#0b1526; color:#9fd3ff; font-family:Consolas,monospace; font-size:.82rem; padding:18px; border-radius:8px; overflow-x:auto; white-space:pre; margin:12px 0; }}
footer {{ text-align:center; color:var(--grey); font-size:.82rem; padding:26px; }}
.topnav {{ position:sticky; top:0; z-index:100; background:var(--navy); display:flex; flex-wrap:wrap;
  align-items:center; gap:2px; padding:0 16px; box-shadow:0 2px 10px rgba(0,0,0,.15); }}
.topnav .home {{ color:var(--gold); font-weight:700; letter-spacing:1.5px; font-size:13px; padding:14px 12px 14px 0; text-transform:uppercase; }}
.topnav a {{ color:#cfe0f5; text-decoration:none; font-size:12px; padding:14px 10px; border-bottom:2px solid transparent; transition:.15s; white-space:nowrap; }}
.topnav a:hover {{ color:#fff; border-bottom-color:var(--gold); }}
.topnav .ext {{ margin-left:auto; display:flex; gap:6px; padding:8px 0; }}
.topnav .ext a {{ background:var(--teal); color:#fff; border-radius:6px; padding:7px 13px; font-weight:600; border-bottom:none; }}
.topnav .ext a:hover {{ background:#00807e; color:#fff; }}
.topnav .ext a.pdf {{ background:var(--red); }}
.topnav .ext a.pdf:hover {{ background:#b5001f; }}
html {{ scroll-behavior:smooth; }}
section {{ scroll-margin-top:60px; }}
@media print {{ .topnav {{ display:none; }} }}
</style>
</head>
<body>

<div class="topnav">
  <span class="home">{COMPANY}</span>
  <a href="#story">Story</a>
  <a href="#fuel">Fuel</a>
  <a href="#fleet">Fleet &amp; haulage</a>
  <a href="#map">Map</a>
  <a href="#refund">SARS refund</a>
  <a href="#dq">Data quality</a>
  <a href="#ml">ML anomalies</a>
  <a href="#build">How it's built</a>
  <a href="qlik/QLIK_APP_GUIDE.md">Qlik guide</a>
  <a href="azure/AZURE_ARCHITECTURE.md">Azure architecture</a>
  <div class="ext">
    <a href="{REPO}" target="_blank" rel="noopener">GitHub repo</a>
    <a href="reports/Kalahari_Petroleum_Fuel_Data_Story.xlsx" download>Excel</a>
    <a class="pdf" href="reports/Kalahari_Petroleum_Fuel_Data_Story.pdf" download>PDF report</a>
  </div>
</div>

<div class="hero">
  <h1>Fuelling an Oil &amp; Gas Giant</h1>
  <p>A diesel, haulage and SARS (South African Revenue Service) refund data story — 23.7 million rows from
     {COMPANY}'s upstream fleet-operations ERP (Enterprise Resource Planning system), modelled as a SQL Server
     star schema, shipped through Azure Data Factory, and served to Qlik Sense.</p>
  <p style="margin-top:14px;font-size:.85rem;"><a href="{REPO}" target="_blank" rel="noopener" style="color:#FFB81C;">View source on GitHub →</a></p>
  <div class="case-study-note" style="max-width:900px; margin:20px auto 0; text-align:left;">
    <strong>Case-study note:</strong> {COMPANY} is a fictional company invented for this portfolio piece. The
    underlying operational data is real (anonymised) mining/haulage fleet-fuel ERP data, presented here under a
    fictional oil &amp; gas identity to demonstrate the data model and analytics pipeline without naming the
    source organisation.
  </div>
</div>

<div class="kpis">
  <div class="kpi"><div class="v">290.6M L</div><div class="l">fuel issued 2009–2022</div></div>
  <div class="kpi" title="Automated Fuel System"><div class="v">325 504</div><div class="l">AFS fuel transactions</div></div>
  <div class="kpi"><div class="v">778 254</div><div class="l">equipment trips</div></div>
  <div class="kpi"><div class="v">R {fmt(total_refund/1e6,1)}m</div><div class="l">modelled diesel refunds</div></div>
  <div class="kpi"><div class="v">23.7M</div><div class="l">rows through the pipeline</div></div>
</div>

<div class="wrap">

<section id="story">
  <h2>1 · More than fuel records</h2>
  <p>The source system is an operational ERP for {COMPANY}'s upstream fleet: an Automated Fuel System (AFS)
     issuing diesel to haul trucks and drill rigs, tank deliveries, odometer and hour-meter readings, haulage
     trips with material types, GPS trip traces over a 21.9-million-point coordinate grid, geofences, SAP
     integration staging and cost-centre accounting. Fuel is the connective tissue — every litre issued ties
     equipment, location, activity and money together. {COMPANY}'s fleet-management system classifies vehicles
     the way a mine would — drill rigs, haul trucks, waste removal — because well-pad construction and haulage
     logistics on an oil &amp; gas site mirror mining operations almost exactly.</p>
  <p>This project models that data as a Kimball star schema (8 dimensions, 8 facts) with one high-stakes
     business calculation at its centre: the <strong>SARS diesel refund</strong> under Rebate Item 670.04 of
     the Customs &amp; Excise Act, where classifying litres as eligible or non-eligible is worth millions of
     rand per month.</p>
</section>

<section id="fuel">
  <h2>2 · The fuel story</h2>
  {img('02_yearly_fuel.png')}
  <p>Fuel issue volumes step up sharply from 2019 as the AFS rollout reaches full coverage, settling around
     70–80 million litres a year across the operation.</p>
  {img('03_monthly_fuel_trend.png')}
  {img('04_fuel_by_location.png')}
  {img('09_seasonal_fuel.png')}
  <p>Demand is not smooth: maintenance shutdowns, production cycles and season shape the curve — one reason a
     refund forecast needs more than a flat average.</p>
</section>

<section id="fleet">
  <h2>3 · Fleet &amp; haulage</h2>
  {img('05_top_equipment.png')}
  {img('06_vehicle_type_fuel.png')}
  {img('07_material_movement.png')}
  <p>Trip records carry the material being moved — extracted product, waste, consumables — which is exactly the
     evidence SARS eligibility classification leans on: transport of extracted material on the production site
     is claimable, general road use is not.</p>
  {img('08_trips_by_month.png')}
</section>

<section id="map">
  <h2>4 · Haulage &amp; site activity map</h2>
  <p>Real GPS trip data plotted against a label-free basemap — three toggleable layers built for
     three different audiences: <strong>dispatch</strong> (where the traffic actually is),
     <strong>production</strong> (what's moving out of each site), and <strong>compliance</strong>
     (which activity supports a SARS eligible-activity claim). The top 40 haul routes overlay
     shows road-maintenance priority by traffic volume.</p>
  {MAP_SECTION}
</section>

<section id="refund">
  <h2>5 · The SARS diesel refund</h2>
  <p>For on-land primary producers (mining included), the refund formula from the policy evidence is:</p>
  <div class="flow">eligible_litres    = total_litres − non_eligible_litres
qualifying_litres  = eligible_litres × 80%
refund_rand        = qualifying_litres × refund_rate (c/L) ÷ 100</div>
  {img('01_refund_by_month.png')}
  <h3>Last 12 claim months</h3>
  <table>
    <tr><th>Claim month</th><th>Total L</th><th>Non-eligible L</th><th>Eligible L</th><th>Qualifying L</th><th>Refund</th></tr>
    {refund_rows}
  </table>
  <div class="note"><strong>Caution:</strong> rates are the 2020 SARS policy examples found in the project's
  evidence pack (349 c/L on-land after 1 Apr 2020). They are implementation evidence, not tax advice — update
  <code>dw.DimRefundRate</code> with current rates before relying on any figure.</div>
</section>

<section id="dq">
  <h2>6 · Data quality — where the money leaks</h2>
  {img('10_data_quality.png')}
  <table>
    <tr><th>Finding</th><th>Rows</th></tr>
    {dq_rows}
  </table>
  <p>The stand-outs: over 200&nbsp;000 usage-logbook rows carry registration numbers that don't match the
     equipment master (an audit-trail gap for refund claims), and ~14&nbsp;700 single fuel issues exceed 1.5×
     the receiving vehicle's tank size — classic candidates for meter faults or leakage/theft review. One
     equipment-master row even had a tab character embedded in its registration number, found because it was
     the only row in 23.7 million that broke a rectangular file export.</p>
</section>

<section id="ml">
  <h2>7 · Machine learning: fuel-anomaly detection</h2>
  <p>An <strong>Isolation Forest</strong> (a scikit-learn algorithm that isolates unusual data points by how
     few random splits it takes to separate them from the rest — the fewer splits, the more anomalous;
     300 trees, 2% contamination setting) scores every fuel transaction on five features: litres issued,
     tank-fill ratio (litres ÷ that vehicle's tank size), that vehicle's own fill-ratio z-score (how far this
     fill is from <em>that specific vehicle's</em> normal pattern, so a naturally large tanker isn't penalised
     for being large), hour of day, and day of week. This catches what a fixed 1.5×-tank-size rule misses —
     a fill that's unremarkable in isolation but anomalous in combination (e.g. an odd hour <em>plus</em> a
     fill well above that vehicle's own history).</p>
  {img('11_ml_anomaly_scatter.png')}
  <p>{fmt(ml_n_flagged)} of {fmt(len(ml_scores))} transactions flagged ({ml_pct_flagged:.1%}). They split into
     three distinct categories with three different explanations and three different actions:</p>
  <table>
    <tr><th>Category</th><th>Count</th><th>Litres involved</th><th>What it looks like</th><th>Most likely cause</th></tr>
    <tr><td><strong>Extreme</strong> (fill ratio &gt; 50×)</td><td class='num'>{fmt(len(ml_extreme))}</td>
        <td class='num'>{fmt(ml_extreme.Litres.sum()/1e6, 2)}M L</td>
        <td>Single transactions of 100,000+ litres against 100–600&nbsp;L tanks — physically impossible</td>
        <td>Decimal-point data-entry error at the pump terminal (e.g. 159,015.1 L almost certainly means 15.9 L)</td></tr>
    <tr><td><strong>Moderate</strong> (fill ratio 1.5×–50×)</td><td class='num'>{fmt(len(ml_moderate))}</td>
        <td class='num'>{fmt(ml_moderate.Litres.sum()/1e6, 1)}M L</td>
        <td>A real, plausible fill — just larger than that vehicle normally takes</td>
        <td>Genuine theft/leakage candidates, meter faults, or a vehicle swap not reflected in the equipment master</td></tr>
    <tr><td><strong>Behavioural</strong> (fill ratio normal)</td><td class='num'>{fmt(len(ml_behavioural))}</td>
        <td class='num'>—</td>
        <td>Fill size is unremarkable, but timing/pattern is off for that vehicle</td>
        <td>Off-hours or off-schedule fuelling worth a second look, not necessarily theft</td></tr>
  </table>
  <p>Timing is a real signal here, not noise: flagged transactions happen overnight
     (22:00&ndash;05:00) {ml_offhours_flagged_pct:.0%} of the time, against a {ml_offhours_baseline_pct:.0%}
     overnight share for all transactions — a meaningfully higher overnight rate among the flagged group.</p>
  {img('12_ml_anomaly_by_equip.png')}
  <div class="note" style="background:#FDECEA;border-left-color:#E4002B;">
  <strong>Business insight — this isn't spread evenly across the fleet.</strong>
  <strong>{ml_top_loc_name}</strong> alone accounts for {fmt(ml_top_loc_count)} of the
  {fmt(len(ml_anom))} flagged transactions ({ml_top_loc_pct:.0%} of all anomalies) — one depot, not the
  whole operation. That concentration is the single most actionable finding in this section: it points at a
  site-specific cause (pump/terminal hardware, local process, or a specific shift) rather than a
  fleet-wide problem.</div>
  <h3>Top 5 equipment to investigate first</h3>
  <ul>{ml_top_equip_rows}</ul>
  <h3>Top 10 highest-risk transactions</h3>
  <table>
    <tr><th>Date/time</th><th>Fleet ID</th><th>Make</th><th>Litres</th><th>Tank (L)</th><th>Fill ratio</th><th>Anomaly score</th></tr>
    {ml_rows}
  </table>
  <div class="note">
    <strong>Recommendations</strong>
    <ol style="margin:8px 0 0 18px; padding:0;">
      <li><strong>Prevent, don't just detect:</strong> add input validation at the Automated Fuel System (AFS)
          terminal that rejects or holds any single transaction exceeding ~2× the vehicle's registered tank
          size. This alone would have caught all {fmt(len(ml_extreme))} extreme cases before they ever reached
          the ledger.</li>
      <li><strong>Priority audit:</strong> investigate {ml_top_loc_name}'s pump/terminal hardware and shift
          logs first — it explains over half of the flagged volume on its own.</li>
      <li><strong>Wire this into the refund workflow:</strong> run the anomaly score against
          <code>dw.FactFuelUsageClassification</code> before each monthly SARS claim, so flagged litres are
          excluded or held for review rather than claimed on potentially bad data.</li>
      <li><strong>Quantify exposure before acting:</strong> the {fmt(len(ml_moderate))} moderate-tier
          transactions ({fmt(ml_moderate.Litres.sum()/1e6, 1)}M litres) are the ones worth a real
          investigation — most are probably legitimate, but at scale even a small leakage/theft rate here is
          a material rand figure.</li>
    </ol>
  </div>
  <p style="font-size:.85rem;color:#63666A;">Full 200-row review queue: <code>data/analysis/ml_review_queue.csv</code>
     and the "ML Anomaly Review Queue" sheet in the Excel workbook. Model: <code>sql/10_ml_anomaly_detection.py</code>.</p>
</section>

<section id="build">
  <h2>9 · How it's built</h2>
  <div class="flow">SQL Server (source ERP, QA copy)             ── local, always works offline
  └─ dw star schema  · 8 dims, 8 facts, 5 views   (01_create_load_dw_full.sql)
       └─ TSV export (bcp, UTF-8)                 (02_export_dw_to_tsv.ps1)
            ├─ curated_local/ Parquet             (03_build_local_parquet.py)
            └─ azcopy → ADLS (Azure Data Lake Storage) Gen2 raw/  ── Azure mirror
                 └─ Data Factory pl_raw_to_curated (ForEach Copy, TSV → snappy Parquet)
                      └─ curated/dw/&lt;Table&gt;/*.parquet
                           └─ Qlik Sense Cloud (SAS web-files or Azure Storage connector)</div>
  <p>The warehouse reconciles exactly: 290 557 288.29 litres issued in both source and fact table, to the
     hundredth of a litre. Everything regenerates from five scripts, and the Azure resource group tears down
     with one command when it has served its purpose.</p>
  <p>Full source, the SQL build script, both Qlik load scripts (cloud + local), and the Azure Data Factory
     definitions are in the repository: <a href="{REPO}" target="_blank" rel="noopener">{REPO}</a>. See
     <a href="qlik/QLIK_APP_GUIDE.md">qlik/QLIK_APP_GUIDE.md</a> for the six-sheet Qlik Sense app design, and
     <a href="azure/AZURE_ARCHITECTURE.md">azure/AZURE_ARCHITECTURE.md</a> for the deployed-resource inventory
     and kill switch.</p>
</section>

</div>
<footer>
  Anthony Apollis · 2026 · Built with SQL Server, Azure Data Factory, ADLS Gen2, Python &amp; Qlik Sense.<br>
  QA data, anonymised context, presented under a fictional company; SARS figures are modelled examples, not tax advice.<br>
  <a href="{REPO}" target="_blank" rel="noopener" style="color:var(--teal);">{REPO.replace('https://', '')}</a>
</footer>
</body>
</html>
"""

with open(OUT, "w", encoding="utf-8") as f:
    f.write(html)
print(f"ebook: {OUT} ({os.path.getsize(OUT)/1024/1024:.1f} MB)")
