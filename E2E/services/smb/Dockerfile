FROM alpine:3.22

RUN apk add --no-cache samba \
    && adduser -D -H -s /sbin/nologin hamasen \
    && install -d -o hamasen -g hamasen /data

COPY smb.conf /etc/samba/smb.conf
COPY --from=common listening /usr/local/bin/
COPY --from=common touch count-temp /e2e/
COPY set-password /e2e/

ENV E2E_DATA_ROOT=/data
RUN /e2e/set-password hamasen-e2e

CMD ["smbd", "--foreground", "--no-process-group", "--debug-stdout"]
