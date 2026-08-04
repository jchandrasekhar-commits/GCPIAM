FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
# google-cloud-profiler builds a native extension; install a compiler for the
# build, then remove it to keep the runtime image small.
RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc g++ python3-dev \
    && pip install --no-cache-dir -r requirements.txt \
    && apt-get purge -y gcc g++ python3-dev \
    && apt-get autoremove -y \
    && rm -rf /var/lib/apt/lists/*
COPY . .
EXPOSE 8080
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "app:app"]
