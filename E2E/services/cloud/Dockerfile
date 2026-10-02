# Mock of Dropbox, Microsoft Graph and Google Drive with their OAuth token
# endpoints (see server.py and E2E/CONTRACT.md). Standard library only.
FROM python:3.13-alpine3.22

WORKDIR /app
COPY server.py selftest.py ./
RUN mkdir -p /data

ENV PYTHONUNBUFFERED=1 \
    PORT=8090 \
    DATA_DIR=/data
EXPOSE 8090

CMD ["python3", "/app/server.py"]
