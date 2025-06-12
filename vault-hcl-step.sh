#!/bin/bash
set -euo pipefail

# --- Configuration ---
VAULT_ADDR="${VAULT_ADDR:?VAULT_ADDR is not set}"
VAULT_TOKEN="${VAULT_TOKEN:?VAULT_TOKEN is not set}"
HCL_TEMPLATE="${HCL_TEMPLATE:?Path to HCL template is not set}"
VAULT_KV_VERSION="${VAULT_KV_VERSION:-2}"
VAULT_SECRETS="${VAULT_SECRETS:?VAULT_SECRETS are not set (e.g., secret/path1,secret/path2)}"

# --- Command Check ---
install_ubuntu_commands() {
  local commands=("curl" "jq" "sed")
  local missing_commands=()

  # Check for missing commands
  for cmd in "${commands[@]}"; do
    if ! command -v "$cmd" >/dev/null; then
      missing_commands+=("$cmd")
    fi
  done

  if [[ ${#missing_commands[@]} -gt 0 ]]; then
    echo "Warning: The following required commands are not found: ${missing_commands[*]}" >&2
    echo "Attempting to install them using apt..." >&2

    # Update package lists and install missing commands
    sudo apt update -q && sudo apt install -yq "${missing_commands[@]}"

    # Verify installation
    for cmd_to_verify in "${missing_commands[@]}"; do
      if ! command -v "$cmd_to_verify" >/dev/null; then
        echo "Error: Failed to install $cmd_to_verify. Please install it manually." >&2
        exit 1
      fi
    done
    echo "All missing commands have been installed successfully." >&2
  else
    echo "All required commands (curl, jq, sed) are already installed." >&2
  fi
}

renew_vault_token_api() {
  echo "Attempting to renew Vault token via API for address: $VAULT_ADDR"

  local renew_response
  renew_response=$(curl -s --request POST  -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/auth/token/renew-self")

  # Check for errors in the response
  if echo "$renew_response" | jq -e 'has("errors")' >/dev/null; then
    local error_message # Declare separately
    error_message=$(echo "$renew_response" | jq -r '.errors[]' 2>/dev/null) # Assign separately
    echo "Error renewing Vault token: ${error_message:-Unknown error or malformed response.}" >&2
    echo "Full response: $renew_response" >&2
    return 1
  else
    local renewable # Declare separately
    renewable=$(echo "$renew_response" | jq -r '.auth.renewable') # Assign separately
    local current_lease_duration # Declare separately
    current_lease_duration=$(echo "$renew_response" | jq -r '.auth.lease_duration') # Assign separately

    if [[ "$renewable" == "true" ]]; then
      echo "Vault token renewed successfully to its maximum allowed duration."
      echo "Current lease duration after renewal: ${current_lease_duration} seconds"
    else
      echo "Vault token renewed, but it is no longer renewable."
      echo "Current lease duration: ${current_lease_duration} seconds"
      echo "Please consider generating a new token soon."
    fi
    return 0
  fi
}

# --- Get Secret from Vault ---
# Fetches a secret from Vault and returns its data as JSON.
# Arguments:
#   $1: The secret path in Vault (e.g., "secret/my-app/config").
# Returns:
#   JSON string of the secret's data.
# Exits with error if the curl request fails or if the response is not valid JSON.
get_secret() {
  local path="$1"
  local full_path="$path"
  # Adjust path for KV version 2 if necessary (e.g., secret/my-app -> secret/data/my-app)
  [[ "$VAULT_KV_VERSION" == "2" ]] && full_path="${path/#secret\//secret\/data\/}"

  local response
  # Attempt to fetch the secret using curl. Suppress progress meter (-s).
  if ! response=$(curl -s -H "X-Vault-Token: ${VAULT_TOKEN}" "${VAULT_ADDR}/v1/${full_path}"); then
    echo "Error: Failed to request secret from Vault at $path" >&2
    exit 1
  fi

  #Validate if the response is valid JSON before parsing.
  #'jq -e .' will exit non-zero if the input is not valid JSON.
  if ! echo "$response" | jq -e . >/dev/null; then
    echo "Error: Vault response for secret '$path' is not valid JSON." >&2
    echo "Raw response received:" >&2
    echo "$response" >&2 # Print the raw response for debugging.
    exit 1
  fi

  #Extract data based on the Vault KV engine version.
  if [[ "$VAULT_KV_VERSION" == "2" ]]; then
    echo "$response" | jq -r '.data.data' # For KV v2, actual data is nested under .data.data
  else
    echo "$response" | jq -r '.data' # For KV v1, data is directly under .data
  fi
}

# --- Generate Secret Assignments File ---
# Processes a JSON string of secret data and writes Bash variable assignments
# to a specified file, ensuring proper quoting for special characters.
# These assignments are suitable for 'sourcing' into the current shell.
# Arguments:
#   $1: The JSON string containing the secret data (e.g., output from get_secret).
#   $2: Path to a file where the variable assignments will be appended.
# Exits with error if input JSON is invalid or if a key is not a valid Bash identifier.
generate_secret_assignments_file() {
  local json_data="$1"
  local output_file="$2" # This function now strictly requires an output file.

  # Validate the input JSON.
  if ! echo "$json_data" | jq -e . >/dev/null; then
    echo "Error: Input JSON to generate_secret_assignments_file is invalid." >&2
    echo "Invalid data: $json_data" >&2
    exit 1
  fi

# Iterate over each key-value pair in the JSON.
# Use -c to output compact JSON on a single line for each entry
echo "$json_data" | jq -c 'to_entries[]' | while IFS= read -r entry_json; do
  local key
  local value

  key=$(echo "$entry_json" | jq -r '.key')

  # Extract the value as a JSON string (with quotes and \n)
  value=$(echo "$entry_json" | jq '.value')

  echo "$key=$value" >> "$output_file"
  echo "Prepared assignment for variable: $key"
done

}

# --- Substitute Placeholders In-Place ---
# Replaces placeholders like %KEY% in the HCL_TEMPLATE file
# with the corresponding environment variable values.
#
# Args:
#   $1: Path to the file containing key-value assignments (e.g., all_secrets_temp_file)
substitute_placeholders_inplace() {
  local assignments_file="$1" # Capture the first argument as the assignments file
  echo "Substituting values directly into $HCL_TEMPLATE from $assignments_file..."

  # Read each line from the assignments file.
  # Assuming the file format is KEY="VALUE"
  while IFS='=' read -r key_part value_part; do
    # The 'value_part' will contain the quoted string, e.g., '"-----BEGIN CERTIFICATE-----\n..."'
    # We need to extract the actual key name from key_part (which might be "KEY")
    # And unquote the value, preserving the literal \n.

    # Remove potential leading/trailing quotes from the key_part if present
    # (though your generate_secret_assignments_file should ideally write just KEY)
    key=$(echo "$key_part" | sed 's/^"//;s/"$//')

    # Remove the outer quotes from the value, keeping literal \n
    # This is exactly what was done for the `value=$(echo ... | jq '.value' | sed ...)` part
    value=$(echo "$value_part" | sed 's/^"//;s/"$//')

    # Important: Check if the line was successfully parsed into non-empty key and value
    if [ -n "$key" ] && [ -n "$value" ]; then
      echo "Processing variable: $key=(value for $key)" # Avoid logging sensitive values.

      # Check if the placeholder exists in the template before attempting substitution.
      if grep -q "%$key%" "$HCL_TEMPLATE"; then
        # Perform the substitution using a non-conflicting delimiter '|'
        sed -ri "s|%$key%|$value|g" "$HCL_TEMPLATE"
        echo "Replaced: %$key% -> (value for $key) in $HCL_TEMPLATE" # Avoid logging sensitive values.
      fi
    fi
  done < "$assignments_file" # Redirect assignments_file as input to the while loop
}

# --- Main Process ---
# Orchestrates fetching secrets, preparing variables, and substituting into the template.
main() {
  ### Install commands before main logic
  install_ubuntu_commands

  ### Renew VAULT_TOKEN each time we running the script
  renew_vault_token_api

  # Split the comma-separated VAULT_SECRETS string into an array of paths.
  IFS=',' read -ra secret_paths <<< "$VAULT_SECRETS"

  # Create a single temporary file to accumulate all variable assignments from secrets.
  # This file will be sourced later to make variables available.
  local all_secrets_temp_file
  all_secrets_temp_file=$(mktemp)
  echo "Created temporary file for all secret assignments: $all_secrets_temp_file"

  # Fetch each secret and append its assignments to the temporary file.
  for path in "${secret_paths[@]}"; do
    echo "Fetching secret: $path"
    local json_output # Declare separately
    json_output=$(get_secret "$path") # Assign separately

    # Pass the JSON output and the temporary file path to the generator function.
    generate_secret_assignments_file "$json_output" "$all_secrets_temp_file"
  done

 # --- NO MORE SOURCING HERE ---
  # Variables will be read directly from the file in the substitution function.
  echo "Secret assignments prepared in: $all_secrets_temp_file"

  # Proceed with substituting placeholders in the HCL template.
  # Pass the temporary file path to the substitution function.
  substitute_placeholders_inplace "$all_secrets_temp_file"
  echo "Script execution complete: HCL template modified in-place -> $HCL_TEMPLATE"

  # Clean up the temporary file containing the secret assignments.
  # It's important to remove this file as it might contain sensitive data.
  rm "$all_secrets_temp_file"
  echo "Cleaned up temporary secrets file: $all_secrets_temp_file"
}

# Execute the main function.
main
