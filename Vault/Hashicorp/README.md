This contains examples leveraging the Hashicorp Vault technology.

### DockerVaultDev.sh

This will run a bash shell script which creates a docker instance of the Hashicorp Vault.  It will create self-signed certs that can be used for
authenticaiton.  It generates a random token that is displayed to the console for root access to the vault if it is needed.

The script prompts for the app name for which keys are going to be stored in and creates that under the secrets store path.  The script then asks for any
keys and values that will be stored.

The idea here is to demonstrate automation in the development environment for maintaining secrets and keys.  In most cases, apps are now accessing third party 
applications and do not need to be hard coding those keys in property files or in code.  There is a greater risk with the increase of API keys that they will
accidently get leaked in someway shape or form.

With this script, the idea is to store API keys in the vault and use the self signed certs to authenticate.  

This script will export various enviornment variables.  To run the command use `. ./DockerVaultDev.sh`
