"""
Build the local curated Parquet layer from the exported TSVs.
Mirrors the Azure layout: curated_local/dw/<Table>/<Table>.parquet
so the project runs fully offline (Azure is a mirror, not a dependency).

Parser: pandas with QUOTE_NONE (fields may contain literal " characters;
pyarrow's csv reader mis-parses this data even with quoting disabled).
All columns kept as strings to match the Azure curated layer exactly;
consumers (Qlik Num#(), pandas astype) do the typing.

Usage: python 03_build_local_parquet.py
Requires: pandas, pyarrow
"""
import csv
import os
import pandas as pd
import pyarrow as pa
import pyarrow.parquet as pq

BASE = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(BASE, "data_export")
DST = os.path.join(BASE, "curated_local", "dw")
CHUNK = 2_000_000

for fname in sorted(os.listdir(SRC)):
    if not fname.endswith(".tsv"):
        continue
    table = fname[:-4]
    src_path = os.path.join(SRC, fname)
    out_dir = os.path.join(DST, table)
    os.makedirs(out_dir, exist_ok=True)
    out_path = os.path.join(out_dir, f"{table}.parquet")

    # incremental: skip tables whose parquet is newer than the TSV
    if os.path.exists(out_path) and os.path.getmtime(out_path) > os.path.getmtime(src_path):
        print(f"{table}: up to date, skipped")
        continue

    writer = None
    rows = 0
    for chunk in pd.read_csv(src_path, sep="\t", dtype=str, quoting=csv.QUOTE_NONE,
                             keep_default_na=False, encoding="utf-8", chunksize=CHUNK):
        tbl = pa.Table.from_pandas(chunk, preserve_index=False)
        if writer is None:
            writer = pq.ParquetWriter(out_path, tbl.schema, compression="snappy")
        writer.write_table(tbl)
        rows += len(chunk)
    if writer:
        writer.close()
    mb = os.path.getsize(out_path) / 1024 / 1024
    print(f"{table}: {rows:,} rows -> {out_path} ({mb:.1f} MB)")

print("Local curated layer complete.")
