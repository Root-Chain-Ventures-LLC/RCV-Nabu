# RCV Nabu

**Nabu** is a self-hosted process knowledge base. Upload SOPs, procedures, policies, forms and
reference documents (or write them in the app); Nabu parses them, shows them inline, keeps every
version, runs them through review and approval, and tags and links everything so the whole picture
of how an organization works is one search away. One Docker image plus PostgreSQL.

- Inline viewing of PDF, Office documents, spreadsheets, images and Markdown
- Text extraction with OCR fallback, section-level full-text search with highlights
- Versions, diffs, review and approval, review cycles and read acknowledgements
- Tags, typed links, backlinks, entities (systems, roles, vendors) and a graph view
- Optional AI with a provider you choose: suggested tags, links and summaries, semantic search and
  "Ask" answers with citations

## License

**RCV Community License 1.1**: free for personal and hobbyist use and for any organization's own
internal operations. A paid commercial license is required only to offer the software to third
parties as a hosted, managed, or SaaS service. See [`LICENSE`](LICENSE). Commercial inquiries:
**legal@rootchainventures.com**.

## Requirements

- **Docker** path (single host): Docker Engine and Docker Compose **2.24 or newer**. The compose
  file runs its own PostgreSQL 17 with pgvector. About 4 GB of RAM is a comfortable minimum (the
  app container is limited to 3 GB by default).
- **Kubernetes** path: a cluster, a PostgreSQL server (14 or newer, with the `vector` and `pg_trgm`
  extensions) you already run, an ingress controller that terminates TLS, and a volume.
- A DNS name and a TLS certificate, normally on a **reverse proxy or ingress** in front of Nabu.
  The app can also serve HTTPS itself (see "Securing a deployment").

The image is published on GHCR as `ghcr.io/root-chain-ventures-llc/nabu` and can be pulled without
logging in. It is built from a private source repository; the source is not published here (see
[CONTRIBUTING.md](CONTRIBUTING.md)).

## Install

### With the install script

```sh
git clone https://github.com/Root-Chain-Ventures-LLC/RCV-Nabu.git
cd RCV-Nabu
./install.sh
```

`install.sh` creates `.env` from `.env.example` if it is missing, generates `NABU_SECRET_KEY` and
`NABU_DB_PASSWORD` with `openssl rand` when they are empty (it never prints them), pulls the image,
starts the stack, waits for `/api/health` and prints the URL and the first-run step. It is safe to
re-run: an existing `.env` is kept and only empty secrets are filled in. Read it before you run it;
it is short.

Set `BASE_URL` in `.env` to the real `https://` address first: the app refuses to start on an
`http://` one. For a local trial over plain http set `BASE_URL=http://localhost:8080` and
`ALLOW_INSECURE_BASE_URL=true`.

### By hand

```sh
git clone https://github.com/Root-Chain-Ventures-LLC/RCV-Nabu.git
cd RCV-Nabu
cp .env.example .env
# edit .env: set NABU_SECRET_KEY (openssl rand -base64 32), NABU_DB_PASSWORD
# (openssl rand -hex 24) and BASE_URL
docker compose pull
docker compose up -d
curl http://127.0.0.1:8080/api/health
```

This starts PostgreSQL (`db`, published on loopback only, volume `nabu-pg`) and the app (`app`,
port 8080 on loopback, volume `nabu-data` for uploaded files). Pin a release with `NABU_VERSION=X.Y.Z`
in `.env`; without it the latest stable release runs. The app container runs with a read-only root
filesystem, all capabilities dropped, `no-new-privileges`, and memory and process limits.

**First run.** Open the `BASE_URL` and create the first administrator. Setup is open only until the
first account exists. If the host can be reached by others before you finish, set `SETUP_TOKEN` in
`.env` first: the setup page then asks for it. Without one, Nabu prints a one-time token in the app
log (`docker compose logs app`) until the first administrator exists. Everything else (AI providers,
email, single sign-on, branding) is configured under **Settings** by an administrator.

**Optional document renderer.** `docker compose --profile renderer up -d`, then set
`RENDERER_URL=http://renderer:3000` in `.env`. Word, Excel and PowerPoint files then get a faithful
PDF view and legacy Office formats become searchable. The renderer runs on an internal network with
no route out.

## Configuration

Copy `.env.example` and read the comments: every variable is documented there. The ones you will set:

| Variable | Notes |
|---|---|
| `BASE_URL` | The public URL people type, exactly. Must be `https://` unless `ALLOW_INSECURE_BASE_URL=true`. Drives the `Secure` cookie flag, HSTS, the same-origin check on writes and the links in email. |
| `NABU_SECRET_KEY` | 32 random bytes (`openssl rand -base64 32`). Encrypts stored files and every credential saved in Settings. **Back it up.** |
| `NABU_DB_PASSWORD` | Password of the bundled PostgreSQL; letters and digits only. |
| `TRUST_PROXY` | Whether to trust `X-Forwarded-*`. See below. |
| `NABU_BIND`, `NABU_PORT` | Host interface and port that publish the app (default `127.0.0.1:8080`). |
| `NABU_VERSION` | Image version to run. |
| `SETUP_TOKEN` | Extra value required to create the first administrator. |
| `ALLOW_PRIVATE_OUTBOUND` | Allow AI providers, mail relays and identity providers on private addresses. |

## Securing a deployment

- **HTTPS.** Put a reverse proxy (or the Kubernetes ingress) in front of Nabu that terminates TLS,
  and set `BASE_URL` to the exact `https://` address. Nabu never redirects http to https itself.
- **TLS between the proxy and the app (optional).** Set `TLS_CERT_FILE` and `TLS_KEY_FILE` (PEM,
  mounted read-only, for example `./certs:/certs:ro`) and the app serves HTTPS on 8080; the files
  are re-read on `SIGHUP` or when they change. Point the proxy at `https://` and have it trust the
  certificate's CA. `TLS_CLIENT_CA_FILE` additionally requires the proxy to present a client
  certificate signed by that CA (only `/api/health` answers without one).
- **`TRUST_PROXY`.** Set it so rate limits, lockout and the audit log see real client addresses:
  `1` for one proxy hop (a proxy on the same host, or an ingress), `2` behind a cloud load balancer
  plus a proxy, or a comma-separated list of proxy addresses (the strongest form).
- **Keep the app off the network.** The default `NABU_BIND=127.0.0.1` publishes the app on loopback
  only, which is what a proxy on the same host needs. Set `NABU_BIND=0.0.0.0` only when the proxy
  runs on another machine.
- **Private certificate authorities and outbound TLS.** AI providers, mail servers and identity
  providers are reached over TLS by the app. Their addresses are checked before use: loopback and
  cloud-metadata addresses are always refused; private addresses need `ALLOW_PRIVATE_OUTBOUND=true`;
  plain http needs `ALLOW_INSECURE_OUTBOUND=true`. For a provider signed by a private CA, set
  `OUTBOUND_CA_FILE` to that CA (PEM bundle, trusted next to the public roots).
- **Database TLS (optional).** Append `?sslmode=verify-full` to the database URL (compose:
  `NABU_DB_URL_PARAMS=?sslmode=verify-full`) and set `DATABASE_CA_FILE`.
- **Files at rest** are always encrypted with keys derived from `NABU_SECRET_KEY`. To rotate the
  key, put the new one in `NABU_SECRET_KEY` and the old one in `NABU_SECRET_KEY_PREVIOUS`; stored
  files and secrets are re-encrypted in the background. Keep the old key until that is done.
- **Interactive HTML documents** are off by default. An administrator can switch them on per space;
  they then play inside a sandboxed frame with no network access and no access to Nabu. For defence
  in depth set `LIVE_HTML_ORIGIN` to a separate https hostname routed to the same app, so the frame
  runs on an origin that holds no session. Leave the feature off where editors are not trusted to publish.
- **Secrets.** Back up `NABU_SECRET_KEY` separately from the database and volume backups: without
  it the stored files and saved credentials cannot be read.

Caddy (automatic certificates):

```
nabu.example.com {
    request_body {
        max_size 110MB
    }
    reverse_proxy 127.0.0.1:8080
}
```

The proxy must accept request bodies larger than `MAX_UPLOAD_MB` (default 100) and give slow uploads
and large downloads time.

## Kubernetes

Manifests live in [`deploy/k8s/`](deploy/k8s/): plain YAML with Kustomize, no Helm. Each release
also carries them as `deploy-k8s-<version>.tar.gz`.

- **Single replica (default):** `kubectl apply -k deploy/k8s`.
- **HA on 3 nodes:** `kubectl apply -k deploy/k8s/overlays/ha`. Needs a `ReadWriteMany` storage class.

Kubernetes does not bundle a database: Nabu uses a PostgreSQL server you already run
(`deploy/k8s/create-db.sql` creates the database and role). Edit `base/configmap.yaml` (`BASE_URL`),
`base/ingress.yaml` (host, TLS) and `base/pvc.yaml` first. See
[`deploy/k8s/README.md`](deploy/k8s/README.md) for the full walkthrough.

## Upgrading

- **Docker Compose:** set `NABU_VERSION` in `.env` (or `git pull` for a newer `docker-compose.yml`),
  then `docker compose pull && docker compose up -d`.
- **Kubernetes:** change `newTag` in `deploy/k8s/base/kustomization.yaml` and re-apply.

Database migrations run automatically on start and only go forward. **Back up first** (below).
Releases are listed under **Releases**; the running build is shown at **Settings, About**.

## Backup and restore

Nabu's state is in two places that must be backed up **together**: the PostgreSQL database and the
data volume (`/data`: uploaded files and renditions). Also keep a copy of `NABU_SECRET_KEY`: without
it the stored files and credentials cannot be read.

```sh
# Docker Compose backup
docker compose exec -T db pg_dump -U nabu nabu > nabu-db.sql
docker compose run --rm --no-deps -T app tar czf - -C /data . > nabu-data.tgz
```

```sh
# Docker Compose restore (into an empty install of the same or a newer version)
docker compose down
docker compose up -d db
docker compose exec -T db psql -U nabu -d postgres \
  -c 'DROP DATABASE IF EXISTS nabu' -c 'CREATE DATABASE nabu OWNER nabu'
docker compose exec -T db psql -U nabu -d nabu < nabu-db.sql
docker compose run --rm --no-deps -T app sh -c 'rm -rf /data/* && tar xzf - -C /data' < nabu-data.tgz
docker compose up -d
```

Restoring a database without its matching data volume (or the reverse) leaves documents pointing at
files that do not exist. After a restore check `http://127.0.0.1:8080/api/health`, then open a
document with an attachment. On Kubernetes, back up the PostgreSQL database the way you do for any
other application and snapshot or copy the `nabu-data` volume.

## Uninstall

- **Docker Compose:** `docker compose down` (add `-v` to also delete the database and data volumes,
  which destroys all data).
- **Kubernetes:** `kubectl delete -k deploy/k8s`. The PersistentVolumeClaim goes with it, so
  snapshot the volume first if you want to keep the data, and drop the database separately.

## Support and contributing

Bug reports and feature requests are welcome as GitHub Issues on this repository. Pull requests are
not accepted, and security issues should be reported privately. See [CONTRIBUTING.md](CONTRIBUTING.md).
