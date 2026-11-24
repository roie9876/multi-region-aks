#!/bin/sh
set -eu

result=0
while read -r label url; do
  if ! curl --noproxy '*' --fail --silent --show-error \
    --connect-timeout 3 --max-time 5 --output /dev/null \
    --write-out "$label ($url): HTTP %{http_code}\n" "$url"; then
    result=1
  fi
done <<'EOF'
On-premises http://10.60.0.12/
GCP http://10.70.0.12/
West-Europe http://10.43.2.10/
Sweden-Central http://10.44.1.5/
West-Europe-AKS1 http://10.42.129.6/
West-Europe-AKS2 http://10.43.1.6/
EOF
exit "$result"
