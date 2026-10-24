# Build from this folder: cd social && fly deploy
FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY . social/
ENV SOCIAL_DB=/data/social.db
EXPOSE 8080
CMD ["uvicorn", "social.app:create_app", "--factory", "--host", "0.0.0.0", "--port", "8080", "--proxy-headers", "--forwarded-allow-ips", "*"]
