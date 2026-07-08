"""
BrickBot — Zillow Research Data Ingestion
Loads ZHVI (home values) and ZORI (rental index) from
manually downloaded Zillow Research CSV files.

Files needed in data/raw/:
    zillow_zhvi_zip.csv  — Zillow Home Value Index by zip
    zillow_zori_zip.csv  — Zillow Observed Rent Index by zip

Download from: https://www.zillow.com/research/data/
"""

import pandas as pd
from pipeline.ingestion.base import (
    upsert_records,
    get_metro_id,
    logger,
    RAW_DIR,
    STAGING_DIR,
)

# ── Target metros and zip codes ───────────────────────────────
TARGET_METROS = {
    "Boston":  ["02101", "02108", "02109", "02110", "02111",
                "02112", "02113", "02114", "02115", "02116",
                "02118", "02119", "02120", "02121", "02122",
                "02124", "02125", "02126", "02127", "02128",
                "02129", "02130", "02131", "02132", "02134",
                "02135", "02136", "02163", "02199", "02210"],
    "Austin":  ["78701", "78702", "78703", "78704", "78705",
                "78712", "78717", "78719", "78721", "78722",
                "78723", "78724", "78725", "78726", "78727",
                "78728", "78729", "78730", "78731", "78732",
                "78733", "78734", "78735", "78736", "78737",
                "78738", "78739", "78741", "78742", "78745"],
    "Phoenix": ["85001", "85002", "85003", "85004", "85006",
                "85007", "85008", "85009", "85012", "85013",
                "85014", "85015", "85016", "85017", "85018",
                "85019", "85020", "85021", "85022", "85023",
                "85024", "85027", "85028", "85029", "85031",
                "85032", "85033", "85034", "85035", "85040"],
    "Chicago": ["60601", "60602", "60603", "60604", "60605",
                "60606", "60607", "60608", "60609", "60610",
                "60611", "60612", "60613", "60614", "60615",
                "60616", "60617", "60618", "60619", "60620",
                "60621", "60622", "60623", "60624", "60625",
                "60626", "60628", "60629", "60630", "60631"],
    "Denver":  ["80201", "80202", "80203", "80204", "80205",
                "80206", "80207", "80209", "80210", "80211",
                "80212", "80214", "80215", "80216", "80218",
                "80219", "80220", "80221", "80222", "80223",
                "80224", "80226", "80227", "80228", "80229",
                "80230", "80231", "80232", "80233", "80234"],
}

ALL_TARGET_ZIPS = {
    z for zips in TARGET_METROS.values() for z in zips
}

# 10 year cutoff
CUTOFF_DATE = pd.Timestamp.now() - pd.DateOffset(years=10)


def load_zhvi(path):
    """
    Load and process ZHVI (home value) CSV from Zillow.
    Zillow stores data in wide format — we melt to long format.
    """
    logger.info(f"Loading ZHVI from {path}")

    df = pd.read_csv(path, dtype={"RegionName": str})
    logger.info(f"Raw shape: {df.shape}")
    logger.info(f"Columns sample: {list(df.columns[:10])}")

    # Normalize zip codes to 5 digits
    df["RegionName"] = df["RegionName"].str.zfill(5)

    # Filter to target zips
    before = len(df)
    df = df[df["RegionName"].isin(ALL_TARGET_ZIPS)].copy()
    logger.info(f"Filtered {before} -> {len(df)} rows for target zips")

    if df.empty:
        logger.error("No matching zip codes found — check zip code format")
        return pd.DataFrame()

    # Identify date columns — they look like "2000-01-31"
    meta_cols = [
        "RegionID", "SizeRank", "RegionName", "RegionType",
        "StateName", "State", "City", "Metro", "CountyName",
    ]
    date_cols = [
        c for c in df.columns
        if c not in meta_cols and c[0].isdigit()
    ]

    logger.info(f"Found {len(date_cols)} date columns")

    # Melt wide -> long
    df_long = df.melt(
        id_vars=["RegionName", "Metro"],
        value_vars=date_cols,
        var_name="period_start",
        value_name="zhvi",
    )

    # Parse dates
    df_long["period_start"] = pd.to_datetime(
        df_long["period_start"], errors="coerce"
    )

    # Filter to last 10 years
    before = len(df_long)
    df_long = df_long[df_long["period_start"] >= CUTOFF_DATE].copy()
    logger.info(f"Date filter: {before} -> {len(df_long)} rows (last 10 years)")

    # Rename columns
    df_long = df_long.rename(columns={
        "RegionName": "zip_code",
        "Metro":      "region_name",
    })

    # Drop nulls
    df_long = df_long.dropna(subset=["zhvi"])

    # Add metadata
    df_long["data_source"] = "zillow_zhvi"
    df_long["granularity"] = "monthly"
    df_long["region_type"] = "zip"

    logger.info(f"ZHVI final shape: {df_long.shape}")
    return df_long


def load_zori(path):
    """
    Load and process ZORI (rental index) CSV from Zillow.
    Same wide format as ZHVI — melt to long.
    """
    logger.info(f"Loading ZORI from {path}")

    df = pd.read_csv(path, dtype={"RegionName": str})
    logger.info(f"Raw shape: {df.shape}")

    # Normalize zip codes
    df["RegionName"] = df["RegionName"].str.zfill(5)

    # Filter to target zips
    before = len(df)
    df = df[df["RegionName"].isin(ALL_TARGET_ZIPS)].copy()
    logger.info(f"Filtered {before} -> {len(df)} rows for target zips")

    if df.empty:
        logger.warning("No ZORI data for target zips")
        return pd.DataFrame()

    # Identify date columns
    meta_cols = [
        "RegionID", "SizeRank", "RegionName", "RegionType",
        "StateName", "State", "City", "Metro", "CountyName",
        "MsaName",
    ]
    date_cols = [
        c for c in df.columns
        if c not in meta_cols and c[0].isdigit()
    ]

    # Melt wide -> long
    df_long = df.melt(
        id_vars=["RegionName"],
        value_vars=date_cols,
        var_name="period_start",
        value_name="zori",
    )

    # Parse dates
    df_long["period_start"] = pd.to_datetime(
        df_long["period_start"], errors="coerce"
    )

    # Filter to last 10 years
    df_long = df_long[df_long["period_start"] >= CUTOFF_DATE].copy()

    # Rename
    df_long = df_long.rename(columns={"RegionName": "zip_code"})

    # Drop nulls
    df_long = df_long.dropna(subset=["zori"])

    df_long["data_source"] = "zillow_zori"
    df_long["granularity"] = "monthly"

    logger.info(f"ZORI final shape: {df_long.shape}")
    return df_long


def assign_metro_ids(df):
    """Add metro_id column based on zip code."""
    zip_to_metro = {}
    for metro, zips in TARGET_METROS.items():
        for z in zips:
            zip_to_metro[z] = metro

    metro_name_to_id = {}
    for metro_name in TARGET_METROS:
        mid = get_metro_id(metro_name)
        if mid:
            metro_name_to_id[metro_name] = mid

    df["metro_name"] = df["zip_code"].map(zip_to_metro)
    df["metro_id"]   = df["metro_name"].map(metro_name_to_id)
    df = df.drop(columns=["metro_name"], errors="ignore")
    return df


def merge_zhvi_zori(zhvi_df, zori_df):
    """
    Merge ZHVI and ZORI on zip_code + period_start.
    ZHVI is the base — ZORI joined where available.
    """
    if zori_df.empty:
        zhvi_df["zori"] = None
        return zhvi_df

    zori_slim = zori_df[["zip_code", "period_start", "zori"]].copy()

    merged = zhvi_df.merge(
        zori_slim,
        on=["zip_code", "period_start"],
        how="left",
    )
    logger.info(f"Merged shape: {merged.shape}")
    return merged


def df_to_records(df):
    """Convert DataFrame to list of dicts for Supabase upsert."""
    records = []
    for _, row in df.iterrows():
        record = {}
        for col in df.columns:
            val = row[col]
            if pd.isna(val):
                record[col] = None
            elif hasattr(val, "item"):
                record[col] = val.item()
            elif isinstance(val, pd.Timestamp):
                record[col] = val.date().isoformat()
            else:
                record[col] = val
        records.append(record)
    return records


def run():
    """
    Full Zillow ingestion pipeline:
    1. Load ZHVI and ZORI from local CSV files
    2. Melt wide -> long format
    3. Filter to target metros + last 10 years
    4. Merge ZHVI + ZORI
    5. Upsert into Supabase price_history table
    """
    logger.info("=" * 60)
    logger.info("Starting Zillow Research ingestion")
    logger.info("=" * 60)

    # ── Load files ────────────────────────────────────────────
    zhvi_path = RAW_DIR / "zillow_zhvi_zip.csv"
    zori_path = RAW_DIR / "zillow_zori_zip.csv"

    if not zhvi_path.exists():
        logger.error(
            f"ZHVI file not found: {zhvi_path}\n"
            "Download from https://www.zillow.com/research/data/\n"
            "Geography: Zip Code, Data: ZHVI All Homes"
        )
        return

    zhvi_df = load_zhvi(zhvi_path)
    if zhvi_df.empty:
        logger.error("ZHVI data empty after processing")
        return

    zori_df = pd.DataFrame()
    if zori_path.exists():
        zori_df = load_zori(zori_path)
    else:
        logger.warning("ZORI file not found — skipping rental index")

    # ── Merge ─────────────────────────────────────────────────
    df = merge_zhvi_zori(zhvi_df, zori_df)

    # ── Assign metro IDs ──────────────────────────────────────
    df = assign_metro_ids(df)

    # ── Save staging copy ─────────────────────────────────────
    staging_path = STAGING_DIR / "zillow_price_history.parquet"
    df.to_parquet(staging_path, index=False)
    logger.info(f"Saved staging: {staging_path}")

    # ── Drop columns not in price_history schema ──────────────
    df = df.drop(
        columns=["city", "state", "region_name"],
        errors="ignore"
    )

    # Keep only schema columns
    schema_cols = [
        "metro_id", "zip_code", "region_type",
        "zhvi", "zori", "granularity",
        "data_source", "period_start",
    ]
    df = df[[c for c in schema_cols if c in df.columns]]

    # ── Upsert to Supabase ────────────────────────────────────
    records = df_to_records(df)
    logger.info(f"Upserting {len(records)} records to price_history...")
    total = upsert_records("price_history", records)
    logger.info(f"Zillow ingestion complete — {total} rows upserted")


if __name__ == "__main__":
    run()