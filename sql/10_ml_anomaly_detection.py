"""
Fuel-transaction anomaly detection: flags candidate theft/leakage/meter-fault
events using an Isolation Forest over per-transaction features. Same pattern
as the Karoo Online fraud_signals / fraud_review_queue build.

Outputs:
  data/analysis/ml_anomaly_scores.csv     every scored transaction
  data/analysis/ml_review_queue.csv       top 200 highest-risk transactions
  data/charts/11_ml_anomaly_scatter.png   TankFillRatio vs HourOfDay, anomalies highlighted
  data/charts/12_ml_anomaly_by_equip.png  top equipment by anomaly count

Usage: python 10_ml_anomaly_detection.py
Requires: pandas, scikit-learn, matplotlib
"""
import os
import numpy as np
import pandas as pd
from sklearn.ensemble import IsolationForest
from sklearn.preprocessing import StandardScaler
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ANA = os.path.join(BASE, "data", "analysis")
CHARTS = os.path.join(BASE, "data", "charts")

NAVY, RED, TEAL, GREY = "#002F6C", "#E4002B", "#00A3A1", "#63666A"
plt.rcParams.update({
    "figure.facecolor": "white", "axes.facecolor": "white",
    "axes.edgecolor": GREY, "axes.grid": True, "grid.color": "#E5E7EB",
    "grid.linewidth": 0.6, "axes.axisbelow": True,
    "font.family": "Segoe UI", "font.size": 10,
    "axes.titlesize": 13, "axes.titleweight": "bold", "axes.titlecolor": NAVY,
    "axes.spines.top": False, "axes.spines.right": False,
})

df = pd.read_csv(os.path.join(ANA, "ml_fuel_features.csv"))
df = df.dropna(subset=["TankFillRatio", "HourOfDay", "DayOfWeek", "Litres"]).copy()

# Per-equipment context: how far each transaction sits from that vehicle's own
# normal fill ratio (a fixed threshold penalises naturally-large tanks/trucks
# unfairly; z-score within the vehicle's own history does not).
grp = df.groupby("FleetId")["TankFillRatio"]
df["EquipMeanFillRatio"] = grp.transform("mean")
df["EquipStdFillRatio"] = grp.transform("std").fillna(0.0001).replace(0, 0.0001)
df["FillRatioZScore"] = (df["TankFillRatio"] - df["EquipMeanFillRatio"]) / df["EquipStdFillRatio"]

FEATURES = ["Litres", "TankFillRatio", "FillRatioZScore", "HourOfDay", "DayOfWeek"]
X = StandardScaler().fit_transform(df[FEATURES])

model = IsolationForest(
    n_estimators=300, contamination=0.02, random_state=42, n_jobs=-1
)
df["AnomalyScore"] = -model.fit(X).score_samples(X)   # higher = more anomalous
df["IsAnomaly"] = model.predict(X) == -1

n_anom = int(df["IsAnomaly"].sum())
print(f"Scored {len(df):,} transactions, flagged {n_anom:,} anomalies ({n_anom/len(df):.1%})")

df.sort_values("AnomalyScore", ascending=False).to_csv(
    os.path.join(ANA, "ml_anomaly_scores.csv"), index=False
)

review_cols = ["FuelTransactionKey", "TransactionDateTime", "FleetId", "RegNumber",
                "MakeName", "VehicleTypeName", "LocationDescription", "Litres",
                "TankSize", "TankFillRatio", "FillRatioZScore", "HourOfDay",
                "AnomalyScore", "VoucherNumber", "FuelEventId"]
review = df.sort_values("AnomalyScore", ascending=False).head(200)[review_cols]
review.to_csv(os.path.join(ANA, "ml_review_queue.csv"), index=False)
print(f"Review queue: {len(review)} transactions -> ml_review_queue.csv")

# --- chart 1: TankFillRatio vs HourOfDay scatter, anomalies highlighted ---
fig, ax = plt.subplots(figsize=(9, 5))
normal = df[~df["IsAnomaly"]]
anom = df[df["IsAnomaly"]]
ax.scatter(normal["HourOfDay"], normal["TankFillRatio"], s=6, alpha=0.15, color=NAVY, label="Normal")
ax.scatter(anom["HourOfDay"], anom["TankFillRatio"], s=16, alpha=0.8, color=RED, label="Flagged anomaly")
ax.axhline(1.5, color=GREY, linestyle="--", linewidth=1, label="1.5x tank size (DQ threshold)")
ax.set_xlabel("Hour of day")
ax.set_ylabel("Litres issued / vehicle tank size")
ax.set_title(f"Fuel-transaction anomalies: fill ratio vs time of day ({n_anom:,} flagged)")
ax.legend(frameon=False, loc="upper right")
fig.savefig(os.path.join(CHARTS, "11_ml_anomaly_scatter.png"), dpi=150, bbox_inches="tight")
plt.close(fig)

# --- chart 2: top equipment by anomaly count ---
top_equip = (anom.groupby(["FleetId", "MakeName"]).size()
             .reset_index(name="AnomalyCount")
             .sort_values("AnomalyCount", ascending=False).head(15).iloc[::-1])
top_equip["label"] = top_equip["FleetId"].astype(str) + "  (" + top_equip["MakeName"].fillna("?") + ")"
fig, ax = plt.subplots(figsize=(8.5, 5.5))
ax.barh(top_equip["label"], top_equip["AnomalyCount"], color=RED, alpha=0.85)
ax.set_title("Top 15 equipment by flagged fuel-anomaly count")
fig.savefig(os.path.join(CHARTS, "12_ml_anomaly_by_equip.png"), dpi=150, bbox_inches="tight")
plt.close(fig)

print("ML anomaly detection complete.")
