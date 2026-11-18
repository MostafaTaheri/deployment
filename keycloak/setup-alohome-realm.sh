#!/usr/bin/env bash
# Creates or updates the "alohome" realm the API expects. Safe to run again.
#
# What the API needs (see KeyCloakRestClient):
#   - a confidential client (password grant + token exchange) -> ExternalServices:Keycloak:AdminClientId / ClientSecret
#   - a service user that manages users and may impersonate    -> ExternalServices:Keycloak:Username / Password
#   - legacy token exchange with requested_subject to issue tokens for a user after OTP login
#   - a realm role "Admin" for backoffice endpoints
#
# Usage:
#   KC_CLIENT_SECRET=... KC_SERVICE_PASSWORD=... ./keycloak/setup-alohome-realm.sh
set -euo pipefail

CONTAINER="${KC_CONTAINER:-alohome-keycloak}"
REALM="${KC_REALM:-alohome}"
CLIENT_ID="${KC_CLIENT_ID:-alohome-api}"
CLIENT_SECRET="${KC_CLIENT_SECRET:?Set KC_CLIENT_SECRET}"
SERVICE_USER="${KC_SERVICE_USER:-alohome-service}"
SERVICE_PASSWORD="${KC_SERVICE_PASSWORD:?Set KC_SERVICE_PASSWORD}"
ADMIN_USER="${KC_ADMIN_USERNAME:-admin}"
ADMIN_PASSWORD="${KC_ADMIN_PASSWORD:-admin}"

kc() { docker exec -i "$CONTAINER" /opt/keycloak/bin/kcadm.sh "$@" --config /tmp/kcadm-alohome.config 2>/dev/null; }
id_of() { tr -d '\r' | grep -m1 '"id"' | sed 's/.*"id" : "\([^"]*\)".*/\1/'; }

echo "Signing in to Keycloak master realm"
kc config credentials --server http://localhost:8080 --realm master --user "$ADMIN_USER" --password "$ADMIN_PASSWORD" >/dev/null

if ! kc get "realms/$REALM" >/dev/null; then
  echo "Creating realm $REALM"
  kc create realms -s realm="$REALM" -s enabled=true -s registrationAllowed=false -s loginWithEmailAllowed=false \
     -s accessTokenLifespan=900 -s ssoSessionIdleTimeout=86400 -s ssoSessionMaxLifespan=2592000 >/dev/null
fi

# Users are created with a custom "Type" attribute; the declarative user profile must accept it.
kc update users/profile -r "$REALM" -s unmanagedAttributePolicy=ENABLED >/dev/null

if ! kc get "roles/Admin" -r "$REALM" >/dev/null; then
  echo "Creating realm role Admin"
  kc create roles -r "$REALM" -s name=Admin -s 'description=AloHome backoffice administrator' >/dev/null
fi

CLIENT_UUID=$(kc get clients -r "$REALM" -q clientId="$CLIENT_ID" --fields id | id_of || true)
if [ -z "$CLIENT_UUID" ]; then
  echo "Creating client $CLIENT_ID"
  kc create clients -r "$REALM" -s clientId="$CLIENT_ID" -s enabled=true -s publicClient=false \
     -s standardFlowEnabled=false -s directAccessGrantsEnabled=true -s serviceAccountsEnabled=true >/dev/null
  CLIENT_UUID=$(kc get clients -r "$REALM" -q clientId="$CLIENT_ID" --fields id | id_of)
fi
kc update "clients/$CLIENT_UUID" -r "$REALM" -s secret="$CLIENT_SECRET" -s directAccessGrantsEnabled=true -s publicClient=false >/dev/null

SERVICE_UUID=$(kc get users -r "$REALM" -q username="$SERVICE_USER" -q exact=true --fields id | id_of || true)
if [ -z "$SERVICE_UUID" ]; then
  echo "Creating service user $SERVICE_USER"
  kc create users -r "$REALM" -s username="$SERVICE_USER" -s enabled=true -s emailVerified=true \
     -s firstName=AloHome -s lastName=Service -s email="$SERVICE_USER@alohome.local" >/dev/null
fi
kc set-password -r "$REALM" --username "$SERVICE_USER" --new-password "$SERVICE_PASSWORD" >/dev/null
kc add-roles -r "$REALM" --uusername "$SERVICE_USER" --cclientid realm-management \
   --rolename manage-users --rolename view-users --rolename query-users --rolename view-realm --rolename impersonation >/dev/null

# Legacy token exchange (V1): the service user's token is exchanged for a token of the logged-in user (requested_subject).
# That needs fine-grained user permissions with a client policy that lets this client impersonate.
echo "Configuring impersonation permission for $CLIENT_ID"
kc update "realms/$REALM/users-management-permissions" -s enabled=true >/dev/null
RM_UUID=$(kc get clients -r "$REALM" -q clientId=realm-management --fields id | id_of)
POLICY_NAME="$CLIENT_ID-impersonation"
POLICY_UUID=$(kc get "clients/$RM_UUID/authz/resource-server/policy" -r "$REALM" -q name="$POLICY_NAME" --fields id | id_of || true)
if [ -z "$POLICY_UUID" ]; then
  kc create "clients/$RM_UUID/authz/resource-server/policy/client" -r "$REALM" \
     -s name="$POLICY_NAME" -s logic=POSITIVE -s "clients=[\"$CLIENT_UUID\"]" >/dev/null
  POLICY_UUID=$(kc get "clients/$RM_UUID/authz/resource-server/policy" -r "$REALM" -q name="$POLICY_NAME" --fields id | id_of)
fi
IMPERSONATE_UUID=$(kc get "clients/$RM_UUID/authz/resource-server/permission" -r "$REALM" -q name=admin-impersonating.permission.users --fields id | id_of)
kc update "clients/$RM_UUID/authz/resource-server/permission/scope/$IMPERSONATE_UUID" -r "$REALM" \
   -s "policies=[\"$POLICY_UUID\"]" -s decisionStrategy=AFFIRMATIVE >/dev/null

# The client must also be allowed to exchange tokens whose audience is itself.
kc update "clients/$CLIENT_UUID/management/permissions" -r "$REALM" -s enabled=true >/dev/null
EXCHANGE_UUID=$(kc get "clients/$RM_UUID/authz/resource-server/permission" -r "$REALM" -q name="token-exchange.permission.client.$CLIENT_UUID" --fields id | id_of)
kc update "clients/$RM_UUID/authz/resource-server/permission/scope/$EXCHANGE_UUID" -r "$REALM" \
   -s "policies=[\"$POLICY_UUID\"]" -s decisionStrategy=AFFIRMATIVE >/dev/null

echo "Realm $REALM ready: client $CLIENT_ID, service user $SERVICE_USER, role Admin"
