FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . .
EXPOSE 8080
# 2 workers is plenty for the demo; the app is stateless (state lives in Redis).
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "app:app"]
