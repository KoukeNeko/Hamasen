FROM alpine:3.22

RUN apk add --no-cache openssl openssh-keygen

COPY --from=common issue-server-cert /usr/local/bin/
COPY generate /usr/local/bin/

CMD ["generate"]
