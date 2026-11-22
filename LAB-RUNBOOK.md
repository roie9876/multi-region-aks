# Lab runbook

Use the [Azure-only bill of materials](./LAB-BOM.md) and the [design and address plan](./README.md) with isolated lab subscriptions and non-production IP space. On-premises and GCP refer to Azure-hosted emulators throughout this runbook. Expected results below are hypotheses to validate, not measured results.

## 1. Prepare

- [ ] Build both emulators in separate, unpeered Azure VNets. In each, place a test client and DNS server behind a route-based IPsec/BGP router VM. Verify uncached private DNS lookups cannot bypass the tunnels. Real GCP-managed behavior is outside this lab's scope.
- [ ] Confirm Azure regional service/SKU availability, emulator region choices, quota, address allocations, and cost before deployment. Record the BGP ASNs, peer IPs, expected advertised prefixes, AKS network and outbound types, DNS suffixes, and tunnel ownership.
- [ ] Bootstrap the persistent Sweden Central Terraform runner, private state backend, shared DNS, and logging. Run regional Terraform applies from that VM. Follow the [BOM reset order](./LAB-BOM.md#terraform-runner-private-access-and-reset) when rebuilding Israel.
- [ ] Deploy one regional echo workload per cluster. Use stable private frontend addresses and matching DNS and TLS names. Use private Windows test clients in West Europe, Israel Central, Sweden Central, and both emulators. Prepare controlled HTTPS endpoints for egress testing. Enable application, gateway, and Azure Firewall diagnostics before testing; use unique request IDs and synchronized timestamps.
- [ ] Deploy the five [private browser test sites](./LAB-BOM.md#private-browser-test-sites) and record their `http://<private-ip>/` URLs from the Terraform outputs.

## 2. Establish the single-region baseline

Run the deployment roots in dependency order:

| Root | Execution location | Depends on |
|---|---|---|
| [`access`](./infra/access) | Approved Azure administrator workstation, with separate protected local state | Management bootstrap |
| `west-europe`, `sweden-workload` | Sweden Terraform runner | Scoped access and shared private DNS zones |
| `emulators` | Sweden Terraform runner | West Europe gateway addresses |
| [`baseline-links`](./infra/baseline-links) | Sweden Terraform runner | West Europe, Sweden and emulator outputs |
| [`aks1-cutover`](./infra/aks1-cutover) | Sweden Terraform runner | West Europe VPN gateway and AKS 1 spoke |

On the runner, set `ARM_SUBSCRIPTION_ID`, `ARM_CLIENT_ID` and `LAB_STATE_ACCOUNT` from the management bootstrap. Use [`infra/run-layer.sh`](./infra/run-layer.sh) with `<root> plan`, review the saved plan, then use `<root> apply`. Give each root a unique private Blob state key. Keep any Windows passwords and VPN shared keys in protected inputs, not in Git or shell history. Do not give the runner subscription-wide Contributor or Owner rights.

The [management Terraform root](./infra/management/main.tf) is the first implementation layer. Its initial apply uses admin credentials and local bootstrap state because the private Blob backend does not exist yet. Preserve that state securely; do not commit it or rerun bootstrap with an empty state. Future lab roots should run from the private runner with managed identity and a separate Blob state key per root. Grant the runner provisioning rights only on the relevant lab resource groups when those layers are prepared.

If Terraform times out creating Bastion, check its Azure provisioning state before running another apply. While it is `Updating`, do not attempt to recreate it. If it reaches `Succeeded` and is missing from Terraform state, import its Azure resource ID as `azurerm_bastion_host.management` into the **existing** management state, then review a fresh plan. If Azure reports `Failed`, inspect the Azure operation error before retrying.

Use **Azure Bastion** to connect to the private runner as `labadmin`. SSH through Bastion and execution of Terraform on the VM were verified after the Bastion-only retry. If Bastion is unavailable, an authorized operator can use **Azure VM Run Command** on `vm-aks-migration-lab-mgmt` without exposing SSH publicly. Run Terraform as `labadmin` from a directory that account can access; Run Command starts as root. Use the runner's managed identity for backend access and review the saved plan before applying. The fallback was verified by creating and removing a `terraform_data` test resource in a separate private Blob state key.

#### Windows test VM access

In Azure Portal, open the Windows VM and choose **Connect > Bastion**. Use username `labadmin` and the password for its deployment layer. Retrieve it in your own SSH session on the Terraform runner, not through Azure Run Command or chat.

| Windows VM | Bastion host | Password file under `~/aks-lab/infra/` on the runner |
|---|---|---|
| `vm-aks-migration-lab-onprem-client` | `vnet-aks-migration-lab-onprem-bastion` | `emulators/windows-password.local` (append one `!`) |
| `vm-aks-migration-lab-gcp-client` | `vnet-aks-migration-lab-gcp-bastion` | `emulators/windows-password.local` (append one `!`) |
| `vm-aks-migration-lab-we-win` | `bas-aks-migration-lab-mgmt` | `west-europe/windows-password.local` |
| `vm-aks-migration-lab-se-win` | `bas-aks-migration-lab-mgmt` | `sweden-workload/windows-password.local` |

The emulator Bastion hosts are managed separately from the baseline Terraform roots. Do not peer the emulator VNets to management for RDP: doing so would add a direct path outside the VPN lab. Do not expose TCP/3389 publicly.

Bring up the on-prem-to-West Europe and West Europe-to-GCP links and the West Europe hub/spoke. From on-prem and GCP, record route selection, private DNS answers, and HTTPS access to the West Europe frontend. From West Europe AKS, record private egress to both sites and public egress. Record which flows appear in the West Europe firewall logs and which do not. If modeling an existing West Europe inspection policy, export both `GatewaySubnet` and AKS subnet routing configuration before changing anything.

### Verified baseline

- Both emulator BGP sessions were connected. West Europe advertised `10.42.128.0/17` and Sweden's `10.44.1.0/24` to both peers.
- Both Windows emulator clients resolved the Sweden Blob endpoint privately and reached the West Europe and Sweden browser probes, plus both internal AKS smoke services. The smoke services use HTTP; TLS is a separate check.
- West Europe's Windows VM resolved `web.onprem.lab.internal` and `web.gcp.lab.internal` through Azure DNS. The emulator routers use source NAT only for DNS from the West Europe resolver's outbound subnet to their local DNS VMs; client traffic keeps its original source address.
- With `inspect_browser_probe=true`, the West Europe firewall logged an Allow for the on-premises HTTP probe. With `deny_onprem_browser_probe=true`, a fresh connection timed out and the firewall logged a Deny. The temporary deny rule was removed, and HTTP access was verified again. Keep `inspect_browser_probe=true` on subsequent plans to preserve those inspection routes.
- The Sweden Foundry account, project, private endpoint, and model deployments were provisioned. Private DNS and TCP/443 from the on-premises emulator passed; a Content Understanding inference request was not tested.

## 3. Add Israel Central and stage the cutover

1. Deploy the Israel hub, firewall, regional resolver, and replacement AKS spoke and private app endpoint. Keep that spoke isolated while it duplicates the existing `/17`. Bring up the inter-region VPN with BGP and verify exchange of the non-overlapping prefixes; the replacement spoke must not be advertised yet.
2. Bring up the new on-prem and GCP links to Israel using BGP. Keep the existing West Europe paths available for rollback. During coexistence, deliberately control which paths are preferred using route policy where supported, or isolate testing to lab prefixes. Check for asymmetric routing or unexpected equal-cost paths rather than assuming the newest tunnel wins.
3. Link the private DNS zones to both resolver VNets and configure per-region forwarding. Validate the Israel inbound endpoint directly and through each client's normal DNS path before switching conditional forwarders.
4. Run cutover tests with all four external links up. If retirement is planned, simulate withdrawing the West Europe links in the lab without deleting their configuration and verify the remaining paths. Do not retire the actual links before migration is complete and those paths have passed validation.

## 4. Test matrix

| ID | Test | Expected evidence |
|---|---|---|
| R1 | On-prem -> West Europe and Israel AKS | Both private frontends answer. Verify selected forward and return paths match the agreed policy while both regional VPNs are up. |
| R2 | GCP -> both Azure regions; on-prem <-> GCP if required | Each side learns the expected prefixes, selects the intended paths while both regional VPNs are up, and passes HTTPS in both required initiation directions. |
| F1 | On-prem -> West Europe AKS, BGP-only comparison | With no steering routes in the test path, HTTPS succeeds and does not traverse either firewall. Confirm chosen next hops and working diagnostics; absence of a log entry alone does not prove bypass. |
| F2 | Verify firewall inspection before and after cutover | Before cutover, confirm AKS 1 traffic traverses West Europe Firewall; after cutover, confirm it traverses Israel Central Firewall. Verify effective routes in both directions, a matching `AZFWNetworkRule` allow log, and a reversible deny rule that blocks a fresh test connection. |
| D1 | Query both inbound VIPs, then query through normal on-prem and GCP DNS | Both Azure endpoints give consistent answers for linked zones. Both site clients resolve regional app records and required AKS API records. Verify UDP and TCP and capture TTLs. |
| D2 | Pods in both regions -> on-prem and GCP DNS | Regional forwarding returns the authoritative private IPs. Check that nonexistent names fail as expected rather than timing out in a forwarding loop. |
| I1 | On-prem/GCP -> private HTTPS endpoint in each region | DNS, TLS hostname, HTTP status, and response region match. An internet-only test client without private network access cannot reach the private frontend. |
| I2 | Windows test VMs -> private HTTP test sites by IP | From each Windows VM, open each expected reachable `http://<private-ip>/` URL in a browser and verify the large site heading matches the destination. Record source, destination, and result. Repeat before and after cutover for the sites deployed in each phase. For inspected paths, correlate with the intended firewall's TCP/80 network-rule logs. |
| E1 | Pod in each region -> on-prem and GCP HTTPS | Destination records the expected source identity/IP for the selected CNI mode; response succeeds and observed routing and inspection match policy. |
| E2 | Pod in each region -> controlled public HTTPS endpoint | Destination records the expected public egress IP and regional egress behavior. If testing forced egress, verify intended allow/deny and AKS dependency connectivity separately. |
| H1 | Withdraw a single tunnel in a redundant site VPN | Measure BGP convergence and application recovery over the surviving tunnel. Compare to the agreed recovery target. |
| H2 | Simulate loss of Israel transit after old links are withdrawn | On-prem loses the route through Israel to West Europe and cannot fail over to its resolver through that same hub. Separately test a resolver-only failure with routing intact. Observe what still works within West Europe. |
| M1 | Cut over the first AKS spoke with an identical `/17` | Old route is withdrawn before the replacement is advertised. On-prem and GCP select Israel; private app VIP/TLS and required firewall policy still work. AKS 2 stays reachable in West Europe. |
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
