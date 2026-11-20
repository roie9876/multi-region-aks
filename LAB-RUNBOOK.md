# Lab runbook

Use the [design and address plan](./README.md) with isolated lab subscriptions/projects and non-production IP space. Expected results below are hypotheses to validate, not measured results.

## 1. Prepare

- [ ] Choose a lab router that supports route-based IPsec and BGP to represent on-prem. Place a test client and a DNS server behind it. In GCP, create a test VM and use Cloud Router, HA VPN, and Cloud DNS where those features are being tested.
- [ ] Confirm Azure regional service/SKU availability, GCP region, quota, address allocations, and cost before deployment. Record the BGP ASNs, peer IPs, expected advertised prefixes, AKS network and outbound types, DNS suffixes, and tunnel ownership.
- [ ] Deploy one regional echo workload per cluster. Use stable private frontend addresses and matching DNS and TLS names. Prepare controlled HTTPS endpoints behind on-prem, in GCP, and on the internet. Enable application, gateway, and Azure Firewall diagnostics before testing; use unique request IDs and synchronized timestamps.

## 2. Establish the single-region baseline

Bring up the on-prem-to-West Europe and West Europe-to-GCP links and the West Europe hub/spoke. From on-prem and GCP, record route selection, private DNS answers, and HTTPS access to the West Europe frontend. From West Europe AKS, record private egress to both sites and public egress. Record which flows appear in the West Europe firewall logs and which do not. If modeling an existing West Europe inspection policy, export both `GatewaySubnet` and AKS subnet routing configuration before changing anything.

## 3. Add Israel Central and stage the cutover

1. Deploy the Israel hub, peered AKS spoke, regional resolver, and private app endpoint. Bring up the inter-region VPN with BGP. Verify that Israel learns the West Europe hub and spoke routes and that West Europe learns the Israel equivalents.
2. Bring up the new on-prem and GCP links to Israel using BGP. Keep the existing West Europe paths available for rollback. During coexistence, deliberately control which paths are preferred using route policy where supported, or isolate testing to lab prefixes. Check for asymmetric routing or unexpected equal-cost paths rather than assuming the newest tunnel wins.
3. Link the private DNS zones to both resolver VNets and configure per-region forwarding. Validate the Israel inbound endpoint directly and through each client's normal DNS path before switching conditional forwarders.
4. Run cutover tests with all four external links up. If retirement is planned, simulate withdrawing the West Europe links in the lab without deleting their configuration and verify the remaining paths. Do not retire the actual links before migration is complete and those paths have passed validation.

## 4. Test matrix

| ID | Test | Expected evidence |
|---|---|---|
| R1 | On-prem -> West Europe and Israel AKS | Both private frontends answer. Verify selected forward and return paths match the agreed policy while both regional VPNs are up. |
| R2 | GCP -> both Azure regions; on-prem <-> GCP if required | Each side learns the expected prefixes, selects the intended paths while both regional VPNs are up, and passes HTTPS in both required initiation directions. |
| F1 | On-prem -> West Europe AKS, BGP-only comparison | With no steering routes in the test path, HTTPS succeeds and does not traverse either firewall. Confirm chosen next hops and working diagnostics; absence of a log entry alone does not prove bypass. |
| F2 | Repeat with existing West Europe inspection routes | West Europe `GatewaySubnet` steers to the firewall, and the spoke return route steers to it too. Confirm the flow using effective routes, a matching allow log, and a reversible deny rule for that test flow. Israel firewall remains out of path. |
| D1 | Query both inbound VIPs, then query through normal on-prem and GCP DNS | Both Azure endpoints give consistent answers for linked zones. Both site clients resolve regional app records and required AKS API records. Verify UDP and TCP and capture TTLs. |
| D2 | Pods in both regions -> on-prem and GCP DNS | Regional forwarding returns the authoritative private IPs. Check that nonexistent names fail as expected rather than timing out in a forwarding loop. |
| I1 | On-prem/GCP -> private HTTPS endpoint in each region | DNS, TLS hostname, HTTP status, and response region match. An internet-only test client without private network access cannot reach the private frontend. |
| E1 | Pod in each region -> on-prem and GCP HTTPS | Destination records the expected source identity/IP for the selected CNI mode; response succeeds and observed routing and inspection match policy. |
| E2 | Pod in each region -> controlled public HTTPS endpoint | Destination records the expected public egress IP and regional egress behavior. If testing forced egress, verify intended allow/deny and AKS dependency connectivity separately. |
| H1 | Withdraw a single tunnel in a redundant site VPN | Measure BGP convergence and application recovery over the surviving tunnel. Compare to the agreed recovery target. |
| H2 | Simulate loss of Israel transit after old links are withdrawn | On-prem loses the route through Israel to West Europe and cannot fail over to its resolver through that same hub. Separately test a resolver-only failure with routing intact. Observe what still works within West Europe. |
| M1 | Cut over the first AKS spoke with an identical `/17` | Old route is withdrawn before the replacement is advertised. On-prem and GCP select Israel; private app VIP/TLS and required firewall policy still work. Both other West Europe spokes remain reachable. |
| M2 | Check Sweden, Blob Storage, and Key Vault from the moved spoke | DNS returns the intended private endpoints, approved HTTPS requests succeed, and forward/return routes and inspection match policy. Test this before declaring the first wave complete. |
| M3 | Roll back the first spoke | Disconnect and verify withdrawal of the Israel `/17` before reconnecting West Europe. Verify the app VIP, policies, and DNS recover without concurrent route ownership. |

## 5. Capture evidence and decide

Azure-side route checks (read-only):

```sh
az network vnet-gateway list-learned-routes -g "$ISRAEL_RG" -n "$ISRAEL_GW" -o table
az network vnet-gateway list-advertised-routes -g "$ISRAEL_RG" -n "$ISRAEL_GW" \
  --peer "$ONPREM_BGP_PEER_IP" -o table
```

Also check the West Europe gateway's learned routes, effective routes on representative Azure NICs, and on-prem/GCP router route tables. Compare source prefix, next hop, BGP AS path, and the return direction. See [Azure VPN Gateway CLI](https://learn.microsoft.com/en-us/cli/azure/network/vnet-gateway).

Run DNS and HTTPS probes from each appropriate client or pod, setting variables to the lab DNS names, resolver IP, and app frontend IP:

```sh
dig @"$RESOLVER_IP" "$APP_FQDN" A
dig +tcp @"$RESOLVER_IP" "$APP_FQDN" A
dig "$APP_FQDN" A
curl --fail --show-error --max-time 10 "https://$APP_FQDN/healthz"
curl --fail --show-error --max-time 10 \
  --resolve "$APP_FQDN:443:$APP_PRIVATE_IP" "https://$APP_FQDN/healthz"
```

The final probe bypasses the DNS lookup but keeps the hostname and TLS verification. A successful response there with a failed normal probe helps distinguish DNS from reachability. Record the test ID, phase, timestamp, source/destination, DNS answer, selected route, HTTP result, region marker, source IP at destination, and firewall verdict. For failover tests, record both route convergence and user-visible recovery.

**Acceptance:** Required routes work with all four external links up; DNS returns the intended regional addresses; ingress and egress match expectations; and the observed inspection paths meet policy. If post-migration retirement is planned, also validate the required routes without the West Europe links and assess the resulting dependency on Israel.

**Rollback:** If critical routes disappear, return traffic is asymmetric, DNS responses are wrong, or required inspection is bypassed, restore the previous West Europe VPN advertisements and preferences, restore the previous DNS forwarders and any changed inspection settings, and rerun baseline probes. Account for DNS caching. Preserve configuration and evidence before decommissioning legacy links or deleting lab resources.
