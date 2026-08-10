FROM python:3.14-slim-bookworm@sha256:23c59390fc717bf09f9336908199a0ae75d9c4264bf296123f94ad772fea3b52

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    WEB_ROOT=/opt/tokenfleet/web

WORKDIR /opt/tokenfleet

COPY server/requirements.txt server/constraints.txt /tmp/tokenfleet-dependencies/
RUN python -m pip install --no-cache-dir \
      -r /tmp/tokenfleet-dependencies/requirements.txt \
      -c /tmp/tokenfleet-dependencies/constraints.txt \
    && rm -rf /tmp/tokenfleet-dependencies

COPY server /opt/tokenfleet/server
COPY web /opt/tokenfleet/web

RUN groupadd --system --gid 10001 tokenfleet \
    && useradd --system --uid 10001 --gid tokenfleet \
      --home-dir /nonexistent --shell /usr/sbin/nologin tokenfleet

WORKDIR /opt/tokenfleet/server
USER 10001:10001

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=20s --retries=3 \
  CMD ["python", "-c", "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=3).read()"]

CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--workers", "1", "--proxy-headers", "--forwarded-allow-ips", "172.30.50.1"]
