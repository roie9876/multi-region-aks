#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
result=0
for cluster in aks-aks-migration-lab-we-aks1 aks-aks-migration-lab-we-aks2; do
  printf '\n%s\n' "$cluster"
  if ! response=$(az aks command invoke --resource-group rg-aks-migration-lab-we \
    --name "$cluster" --file "$root/curl-targets.sh" \
    --command 'kubectl -n default exec -i lab-curl -- sh -s < curl-targets.sh' \
    --output json); then
    result=1
    continue
  fi
  jq -r '.logs // "Run Command did not return logs"' <<<"$response"
  if ! jq -e '.provisioningState == "Succeeded" and .exitCode == 0' \
    >/dev/null <<<"$response"; then
    result=1
  fi
done
exit "$result"
