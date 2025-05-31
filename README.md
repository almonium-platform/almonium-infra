# Almonium Infrastructure

This repository contains the infrastructure configurations and deployment automation for the Almonium platform services.
It leverages Docker, Docker Compose, Traefik, and GitHub Actions to provide a reproducible and automated hosting
environment.

## Overview

The core components managed by this infrastructure setup include:

* **Traefik Proxy:** Acts as the edge router, handling incoming traffic, SSL termination (via Let's Encrypt with Porkbun
  DNS-01), and reverse proxying to backend services.
* **Application Deployment (`almonium-be`):** Uses a blue/green deployment strategy orchestrated by `deploy.sh` and
  templated with `docker-compose.template.yaml`.
* **RabbitMQ:** Deployed as a Docker container for message queuing.
* **Static Sites:** Configurations for serving static frontend applications (e.g., `almonium.com`,
  `adoptik.almonium.com`, `voices.almonium.com`) via Traefik. *(Update this once migrated)*

## Directory Structure

* `.github/workflows/`: Contains GitHub Actions workflows for:
    * `deploy-traefik.yaml`: Deploys/updates the Traefik proxy stack.
    * `deploy-rabbitmq.yaml`: Deploys/updates the RabbitMQ service.
* `traefik/`:
    * `docker-compose.yaml`: Defines the Traefik service and any co-located test/static site services.
    * `acme.json`: (Gitignored) Stores Let's Encrypt certificates.
* `rabbitmq/`:
    * `docker-compose.yaml`: Defines the RabbitMQ service.
* `deploy.sh`: Core shell script for blue/green deployment of the `almonium-be` application. Triggered by the
  `almonium-be` repository's CI/CD pipeline.
* `docker-compose.template.yaml`: Docker Compose template for the `almonium-be` application, populated by `deploy.sh`.
* `README.md`: This file.

## Prerequisites for a New Server

1. Linux VM (e.g., Ubuntu 22.04 LTS).
2. Docker and Docker Compose plugin installed.
3. `git` installed.
4. User `almonium` (or your chosen deployment user) created with sudo privileges and added to the `docker` group.
5. SSH key for `almonium` user configured for passwordless login from GitHub Actions (public key on server, private key
   in `CLOUD_KEY` GitHub Secret).
6. SSH deploy key (read-only) for the `almonium` user added to this `almonium-infra` repository to allow `git clone`.
7. DNS A records for all domains (`api.almonium.com`, `almonium.com`, etc.) pointing to the new server's IP.

## Initial Setup on a New Server

1. **Update GitHub Secrets:**
    * In both `almonium-infra` and `almonium-be` repositories, update `CLOUD_HOST` to the new server's IP.
    * Update `CLOUD_KEY` if using a new SSH key.
    * Ensure `PORKBUN_API_KEY` and `PORKBUN_SECRET_KEY` are set in `almonium-infra` secrets.
    * Ensure all application-specific `CONF_*` secrets/vars are set in `almonium-be` secrets/vars.
2. **Bootstrap the VM:**
   ```bash
   # As root or sudo user on the new VM:
   apt update && apt upgrade -y
   apt install -y git curl docker.io docker-compose-plugin
   systemctl enable docker && systemctl start docker
   adduser --disabled-password --gecos "" almonium # Or your user
   usermod -aG sudo almonium
   usermod -aG docker almonium
   # Log out and log back in as 'almonium' or run 'newgrp docker'
   ```
3. **Clone this Repository (as `almonium` user):**
   ```bash
   cd /home/almonium
   git clone git@github.com:almonium-platform/almonium-infra.git infra
   cd infra
   ```
4. **Deploy Core Infrastructure via GitHub Actions:**
    * Trigger the "Deploy Traefik Proxy" workflow from the `almonium-infra` GitHub Actions tab.
    * Trigger the "Deploy RabbitMQ Service" workflow.
5. **Deploy Application:**
    * Trigger the "Build & Deploy" workflow from the `almonium-be` GitHub Actions tab (or push to its `main` branch).

## Deployment Process (Application)

The `almonium-be` application is deployed using a blue/green strategy:

1. The CI/CD pipeline in the `almonium-be` repository builds a new Docker image tagged with the Git SHA.
2. The `deploy` job in that pipeline SSHes into the server and executes `/home/almonium/infra/deploy.sh <GIT_SHA>`.
3. `deploy.sh` determines the next slot (blue or green), pulls the new image, and starts it using
   `docker-compose.template.yaml`.
4. After a health check on the new slot, the script stops the previous slot. Traefik automatically routes traffic to the
   new, healthy instance based on Docker labels.
