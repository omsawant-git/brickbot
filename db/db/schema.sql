-- ============================================================
-- BrickBot Database Schema
-- Supabase (PostgreSQL + pgvector)
-- Run this entire file in Supabase SQL Editor
-- ============================================================

-- ── Extensions ───────────────────────────────────────────────
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS pg_trgm;

-- ============================================================
-- 1. METROS
-- ============================================================
CREATE TABLE IF NOT EXISTS metros (
    id              SERIAL PRIMARY KEY,
    name            VARCHAR(100) NOT NULL,
    state           CHAR(2) NOT NULL,
    cbsa_code       VARCHAR(10),
    lat             DOUBLE PRECISION,
    lon             DOUBLE PRECISION,
    created_at      TIMESTAMPTZ DEFAULT NOW()
);

-- ============================================================
-- 2. PROPERTIES
-- ============================================================
CREATE TABLE IF NOT EXISTS properties (
    id                      SERIAL PRIMARY KEY,
    metro_id                INTEGER REFERENCES metros(id),

    -- Location
    address                 TEXT,
    city                    VARCHAR(100),
    state                   CHAR(2),
    zip_code                VARCHAR(10),
    lat                     DOUBLE PRECISION,
    lon                     DOUBLE PRECISION,
    census_tract            VARCHAR(20),

    -- Property details
    property_type           VARCHAR(50),
    bedrooms                SMALLINT,
    bathrooms               NUMERIC(4,1),
    sqft                    INTEGER,
    lot_size_sqft           INTEGER,
    year_built              SMALLINT,
    stories                 SMALLINT,

    -- Listing info
    list_price              NUMERIC(12,2),
    last_sale_price         NUMERIC(12,2),
    last_sale_date          DATE,
    days_on_market          INTEGER,
    listing_status          VARCHAR(30),
    listing_description     TEXT,

    -- LLM-extracted features
    condition_label         VARCHAR(20),
    renovation_signal       BOOLEAN,
    distress_flag           BOOLEAN,
    price_justification     TEXT,
    extraction_confidence   NUMERIC(5,4),

    -- Computed scores
    roi_score               NUMERIC(6,4),
    appreciation_score      NUMERIC(6,4),
    risk_score              NUMERIC(6,4),
    composite_score         NUMERIC(6,4),

    -- Metadata
    data_source             VARCHAR(50),
    created_at              TIMESTAMPTZ DEFAULT NOW(),
    updated_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_properties_zip        ON properties(zip_code);
CREATE INDEX IF NOT EXISTS idx_properties_metro      ON properties(metro_id);
CREATE INDEX IF NOT EXISTS idx_properties_status     ON properties(listing_status);
CREATE INDEX IF NOT EXISTS idx_properties_price      ON properties(list_price);
CREATE INDEX IF NOT EXISTS idx_properties_type       ON properties(property_type);
CREATE INDEX IF NOT EXISTS idx_properties_geo        ON properties USING GIST (
    ST_SetSRID(ST_MakePoint(lon, lat), 4326)
);

-- ============================================================
-- 3. PRICE HISTORY
-- ============================================================
CREATE TABLE IF NOT EXISTS price_history (
    id                  SERIAL PRIMARY KEY,
    metro_id            INTEGER REFERENCES metros(id),
    zip_code            VARCHAR(10),
    region_name         VARCHAR(100),
    region_type         VARCHAR(20),

    -- Price metrics
    median_sale_price   NUMERIC(12,2),
    median_list_price   NUMERIC(12,2),
    median_ppsf         NUMERIC(8,2),
    zhvi                NUMERIC(12,2),
    zori                NUMERIC(10,2),

    -- Market metrics
    homes_sold          INTEGER,
    inventory           INTEGER,
    days_on_market      NUMERIC(6,1),
    sale_to_list_ratio  NUMERIC(6,4),
    price_drops_pct     NUMERIC(6,4),

    -- Time
    period_start        DATE NOT NULL,
    period_end          DATE,
    granularity         VARCHAR(10) DEFAULT 'monthly',

    data_source         VARCHAR(30),
    created_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_price_history_zip     ON price_history(zip_code);
CREATE INDEX IF NOT EXISTS idx_price_history_metro   ON price_history(metro_id);
CREATE INDEX IF NOT EXISTS idx_price_history_period  ON price_history(period_start);
CREATE INDEX IF NOT EXISTS idx_price_history_region  ON price_history(region_type, region_name);

-- ============================================================
-- 4. PERMITS
-- ============================================================
CREATE TABLE IF NOT EXISTS permits (
    id                  SERIAL PRIMARY KEY,
    metro_id            INTEGER REFERENCES metros(id),

    address             TEXT,
    zip_code            VARCHAR(10),
    lat                 DOUBLE PRECISION,
    lon                 DOUBLE PRECISION,
    census_tract        VARCHAR(20),

    permit_number       VARCHAR(100),
    permit_type         VARCHAR(100),
    permit_subtype      VARCHAR(100),
    work_description    TEXT,
    estimated_cost      NUMERIC(12,2),
    permit_status       VARCHAR(50),

    issued_date         DATE,
    finaled_date        DATE,
    expiry_date         DATE,

    applicant_name      TEXT,
    contractor_name     TEXT,

    data_source         VARCHAR(50),
    source_id           VARCHAR(100),
    created_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_permits_zip           ON permits(zip_code);
CREATE INDEX IF NOT EXISTS idx_permits_metro         ON permits(metro_id);
CREATE INDEX IF NOT EXISTS idx_permits_type          ON permits(permit_type);
CREATE INDEX IF NOT EXISTS idx_permits_issued        ON permits(issued_date);
CREATE INDEX IF NOT EXISTS idx_permits_geo           ON permits USING GIST (
    ST_SetSRID(ST_MakePoint(lon, lat), 4326)
);

-- ============================================================
-- 5. CRIME INCIDENTS
-- ============================================================
CREATE TABLE IF NOT EXISTS crime_incidents (
    id                  SERIAL PRIMARY KEY,
    metro_id            INTEGER REFERENCES metros(id),

    zip_code            VARCHAR(10),
    block_address       TEXT,
    lat                 DOUBLE PRECISION,
    lon                 DOUBLE PRECISION,
    census_tract        VARCHAR(20),
    district            VARCHAR(50),

    incident_number     VARCHAR(100),
    offense_code        VARCHAR(20),
    offense_category    VARCHAR(100),
    offense_description TEXT,
    severity            SMALLINT,

    incident_date       DATE,
    incident_time       TIME,
    incident_year       SMALLINT,
    incident_month      SMALLINT,

    data_source         VARCHAR(50),
    source_id           VARCHAR(100),
    created_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_crime_zip             ON crime_incidents(zip_code);
CREATE INDEX IF NOT EXISTS idx_crime_metro           ON crime_incidents(metro_id);
CREATE INDEX IF NOT EXISTS idx_crime_category        ON crime_incidents(offense_category);
CREATE INDEX IF NOT EXISTS idx_crime_date            ON crime_incidents(incident_date);
CREATE INDEX IF NOT EXISTS idx_crime_year            ON crime_incidents(incident_year);
CREATE INDEX IF NOT EXISTS idx_crime_geo             ON crime_incidents USING GIST (
    ST_SetSRID(ST_MakePoint(lon, lat), 4326)
);

-- ============================================================
-- 6. SCHOOLS
-- ============================================================
CREATE TABLE IF NOT EXISTS schools (
    id                  SERIAL PRIMARY KEY,
    metro_id            INTEGER REFERENCES metros(id),

    nces_id             VARCHAR(20) UNIQUE,
    school_name         TEXT NOT NULL,
    district_name       TEXT,

    address             TEXT,
    city                VARCHAR(100),
    state               CHAR(2),
    zip_code            VARCHAR(10),
    lat                 DOUBLE PRECISION,
    lon                 DOUBLE PRECISION,

    school_type         VARCHAR(30),
    school_level        VARCHAR(20),
    grades_offered      VARCHAR(50),

    rating_overall      NUMERIC(4,2),
    rating_academics    NUMERIC(4,2),
    rating_diversity    NUMERIC(4,2),
    rating_teachers     NUMERIC(4,2),
    test_score_pct      NUMERIC(6,2),
    enrollment          INTEGER,

    data_source         VARCHAR(50),
    academic_year       VARCHAR(10),
    created_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_schools_zip           ON schools(zip_code);
CREATE INDEX IF NOT EXISTS idx_schools_metro         ON schools(metro_id);
CREATE INDEX IF NOT EXISTS idx_schools_level         ON schools(school_level);
CREATE INDEX IF NOT EXISTS idx_schools_rating        ON schools(rating_overall);
CREATE INDEX IF NOT EXISTS idx_schools_geo           ON schools USING GIST (
    ST_SetSRID(ST_MakePoint(lon, lat), 4326)
);

-- ============================================================
-- 7. TRANSIT STOPS
-- ============================================================
CREATE TABLE IF NOT EXISTS transit_stops (
    id                  SERIAL PRIMARY KEY,
    metro_id            INTEGER REFERENCES metros(id),

    stop_id             VARCHAR(100),
    stop_name           TEXT,
    stop_desc           TEXT,
    stop_lat            DOUBLE PRECISION,
    stop_lon            DOUBLE PRECISION,
    zone_id             VARCHAR(50),

    transit_type        VARCHAR(30),
    agency_name         VARCHAR(100),
    route_count         INTEGER,
    is_accessible       BOOLEAN,

    zip_code            VARCHAR(10),
    data_source         VARCHAR(50),
    created_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_transit_zip           ON transit_stops(zip_code);
CREATE INDEX IF NOT EXISTS idx_transit_metro         ON transit_stops(metro_id);
CREATE INDEX IF NOT EXISTS idx_transit_type          ON transit_stops(transit_type);
CREATE INDEX IF NOT EXISTS idx_transit_geo           ON transit_stops USING GIST (
    ST_SetSRID(ST_MakePoint(stop_lon, stop_lat), 4326)
);

-- ============================================================
-- 8. CENSUS TRACTS
-- ============================================================
CREATE TABLE IF NOT EXISTS census_tracts (
    id                      SERIAL PRIMARY KEY,
    metro_id                INTEGER REFERENCES metros(id),

    tract_id                VARCHAR(20) UNIQUE NOT NULL,
    state_fips              CHAR(2),
    county_fips             CHAR(3),
    tract_code              VARCHAR(10),
    zip_code                VARCHAR(10),

    total_population        INTEGER,
    median_household_income NUMERIC(10,2),
    median_age              NUMERIC(5,1),
    pct_college_educated    NUMERIC(6,4),
    pct_owner_occupied      NUMERIC(6,4),
    pct_renter_occupied     NUMERIC(6,4),
    pct_vacant              NUMERIC(6,4),
    unemployment_rate       NUMERIC(6,4),
    poverty_rate            NUMERIC(6,4),

    median_home_value       NUMERIC(12,2),
    median_gross_rent       NUMERIC(8,2),
    total_housing_units     INTEGER,

    geom                    GEOMETRY(MULTIPOLYGON, 4326),

    acs_year                SMALLINT,
    created_at              TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_census_tract_id       ON census_tracts(tract_id);
CREATE INDEX IF NOT EXISTS idx_census_zip            ON census_tracts(zip_code);
CREATE INDEX IF NOT EXISTS idx_census_metro          ON census_tracts(metro_id);
CREATE INDEX IF NOT EXISTS idx_census_income         ON census_tracts(median_household_income);
CREATE INDEX IF NOT EXISTS idx_census_geo            ON census_tracts USING GIST(geom);

-- ============================================================
-- 9. NEIGHBORHOOD EMBEDDINGS
-- ============================================================
CREATE TABLE IF NOT EXISTS neighborhood_embeddings (
    id                  SERIAL PRIMARY KEY,
    metro_id            INTEGER REFERENCES metros(id),

    zip_code            VARCHAR(10),
    neighborhood_name   VARCHAR(100),
    chunk_index         INTEGER,
    total_chunks        INTEGER,

    content             TEXT NOT NULL,
    content_type        VARCHAR(50),
    source_url          TEXT,
    source_title        TEXT,

    embedding           VECTOR(384),

    token_count         INTEGER,
    created_at          TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_embeddings_vector     ON neighborhood_embeddings
    USING hnsw (embedding vector_cosine_ops)
    WITH (m = 16, ef_construction = 64);
CREATE INDEX IF NOT EXISTS idx_embeddings_zip        ON neighborhood_embeddings(zip_code);
CREATE INDEX IF NOT EXISTS idx_embeddings_type       ON neighborhood_embeddings(content_type);
CREATE INDEX IF NOT EXISTS idx_embeddings_fts        ON neighborhood_embeddings
    USING GIN (to_tsvector('english', content));

-- ============================================================
-- 10. FORECASTS
-- ============================================================
CREATE TABLE IF NOT EXISTS forecasts (
    id                  SERIAL PRIMARY KEY,
    metro_id            INTEGER REFERENCES metros(id),
    zip_code            VARCHAR(10) NOT NULL,
    region_name         VARCHAR(100),

    forecast_date       DATE NOT NULL,
    predicted_price     NUMERIC(12,2),
    predicted_pct_change NUMERIC(8,4),
    lower_bound         NUMERIC(12,2),
    upper_bound         NUMERIC(12,2),

    model_name          VARCHAR(50),
    model_version       VARCHAR(20),
    horizon_months      SMALLINT,
    baseline_price      NUMERIC(12,2),
    baseline_date       DATE,

    mape                NUMERIC(8,4),
    smape               NUMERIC(8,4),

    generated_at        TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_forecasts_zip         ON forecasts(zip_code);
CREATE INDEX IF NOT EXISTS idx_forecasts_metro       ON forecasts(metro_id);
CREATE INDEX IF NOT EXISTS idx_forecasts_date        ON forecasts(forecast_date);
CREATE INDEX IF NOT EXISTS idx_forecasts_model       ON forecasts(model_name);
CREATE UNIQUE INDEX IF NOT EXISTS idx_forecasts_unique
    ON forecasts(zip_code, forecast_date, model_name);

-- ============================================================
-- 11. ROI SCORES
-- ============================================================
CREATE TABLE IF NOT EXISTS roi_scores (
    id                          SERIAL PRIMARY KEY,
    property_id                 INTEGER REFERENCES properties(id),
    zip_code                    VARCHAR(10),
    metro_id                    INTEGER REFERENCES metros(id),

    rental_yield_score          NUMERIC(6,4),
    appreciation_score          NUMERIC(6,4),
    school_score                NUMERIC(6,4),
    crime_score                 NUMERIC(6,4),
    transit_score               NUMERIC(6,4),
    permit_activity_score       NUMERIC(6,4),

    roi_score                   NUMERIC(6,4),
    risk_score                  NUMERIC(6,4),
    composite_score             NUMERIC(6,4),

    estimated_monthly_rent      NUMERIC(10,2),
    estimated_annual_yield      NUMERIC(8,4),
    estimated_1yr_appreciation  NUMERIC(8,4),
    estimated_3yr_appreciation  NUMERIC(8,4),

    investor_profile            VARCHAR(30),
    budget_tier                 VARCHAR(20),

    model_version               VARCHAR(20),
    scored_at                   TIMESTAMPTZ DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS idx_roi_property          ON roi_scores(property_id);
CREATE INDEX IF NOT EXISTS idx_roi_zip               ON roi_scores(zip_code);
CREATE INDEX IF NOT EXISTS idx_roi_composite         ON roi_scores(composite_score DESC);
CREATE INDEX IF NOT EXISTS idx_roi_profile           ON roi_scores(investor_profile);

-- ============================================================
-- TRIGGER — auto-update updated_at on properties
-- ============================================================
CREATE OR REPLACE FUNCTION update_updated_at()
RETURNS TRIGGER AS $$
BEGIN
    NEW.updated_at = NOW();
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_properties_updated_at
    BEFORE UPDATE ON properties
    FOR EACH ROW EXECUTE FUNCTION update_updated_at();

-- ============================================================
-- SEED DATA
-- ============================================================
INSERT INTO metros (name, state, cbsa_code, lat, lon) VALUES
    ('Boston',  'MA', '14460', 42.3601,  -71.0589),
    ('Austin',  'TX', '12420', 30.2672,  -97.7431),
    ('Phoenix', 'AZ', '38060', 33.4484, -112.0740),
    ('Chicago', 'IL', '16980', 41.8781,  -87.6298),
    ('Denver',  'CO', '19740', 39.7392, -104.9903)
ON CONFLICT DO NOTHING;