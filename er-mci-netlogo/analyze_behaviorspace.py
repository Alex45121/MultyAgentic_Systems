"""Turn the BehaviorSpace 'table' output of breaking-point-sweep into breaking points + figures.

In NetLogo: Tools > BehaviorSpace > breaking-point-sweep > Run, tick "Table output",
save e.g. as results/sweep-table.csv, then:

    pip install pandas matplotlib
    python analyze_behaviorspace.py results/sweep-table.csv --threshold 0.25
"""
import argparse
import json
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np
import pandas as pd

LABEL = {False: "Single-nurse triage", True: "Co-triage (2 nurses)"}
COLOUR = {False: "#c0392b", True: "#2471a3"}


def load(path):
    df = pd.read_csv(path, skiprows=6)          # BehaviorSpace table output has 6 header lines
    df.columns = [c.strip() for c in df.columns]
    df["co-triage?"] = df["co-triage?"].astype(str).str.lower().eq("true")
    return df


def breaking_point(g, metric, thr):
    g = g.sort_values("casualties")
    x, y = g["casualties"].to_numpy(), g[metric].to_numpy()
    for i in range(len(x)):
        if y[i] > thr:
            if i == 0:
                return float(x[0])
            return float(x[i - 1] + (thr - y[i - 1]) * (x[i] - x[i - 1]) / (y[i] - y[i - 1]))
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("table")
    ap.add_argument("--threshold", type=float, default=0.25)
    ap.add_argument("--out", default="results")
    a = ap.parse_args()
    df = load(a.table)
    metrics = ["critical-delay-rate", "deaths-waiting", "preventable-deaths", "lwbs", "p90-door-to-triage",
               "under-triage-rate", "deaths"]
    g = df.groupby(["co-triage?", "casualties"])[metrics]
    mean, ci = g.mean(), 1.96 * g.std() / np.sqrt(g.count())
    agg = mean.join(ci.add_suffix("_ci95")).reset_index()
    out = Path(a.out)
    out.mkdir(exist_ok=True, parents=True)
    agg.to_csv(out / "sweep_summary.csv", index=False)

    criteria = {f"critical-delay-rate>{a.threshold}": ("critical-delay-rate", a.threshold),
                "deaths-waiting>=1": ("deaths-waiting", 0.999),
                "preventable-deaths>=1": ("preventable-deaths", 0.999),
                "p90-door-to-triage>30": ("p90-door-to-triage", 30)}
    res = {}
    for name, (m, thr) in criteria.items():
        s = breaking_point(agg[~agg["co-triage?"]], m, thr)
        c = breaking_point(agg[agg["co-triage?"]], m, thr)
        res[name] = {"single": s, "co-triage": c,
                     "extra_patients_from_co_triage": None if s is None or c is None else round(c - s, 1)}
    (out / "breaking_points.json").write_text(json.dumps(res, indent=2))
    print(json.dumps(res, indent=2))

    for m in metrics:
        fig, ax = plt.subplots(figsize=(6.4, 4))
        for co, gg in agg.groupby("co-triage?"):
            gg = gg.sort_values("casualties")
            ax.plot(gg.casualties, gg[m], marker="o", ms=3, color=COLOUR[co], label=LABEL[co])
            ax.fill_between(gg.casualties, gg[m] - gg[m + "_ci95"], gg[m] + gg[m + "_ci95"], color=COLOUR[co], alpha=.15, lw=0)
        ax.set_xlabel("Incident casualties")
        ax.set_ylabel(m)
        ax.grid(alpha=.3)
        ax.legend(frameon=False)
        fig.tight_layout()
        fig.savefig(out / f"{m}.png", dpi=160)
        plt.close(fig)
    print("written to", out)


if __name__ == "__main__":
    main()
