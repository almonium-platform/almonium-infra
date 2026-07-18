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
| Applications | Almonium (prod and staging), FamSub |
| Frontends and static sites | Almonium FE, FamSub FE, TG Voices |
| Personal services | Emby and Syncthing |

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
- **Almonium** and **FamSub** backend/frontend playbooks are intended to be
  invoked by their application CI pipelines with an image tag and registry
  credentials. Backend deployments use blue/green slots and a health check.

The GitHub workflows in this repository cover the shared stacks and personal
services. The application deployment playbooks are kept here so application
repositories can invoke the same server-side conventions.

## Secrets and access

- Encrypted `vault*.yaml` files are committed. Their matching `*.schema.yaml`
  files document the shape only and must never contain real values.
- GitHub Actions receives SSH and vault passwords through GitHub Secrets.
- RabbitMQ is internal to Docker's `broker-net`. Its AMQP and management ports
  bind only to localhost for troubleshooting through SSH, for example:

  ```bash
  ssh -L 15672:127.0.0.1:15672 oci
  ```

- Persistent data is outside disposable containers: PostgreSQL backups live in
  `/opt/db/backups`; Emby and media data live on host-mounted paths.

## PostgreSQL backups

The database role creates fresh custom-format dumps for every tenant marked
`backup: true`, then stores an encrypted restic snapshot in Backblaze B2. The
B2 key ID, key, and restic repository password are in the encrypted DB vault;
the bucket, schedule, and retention policy are in
`ansible/vars/stacks/db/vars.yaml` under `db_backup_defaults`.

The `db-backup.timer` runs daily at 03:15 server time with up to ten minutes of
random delay. It keeps seven local dumps per database and retains seven daily,
four weekly, and twelve monthly remote snapshots.

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
