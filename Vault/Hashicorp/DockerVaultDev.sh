#!/bin/bash

# This will install Hashicorp Vault as a docker container.  It will use the latest version of Hashicorp Vault's container from the main repository.


#This is a function that will reset the containers.
function remove_container() {
  local container_name=$1

  # Stop the container if it's running
  if docker ps --filter "name=${container_name}" --format "{{.Names}}" | grep -q "${container_name}"; then
    echo "Stopping container ${container_name}..."
    docker stop "${container_name}" >/dev/null 2>&1
  fi

  # Remove the container, even if it wasn't running
  if docker ps --all --filter "name=${container_name}" --format "{{.Names}}" | grep -q "${container_name}"; then
    echo "Removing container ${container_name}..."
    docker rm "${container_name}" >/dev/null 2>&1
  fi
}

# Function to display help message
function display_help {
  echo "Usage: $0 [OPTIONS]"
  echo "  --keylist=KEYLIST     Comma-separated list of keys to store in Vault"
  echo "  --clear-db            Clear the database before running the script"
  echo "  --help                Display this help message and exit"
}

clear_db=false
keylist=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --help)
      display_help
      return
      ;;
    --clear-db)
      clear_db=true
      processed=true
      ;;
    --keylist)
      if [[ "$2" =~ ^[a-zA-Z][-a-zA-Z0-9,_]*$ ]]; then
        keylist="$2"
      else
        echo "Invalid keylist format. Please enter a comma-separated list of alphanumeric keys and hyphens." >&2
        return 1
      fi
      processed=true
      shift
      ;;
    *)
      echo "Invalid argument: $1" >&2
      return 1
      ;;
  esac
  if $processed; then
    shift
  fi
done

# Check if apt-get is available, otherwise try to use yum
if [ -x "$(command -v apt-get)" ]; then
  INSTALLER="apt-get"
elif [ -x "$(command -v yum)" ]; then
  INSTALLER="yum"
else
  echo "Neither apt-get nor yum is available. Aborting installation." >&2
  return 1
fi

# Install required packages
if ! command -v docker >/dev/null 2>&1; then
  echo "Installing docker..."
  sudo $INSTALLER update
  sudo $INSTALLER -y install docker

  # Create docker group (if it doesn't exist)
  sudo groupadd docker

  # Add current user to docker group
  sudo usermod -aG docker $USER

  # Set docker up as a service
  sudo systemctl enable docker.service

  # Start the docker daemon
  sudo systemctl start docker.service
fi

# Make sure curl is installed.
if ! command -v curl >/dev/null 2>&1; then
  echo "Installing curl..."
  sudo $INSTALLER update
  sudo $INSTALLER -y install curl
fi

#Make sure jq is installed.
if ! command -v jq >/dev/null 2>&1; then
  echo "Installing jq..."
  sudo $INSTALLER update
  sudo $INSTALLER -y install jq
fi

while true; do
  read -p "Enter the app name (must start with a letter and contain only alphanumeric characters): " APP_NAME
  if [[ "$APP_NAME" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
    break
  else
    echo "Invalid app name. Please try again."
  fi
done


# Create a self-signed certificate for localhost
openssl req -newkey rsa:2048 -nodes -keyout localhost.key \
  -x509 -days 365 -out localhost.crt \
  -subj "/C=US/ST=CA/L=San Francisco/O=MyOrg/OU=MyUnit/CN=localhost"

remove_container vault
remove_container postgres

# Set the VAULT_TOKEN environment variable
export VAULT_TOKEN=$(openssl rand -hex 16)
export VAULT_ADDR='http://127.0.0.1:8200'

# Generate random password
POSTGRES_PASSWORD=$(openssl rand -hex 16)

echo "Posrgress Password: $POSTGRES_PASSWORD"
docker run --name postgres -e POSTGRES_PASSWORD=$POSTGRES_PASSWORD -d postgres

# Wait for PostGres to start up
sleep 5

if $clear_db; then
  # The --clear-db argument is present
  echo "Clearing 'vault' database..."
  if docker exec postgres psql -U postgres -tAc "SELECT 1 FROM pg_database WHERE datname='vault'" | grep -q 1; then
    docker exec postgres psql -U postgres -c "DROP DATABASE vault"
  fi
fi


# Check if the "vault" database exists
if ! docker exec -it postgres psql -U postgres -lqt | cut -d \| -f 1 | grep -qw vault; then
  # The "vault" database does not exist
  echo "Creating 'vault' database..."
  docker exec -it postgres createdb -U postgres vault

  # Create the tables needed for the vault store.
  docker exec postgres psql -U postgres -d vault -c "CREATE TABLE vault_kv_store (parent_path TEXT COLLATE \"C\" NOT NULL, path TEXT COLLATE \"C\", key TEXT COLLATE \"C\", value BYTEA, CONSTRAINT pkey PRIMARY KEY (path, key));"
  docker exec postgres psql -U postgres -d vault -c "CREATE INDEX parent_path_idx ON vault_kv_store (parent_path);"
  docker exec postgres psql -U postgres -d vault -c "CREATE TABLE vault_ha_locks (ha_key TEXT COLLATE \"C\" NOT NULL, ha_identity TEXT COLLATE \"C\" NOT NULL, ha_value TEXT COLLATE \"C\", valid_until TIMESTAMP WITH TIME ZONE NOT NULL, CONSTRAINT ha_key PRIMARY KEY (ha_key));"

fi




# Output the root token to the console
echo "Vault root token: $VAULT_TOKEN"
echo "WARNING: Save this token securely! It is required to access Vault."

# Deploy Vault in a Docker container with PostgreSQL as backend
docker run --name vault -d \
  --cap-add=IPC_LOCK \
  -p 8200:8200 \
  -v $(pwd)/localhost.crt:/vault/tls/server.crt \
  -v $(pwd)/localhost.key:/vault/tls/server.key \
  -e VAULT_DEV_ROOT_TOKEN_ID=$VAULT_TOKEN \
  -e VAULT_ADDR=https://localhost:8200 \
  --link postgres:postgres \
  -e 'VAULT_LOCAL_CONFIG={"storage": {"postgresql": {"connection_url": "postgres://postgres:'"$POSTGRES_PASSWORD"'@postgres:5432/vault?sslmode=disable"}}}' \
  vault:latest

# Wait for Vault to start up
sleep 5

# Create a policy for the appname secrets
echo "path \"secret/$APP_NAME\" { capabilities = [\"read\", \"list\"] }" | vault policy write $APP_NAME -

# Create a token with the appname policy
TOKEN=$(vault token create -policy=$APP_NAME -format=json | jq -r '.auth.client_token')

# Output the token to the console
echo "App token for $APP_NAME: $TOKEN"
echo "WARNING: Save this token securely! It is required to access the '$APP_NAME' secrets."

if [[ -n $keylist ]]; then
  # Split the keylist into an array
  IFS=',' read -ra keys <<< "$keylist"

  for key in "${keys[@]}"; do
    value=$(openssl rand -hex 16)
    echo "Going to store $key with value $value"
    vault kv put secret/$APP_NAME/$key value=$value
  done
else
  while true; do
    read -p "Enter secret key (or 'exit' to quit): " key
    if [ "$key" = "exit" ]; then
      break
    fi

    if [[ "$key" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]]; then
        read -p "Enter secret value: " value
        # Store the secret in Vault
        vault kv put secret/$APP_NAME/$key value=$value

        if [ $? -ne 0 ]; then
          echo "Failed to store secret in Vault. Please try again."
          continue
        fi
    else
       echo "Invalid key format."
    fi
  done
fi
