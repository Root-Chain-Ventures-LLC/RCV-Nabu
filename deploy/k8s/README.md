# Nabu on Kubernetes

Plain manifests: `kubectl apply -k .` or `kustomize build .`. No Helm, nothing to install first. Paths
below are relative to this directory (`deploy/k8s/`). The environment variable reference, backups,
upgrades and sizing notes are in [`../../README.md`](../../README.md).

## Shapes: single replica, multiple replicas, optional renderer

- **`base/`** is one replica behind a `ReadWriteOnce` volume, a ClusterIP Service and an Ingress that
  terminates TLS and talks plain HTTP to the pod, with `strategy: Recreate`. `kubectl apply -k .` (this
  directory's `kustomization.yaml` is a one-line pointer at `base/`) deploys it.
- **`overlays/ha/`** is the multi-replica choice, `kubectl apply -k overlays/ha`. Same app, Secret, Service,
  Ingress and ConfigMap, patched for two replicas.
- **`components/renderer/`** is the optional document renderer, added on top of either shape (below).

Pick one of `base/` or `overlays/ha/` per namespace: the overlay builds `base/` in, it does not sit
alongside it.

A namespace shared with other applications is supported: the pods set `enableServiceLinks: false`, so a Service in
the namespace named `api` or `nabu` cannot inject `API_PORT` or `NABU_PORT`-style variables into the containers.

### What `base/` deploys

A Deployment with one replica (non-root, `readOnlyRootFilesystem`, all capabilities dropped, a
`RuntimeDefault` seccomp profile), a PersistentVolumeClaim mounted at `/data`, an `emptyDir` at `/tmp`,
probes on `/api/health` (startup, liveness) and `/api/ready` (readiness), a ConfigMap, a Service and an
Ingress. The Secret is created by you (below). Nabu never terminates TLS itself, so your ingress controller
must.

**Do not raise `replicas` on `base/`; use `overlays/ha` instead.** `/data` (uploaded files and their
renditions) is plain files on one `ReadWriteOnce` volume with one writer. Two pods mounting that volume,
or both writing into one tree, is not safe. Migrations are not the blocker: they run on every start under
a Postgres advisory lock, so two pods racing to migrate is already safe.

### What `overlays/ha` adds

| What | How | Why |
|---|---|---|
| `replicas: 2` | `overlays/ha/deployment-ha.yaml` | The multi-replica shape. Raise it (and the PodDisruptionBudget) if you want more. |
| `ReadWriteMany` volume | `overlays/ha/pvc-rwx.yaml` patches `accessModes` | Every pod now reads and writes the same `/data` tree at once. Needs a storage class that provides RWX: NFS, CephFS or Longhorn with RWX share-manager volumes. A plain block-storage class (most cloud defaults, most local-path provisioners) does **not**; set `storageClassName` in the patch and check `kubectl get storageclass` before applying. **A claim's `accessModes` cannot be changed after it exists**, so decide before the first install: applying this overlay over a cluster that already ran `base/` fails with "spec is immutable". To move later, scale to zero, copy `/data` off, delete the old claim, apply the overlay and copy the data back. |
| `strategy: RollingUpdate`, `maxUnavailable: 0`, `maxSurge: 1` | `overlays/ha/deployment-ha.yaml` | Safe for the volume now that it supports concurrent writers; the rollout never drops below the desired number of ready pods. It runs replicas + 1 pods at the peak, so the cluster needs room for one more pod. Whether old and new *versions* may overlap is a database question: see "Upgrades differ". |
| Pod anti-affinity on `kubernetes.io/hostname` | `overlays/ha/deployment-ha.yaml` | A *preference* to place the replicas on different nodes, so one node failing costs one pod. It is deliberately not a hard rule: with a required rule, a two-node cluster running two replicas has no node free for the rolling update's extra pod and the rollout deadlocks. |
| `PodDisruptionBudget`, `minAvailable: 1` | `overlays/ha/pdb.yaml` | Bounds *voluntary* disruption (node drain, autoscaler scale-down) to one pod at a time. It does not protect against a node dying outright; spreading the pods over nodes does that. |
| `TRUST_PROXY: "1"` | `overlays/ha/configmap-trustproxy.yaml` | The base already ships this hop count, so the patch is a no-op value change kept explicit on purpose: every pod must trust `X-Forwarded-*` from your ingress specifically. Do not put another proxy between the ingress and the Service. Use `2` if a cloud load balancer sits in front of the ingress controller, or a CIDR list. |
| Probes | unchanged, inherited from `base/` | `/api/health` and `/api/ready` behave identically per pod. |

**What `overlays/ha` needs from the cluster:** a storage class that provides `ReadWriteMany`; room for one
more pod than `replicas` during a rollout (`maxSurge: 1`); and, to get real resilience to a node failure,
at least two schedulable worker nodes (with one node it still runs, but both replicas share that node's
fate). Two nodes are enough for rollouts and drains: spreading is a preference, not a rule.

**Sticky sessions are not required.** Sessions are random tokens validated against Postgres on every
request, so any pod can serve any request for any signed-in person.

**Background work is safe on every replica.** The parsing queue claims jobs with `FOR UPDATE SKIP
LOCKED`; the periodic housekeeping loop and the daily email digest take a Postgres advisory lock for the
duration of a tick, so with several replicas all tick but only one does the work; migrations take their
own advisory lock on start. No coordination beyond Postgres is needed.

**Sign-in request limits are per pod.** The per-address limits on sign-in and setup are counted in each
pod's memory, so an attacker spread across N pods gets up to N times the configured limit before the
account lockout (stored in Postgres, shared by every pod) catches them.

**Upgrades differ.** `base/` stops the old pod before the new one starts (a few seconds with no pod).
`overlays/ha` adds a new pod, waits for its startup and readiness probes, then removes an old one,
repeating until all are new: no gap, at the cost of briefly running two image versions against the same
database and `/data`. That overlap is only safe when the new version's migrations are compatible with
the old version still running: the first new pod migrates the database before it listens, while old pods
keep serving from the migrated schema. Migrations are forward-only and an old image against a newer
schema is not supported in general, so **read the release notes**: when a release says its migration is not
backward compatible, upgrade that release with zero overlap instead (scale to zero or switch the strategy
to `Recreate` for that one rollout, then restore it). `base/` is always zero overlap.

## Shared Postgres

Nabu does not bundle a database on this path. Postgres is its only datastore and on Kubernetes that means
a server you already run, with **one database and one role for Nabu**, never a schema shared with another
application. It needs PostgreSQL 14 or newer with the `pgvector` and `pg_trgm` extensions available.
`create-db.sql` (next to this file) creates the role, the database and both extensions; run it once, as a superuser
(pgvector is not a trusted extension, so an ordinary role cannot create it):

```bash
psql "$POSTGRES_ADMIN_URL" -v db_password='<a strong, generated password>' -f create-db.sql
```

Then put the resulting URL in the Secret. This is identical for `base/` and `overlays/ha`: the database
was always multi-writer-safe, only `/data` needs the overlay's RWX patch.

## Before you apply

Edit these in `base/` (whichever shape you deploy, `overlays/ha` inherits them):

| Where | What |
|---|---|
| `base/kustomization.yaml` | `images:` sets the registry and version of the image, `newName` and `newTag`. It is set to the published image and the version of the release it came with. The Deployment names its image just `nabu`; this entry is the only place that says where it comes from. To change the version, run `kustomize edit set image nabu=ghcr.io/root-chain-ventures-llc/nabu:X.Y.Z`. A digest works too. |
| `base/configmap.yaml` | `BASE_URL`, the public `https://` URL. It controls the cookie `Secure` flag, the CSP's HSTS and `upgrade-insecure-requests`, and the origin the CSRF check accepts; it does **not** make the app speak TLS. Also `MAX_UPLOAD_MB`. |
| `base/ingress.yaml` | The host (twice: `spec.tls[0].hosts` and `spec.rules[0].host`), `ingressClassName`, how the certificate is issued, and `proxy-body-size` (keep it above `MAX_UPLOAD_MB`). |
| `base/pvc.yaml` | `storage` and, if the cluster has no usable default, `storageClassName` (`overlays/ha` needs one that supports `ReadWriteMany`). |

Then create the Secret out of band: `base/secret.example.yaml` is a template with no values and is
deliberately **not** in any `kustomization.yaml`, so no credential can reach a repository through it.

```bash
kubectl create namespace nabu
kubectl -n nabu create secret generic nabu \
  --from-literal=DATABASE_URL="postgres://nabu:<password>@<postgres-host>:5432/nabu" \
  --from-literal=NABU_SECRET_KEY="$(openssl rand -base64 32)"
kubectl apply -k .                      # base/, one replica
# or
kubectl apply -k overlays/ha            # multiple replicas
```

`DATABASE_URL` and `NABU_SECRET_KEY` are the two required secrets in both shapes. The first administrator
is created from the running app's setup screen (open only while no account exists; set `SETUP_TOKEN` in the
Secret if the service is reachable before you finish), not from an environment variable.

`NABU_SECRET_KEY` (32 bytes, base64 or 64 hex characters) encrypts every secret saved in Settings (SMTP
password, AI provider keys, single sign-on client secret). Every pod reads the same value from the one
`nabu` Secret, so replicas never disagree about it. **Back it up separately from your database backups**:
lose it and those stored secrets become unreadable (re-enter them in the app). To rotate it, set
`NABU_SECRET_KEY_PREVIOUS` to the old value next to the new `NABU_SECRET_KEY`, roll the deployment, and
re-save each stored secret in the app.

Everything else (email, AI providers, single sign-on, parsing) is configured in the app by an
administrator and stored in the database.

## Document renderer (optional)

Without it Office files show a built-in sanitized HTML view and legacy formats are download-only. With it
they get a faithful PDF view and become searchable. Add the component from a kustomization of your own:

```yaml
# my-nabu/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - ../path/to/deploy/k8s/overlays/ha     # or .../base
components:
  - ../path/to/deploy/k8s/components/renderer
images:
  - name: nabu
    newName: ghcr.io/root-chain-ventures-llc/nabu
    newTag: "0.1.2"
```

(`kubectl apply -k my-nabu`; `kustomize build --load-restrictor LoadRestrictionsNone my-nabu` when the
paths leave the directory.) The component adds a `nabu-renderer` Deployment (Gotenberg 8, non-root,
read-only root filesystem) and Service, sets `RENDERER_URL=http://nabu-renderer:3000` on the Nabu
ConfigMap, and adds a NetworkPolicy that lets only the Nabu pods reach the renderer and gives it **no
egress at all**. The renderer opens untrusted documents with LibreOffice, which follows links and fetches
linked content when a document asks; it must not be able to reach the cluster or the internet. The policy
only works on a CNI that enforces NetworkPolicy, so check yours. Memory: the renderer is limited to 2 Gi.

## Image

The image is public: `ghcr.io/root-chain-ventures-llc/nabu`, tagged `X.Y.Z` and `vX.Y.Z` (and `latest` for
stable releases). It can be pulled without logging in, so no pull secret is needed. If your cluster mirrors
images into a private registry, change `newName` in `base/kustomization.yaml` and add an `imagePullSecrets`
entry in a patch of your own.

## Upgrading

Bump `newTag` (or run `kustomize edit set image`) and re-apply. Take a Postgres backup (`pg_dump`) and a
snapshot of the `/data` volume first; migrations run on start and are forward-only, so the way back is
restoring that backup. See "Upgrades differ" above for how each shape rolls.

**A volume with the wrong owner.** A volume provisioned without `fsGroup`, or restored from a backup
taken as root, can come up with `/data` owned by the wrong user, which fails every write with `EACCES`.
Fix it once with a throwaway pod running as root against the same claim:

```bash
kubectl -n nabu run nabu-chown --rm -it --restart=Never --image=busybox \
  --overrides='{"spec":{"securityContext":{"runAsUser":0},"containers":[{"name":"nabu-chown","image":"busybox","command":["chown","-R","1000:1000","/data"],"volumeMounts":[{"name":"data","mountPath":"/data"}]}],"volumes":[{"name":"data","persistentVolumeClaim":{"claimName":"nabu-data"}}]}}'
```

(With `base/`'s `ReadWriteOnce` volume, scale the Deployment to zero first; the claim can be held by one
pod at a time.)

## Troubleshooting

**Pod crashlooping on a write.** `readOnlyRootFilesystem: true` is set, with an `emptyDir` at `/tmp`.
Everything the app writes lands in `/data` or `/tmp`; the logs name the path.

**`/api/ready` returns 503.** Postgres is unreachable: check `DATABASE_URL` in the Secret and that the
server and the `nabu` database and role are up. `/api/health` still answers 200 in this state: the process
is fine, only its dependency is down, and a restart would not help.

**Out-of-memory kills (`OOMKilled`).** The default memory limit assumes the default parsing settings
(`PARSE_CONCURRENCY` 2, `PARSE_WORKER_MAX_HEAP_MB` 768). If you raise either, raise the limit by the
formula in [`../../README.md`](../../README.md), "OCR and parsing memory".

**`overlays/ha` pods stuck `Pending`.** Either the storage class does not provide `ReadWriteMany`, or the
cluster has no room for the extra pod a rolling update adds (the overlay's anti-affinity is only a
preference, so spare *nodes* are not required, but spare CPU and memory for one more pod are: the requests
are 200m / 512Mi, the limits 2 / 3Gi).

**Which build is running.** Settings, About (any signed-in account), or `GET /api/version` with a session.
