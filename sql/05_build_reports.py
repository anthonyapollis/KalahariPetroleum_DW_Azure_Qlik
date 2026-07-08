"""
Build the publication layer from data/analysis/*.csv:
  - data/charts/*.png          (matplotlib, report-styled)
  - reports/Kalahari_Petroleum_Fuel_Data_Story.xlsx  (all aggregates + native charts)

Usage: python 05_build_reports.py
Requires: pandas, matplotlib, xlsxwriter
"""
import os
import pandas as pd
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import matplotlib.ticker as mtick

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ANA = os.path.join(BASE, "data", "analysis")
CHARTS = os.path.join(BASE, "data", "charts")
REPORTS = os.path.join(BASE, "reports")
os.makedirs(CHARTS, exist_ok=True)
os.makedirs(REPORTS, exist_ok=True)

NAVY, BLUE, RED, GOLD, TEAL, GREY = "#002F6C", "#0072CE", "#E4002B", "#FFB81C", "#00A3A1", "#63666A"

plt.rcParams.update({
    "figure.facecolor": "white", "axes.facecolor": "white",
    "axes.edgecolor": GREY, "axes.grid": True, "grid.color": "#E5E7EB",
    "grid.linewidth": 0.6, "axes.axisbelow": True,
    "font.family": "Segoe UI", "font.size": 10,
    "axes.titlesize": 13, "axes.titleweight": "bold", "axes.titlecolor": NAVY,
    "axes.spines.top": False, "axes.spines.right": False,
})

def read(name):
    return pd.read_csv(os.path.join(ANA, f"{name}.csv"))

def save(fig, name):
    p = os.path.join(CHARTS, f"{name}.png")
    fig.savefig(p, dpi=150, bbox_inches="tight")
    plt.close(fig)
    print(f"chart: {name}.png")

def millions(x, _):
    return f"{x/1e6:.0f}M"

# ---------------------------------------------------------------- 1. refund
rf = read("refund_by_month")
rf = rf[rf.ClaimYearMonth >= "2019-01"]
fig, ax = plt.subplots(figsize=(11, 4.5))
x = range(len(rf))
ax.bar(x, rf.EligibleLitres, color=TEAL, label="Eligible litres")
ax.bar(x, rf.NonEligibleLitres, bottom=rf.EligibleLitres, color=GREY, label="Non-eligible litres")
ax.set_xticks(list(x))
ax.set_xticklabels(rf.ClaimYearMonth, rotation=90, fontsize=7.5)
ax.yaxis.set_major_formatter(mtick.FuncFormatter(millions))
ax.set_title("SARS diesel refund: eligible vs non-eligible litres by claim month")
ax2 = ax.twinx()
ax2.plot(list(x), rf.RefundAmountRand / 1e6, color=RED, lw=2.2, marker="o", ms=3.5, label="Refund (R m)")
ax2.set_ylabel("Refund (R million)", color=RED)
ax2.tick_params(axis="y", colors=RED)
ax2.grid(False); ax2.spines.top.set_visible(False)
h1, l1 = ax.get_legend_handles_labels(); h2, l2 = ax2.get_legend_handles_labels()
ax.legend(h1 + h2, l1 + l2, loc="upper left", frameon=False)
save(fig, "01_refund_by_month")

# ---------------------------------------------------------------- 2. yearly
yf = read("yearly_fuel")
fig, ax = plt.subplots(figsize=(8, 4))
ax.bar(yf.Year.astype(str), yf.LitresIssued, color=NAVY)
ax.yaxis.set_major_formatter(mtick.FuncFormatter(millions))
ax.set_title("Fuel issued per year (litres)")
for i, v in enumerate(yf.LitresIssued):
    ax.text(i, v, f"{v/1e6:.1f}M", ha="center", va="bottom", fontsize=9, color=NAVY)
save(fig, "02_yearly_fuel")

# ---------------------------------------------------------------- 3. monthly trend
mf = read("monthly_fuel")
trend = mf.groupby("YearMonth", as_index=False).LitresIssued.sum()
trend = trend[trend.YearMonth >= "2019-01"]
fig, ax = plt.subplots(figsize=(11, 4))
ax.plot(trend.YearMonth, trend.LitresIssued, color=BLUE, lw=2)
ax.fill_between(trend.YearMonth, trend.LitresIssued, color=BLUE, alpha=0.12)
ax.set_xticks(trend.YearMonth[::3])
ax.tick_params(axis="x", rotation=90, labelsize=7.5)
ax.yaxis.set_major_formatter(mtick.FuncFormatter(millions))
ax.set_title("Monthly fuel issued (litres, 2019 onward)")
save(fig, "03_monthly_fuel_trend")

# ---------------------------------------------------------------- 4. locations
loc = read("fuel_by_location").head(12).iloc[::-1]
fig, ax = plt.subplots(figsize=(8, 5))
ax.barh(loc.LocationDescription, loc.LitresIssued, color=TEAL)
ax.xaxis.set_major_formatter(mtick.FuncFormatter(millions))
ax.set_title("Fuel issued by depot / location (top 12)")
save(fig, "04_fuel_by_location")

# ---------------------------------------------------------------- 5. equipment
te = read("top_equipment").head(15).iloc[::-1]
te["label"] = te.FleetId.fillna(te.RegNumber).astype(str) + "  (" + te.MakeName.fillna("?") + ")"
fig, ax = plt.subplots(figsize=(8.5, 5.5))
colors = [RED if c == "Ineligible" else NAVY for c in te.EligibilityClass]
ax.barh(te.label, te.TotalLitres, color=colors)
ax.xaxis.set_major_formatter(mtick.FuncFormatter(millions))
ax.set_title("Top 15 fuel-consuming equipment (red = SARS-ineligible class)")
save(fig, "05_top_equipment")

# ---------------------------------------------------------------- 6. vehicle types
vt = read("vehicle_type_fuel").head(12).iloc[::-1]
fig, ax = plt.subplots(figsize=(8, 5))
ax.barh(vt.VehicleTypeName, vt.LitresIssued, color=BLUE)
ax.xaxis.set_major_formatter(mtick.FuncFormatter(millions))
ax.set_title("Fuel issued by vehicle type (top 12)")
save(fig, "06_vehicle_type_fuel")

# ---------------------------------------------------------------- 7. material movement
mm = read("material_movement").head(10).iloc[::-1]
fig, ax = plt.subplots(figsize=(8, 4.5))
ax.barh(mm.MaterialType, mm.Trips, color=GOLD, edgecolor=NAVY, linewidth=0.4)
ax.xaxis.set_major_formatter(mtick.FuncFormatter(lambda x, _: f"{x/1e3:.0f}k"))
ax.set_title("Haulage: trips by material type (778k trips)")
save(fig, "07_material_movement")

# ---------------------------------------------------------------- 8. trips trend
tm = read("trips_by_month")
fig, ax = plt.subplots(figsize=(11, 4))
ax.bar(tm.YearMonth, tm.Trips, color=NAVY)
ax.tick_params(axis="x", rotation=90, labelsize=7.5)
ax.yaxis.set_major_formatter(mtick.FuncFormatter(lambda x, _: f"{x/1e3:.0f}k"))
ax.set_title("Equipment trips per month")
save(fig, "08_trips_by_month")

# ---------------------------------------------------------------- 9. seasonality
sf = read("seasonal_fuel")
piv = sf.pivot_table(index="Year", columns="SeasonSouthernAfrica", values="LitresIssued", aggfunc="sum")
piv = piv[["Summer", "Autumn", "Winter", "Spring"]]
fig, ax = plt.subplots(figsize=(9, 4.2))
piv.plot(kind="bar", ax=ax, color=[GOLD, "#C77B30", BLUE, TEAL], width=0.8)
ax.yaxis.set_major_formatter(mtick.FuncFormatter(millions))
ax.set_title("Seasonal fuel demand (Southern-hemisphere seasons)")
ax.legend(frameon=False, ncol=4)
ax.tick_params(axis="x", rotation=0)
save(fig, "09_seasonal_fuel")

# ---------------------------------------------------------------- 10. data quality
dq = read("data_quality")
dq = dq[dq.row_count > 0].sort_values("row_count").tail(8)
fig, ax = plt.subplots(figsize=(8.5, 4.2))
ax.barh(dq.issue, dq.row_count, color=RED, alpha=0.85)
ax.set_xscale("log")
ax.set_title("Data-quality findings (log scale)")
for i, (n, v) in enumerate(zip(dq.issue, dq.row_count)):
    ax.text(v, i, f" {v:,}", va="center", fontsize=9, color=NAVY)
save(fig, "10_data_quality")

# ================================================================ Excel
xlsx = os.path.join(REPORTS, "Kalahari_Petroleum_Fuel_Data_Story.xlsx")
sheets = [
    ("Refund Claims", "refund_by_month"),
    ("Yearly Fuel", "yearly_fuel"),
    ("Monthly Fuel", "monthly_fuel"),
    ("Fuel by Location", "fuel_by_location"),
    ("Top Equipment", "top_equipment"),
    ("Vehicle Types", "vehicle_type_fuel"),
    ("Material Movement", "material_movement"),
    ("Trips by Month", "trips_by_month"),
    ("Seasonal Fuel", "seasonal_fuel"),
    ("Tank Reconciliation", "tank_reconciliation"),
    ("Data Quality", "data_quality"),
    ("DQ Over-Tank Issues", "dq_over_tank"),
    ("ML Anomaly Review Queue", "ml_review_queue"),
    ("Haulage Sites (Map)", "map_sites"),
]
with pd.ExcelWriter(xlsx, engine="xlsxwriter") as xw:
    wb = xw.book
    hdr = wb.add_format({"bold": True, "font_color": "white", "bg_color": NAVY, "border": 1})
    title_fmt = wb.add_format({"bold": True, "font_size": 18, "font_color": NAVY})
    sub_fmt = wb.add_format({"font_color": GREY})
    kpi_fmt = wb.add_format({"bold": True, "font_size": 14, "font_color": TEAL})
    num_fmt = wb.add_format({"num_format": "#,##0"})

    # ReadMe sheet
    ws = wb.add_worksheet("ReadMe")
    ws.hide_gridlines(2)
    ws.set_column("B:B", 60)
    ws.write("B2", "Kalahari Petroleum — Fuel & Diesel Refund Data Story", title_fmt)
    ws.write("B3", "SQL Server star schema → Azure Data Factory → Qlik Sense | built 2026-07 | fictional company, real (anonymised) fleet-fuel data", sub_fmt)
    kpis = [
        ("Fuel issued (2009–2022)", "290.6 million litres, 325,504 AFS transactions"),
        ("Haulage", "778,254 equipment trips"),
        ("Usage classified for SARS", "231.7M litres; 92.3M non-eligible"),
        ("Diesel refund modelled", "44 claim months (Rebate Item 670.04, 80% qualifying rule)"),
        ("ML anomaly detection", "Isolation Forest, 325,504 transactions scored, 6,511 flagged (2.0%)"),
        ("Rows through the pipeline", "~23.7 million (incl. 21.9M-row CoordRef geo grid)"),
    ]
    r = 5
    for k, v in kpis:
        ws.write(r, 1, k, kpi_fmt); ws.write(r + 1, 1, v); r += 3
    ws.write(r, 1, "Rates are 2020 SARS policy examples from the evidence pack — not tax advice.", sub_fmt)

    for sheet, csv in sheets:
        df = read(csv)
        df.to_excel(xw, sheet_name=sheet, index=False, startrow=1, header=False)
        ws = xw.sheets[sheet]
        for c, col in enumerate(df.columns):
            ws.write(0, c, col, hdr)
            width = max(12, min(38, int(df[col].astype(str).str.len().quantile(0.9)) + 2))
            ws.set_column(c, c, width, num_fmt if pd.api.types.is_numeric_dtype(df[col]) else None)
        ws.freeze_panes(1, 0)
        ws.autofilter(0, 0, len(df), len(df.columns) - 1)

    # native charts on key sheets
    def add_chart(sheet, ctype, cat_col, val_cols, colors, title, pos="H2", rows=None):
        df = read(dict(sheets)[sheet])
        n = rows or len(df)
        ch = wb.add_chart({"type": ctype})
        for vc, colr in zip(val_cols, colors):
            ch.add_series({
                "name": vc,
                "categories": [sheet, 1, df.columns.get_loc(cat_col), n, df.columns.get_loc(cat_col)],
                "values": [sheet, 1, df.columns.get_loc(vc), n, df.columns.get_loc(vc)],
                "fill": {"color": colr},
            })
        ch.set_title({"name": title, "name_font": {"size": 12, "color": NAVY}})
        ch.set_legend({"position": "bottom"})
        ch.set_size({"width": 640, "height": 360})
        xw.sheets[sheet].insert_chart(pos, ch)

    add_chart("Refund Claims", "column", "ClaimYearMonth", ["EligibleLitres", "NonEligibleLitres"],
              [TEAL, GREY], "Eligible vs non-eligible litres", pos="K2")
    add_chart("Yearly Fuel", "column", "Year", ["LitresIssued"], [NAVY], "Fuel issued per year", pos="F2")
    add_chart("Fuel by Location", "bar", "LocationDescription", ["LitresIssued"], [TEAL],
              "Fuel by location", pos="F2", rows=12)
    add_chart("Material Movement", "bar", "MaterialType", ["Trips"], [GOLD], "Trips by material", pos="F2")

print(f"excel: {xlsx}")
print("Publication data layer complete.")
