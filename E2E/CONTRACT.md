# E2E environment contract

What the Docker services provide and how the Swift e2e harness reaches
them. Everything below is fixed; the harness hard-codes it.

Ports are bound to `127.0.0.1` (to `0.0.0.0` in remote mode, below). Compose
project name: `hamasen-e2e`. Generated material (certificates, keys) goes to
`E2E/.run/`, or to `E2E/.run/<ssh host>/` for a remote stack; both are
git-ignored.

## Accounts

| Item | Value |
|---|---|
| Username (every protocol) | `hamasen` |
| Password (every protocol) | `hamasen-e2e` |
| S3 access key / secret | `hamasen-e2e` / `hamasen-e2e-secret` |
| S3 bucket | `hamasen` (exists when the stack is healthy) |
| S3 region | `us-east-1` |
| SFTP key | `E2E/.run/keys/id_ed25519` (OpenSSH, Ed25519, no passphrase), authorized for `hamasen` |
| TLS CA | `E2E/.run/certs/ca.pem` (PEM) — signs every server certificate |
| Server certificate SANs | `localhost`, `127.0.0.1`, and `E2E_HOST` when set (an IP address or a DNS name) |

## Services and ports

| Service | Container port | Direct host port | Through toxiproxy | Remote path the client mounts |
|---|---|---|---|---|
| `sftp` (OpenSSH, Alpine) | 22 | 2222 | 12222 | `/home/hamasen/data` |
| `ftp` (vsftpd, plain + explicit FTPS on one port) | 21 | 2121 | 12121 | `/data` (login is chrooted to `/home/hamasen`) |
| `ftp` passive data | 30000–30049 | 30000–30049 | — (direct) | |
| `webdav` (rclone serve webdav, HTTP) | 8080 | 8081 | 18081 | `/` |
| `webdavs` (rclone serve webdav, HTTPS) | 8443 | 8443 | — | `/` |
| `smb` (Samba, SMB2+) | 445 | 1445 | 11445 | share `data`, client remote path `/data` |
| `s3` (SeaweedFS) | 8333 | 8333 | 18333 | `/hamasen` (path-style, plain HTTP) |
| `cloud` (mock of Dropbox, Microsoft Graph, Google Drive + their OAuth token endpoints) | 8090 | 8090 | 18090 | `/` |
| `toxiproxy` API | 8474 | 8474 | — | |

Toxiproxy proxies are named `sftp`, `ftp`, `webdav`, `smb`, `s3`, `cloud`,
each listening inside the toxiproxy container on the "through toxiproxy"
port above (published to the host on the same number) and forwarding to the
service's container port. They are defined in a config file so they exist as
soon as toxiproxy starts.

vsftpd's passive replies name `E2E_HOST` (default `127.0.0.1`) so data
connections from the client reach the published passive ports. TLS session reuse between control and
data connections must not be required (`require_ssl_reuse=NO`).

## Server control

The harness changes server state the way an administrator or another device
would, through `docker compose -p hamasen-e2e exec -T <service> /e2e/<command>`.
Every command exits 0 on success.

| Service | Command | Effect |
|---|---|---|
| `sftp`, `ftp`, `smb`, `webdav`, `webdavs` | `set-password <new>` | Changes `hamasen`'s password (WebDAV services may restart their server process; the container must stay up) |
| `sftp`, `ftp`, `smb`, `webdav`, `webdavs` | `touch <relative-path> <unix-seconds>` | Sets a file's modification time, path relative to the client's remote path |
| `sftp`, `ftp`, `smb`, `webdav`, `webdavs` | `count-temp` | Prints the number of entries anywhere under the data root whose name starts with `.hamasen-upload-` |
| `sftp` | `rotate-hostkey` | Replaces the server's host keys and restarts sshd (container stays up) |
| `ftp`, `webdavs` | `rotate-cert` | Reissues the server certificate from the same CA and reloads |

Host keys, certificates and data survive `docker compose restart` (named
volumes or the bind-mounted `.run` directory).

## Cloud mock

One HTTP server on port 8090. The harness rewrites every request a cloud
client makes from `https://<host>/<path>` to
`http://<HAMASEN_E2E_HOST, default 127.0.0.1>:<port>/<host>/<path>`, keeping method, headers, query and
body. The mock therefore dispatches on the first path component, which is the
real API host:

- `api.dropboxapi.com/2/...`, `content.dropboxapi.com/2/...`, `api.dropboxapi.com/oauth2/token`
- `graph.microsoft.com/v1.0/...`, `login.microsoftonline.com/common/oauth2/v2.0/token`
- `www.googleapis.com/drive/v3/...`, `www.googleapis.com/upload/drive/v3/...`, `oauth2.googleapis.com/token`

Behaviour the clients depend on is defined by the Swift clients themselves
(`HamasenCore/Sources/HamasenCore/Cloud/*.swift`) and their in-memory fakes
(`HamasenCore/Tests/HamasenCoreTests/{Dropbox,OneDrive,GoogleDrive}FileServiceTests.swift`).

Tokens: the token endpoints accept `grant_type=refresh_token` with any refresh
token the mock issued and not revoked, and `grant_type=authorization_code`
with code `e2e-code`. Access tokens expire after `TOKEN_LIFETIME` seconds
(environment, default 3600; the soak sets it low). Microsoft rotates refresh
tokens: each refresh returns a new one, and the previous one stops working
`ROTATION_GRACE` seconds later (default 60). Google and Dropbox return no new
refresh token on refresh.

Admin API, under `/__admin/`, JSON in and out:

| Method and path | Effect |
|---|---|
| `POST /__admin/reset` | Empties every drive and forgets every token |
| `POST /__admin/token` `{"provider": "google"\|"microsoft"\|"dropbox"}` | Issues a token pair; returns `{"access_token", "refresh_token", "expires_in"}` |
| `POST /__admin/revoke` `{"provider": ...}` | Invalidates every refresh and access token of that provider |
| `POST /__admin/throttle` `{"provider": ..., "count": n}` | The next n API requests of that provider answer with its rate-limit response (Dropbox/Graph 429 with `Retry-After: 1`, Google 403 `userRateLimitExceeded`) |
| `GET /__admin/stats` | Request counts per provider, refreshes, items stored |

Content is stored on disk under the container's `/data`, not in memory, so a
five-year soak does not grow the process.

## Remote mode

With `HAMASEN_E2E_SSH=<ssh host>`, `scripts/e2e.sh` copies
`docker-compose.yml`, `services`, `scripts` and this file to `~/hamasen-e2e`
on that host (`HAMASEN_E2E_REMOTE_DIR`). It writes `.env` there with
`E2E_BIND=0.0.0.0` and `E2E_HOST=$HAMASEN_E2E_HOST` (default: the first
address `hostname -I` reports on that host), so a service the harness
restarts keeps listening on the network. Every compose command, ServerControl's
included, runs there over `ssh -o BatchMode=yes`. After `up`,
`.run/certs/ca.pem` and `.run/keys` are copied back to `E2E/.run/<ssh host>/`,
which `HAMASEN_E2E_RUN_DIR` names. TLS clients connect to `E2E_HOST` instead
of `localhost`.
