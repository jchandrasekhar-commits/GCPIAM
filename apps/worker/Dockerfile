FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
# -u for unbuffered stdout so logs stream to Cloud Logging immediately.
CMD ["python", "-u", "worker.py"]
