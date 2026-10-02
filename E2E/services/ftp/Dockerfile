FROM alpine:3.22

RUN apk add --no-cache vsftpd openssl \
    && adduser -D -h /home/hamasen -s /bin/sh hamasen \
    && install -d -o hamasen -g hamasen /home/hamasen/data \
    && install -d /tls

COPY vsftpd.conf /etc/vsftpd/vsftpd.conf
COPY --from=common supervise restart-server listening issue-server-cert /usr/local/bin/
COPY entrypoint /usr/local/bin/
COPY --from=common touch count-temp /e2e/
COPY set-password rotate-cert /e2e/

ENV E2E_DATA_ROOT=/home/hamasen/data E2E_PORT=21
RUN /e2e/set-password hamasen-e2e

ENTRYPOINT ["entrypoint"]
