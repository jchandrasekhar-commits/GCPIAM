"""Cloud-native observability wiring: distributed tracing, profiling, and error
reporting. Kept dependency-tolerant so the apps still boot in local/dev where
the GCP libraries or credentials may be missing (each setup step is best-effort
and only logs a warning on failure).

- Tracing: OpenTelemetry SDK -> Cloud Trace exporter, with the Cloud Trace
  propagator so the `X-Cloud-Trace-Context` header set by the global HTTPS load
  balancer stitches LB spans and app spans into one trace. Flask/Redis/psycopg2
  are auto-instrumented when those packages are installed.
- Profiling: Cloud Profiler agent (CPU/heap) started per process.
- Error Reporting: unhandled exceptions are reported to Cloud Error Reporting.
"""
import logging
import os

log = logging.getLogger(__name__)


def _project_id():
    # On GKE the exporter/agents auto-detect the project from the metadata
    # server, so an explicit value is optional.
    return (
        os.getenv("GOOGLE_CLOUD_PROJECT")
        or os.getenv("GCP_PROJECT")
        or os.getenv("PROJECT_ID")
    )


def setup_tracing(service_name, flask_app=None):
    """Configure OpenTelemetry -> Cloud Trace and auto-instrument libraries."""
    if os.getenv("OTEL_SDK_DISABLED", "").lower() == "true":
        log.info("tracing disabled via OTEL_SDK_DISABLED")
        return
    try:
        from opentelemetry import trace
        from opentelemetry.exporter.cloud_trace import CloudTraceSpanExporter
        from opentelemetry.propagate import set_global_textmap
        from opentelemetry.propagators.cloud_trace_propagator import (
            CloudTraceFormatPropagator,
        )
        from opentelemetry.sdk.resources import Resource
        from opentelemetry.sdk.trace import TracerProvider
        from opentelemetry.sdk.trace.export import BatchSpanProcessor

        provider = TracerProvider(
            resource=Resource.create({"service.name": service_name})
        )
        provider.add_span_processor(
            BatchSpanProcessor(CloudTraceSpanExporter(project_id=_project_id()))
        )
        trace.set_tracer_provider(provider)
        # Match the LB's trace context format so traces stitch end-to-end.
        set_global_textmap(CloudTraceFormatPropagator())

        if flask_app is not None:
            from opentelemetry.instrumentation.flask import FlaskInstrumentor

            FlaskInstrumentor().instrument_app(flask_app)

        # Optional client-library instrumentation (guarded: only if installed).
        try:
            from opentelemetry.instrumentation.redis import RedisInstrumentor

            RedisInstrumentor().instrument()
        except Exception:  # noqa: BLE001
            pass
        try:
            from opentelemetry.instrumentation.psycopg2 import Psycopg2Instrumentor

            Psycopg2Instrumentor().instrument()
        except Exception:  # noqa: BLE001
            pass

        log.info("Cloud Trace enabled (service=%s)", service_name)
    except Exception as exc:  # noqa: BLE001 - never block startup on telemetry
        log.warning("tracing disabled (%s)", exc)


def setup_profiler(service_name):
    """Start the Cloud Profiler agent (CPU + heap)."""
    try:
        import googlecloudprofiler

        googlecloudprofiler.start(
            service=service_name,
            service_version=os.getenv("APP_VERSION", "1.0.0"),
            verbose=0,
        )
        log.info("Cloud Profiler enabled (service=%s)", service_name)
    except Exception as exc:  # noqa: BLE001
        log.warning("profiler disabled (%s)", exc)


def setup_error_reporting(flask_app=None):
    """Return a Cloud Error Reporting client; register a Flask handler if given."""
    try:
        from google.cloud import error_reporting

        client = error_reporting.Client()

        if flask_app is not None:
            from werkzeug.exceptions import HTTPException

            @flask_app.errorhandler(Exception)
            def _report_exception(exc):  # noqa: ANN001
                # Let normal 4xx/HTTP responses through without reporting them.
                if isinstance(exc, HTTPException):
                    return exc
                try:
                    client.report_exception()
                except Exception:  # noqa: BLE001
                    pass
                return "Internal Server Error", 500

        log.info("Cloud Error Reporting enabled")
        return client
    except Exception as exc:  # noqa: BLE001
        log.warning("error reporting disabled (%s)", exc)
        return None
