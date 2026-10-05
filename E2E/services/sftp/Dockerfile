FROM alpine:3.22

RUN apk add --no-cache openssh-server openssh-keygen \
    && adduser -D -h /home/hamasen -s /bin/sh hamasen \
    && install -d -o hamasen -g hamasen /home/hamasen/data \
    && install -d /etc/ssh/keys

COPY sshd_config /etc/ssh/sshd_config
COPY --from=common supervise restart-server listening /usr/local/bin/
COPY generate-hostkeys entrypoint /usr/local/bin/
COPY --from=common touch count-temp /e2e/
COPY set-password rotate-hostkey /e2e/

ENV E2E_DATA_ROOT=/home/hamasen/data E2E_PORT=22
RUN /e2e/set-password hamasen-e2e

ENTRYPOINT ["entrypoint"]
