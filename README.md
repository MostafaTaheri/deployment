# AloHome Deployments

Local infrastructure for the AloHome API: Keycloak, PostgreSQL, Redis and RabbitMQ, run with Docker Compose.

> **Local development only.** Keycloak runs in dev mode on its embedded H2 database and every password is a local default. Do not use this in production.

## Services

| Service    | Image                          | Host port(s)                 | Default credentials            |
|------------|--------------------------------|------------------------------|--------------------------------|
| Keycloak   | `quay.io/keycloak/keycloak`    | 8020 (UI/API), 9020 (mgmt)   | `admin` / `admin`              |
| PostgreSQL | `postgres`                     | 5432                         | `postgres` / `@dmin2026` (db `alohome`) |
| Redis      | `redis/redis-stack-server`     | 6379                         | none                           |
| RabbitMQ   | `rabbitmq:3-management`        | 5672 (AMQP), 15672 (UI)      | `admin` / `admin`              |

Ports and credentials match `src/AloHome.Api/appsettings.Development.json` in the API project.

## Prerequisites

- Docker with the Compose plugin
- bash (for the realm setup script)

## Quick start

```bash
cp .env.example .env            # optional: all values have defaults in docker-compose.yml
docker compose up -d            # start everything

# Create or update the "alohome" realm (safe to run again)
KC_CLIENT_SECRET=<secret> KC_SERVICE_PASSWORD=<password> ./keycloak/setup-alohome-realm.sh
```

- Keycloak admin console: http://localhost:8020/admin
- RabbitMQ management: http://localhost:15672

The realm script creates the confidential `alohome-api` client, the `alohome-service` user, the `Admin` realm role, and enables legacy token exchange, which the API's `KeyCloakRestClient` needs. Use the same client secret and service password in the API's `ExternalServices:Keycloak` settings.

## Configuration

Copy [.env.example](.env.example) to `.env` to override versions, ports and Keycloak admin credentials. `.env` is git-ignored.

The realm script also reads optional variables such as `KC_CONTAINER`, `KC_REALM`, `KC_CLIENT_ID`, `KC_SERVICE_USER`, `KC_ADMIN_USERNAME` and `KC_ADMIN_PASSWORD`. Generated secrets are stored in `keycloak/.alohome-dev-secrets`, which is also git-ignored.

## Layout

```
.
├── docker-compose.yml
├── .env.example
└── keycloak/
    ├── setup-alohome-realm.sh   # idempotent realm setup
    └── realms/                  # realm export JSON, imported on startup (existing realms are skipped)
```

## Common commands

```bash
docker compose ps               # status and health
docker compose logs -f keycloak # follow logs for a service
docker compose down             # stop, keep data
docker compose down -v          # stop and delete all data volumes (full reset)
```
