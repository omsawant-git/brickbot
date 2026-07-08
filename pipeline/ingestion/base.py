"""
BrickBot — Base Ingestion Client
Shared HTTP client, retry logic, rate limiting, and Supabase loader
used by all ingestion scripts.
"""

import os
import time
import logging
from pathlib import Path

import httpx
from dotenv import load_dotenv
from supabase import create_client

# ── Load environment variables ────────────────────────────────
load_dotenv()

# ── Paths ─────────────────────────────────────────────────────
BASE_DIR    = Path(__file__).parent.parent.parent
DATA_DIR    = BASE_DIR / "data"
RAW_DIR     = DATA_DIR / "raw"
STAGING_DIR = DATA_DIR / "staging"
CURATED_DIR = DATA_DIR / "curated"

for d in [RAW_DIR, STAGING_DIR, CURATED_DIR]:
    d.mkdir(parents=True, exist_ok=True)

# ── Logging ───────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s | %(levelname)s | %(name)s | %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)
logger = logging.getLogger("brickbot.ingestion")


# ── Supabase client ───────────────────────────────────────────
def get_supabase_client():
    url = os.getenv("SUPABASE_URL")
    key = os.getenv("SUPABASE_KEY")
    if not url or not key:
        raise ValueError(
            "SUPABASE_URL and SUPABASE_KEY must be set in .env"
        )
    return create_client(url, key)


# ── HTTP client ───────────────────────────────────────────────
def get_http_client(timeout=30):
    return httpx.Client(
        timeout=timeout,
        headers={
            "User-Agent": "BrickBot/1.0 (real-estate research project)",
            "Accept":     "application/json",
        },
        follow_redirects=True,
    )


# ── Retry logic ───────────────────────────────────────────────
def fetch_with_retry(
    url,
    params=None,
    max_retries=3,
    backoff=2.0,
    timeout=30,
):
    """
    GET request with exponential backoff retry.
    Returns parsed JSON response.
    """
    with get_http_client(timeout=timeout) as client:
        for attempt in range(1, max_retries + 1):
            try:
                logger.info(f"Fetching {url} (attempt {attempt}/{max_retries})")
                response = client.get(url, params=params)
                response.raise_for_status()
                return response.json()

            except httpx.HTTPStatusError as e:
                if e.response.status_code == 429:
                    wait = backoff * (2 ** attempt)
                    logger.warning(f"Rate limited. Waiting {wait}s...")
                    time.sleep(wait)
                elif attempt == max_retries:
                    logger.error(f"Failed after {max_retries} attempts: {e}")
                    raise
                else:
                    wait = backoff * attempt
                    logger.warning(f"HTTP {e.response.status_code}. Retrying in {wait}s...")
                    time.sleep(wait)

            except httpx.RequestError as e:
                if attempt == max_retries:
                    logger.error(f"Request error after {max_retries} attempts: {e}")
                    raise
                wait = backoff * attempt
                logger.warning(f"Request error: {e}. Retrying in {wait}s...")
                time.sleep(wait)


# ── Supabase upsert helper ────────────────────────────────────
def upsert_records(
    table,
    records,
    chunk_size=500,
):
    """
    Upsert a list of records into a Supabase table in chunks.
    Returns total rows upserted.
    """
    if not records:
        logger.warning(f"No records to upsert into {table}")
        return 0

    supabase = get_supabase_client()
    total = 0

    for i in range(0, len(records), chunk_size):
        chunk = records[i : i + chunk_size]
        try:
            supabase.table(table).upsert(chunk).execute()
            total += len(chunk)
            logger.info(f"Upserted {total}/{len(records)} rows into {table}")
        except Exception as e:
            logger.error(f"Upsert failed for chunk {i}-{i+chunk_size}: {e}")
            raise

    return total


# ── Rate limiter ──────────────────────────────────────────────
class RateLimiter:
    """
    Simple rate limiter.

    Example:
        limiter = RateLimiter(calls_per_second=2)
        for url in urls:
            limiter.wait()
            fetch_with_retry(url)
    """

    def __init__(self, calls_per_second=1.0):
        self.min_interval = 1.0 / calls_per_second
        self.last_call    = 0.0

    def wait(self):
        elapsed = time.time() - self.last_call
        if elapsed < self.min_interval:
            time.sleep(self.min_interval - elapsed)
        self.last_call = time.time()


# ── Socrata API client ────────────────────────────────────────
class SocrataClient:
    """
    Client for Socrata Open Data APIs.
    Used for permits, crime, assessor data from city portals.

    Example:
        client = SocrataClient("data.cityofchicago.org")
        records = client.fetch_all("crimes", limit=100000)
    """

    BASE = "https://{domain}/resource/{dataset}.json"

    def __init__(
        self,
        domain,
        app_token=None,
        calls_per_second=2.0,
    ):
        self.domain  = domain
        self.headers = {"Accept": "application/json"}
        if app_token:
            self.headers["X-App-Token"] = app_token
        self.limiter = RateLimiter(calls_per_second)

    def fetch_page(
        self,
        dataset,
        limit=1000,
        offset=0,
        where=None,
        order=":id",
    ):
        """Fetch one page of results from a Socrata dataset."""
        url = self.BASE.format(domain=self.domain, dataset=dataset)
        params = {
            "$limit":  limit,
            "$offset": offset,
            "$order":  order,
        }
        if where:
            params["$where"] = where

        self.limiter.wait()
        with get_http_client() as client:
            response = client.get(url, params=params, headers=self.headers)
            response.raise_for_status()
            return response.json()

    def fetch_all(
        self,
        dataset,
        page_size=1000,
        max_records=None,
        where=None,
    ):
        """
        Paginate through entire Socrata dataset.

        Args:
            dataset:     Socrata dataset ID e.g. "ijzp-q8t2"
            page_size:   Records per page (max 50000)
            max_records: Stop after this many records (None = all)
            where:       SoQL WHERE clause e.g. "year >= 2020"

        Returns:
            All records as list of dicts
        """
        all_records = []
        offset = 0

        while True:
            logger.info(
                f"Fetching {dataset} offset={offset} "
                f"(total so far: {len(all_records)})"
            )
            page = self.fetch_page(
                dataset,
                limit=page_size,
                offset=offset,
                where=where,
            )

            if not page:
                break

            all_records.extend(page)
            offset += len(page)

            if len(page) < page_size:
                break

            if max_records and len(all_records) >= max_records:
                all_records = all_records[:max_records]
                break

        logger.info(f"Fetched {len(all_records)} total records from {dataset}")
        return all_records


# ── CSV downloader ────────────────────────────────────────────
def download_csv(url, filename, dest_dir=None):
    """
    Download a CSV/TSV file to the raw data directory.
    Skips download if file already exists.
    Returns Path to saved file.
    """
    if dest_dir is None:
        dest_dir = RAW_DIR

    dest = dest_dir / filename
    if dest.exists():
        logger.info(f"Already exists, skipping download: {dest}")
        return dest

    logger.info(f"Downloading {url} -> {dest}")
    with get_http_client(timeout=120) as client:
        with client.stream("GET", url) as response:
            response.raise_for_status()
            with open(dest, "wb") as f:
                for chunk in response.iter_bytes(chunk_size=8192):
                    f.write(chunk)

    logger.info(f"Saved {dest.stat().st_size / 1024 / 1024:.1f} MB to {dest}")
    return dest


# ── Metro ID lookup ───────────────────────────────────────────
def get_metro_id(metro_name):
    """
    Look up metro_id from the metros table by name.
    Returns metro_id integer or None if not found.
    """
    supabase = get_supabase_client()
    result = (
        supabase.table("metros")
        .select("id")
        .eq("name", metro_name)
        .execute()
    )
    if result.data:
        return result.data[0]["id"]
    logger.warning(f"Metro '{metro_name}' not found in metros table")
    return None