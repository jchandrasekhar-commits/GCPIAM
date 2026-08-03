-- BigQuery log analysis queries for Logging sink exports.
-- These queries assume date-sharded tables like stdout_* and stderr_*.
-- The current sink output in this workspace does not contain events_* or requests_* tables.
-- Query 5 (latency) now uses nginx access logs emitted by the proxy sidecar to stdout.
-- CPU/memory utilization is best sourced from Managed Prometheus metrics, not only Logging exports.

-- Common suffix filter pattern in each query:
-- _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE(TIMESTAMP_MILLIS($__from)))
--                  AND FORMAT_DATE('%Y%m%d', DATE(TIMESTAMP_MILLIS($__to)))

-- 1) Application error rate over time by namespace
WITH app_logs AS (
  SELECT
    TIMESTAMP_TRUNC(timestamp, MINUTE) AS time,
    COALESCE(resource.labels.namespace_name, 'unknown') AS namespace,
    severity,
    'stdout' AS stream
  FROM `PROJECT_ID.logs_dataset_us.stdout_*`
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE(TIMESTAMP_MILLIS($__from)))
    AND FORMAT_DATE('%Y%m%d', DATE(TIMESTAMP_MILLIS($__to)))

  UNION ALL

  SELECT
    TIMESTAMP_TRUNC(timestamp, MINUTE) AS time,
    COALESCE(resource.labels.namespace_name, 'unknown') AS namespace,
    severity,
    'stderr' AS stream
  FROM `PROJECT_ID.logs_dataset_us.stderr_*`
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE(TIMESTAMP_MILLIS($__from)))
    AND FORMAT_DATE('%Y%m%d', DATE(TIMESTAMP_MILLIS($__to)))
)
SELECT
  time,
  namespace,
  SAFE_DIVIDE(
    SUM(IF(severity IN ('ERROR', 'CRITICAL', 'ALERT', 'EMERGENCY') OR stream = 'stderr', 1, 0)),
    COUNT(1)
  ) * 100 AS error_rate_pct
FROM app_logs
GROUP BY time, namespace
ORDER BY time;


-- 2) stderr error events by namespace
SELECT
  TIMESTAMP_TRUNC(timestamp, MINUTE) AS time,
  COALESCE(resource.labels.namespace_name, 'unknown') AS namespace,
  COUNT(1) AS error_events
FROM `PROJECT_ID.logs_dataset_us.stderr_*`
WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE(TIMESTAMP_MILLIS($__from)))
  AND FORMAT_DATE('%Y%m%d', DATE(TIMESTAMP_MILLIS($__to)))
  AND COALESCE(severity, '') IN ('ERROR', 'CRITICAL', 'ALERT', 'EMERGENCY')
GROUP BY time, namespace
ORDER BY time;


-- 3) Application log volume by namespace
WITH log_lines AS (
  SELECT
    TIMESTAMP_TRUNC(timestamp, MINUTE) AS time,
    COALESCE(resource.labels.namespace_name, 'unknown') AS namespace,
    COUNT(1) AS value
  FROM `PROJECT_ID.logs_dataset_us.stdout_*`
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE(TIMESTAMP_MILLIS($__from)))
    AND FORMAT_DATE('%Y%m%d', DATE(TIMESTAMP_MILLIS($__to)))
  GROUP BY time, namespace

  UNION ALL

  SELECT
    TIMESTAMP_TRUNC(timestamp, MINUTE) AS time,
    COALESCE(resource.labels.namespace_name, 'unknown') AS namespace,
    COUNT(1) AS value
  FROM `PROJECT_ID.logs_dataset_us.stderr_*`
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE(TIMESTAMP_MILLIS($__from)))
    AND FORMAT_DATE('%Y%m%d', DATE(TIMESTAMP_MILLIS($__to)))
  GROUP BY time, namespace
)
SELECT time, namespace, SUM(value) AS log_lines
FROM log_lines
GROUP BY time, namespace
ORDER BY time;


-- 4) stderr log volume by namespace
WITH log_vol AS (
  SELECT
    TIMESTAMP_TRUNC(timestamp, MINUTE) AS time,
    COALESCE(resource.labels.namespace_name, 'unknown') AS metric,
    COUNT(1) AS value
  FROM `PROJECT_ID.logs_dataset_us.stderr_*`
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE(TIMESTAMP_MILLIS($__from)))
    AND FORMAT_DATE('%Y%m%d', DATE(TIMESTAMP_MILLIS($__to)))
  GROUP BY time, metric
)
SELECT time, metric, value FROM log_vol ORDER BY time;


-- 5) Request latency p50/p95/p99 (ms) from nginx proxy logs
WITH latency AS (
  SELECT
    TIMESTAMP_TRUNC(timestamp, MINUTE) AS minute_ts,
    SAFE_CAST(REGEXP_EXTRACT(textPayload, r'request_time=([0-9.]+)') AS FLOAT64) * 1000 AS latency_ms
  FROM `PROJECT_ID.logs_dataset_us.stdout_*`
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE(TIMESTAMP_MILLIS($__from)))
    AND FORMAT_DATE('%Y%m%d', DATE(TIMESTAMP_MILLIS($__to)))
), q AS (
  SELECT
    minute_ts,
    APPROX_QUANTILES(latency_ms, 100) AS p
  FROM latency
  WHERE latency_ms IS NOT NULL
  GROUP BY minute_ts
)
SELECT minute_ts AS time, 'p50' AS percentile, p[OFFSET(50)] AS latency_ms FROM q
UNION ALL
SELECT minute_ts AS time, 'p95' AS percentile, p[OFFSET(95)] AS latency_ms FROM q
UNION ALL
SELECT minute_ts AS time, 'p99' AS percentile, p[OFFSET(99)] AS latency_ms FROM q
ORDER BY time;
