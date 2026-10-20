# Almonium Infrastructure

Infrastructure repository for a personal Oracle Cloud server hosting several
independent projects and a small media stack. It is intentionally a single
server orchestrator, not a reusable platform or a Kubernetes-style control
plane.

The server runs Docker services, while Ansible applies configuration and
GitHub Actions triggers the relevant deployment playbooks.

## What runs here

| Area | Services |
| --- | --- |
| Edge | Traefik, HTTPS certificates via Porkbun DNS-01 |
| Shared application services | PostgreSQL with PgBouncer, RabbitMQ |
| Applications | Almonium (prod and staging), Almonium Books (prod and staging), FamSub, Secundor sync |
| Frontends and static sites | Almonium FE, FamSub FE, TG Voices, Cosmos |
| Personal services | Emby and Syncthing |

The Almonium workspace also includes `almonium-mobile`, an Expo/React Native
iOS and Android client. It uses the shared Almonium API with Firebase bearer
authentication and is distributed through Expo/EAS and native app stores; it is
not currently a server-hosted service in this repository.

Shared services are deliberately shared by projects, with separate PostgreSQL
databases/users and RabbitMQ vhosts/users per application environment.

## Layout

```text
ansible/
  playbook-*.yaml       Deployment and synchronization entry points
  roles/                Reusable app-slot, database, and RabbitMQ roles
  vars/                 App/stack configuration and encrypted vaults
services/               Compose definitions for application-adjacent stacks
traefik/                Edge proxy Compose definition
nginx-configs/          Shared frontend Nginx configuration
.github/workflows/      Push/manual deployment entry points
```

## Deployment model

`main` is the desired state. The server checkout lives at
`/home/almonium/infra`.

- **Sync Infra** updates that checkout after every push to `main`. Keep it: it
  makes the checkout useful for manual operations and for application CI that
  deploys from it.
- **Traefik** updates its checkout itself, then runs Docker Compose.
- **PostgreSQL** and **RabbitMQ** are applied by Ansible from the GitHub runner.
  Their roles manage shared networks, persistent state, tenants/vhosts, and
  credentials.
- **Media Stack** and **TG Voices** first update the server checkout, then run
  Docker Compose. They do not rely on the separate sync workflow winning a race.
- **Secundor** (`secundor.almonium.com`) is one container serving the public site,
  the optional sync API and the desktop downloads. Clients encrypt before upload,
  so its database holds only ciphertext. The Secundor repository's CI builds the
  ARM64 image and runs `ansible/playbook-deploy-secundor.yaml` (blue/green on local
  ports 8891/8892). The project was called EonKeep before. `eonkeep.almonium.com`
  still serves `/api` and `/downloads` for builds installed under that name, and
  its other pages redirect.
- **Cosmos** (`cosmos.almonium.com`) is a private reader for a personal
  transcript collection, behind an access code; it also transcribes new
  YouTube episodes through Groq. The cosmos repository's `deploy.sh` copies its
  source to `/home/almonium/cosmos/src`, writes `/home/almonium/cosmos/.env`
  (`SECRET_CODE`, `GROQ_API_KEY`), builds the image on the host and recreates
  the container. Its data lives in `/home/almonium/cosmos/data` and is not
  backed up by the DB backup job. The **Deploy Cosmos** workflow applies
  `services/cosmos` itself.
- **Almonium** and **FamSub** backend/frontend playbooks are intended to be
  invoked by their application CI pipelines with an image tag and registry
  credentials. Backend deployments use blue/green slots and a health check. If
  Docker on the host is managed by Snap, start it locally first with
  `sudo snap start docker`.

The GitHub workflows in this repository cover the shared stacks and personal
services. The application deployment playbooks are kept here so application
repositories can invoke the same server-side conventions.

## Secrets and access

- Encrypted `vault*.yaml` files are committed. Their matching `*.schema.yaml`
  files document the shape only and must never contain real values.
- GitHub Actions receives SSH and vault passwords through GitHub Secrets.
- Ansible workflows require `CLOUD_KNOWN_HOSTS`, containing the reviewed
  OpenSSH `known_hosts` entry for each inventory host. The Traefik SSH workflow
  requires `CLOUD_HOST_FINGERPRINT`, containing the reviewed SHA-256 host-key
  fingerprint. Update these values through a separate trusted channel when a
  host key is deliberately rotated; do not generate them with `ssh-keyscan`
  inside a workflow.
- If a schema file contains a credential-shaped value, treat it as exposed:
  revoke or rotate it at the provider, replace it in the encrypted vault, and
  remove it from Git history with the repository owners' agreed history-rewrite
  procedure.
- RabbitMQ is internal to Docker's `broker-net`. Its AMQP and management ports
  bind only to localhost for troubleshooting through SSH, for example:

  ```bash
  ssh -L 15672:127.0.0.1:15672 oci
  ```

- Persistent data is outside disposable containers: PostgreSQL backups live in
  `/opt/db/backups`; Almonium Books uploads live under
  `/home/almonium/books/<environment>/media`; Emby and media data live on
  host-mounted paths.

Almonium Books uses the existing PostgreSQL and RabbitMQ containers, with a
separate logical database/user and vhost/user for each environment. Production
contains the catalogue and is backed up. Staging is intentionally disposable,
is not backed up, and should contain only the sample editions required for
migration and processing experiments.

Reviewed editions reach staging and production by promotion from another Books
environment, never by reprocessing. Each environment accepts the promotion
secret under `books.promotion_secrets.<environment>` in the shared Almonium
vault; `promotion_targets` in `ansible/vars/apps/books/vars.yaml` says where an
environment may push (staging to production, production nowhere). A laptop
that promotes to staging carries staging's secret in its local `.env`.

Audio clips for the dictionary live in one Cloudflare R2 bucket,
`almonium-audio`, shared by production and staging: clips are immutable and
keyed by content, so the two environments never disagree about an object. The
backend reaches it through the S3 API with the `almonium-audio-backend` token,
whose key pair sits under `audio.s3` in the shared Almonium vault; the endpoint
and bucket name are plain values in `ansible/vars/apps/almonium/vars.yaml`.

The Books processor also reads the backend's `lexicon` schema of its own
environment to resolve lexeme and sense ids, through a read-only PostgreSQL
role (`almonium_books_lexicon_<environment>`) that can connect to the backend
database and select from that one schema and nothing else. The DB stack
declares it under `postgres_reader_grants` in `ansible/vars/stacks/db/vars.yaml`
and creates the role, the schema and its grants; the password is
`postgres_reader_passwords` in the DB vault and `books.lexicon_db.password` in
each environment's Almonium vault. Adding or rotating one is therefore a vault
edit followed by the **Deploy Postgres DB** workflow, then a Books deployment to
pick up `LEXICON_DATABASE_URL`.

## Monitoring

One Grafana Alloy container (`/opt/monitoring`, role `deploy_monitoring`)
ships everything to the Grafana Cloud stack at <https://almonium.grafana.net>:

- host metrics (CPU, memory, disk, network, pressure) and per-container CPU,
  memory, network and OOM events, trimmed to fit the free tier's 10k series;
- the Almonium backend's Micrometer metrics, scraped over `proxy-net` from
  `/api/v1/actuator/prometheus` on whichever slots are running. Traefik refuses
  that path from outside the host (`*-metrics` router in the backend route);
- RabbitMQ's built-in Prometheus plugin at `rabbitmq:15692`;
- logs from Almonium's containers, the services it depends on (Traefik,
  PostgreSQL, PgBouncer, RabbitMQ) and Alloy itself, labelled `container`,
  `app`, `env`, `slot` and `level` (container `almonium_books_worker_prod_blue`
  becomes `app=almonium_books_worker, env=prod, slot=blue`). Grafana Cloud
  keeps them for 14 days, longer than the host's Docker log rotation. The
  other tenants report resource metrics only; to ship one's logs, add its
  `app` to the `discovery.relabel "logs"` filter in the Alloy config.

Grafana itself is configured from `grafana/` in this repository, applied with
`GRAFANA_TOKEN=<Editor service-account token> grafana/apply.sh` (every call is
an upsert, and resources stay editable in the UI; export UI edits back here):

- `dashboards/almonium-overview.json`: HTTP traffic, latency and failing
  endpoints, backend and Books error logs, JVM and connection pool, host,
  PostgreSQL (connections, sizes, transactions, oldest open transaction, cache
  hits, deadlocks), host, per-container memory/CPU/restarts, RabbitMQ queues
  and dead letters, and outside-in uptime with TLS expiry;
- `alerting/`: 22 rules in folder Almonium (critical: prod backend down,
  public endpoint failing, telemetry silent, 5xx rate, disk, memory,
  PostgreSQL down; warning: error logs, OOM kills, crash loops, heap, DB pool
  waits, dead letters, backlog, missing consumers, RabbitMQ alarms, TLS expiry,
  staging down, PostgreSQL connections, long transactions, deadlocks), sent
  by email to tech@almonium.com (critical repeats every 2 h, warnings 12 h). A rule
  whose query fails keeps its last state (`execErrState: KeepLast`): Grafana
  Cloud's own query path sometimes times out, and alerting on that mailed a
  DatasourceError for every flap. The "Host telemetry stopped" rule still
  catches data that genuinely stops arriving.

Synthetic Monitoring probes the public URLs from Frankfurt (and London for the
production API): `api`, `almonium.com`, `books` and the staging API, about
65k of the free tier's 100k monthly executions. The checks live in Grafana
(Testing & synthetics > Synthetics), not in this repository.

PostgreSQL statistics come from Alloy's built-in collector, logged in as the
role `monitoring` (`postgres_monitoring_role` in the DB vars). It holds
`pg_monitor`, which reads server statistics and database sizes but no table
data, and connects only to the maintenance database `postgres`. The **Deploy
Postgres DB** workflow creates the role; its password is in both the DB vault
(`postgres_monitoring_password`) and the monitoring vault
(`monitoring_postgres_password`), with the same value. To rotate it, change
both, then run both deploy workflows.

The write token (`monitoring_grafana_cloud_token`, scopes `metrics:write` and
`logs:write` only) lives in `ansible/vars/stacks/monitoring/vault.yaml` under
the `monitoring` vault id; GitHub Actions has its password as
`ANSIBLE_VAULT_PASSWORD_MONITORING`. The **Deploy Monitoring** workflow applies
the stack. Alloy's own UI binds to localhost: `ssh -L 12345:127.0.0.1:12345 oci`.

## PostgreSQL backups

The database role creates fresh custom-format dumps for every tenant marked
`backup: true`, then stores an encrypted restic snapshot in Backblaze B2. The
B2 key ID, key, and restic repository password are in the encrypted DB vault;
the bucket, schedule, and retention policy are in
`ansible/vars/stacks/db/vars.yaml` under `db_backup_defaults`.

The `db-backup.timer` runs daily at 03:15 server time with up to ten minutes of
random delay. It keeps seven local dumps per database and retains seven daily,
four weekly, and three monthly remote snapshots. Three months is a promise, not
a default: the public account-deletion page and the Privacy Policy tell users a
deleted account leaves the backups within 90 days. With three monthly
snapshots it is gone from all of them within about 62 days. Raising `keep_monthly` means changing those pages first.

To inspect or force a backup on the DB host:

```bash
ssh oci 'sudo systemctl list-timers db-backup.timer --no-pager'
ssh oci 'sudo systemctl start db-backup.service'
ssh oci 'sudo journalctl -u db-backup.service -n 50 --no-pager'
```

The restic password is required to restore data. Keep it in a password manager
as well as the encrypted vault; it cannot be recovered from Backblaze.

## Operating it

For routine changes, modify the relevant Compose definition, Ansible playbook,
or vars file; commit and push to `main`. The path-filtered workflow applies the
affected shared/personal stack. Run a workflow manually from GitHub Actions
when a redeploy is needed without a source change.

Before changing encrypted values, use the corresponding vault ID and retain the
existing vault label. Install Ansible dependencies with:

```bash
ansible-galaxy collection install -r ansible/requirements.yaml
```

### Editing Vault values

Ansible Vault encrypts the complete YAML file. For example, FamSub production
uses the `fam_sub_prod` Vault ID:

```bash
# Generic form
EDITOR=nano ansible-vault edit --vault-id <vault-id>@prompt <encrypted-vault-file>

# Almonium production (most commonly used)
EDITOR=nano ansible-vault edit --vault-id almonium_prod@prompt \
  ansible/vars/apps/almonium/vault.prod.yaml

# Almonium staging
EDITOR=nano ansible-vault edit --vault-id almonium_staging@prompt \
  ansible/vars/apps/almonium/vault.staging.yaml

# Almonium shared
EDITOR=nano ansible-vault edit --vault-id almonium_shared@prompt \
  ansible/vars/apps/almonium/vault.shared.yaml

# FamSub production
ansible-vault view --vault-id fam_sub_prod@prompt \
  ansible/vars/apps/fam_sub/vault.prod.yaml
EDITOR=nano ansible-vault edit --vault-id fam_sub_prod@prompt \
  ansible/vars/apps/fam_sub/vault.prod.yaml
```

Vault IDs and their encrypted files are:

| Vault ID | Encrypted file |
| --- | --- |
| `almonium_prod` | `ansible/vars/apps/almonium/vault.prod.yaml` |
| `almonium_staging` | `ansible/vars/apps/almonium/vault.staging.yaml` |
| `almonium_shared` | `ansible/vars/apps/almonium/vault.shared.yaml` |
| `fam_sub_prod` | `ansible/vars/apps/fam_sub/vault.prod.yaml` |
| `secundor_prod` | `ansible/vars/apps/secundor/vault.prod.yaml` |
| `db` | `ansible/vars/stacks/db/vault.yaml` |
| `rabbitmq` | `ansible/vars/stacks/rabbitmq/vault.yaml` |

The Vault ID is the final field in the encrypted file's first line, which
starts with `$ANSIBLE_VAULT;`. Test canaries under `ansible/vault_canaries/`
also use the IDs `all`, `prod`, and `staging`; they are not application
configuration files.

For example, to edit another operational vault:

```bash
EDITOR=nano ansible-vault edit --vault-id db@prompt ansible/vars/stacks/db/vault.yaml
EDITOR=nano ansible-vault edit --vault-id rabbitmq@prompt \
  ansible/vars/stacks/rabbitmq/vault.yaml
```

If the password is stored in a local, permission-protected file, replace
`@prompt` with `@~/.ansible/vault-fam-sub-prod` (and use the same file when
running the relevant playbook). The other Vault IDs are the labels in the
first line of each encrypted file, such as `db`, `rabbitmq`,
`almonium_prod`, and `almonium_staging`.

To add a value, first add its key to the matching `*.schema.yaml` with an empty
string, then run `ansible-vault edit` and add the real value to the encrypted
`vault*.yaml`. Never put the real value in the schema, a command-line argument,
or shell history. After editing, verify that the encrypted file still opens:

```bash
ansible-vault view --vault-id fam_sub_prod@prompt \
  ansible/vars/apps/fam_sub/vault.prod.yaml >/dev/null
```

## Bootstrapping a new host

Before the first deployment, use the bootstrap playbook once from the machine
that can SSH to the fresh host with a sudo-capable provisioning account:

```bash
cd ansible
ansible-galaxy collection install -r requirements.yaml
ansible-playbook -i inventory/hosts.ini playbook-bootstrap-host.yaml \
  --limit almonium -e ansible_user=<provisioning-user> --become
```

It installs Docker (including Compose) and Git, creates the `almonium` user,
adds it to the `docker` group, copies the provisioning user's authorized SSH
keys by default, creates the required state directories, and creates
`proxy-net`, `db-net`, and `broker-net`. Set
`-e bootstrap_copy_authorized_keys=false` when the `almonium` user's SSH keys
are managed separately.

The database and RabbitMQ roles also ensure Docker is installed and running,
so existing hosts remain deployable without first running the bootstrap.
