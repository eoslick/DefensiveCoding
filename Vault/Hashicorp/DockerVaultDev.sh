#!/bin/bash

# This will install Hashicorp Vault as a docker container.  It will use the latest version of Hashicorp Vault's container from the main repository.


# Check if apt-get is available, otherwise try to use yum
if [ -x "$(command -v apt-get)" ]; then
  INSTALLER="apt-get"
elif [ -x "$(command -v yum)" ]; then
  INSTALLER="yum"
else
  echo "Neither apt-get nor yum is available. Aborting installation." >&2
  exit 1
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

# Prompt the user for the name of the application these secrets will be stored for
read -p "What is the name of the application these secrets will be stored for? " APP_NAME

# Create a self-signed certificate for localhost
openssl req -newkey rsa:2048 -nodes -keyout localhost.key \
  -x509 -days 365 -out localhost.crt \
  -subj "/C=US/ST=CA/L=San Francisco/O=MyOrg/OU=MyUnit/CN=localhost"

# Check if the Vault container is running
if [[ $(docker ps --filter "name=vault" --format "{{.Names}}") == "vault" ]]; then
  # If the container is running, stop and remove it
  docker stop vault
  docker rm vault
fi

# Set the VAULT_TOKEN environment variable
export VAULT_TOKEN=$(openssl rand -hex 16)
export VAULT_ADDR='http://127.0.0.1:8200'

# Output the root token to the console
echo "Vault root token: $VAULT_DEV_ROOT_TOKEN_ID"
echo "WARNING: Save this token securely! It is required to access Vault."

# Deploy Vault in a Docker container
docker run --name vault -d \
  --cap-add=IPC_LOCK \
  -p 8200:8200 \
  -v $(pwd)/localhost.crt:/vault/tls/server.crt \
  -v $(pwd)/localhost.key:/vault/tls/server.key \
  -e VAULT_DEV_ROOT_TOKEN_ID=$VAULT_TOKEN \
  -e VAULT_ADDR=https://localhost:8200 \
  vault:latest

# Wait for Vault to start up
sleep 5

# Create a policy for the 'myapp' secrets
echo "path \"secret/$APP_NAME\" { capabilities = [\"read\", \"list\"] }" | vault policy write $APP_NAME -

# Create a token with the 'myapp' policy
TOKEN=$(vault token create -policy=$APP_NAME -format=json | jq -r '.auth.client_token')

# Output the token to the console
echo "Vault token for $APP_NAME: $TOKEN"
echo "WARNING: Save this token securely! It is required to access the '$APP_NAME' secrets."

# Prompt the user for secrets to store in Vault
while true; do
  read -p "
Enter secret key (or 'exit' to quit): " key
  if [ "$key" = "exit" ]; then
    break
  fi

  read -p "Enter secret value: " value

  # Store the secret in Vault
  vault kv put secret/$APP_NAME/$key value=$value

  if [ $? -ne 0 ]; then
    echo "Failed to store secret in Vault. Please try again."
    continue
  fi
done
