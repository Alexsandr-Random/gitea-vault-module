# Vault Template Renderer

This GitHub Action automates the process of fetching secrets from HashiCorp Vault and substituting their values into any text-based template file. It's perfect for scenarios where you need to dynamically generate configuration files (e.g., for applications, scripts, Nomad, or any other tool) using up-to-date secrets from Vault directly within your CI/CD pipeline.

---

## Features

* **Dynamic Secret Retrieval:** Securely retrieves multiple secrets from HashiCorp Vault based on specified paths. This includes all types of secrets, such as API keys, database credentials, and even multi-line data like **SSL certificates and their private keys**.
* **KV Version Support:** Works with both KV v1 and KV v2 Vault secret engines.
* **Template Substitution:** Replaces placeholders in the `%KEY%` format within your template file with the corresponding secret values.
* **Automatic Vault Token Renewal:** Attempts to renew the existing Vault token to prevent expiration during Action execution.
* **Dependency Check and Installation:** Checks for required utilities (`curl`, `jq`, `sed`) and attempts to install them in Ubuntu-like environments if missing.
* **Security:** Utilizes GitHub Secrets for securely passing sensitive Vault credentials.

---

## Usage

To use this Action, create a workflow file in your repository, for example, `.github/workflows/render_config.yml`.

### Examples:

#### 1. Create your template file (e.g., `nomad/nomad-job.hcl` but you could use ANY file contains templated values like %vault-secret-key%):

```text
# Application Configuration
APP_NAME=MyApp
DB_HOST=localhost
DB_PORT=5432
DB_USERNAME=%DB_USERNAME%
DB_PASSWORD=%DB_PASSWORD%
API_KEY=%MY_API_KEY%
```
#### 2. Setup Git Action (e.g., `.github/workflows/render_config.yml`) and try your new pipline:
```yaml
name: dev CI/CD
on:
  push:
    branches:
      - 'dev'

jobs:
  Dev-Deploy:
    runs-on: ubuntu-latest
    steps:
      -
        name: Check out repository code
        uses: actions/checkout@v4

      -
        name: Prepare template with Vault secrets
        run: .gitea/scripts/vault-hcl-step.sh
        env:
          VAULT_ADDR: https://my-vault-addr.com ### address of your vault cluster\server
          VAULT_TOKEN: ${{ secrets.VAULT_TOKEN_DEV }} ### please, use native gitea secrets in repo to store vault token secret, more: https://docs.gitea.com/usage/secrets
          HCL_TEMPLATE: "nomad/nomad-job.hcl" ### you could use any files, not only HCL 
          VAULT_SECRETS: "mysecret/data/app-auth,mysecret/data/my-auth,mysecret/data/app" ### path to your vault KV files containing secrets
```
