#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  printf 'Usage: bash infra/run-layer.sh ROOT plan|apply\n' >&2
  exit 2
fi

root=$1
action=$2
case "$root" in
  west-europe|sweden-workload|emulators|baseline-links|aks1-cutover) ;;
  *) printf 'Unknown baseline root: %s\n' "$root" >&2; exit 2 ;;
esac

: "${ARM_SUBSCRIPTION_ID:?Set the lab subscription ID}"
: "${ARM_CLIENT_ID:?Set the runner managed identity client ID}"
: "${LAB_STATE_ACCOUNT:?Set the private Terraform state account name}"
export TF_VAR_subscription_id="$ARM_SUBSCRIPTION_ID"
export ARM_USE_MSI=true
export ARM_USE_CLI=false

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
directory="$here/$root"
umask 077
case "$action" in
  plan)
    terraform -chdir="$directory" init -input=false -reconfigure \
      -backend-config="storage_account_name=$LAB_STATE_ACCOUNT" \
      -backend-config=container_name=tfstate \
      -backend-config="key=$root.tfstate" \
      -backend-config=use_msi=true \
      -backend-config=use_azuread_auth=true \
      -backend-config="client_id=$ARM_CLIENT_ID"
    terraform -chdir="$directory" validate
    rm -f -- "$directory/reviewed.tfplan"
    terraform -chdir="$directory" plan -input=false -lock-timeout=2m -out=reviewed.tfplan
    ;;
  apply)
    terraform -chdir="$directory" apply -input=false -lock-timeout=2m reviewed.tfplan
    rm -- "$directory/reviewed.tfplan"
    ;;
  *) printf 'Unknown action: %s\n' "$action" >&2; exit 2 ;;
esac
