-- ============================================================
-- BrickBot Materialized Views
-- Run AFTER schema.sql
-- Refresh: SELECT refresh_all_views();
-- ============================================================

-- ============================================================
-- VIEW 1: ZIP APPRECIATION TRENDS
-- ============================================================
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_zip_appreciation AS
WITH monthly_prices AS (
    SELECT
        zip_code,
        metro_id,
        region_name,
        period_start,
        COALESCE(median_sale_price, zhvi)               AS price,

        LAG(COALESCE(median_sale_price, zhvi), 1)
            OVER (PARTITION BY zip_code ORDER BY period_start)
                                                        AS price_1m_ago,
        LAG(COALESCE(median_sale_price, zhvi), 3)
            OVER (PARTITION BY zip_code ORDER BY period_start)
                                                        AS price_3m_ago,
        LAG(COALESCE(median_sale_price, zhvi), 6)
            OVER (PARTITION BY zip_code ORDER BY period_start)
                                                        AS price_6m_ago,
        LAG(COALESCE(median_sale_price, zhvi), 12)
            OVER (PARTITION BY zip_code ORDER BY period_start)
                                                        AS price_12m_ago,
        LAG(COALESCE(median_sale_price, zhvi), 24)
            OVER (PARTITION BY zip_code ORDER BY period_start)
                                                        AS price_24m_ago,

        AVG(COALESCE(median_sale_price, zhvi))
            OVER (PARTITION BY zip_code
                  ORDER BY period_start
                  ROWS BETWEEN 2 PRECEDING AND CURRENT ROW)
                                                        AS rolling_3m_avg,
        AVG(COALESCE(median_sale_price, zhvi))
            OVER (PARTITION BY zip_code
                  ORDER BY period_start
                  ROWS BETWEEN 11 PRECEDING AND CURRENT ROW)
                                                        AS rolling_12m_avg,

        ROW_NUMBER()
            OVER (PARTITION BY zip_code ORDER BY period_start DESC)
                                                        AS recency_rank
    FROM price_history
    WHERE granularity = 'monthly'
      AND zip_code IS NOT NULL
)
SELECT
    zip_code,
    metro_id,
    region_name,
    period_start,
    price                                               AS current_price,
    rolling_3m_avg,
    rolling_12m_avg,

    CASE WHEN price_1m_ago  > 0
         THEN ROUND(((price - price_1m_ago)  / price_1m_ago  * 100)::NUMERIC, 2)
    END                                                 AS pct_change_1m,
    CASE WHEN price_3m_ago  > 0
         THEN ROUND(((price - price_3m_ago)  / price_3m_ago  * 100)::NUMERIC, 2)
    END                                                 AS pct_change_3m,
    CASE WHEN price_6m_ago  > 0
         THEN ROUND(((price - price_6m_ago)  / price_6m_ago  * 100)::NUMERIC, 2)
    END                                                 AS pct_change_6m,
    CASE WHEN price_12m_ago > 0
         THEN ROUND(((price - price_12m_ago) / price_12m_ago * 100)::NUMERIC, 2)
    END                                                 AS pct_change_yoy,
    CASE WHEN price_24m_ago > 0
         THEN ROUND(((price - price_24m_ago) / price_24m_ago * 100)::NUMERIC, 2)
    END                                                 AS pct_change_2yr,
    CASE WHEN rolling_3m_avg > 0 AND price_3m_ago > 0
         THEN ROUND(((rolling_3m_avg - price_3m_ago) / price_3m_ago * 100)::NUMERIC, 2)
    END                                                 AS momentum_signal,

    recency_rank
FROM monthly_prices
WHERE price IS NOT NULL;

CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_zip_appreciation
    ON mv_zip_appreciation(zip_code, period_start);
CREATE INDEX IF NOT EXISTS idx_mv_zip_appreciation_metro
    ON mv_zip_appreciation(metro_id);
CREATE INDEX IF NOT EXISTS idx_mv_zip_appreciation_recent
    ON mv_zip_appreciation(zip_code, recency_rank);


-- ============================================================
-- VIEW 2: CRIME DENSITY
-- ============================================================
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_crime_density AS
WITH zip_counts AS (
    SELECT
        zip_code,
        metro_id,
        incident_year,
        COUNT(*)                                                AS total_incidents,
        COUNT(*) FILTER (WHERE offense_category = 'violent')   AS violent_incidents,
        COUNT(*) FILTER (WHERE offense_category = 'property')  AS property_incidents,
        COUNT(*) FILTER (WHERE severity = 3)                   AS high_severity_incidents
    FROM crime_incidents
    WHERE zip_code IS NOT NULL
    GROUP BY zip_code, metro_id, incident_year
),
ranked AS (
    SELECT
        *,
        PERCENT_RANK()
            OVER (PARTITION BY metro_id, incident_year
                  ORDER BY total_incidents DESC)        AS crime_percentile,
        PERCENT_RANK()
            OVER (PARTITION BY metro_id, incident_year
                  ORDER BY violent_incidents DESC)      AS violent_percentile
    FROM zip_counts
)
SELECT
    zip_code,
    metro_id,
    incident_year,
    total_incidents,
    violent_incidents,
    property_incidents,
    high_severity_incidents,
    ROUND(crime_percentile::NUMERIC, 4)                 AS safety_score,
    ROUND(violent_percentile::NUMERIC, 4)               AS violent_safety_score,
    ROUND((crime_percentile * 0.4 + violent_percentile * 0.6)::NUMERIC, 4)
                                                        AS composite_safety_score
FROM ranked;

CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_crime_density
    ON mv_crime_density(zip_code, incident_year);
CREATE INDEX IF NOT EXISTS idx_mv_crime_density_metro
    ON mv_crime_density(metro_id, incident_year);


-- ============================================================
-- VIEW 3: SCHOOL QUALITY BY ZIP
-- ============================================================
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_school_quality AS
WITH zip_schools AS (
    SELECT
        zip_code,
        metro_id,
        school_level,
        COUNT(*)            AS school_count,
        AVG(rating_overall) AS avg_rating,
        AVG(test_score_pct) AS avg_test_pct
    FROM schools
    WHERE zip_code IS NOT NULL
      AND rating_overall IS NOT NULL
    GROUP BY zip_code, metro_id, school_level
),
pivoted AS (
    SELECT
        zip_code,
        metro_id,
        MAX(school_count)                                           AS total_schools,
        MAX(avg_rating) FILTER (WHERE school_level = 'elementary') AS elem_avg_rating,
        MAX(avg_rating) FILTER (WHERE school_level = 'middle')     AS middle_avg_rating,
        MAX(avg_rating) FILTER (WHERE school_level = 'high')       AS high_avg_rating
    FROM zip_schools
    GROUP BY zip_code, metro_id
)
SELECT
    zip_code,
    metro_id,
    total_schools,
    ROUND(COALESCE(elem_avg_rating,   0)::NUMERIC, 3)   AS elem_avg_rating,
    ROUND(COALESCE(middle_avg_rating, 0)::NUMERIC, 3)   AS middle_avg_rating,
    ROUND(COALESCE(high_avg_rating,   0)::NUMERIC, 3)   AS high_avg_rating,
    ROUND((
        COALESCE(elem_avg_rating,   0) * 0.50 +
        COALESCE(middle_avg_rating, 0) * 0.25 +
        COALESCE(high_avg_rating,   0) * 0.25
    )::NUMERIC, 4)                                      AS school_composite_score,
    ROUND((
        COALESCE(elem_avg_rating,   0) * 0.50 +
        COALESCE(middle_avg_rating, 0) * 0.25 +
        COALESCE(high_avg_rating,   0) * 0.25
    ) / 10.0, 4)                                        AS school_score_normalized
FROM pivoted;

CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_school_quality
    ON mv_school_quality(zip_code);
CREATE INDEX IF NOT EXISTS idx_mv_school_quality_metro
    ON mv_school_quality(metro_id);


-- ============================================================
-- VIEW 4: TRANSIT ACCESS BY ZIP
-- ============================================================
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_transit_access AS
SELECT
    zip_code,
    metro_id,
    COUNT(*)                                            AS total_stops,
    COUNT(*) FILTER (WHERE transit_type = 'subway')     AS subway_stops,
    COUNT(*) FILTER (WHERE transit_type = 'bus')        AS bus_stops,
    COUNT(*) FILTER (WHERE transit_type = 'rail')       AS rail_stops,
    SUM(route_count)                                    AS total_routes,
    AVG(route_count)                                    AS avg_routes_per_stop,
    ROUND(
        LEAST(LOG(COUNT(*) + 1) / LOG(100), 1.0)::NUMERIC
    , 4)                                                AS transit_score
FROM transit_stops
WHERE zip_code IS NOT NULL
GROUP BY zip_code, metro_id;

CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_transit_access
    ON mv_transit_access(zip_code);


-- ============================================================
-- VIEW 5: PERMIT ACTIVITY BY ZIP
-- ============================================================
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_permit_activity AS
WITH recent_permits AS (
    SELECT
        zip_code,
        metro_id,
        permit_type,
        estimated_cost,
        CASE WHEN issued_date >= NOW() - INTERVAL '12 months'
             THEN 1 ELSE 0 END                          AS is_recent_12m,
        CASE WHEN issued_date >= NOW() - INTERVAL '24 months'
             THEN 1 ELSE 0 END                          AS is_recent_24m
    FROM permits
    WHERE zip_code IS NOT NULL
      AND issued_date IS NOT NULL
)
SELECT
    zip_code,
    metro_id,
    COUNT(*)                                            AS total_permits,
    SUM(estimated_cost)                                 AS total_investment,
    SUM(is_recent_12m)                                  AS permits_12m,
    SUM(estimated_cost * is_recent_12m)                 AS investment_12m,
    SUM(CASE WHEN permit_type ILIKE '%new%construction%'
             AND is_recent_12m = 1 THEN 1 ELSE 0 END)  AS new_construction_12m,
    SUM(CASE WHEN permit_type ILIKE '%renovat%'
             AND is_recent_12m = 1 THEN 1 ELSE 0 END)  AS renovation_12m,
    SUM(is_recent_24m)                                  AS permits_24m,
    ROUND((
        SUM(is_recent_12m)::NUMERIC /
        NULLIF(SUM(is_recent_24m) - SUM(is_recent_12m), 0) - 1
    ) * 100, 2)                                         AS permit_growth_yoy,
    ROUND(
        LEAST(LOG(SUM(is_recent_12m) + 1) / LOG(500), 1.0)::NUMERIC
    , 4)                                                AS permit_activity_score
FROM recent_permits
GROUP BY zip_code, metro_id;

CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_permit_activity
    ON mv_permit_activity(zip_code);


-- ============================================================
-- VIEW 6: MASTER ZIP PROFILE
-- ============================================================
CREATE MATERIALIZED VIEW IF NOT EXISTS mv_zip_profile AS
SELECT
    za.zip_code,
    za.metro_id,
    za.current_price,
    za.pct_change_1m,
    za.pct_change_3m,
    za.pct_change_yoy,
    za.pct_change_2yr,
    za.momentum_signal,
    za.rolling_12m_avg,

    COALESCE(cd.composite_safety_score, 0.5)            AS safety_score,
    COALESCE(cd.total_incidents, 0)                     AS total_crime_incidents,

    COALESCE(sq.school_score_normalized, 0.5)           AS school_score,
    COALESCE(sq.total_schools, 0)                       AS total_schools,
    COALESCE(sq.elem_avg_rating, 0)                     AS elem_school_rating,

    COALESCE(ta.transit_score, 0)                       AS transit_score,
    COALESCE(ta.total_stops, 0)                         AS transit_stops,
    COALESCE(ta.total_routes, 0)                        AS transit_routes,

    COALESCE(pa.permit_activity_score, 0)               AS permit_activity_score,
    COALESCE(pa.permits_12m, 0)                         AS permits_last_12m,
    COALESCE(pa.new_construction_12m, 0)                AS new_construction_12m,
    COALESCE(pa.permit_growth_yoy, 0)                   AS permit_growth_yoy,

    ct.median_household_income,
    ct.pct_owner_occupied,
    ct.unemployment_rate,
    ct.poverty_rate,
    ct.total_population,

    ROUND((
        COALESCE(cd.composite_safety_score,  0.5) * 0.20 +
        COALESCE(sq.school_score_normalized, 0.5) * 0.20 +
        COALESCE(ta.transit_score,           0.0) * 0.15 +
        COALESCE(pa.permit_activity_score,   0.0) * 0.15 +
        LEAST(GREATEST(
            (COALESCE(za.pct_change_yoy, 0) + 10) / 30.0
        , 0), 1)                                        * 0.30
    )::NUMERIC, 4)                                      AS zip_investment_score

FROM (
    SELECT * FROM mv_zip_appreciation WHERE recency_rank = 1
) za
LEFT JOIN (
    SELECT DISTINCT ON (zip_code)
        zip_code, composite_safety_score, total_incidents
    FROM mv_crime_density
    ORDER BY zip_code, incident_year DESC
) cd ON za.zip_code = cd.zip_code
LEFT JOIN mv_school_quality  sq ON za.zip_code = sq.zip_code
LEFT JOIN mv_transit_access  ta ON za.zip_code = ta.zip_code
LEFT JOIN mv_permit_activity pa ON za.zip_code = pa.zip_code
LEFT JOIN (
    SELECT DISTINCT ON (zip_code)
        zip_code, median_household_income, pct_owner_occupied,
        unemployment_rate, poverty_rate, total_population
    FROM census_tracts
    ORDER BY zip_code, acs_year DESC
) ct ON za.zip_code = ct.zip_code;

CREATE UNIQUE INDEX IF NOT EXISTS idx_mv_zip_profile
    ON mv_zip_profile(zip_code);
CREATE INDEX IF NOT EXISTS idx_mv_zip_profile_metro
    ON mv_zip_profile(metro_id);
CREATE INDEX IF NOT EXISTS idx_mv_zip_profile_score
    ON mv_zip_profile(zip_investment_score DESC);


-- ============================================================
-- REFRESH FUNCTION
-- ============================================================
CREATE OR REPLACE FUNCTION refresh_all_views()
RETURNS void AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_zip_appreciation;
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_crime_density;
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_school_quality;
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_transit_access;
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_permit_activity;
    REFRESH MATERIALIZED VIEW CONCURRENTLY mv_zip_profile;
    RAISE NOTICE 'All views refreshed at %', NOW();
END;
$$ LANGUAGE plpgsql;