-- BigQuery log analysis queries for Logging sink exports.
-- These queries assume date-sharded tables like stdout_*, stderr_*, events_*, and requests_*.
-- Query 3 (latency) requires sink coverage for load balancer logs (resource.type="http_load_balancer").
-- CPU/memory utilization is best sourced from Managed Prometheus metrics, not only Logging exports.

-- Common suffix filter pattern in each query:
-- _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE(TIMESTAMP_MILLIS($__from)))
--                  AND FORMAT_DATE('%Y%m%d', DATE(TIMESTAMP_MILLIS($__to)))

-- 1) Application error rate over time by namespace
WITH app_logs AS (
  SELECT
    TIMESTAMP_TRUNC(timestamp, MINUTE) AS minute_ts,
    COALESCE(resource.labels.namespace_name, 'unknown') AS namespace,
    IF(severity IN ('ERROR', 'CRITICAL', 'ALERT', 'EMERGENCY') OR logName LIKE '%stderr%', 1, 0) AS is_error
  FROM `PROJECT_ID.logs_dataset_us.stderr_*`
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE(TIMESTAMP_MILLIS($__from)))
    AND FORMAT_DATE('%Y%m%d', DATE(TIMESTAMP_MILLIS($__to)))
)
SELECT
  minute_ts AS time,
  namespace,
  SAFE_DIVIDE(SUM(is_error), COUNT(1)) * 100 AS error_rate_pct
FROM app_logs
GROUP BY time, namespace
ORDER BY time;


-- 2) Pod restart-related event counts by namespace
SELECT
  TIMESTAMP_TRUNC(timestamp, MINUTE) AS time,
  COALESCE(resource.labels.namespace_name, 'unknown') AS namespace,
  COALESCE(jsonPayload.reason, 'unknown') AS reason,
  COUNT(1) AS event_count
FROM `PROJECT_ID.logs_dataset_us.events_*`
WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE(TIMESTAMP_MILLIS($__from)))
  AND FORMAT_DATE('%Y%m%d', DATE(TIMESTAMP_MILLIS($__to)))
  AND COALESCE(jsonPayload.reason, '') IN ('BackOff', 'Killing', 'Started', 'Unhealthy')
GROUP BY time, namespace, reason
ORDER BY time;


-- 3) Request latency p50/p95/p99 (ms)
WITH lb_requests AS (
  SELECT
    TIMESTAMP_TRUNC(timestamp, MINUTE) AS minute_ts,
    CAST(JSON_VALUE(httpRequest, '$.latency') AS STRING) AS latency_str
  FROM `PROJECT_ID.logs_dataset_us.requests_*`
  WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE(TIMESTAMP_MILLIS($__from)))
    AND FORMAT_DATE('%Y%m%d', DATE(TIMESTAMP_MILLIS($__to)))
), parsed AS (
  SELECT
    minute_ts,
    SAFE_CAST(REGEXP_REPLACE(latency_str, r's$', '') AS FLOAT64) * 1000 AS latency_ms
  FROM lb_requests
  WHERE latency_str IS NOT NULL
), q AS (
  SELECT
    minute_ts,
    APPROX_QUANTILES(latency_ms, 100) AS p
  FROM parsed
  GROUP BY minute_ts
)
SELECT minute_ts AS time, 'p50' AS percentile, p[OFFSET(50)] AS latency_ms FROM q
UNION ALL
SELECT minute_ts AS time, 'p95' AS percentile, p[OFFSET(95)] AS latency_ms FROM q
UNION ALL
SELECT minute_ts AS time, 'p99' AS percentile, p[OFFSET(99)] AS latency_ms FROM q
ORDER BY time;


-- 4) Resource/activity utilization trend proxy from log volume
SELECT
  TIMESTAMP_TRUNC(timestamp, MINUTE) AS time,
  CASE
    WHEN logName LIKE '%stdout%' THEN 'stdout_lines'
    WHEN logName LIKE '%stderr%' THEN 'stderr_lines'
    ELSE 'events'
  END AS signal,
  COUNT(1) AS volume
FROM `PROJECT_ID.logs_dataset_us.stdout_*`
WHERE _TABLE_SUFFIX BETWEEN FORMAT_DATE('%Y%m%d', DATE(TIMESTAMP_MILLIS($__from)))
  AND FORMAT_DATE('%Y%m%d', DATE(TIMESTAMP_MILLIS($__to)))
GROUP BY time, signal
ORDER BY time;
