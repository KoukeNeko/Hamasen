# Serves both webdav (HTTP) and webdavs (HTTPS, E2E_TLS set).
FROM rclone/rclone:1.71.1

RUN apk add --no-cache openssl \
    && install -d /etc/rclone /tls

COPY --from=common supervise restart-server listening issue-server-cert /usr/local/bin/
COPY entrypoint /usr/local/bin/
COPY --from=common touch count-temp /e2e/
COPY set-password rotate-cert /e2e/

ENV E2E_DATA_ROOT=/data
RUN /e2e/set-password hamasen-e2e

ENTRYPOINT ["entrypoint"]
