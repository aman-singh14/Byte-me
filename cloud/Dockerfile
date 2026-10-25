# Built from the repo root (it needs social/ and backend/): `fly deploy` there,
# with fly.toml. Locally: docker build -f cloud/Dockerfile .
# .dockerignore at the repo root sends only the files listed there.
FROM python:3.12-slim
WORKDIR /app
COPY cloud/requirements.txt cloud/requirements.txt
RUN pip install --no-cache-dir -r cloud/requirements.txt
COPY . .
ENV DATA_DIR=/data
EXPOSE 8080
# No access log: helper URLs carry room tokens.
CMD ["uvicorn", "cloud.app:create_app", "--factory", "--host", "0.0.0.0", "--port", "8080", "--no-access-log", "--proxy-headers", "--forwarded-allow-ips", "*"]
