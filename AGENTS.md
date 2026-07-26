# Repository workflow

## Almonium application boundaries

This repository owns the operational platform for neighboring application
repositories, not their source-level configuration contracts:

- `../almonium-be` owns the Spring Boot application, its environment-variable
  bindings/validation, `.env.template`, Liquibase changes, and backend GitHub
  Actions. Its CI builds the ARM64 image and invokes
  `ansible/playbook-deploy-almonium-be.yaml` for deployment.
- `../almonium-fe` owns the Angular client, API contract consumption, and
  browser-facing environment configuration. Its CI builds the ARM64 image and
  invokes `ansible/playbook-deploy-almonium-fe.yaml`.
- `../almonium-mobile` owns the Expo SDK 54 React Native client for iOS and
  Android. It consumes the backend with Firebase ID-token bearer
  authentication and is distributed through native/Expo build and release
  tooling; it is not currently deployed as a server container by this
  repository. Keep mobile public configuration in that repository and do not
  place native provider secrets or mobile app credentials in infra vaults
  unless a future release workflow explicitly requires them.

For an application configuration-key change, coordinate a separate commit in
the relevant application repository for its binding/template and a focused
infra commit for the Compose/Ansible mapping, applicable vault schema, and
encrypted vault value. Do not invent application variables solely in infra, do
not add secrets to an application template, and never expose decrypted vault
contents in source, logs, or tickets. Read the target repository's `AGENTS.md`
before editing it.

- Application deploy playbooks and templates take effect only when the relevant
  application deployment is run; coordinate that rollout rather than assuming
  an infra push redeploys an application.
- Production and staging share one Oracle Cloud ARM host but have separate
  application containers, database users/databases, RabbitMQ users/vhosts, and
  encrypted environment values. Preserve this isolation when editing shared
  topology.
- Treat SSH access as an operations/debugging mechanism, not standing
  authorization for an ad-hoc production deployment. Use the reviewed GitHub
  Actions/Ansible path unless the user explicitly requests an operational
  intervention.

After completing a requested implementation and relevant verification, stage only
the files changed for that task and create a focused commit. Do not include
unrelated working-tree changes or amend an existing commit unless explicitly
asked. Report the commit hash in the handoff.

Leave changes uncommitted only when the user explicitly asks for that, or when
the work is blocked or awaiting a material user decision.
