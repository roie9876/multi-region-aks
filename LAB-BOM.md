# Azure-only migration lab: bill of materials

This is the proposed Terraform build scope. West Europe and Sweden Central form the baseline; Israel Central is added before the first AKS cutover. Both external sites are emulated in Azure. No real GCP project or production on-premises network is required.

## Required Azure resources

| Deployment area | Azure services and quantities | Purpose |
|---|---|---|
| **West Europe** | 1 hub VNet, 1 DNS spoke VNet, and 2 distinct `/17` AKS spoke VNets; 1 route-based VPN Gateway with BGP; 1 Azure Firewall Standard and Firewall Policy; 1 DNS Private Resolver with 1 inbound and 1 outbound endpoint and a forwarding ruleset; 2 private AKS clusters, each with a system node pool and an internal HTTPS test frontend; 1 private Windows test VM in the stationary spoke; 1 Blob Storage account and 1 Key Vault, each with a private endpoint outside the migrating `/17`. | AKS 1 migrates; AKS 2 and its `/17` stay in West Europe. |
| **Israel Central** | 1 hub VNet, 1 DNS spoke VNet, and 1 AKS spoke VNet; 1 route-based VPN Gateway with BGP; 1 Azure Firewall Standard and Firewall Policy; 1 DNS Private Resolver with 1 inbound and 1 outbound endpoint and a forwarding ruleset; 1 replacement private AKS cluster with a system node pool and an internal HTTPS test frontend; 1 private Windows test VM in a hub test subnet; 1 Blob Storage account and 1 Key Vault, each with a private endpoint outside the migrating `/17`. | Stage AKS 1 on `10.42.128.0/17` in isolation. The Windows probe and PaaS endpoints can be tested before attaching the replacement spoke. |
| **Sweden Central workload** | 1 workload VNet with Global VNet Peering to West Europe; 1 private Windows test VM; 1 Blob Storage account and 1 Key Vault with private endpoints; 1 Microsoft Foundry account and project for Content Understanding, with a private endpoint and required model deployments. | Test actual Foundry requests and Blob/Key Vault access across regions. Verify model quota and any private service-to-service dependencies before deploying. No Sweden VPN Gateway or resolver in this phase. |
| **On-premises emulator** | 1 isolated VNet with router and client subnets; 1 Linux IPsec/BGP router VM with a Standard public IP; 1 private Windows Server DNS VM; 1 separate private Windows test VM; NSGs and a client-subnet route table. | Use strongSwan + FRRouting on the router. One Windows DNS server forwards to the Azure inbound endpoints; test retries from the Windows client. |
| **GCP emulator** | 1 separate isolated VNet with router and client subnets; 1 Linux IPsec/BGP router VM with a Standard public IP; 1 private Linux DNS VM; 1 separate private Windows test VM; NSGs and a client-subnet route table. | Simulate GCP-side BGP and DNS using strongSwan, FRRouting, and BIND. This does not validate Google Cloud Router, HA VPN, or Cloud DNS. |
| **Sweden Central management (persistent)** | 1 dedicated management resource group and VNet; 1 private Linux Terraform VM with a user-assigned managed identity; 1 Azure Bastion for operator access to that VM; 1 state Storage account with Blob private endpoint and container; 1 shared Log Analytics workspace; shared Private DNS zones and the management connectivity described below. | Run Terraform from Azure, not from the Mac. Keep the runner, state, shared DNS, and evidence outside both regional destroy scopes. |

Also include required subnets (`GatewaySubnet`, `AzureFirewallSubnet`, delegated resolver endpoint subnets, management/test subnets, and private endpoint subnets), NICs/disks, NSGs, regional peering pairs, identities and role assignments, and approved egress. Keep AKS APIs and app frontends private; disable public access on Blob, Key Vault, and Foundry. Public IP exceptions are the VPN gateways, emulator VPN routers, each firewall's standard deployment, and Bastion if the chosen deployment requires one. No workload VM gets a public IP. Confirm emulator regions, SKU availability, quotas, and cost before provisioning. Reserve distinct address space for AKS 2, the hubs, and other networks; do not assign the whole illustrative `/16` as a VNet.

### Private browser test sites

Add **five private Linux VMs**, one per location below, separate from the Windows test clients, DNS servers, and VPN routers. Each VM runs NGINX on TCP/80 and serves a static page with the site name as a large English heading. Terraform assigns a static private IP and outputs the `http://<private-ip>/` URL for each site.

| Location | VM placement | Page heading |
|---|---|---|
| West Europe | Stationary workload spoke, outside the migrating `/17` | **West Europe** |
| Israel Central | Hub test subnet, outside the duplicate `/17` | **Israel Central** |
| Sweden Central | Workload VNet, not the management VNet | **Sweden Central** |
| On-premises emulator | Client subnet behind the emulator router | **On-Premises** |
| GCP emulator | Client subnet behind the emulator router | **GCP** |

No web VM gets a public IP. Allow TCP/80 only from the lab test-client networks on the VM NSGs and, for inspected paths, in Azure Firewall Policy. From any Windows test VM, use the private IP URL directly to test the expected routed path. Record blocked or unavailable paths separately. These pages test HTTP reachability without relying on DNS, TLS, or AKS; keep the existing AKS HTTPS tests for the migration itself.

### VPN and route resources

- **Baseline:** two site-to-site connections on the West Europe VPN Gateway, one per emulator. Each Azure hub needs its own Local Network Gateway resource for each emulator peer it connects to: two initially and four by coexistence.
- **Coexistence:** add two site-to-site connections on the Israel Central gateway and the proposed BGP-enabled West Europe–Israel Central VNet-to-VNet VPN, with connection resources at both ends. Keep all four external connections in place during the spoke migration.
- **Emulators:** use non-overlapping LAN ranges and distinct BGP ASNs. Enable forwarding on the router NICs and guest OS. Route remote lab prefixes from the client/DNS subnet through its own router VM using UDRs. Do not peer either emulator VNet to the hubs or to the other emulator. Limit inbound IPsec to the intended peers; do not expose DNS or BGP to the internet.
- **Cutover:** Terraform owns the migrating spoke's lab and management connections separately from the clusters and VPNs. Detach West Europe, verify the old `/17` has been withdrawn at both emulators, then attach Israel and verify its advertisement. Rehearse rollback in the reverse order. Keep region-specific firewall inspection routes aligned with the active spoke and remove stale routes for the old spoke.

## Terraform runner, private access, and reset

- **Placement:** Use Sweden Central because it is outside the Israel reset and the long-term West Europe retirement. Bootstrap the management network, runner, identity, and state backend once from an approved admin path, then run routine Terraform from the VM. Store remote state in Blob, not on the VM disk: one locked state key per root, Entra ID authentication, Blob versioning/soft delete, and no state or plans in Git.
- **Access:** Give the runner's identity scoped Azure management-plane permissions for lab resources and separate data-plane roles for state, Blob, Key Vault, Foundry, and AKS as needed. Provide controlled outbound HTTPS to Azure management/identity and approved artifact sources. For private data-plane access, link the runner VNet to the required Blob, Key Vault, Foundry, and AKS private DNS zones and provide explicit routes to the private endpoints and active AKS APIs. Use direct management peerings to the relevant endpoint/spoke VNets where appropriate; peering to a hub alone does not reach every spoke. Verify DNS and HTTPS from the runner before applying roots that use those APIs.
- **Isolation exception:** Do not connect the central runner to both copies of `10.42.128.0/17`. Use an approved in-spoke bootstrap path for the isolated Israel cluster, or defer Kubernetes/Helm applies from the central runner until cutover. Establish isolated AKS egress and DNS first. The runner controls the emulators through Azure's management plane (for example, VM Run Command), not by peering their VNets or adding a path that bypasses the VPN test.

| Terraform root | Scope and lifecycle |
|---|---|
| `management` | Persistent runner, backend, Bastion, shared DNS zones, and logs. Never include in a regional reset. |
| `west-europe`, `sweden-workload`, `emulators` | Baseline regional and emulator resources. Keep them when replaying Israel deployment. |
| `israel-central` | Rebuildable regional network, firewall, resolver, private services, Windows VM, and replacement AKS. |
| `baseline-links`, `israel-links` | Separate baseline from Israel-dependent VPN connections, peerings, resolver and management VNet links, and emulator DNS/BGP configuration. `israel-links` owns the round trip, including the Israel-side dependencies it creates in West Europe or the emulators; keep shared DNS zones in `management`. |
| `aks1-cutover` | Owns the migrating spoke's attachment and related inspection routes in one Terraform state. Apply three configurations in order: West Europe active, detached, then Israel active. Verify BGP withdrawal before attachment. |

**Reset before migration:** verify AKS 1 is active in West Europe, remove Israel-specific test app and link dependencies (including the resolver fallback on each emulator), then review and destroy only `israel-central`. Reapply `israel-central` and `israel-links` in that order. If already cut over, roll back the `/17` first. Never destroy or detach the runner, state backend, West Europe VPNs, or shared DNS zones to reset Israel. Preserve Key Vault purge protection: use a fresh vault name for a clean rebuild or explicitly recover the previous vault; don't assume its original name can be reused immediately.

## Prove Azure Firewall is in the path

Send resource-specific diagnostics from both firewalls to the shared workspace. For the test HTTPS flow, add an explicit TCP/443 network rule from a Windows emulator client to the AKS internal app VIP. Start with a no-inspection comparison for that test flow, then steer inbound VPN traffic from `GatewaySubnet` to the destination hub firewall and steer the spoke's return flow through the same firewall. Keep BGP propagation on `GatewaySubnet`; use targeted routes, not a default route there.

Filter `AZFWNetworkRule` by firewall resource ID, time window, source IP, destination IP/port, and rule name. Capture **Allow and HTTPS success**, then a matching **Deny and failed fresh connection** after a temporary test-only rule change. Restore the allow rule afterward. Repeat before cutover on West Europe and after cutover on Israel Central. No matching log by itself does not prove bypass.

## DNS fidelity and test limits

Configure each emulator client to query only its own DNS VM. For `blob.core.windows.net`, the DNS VM forwards only to the Private Resolver inbound IPs over the tunnels: West Europe (`10.42.2.4`) initially, then Israel Central (`10.42.18.4`) as fallback after verification. Do not let these conditional queries fall back to Azure-provided DNS (`168.63.129.16`) or public recursion. Each DNS VM also serves a distinct test namespace so the Azure resolver outbound rules can test the reverse direction.

Use an uncached query and capture DNS logs or packets: **both tunnels down** must break the lookup from that emulator; **West Europe path unavailable** should trigger a retry through Israel if the configured forwarder supports it. Ensure an alternate route is not still carrying the preferred inbound IP during that test. Verify the answer and a separate HTTPS connection to it, including the Sweden return path. This proves hybrid forwarding and BGP behavior in the lab, not the customer's DNS retry policy unless the same product and settings are used. It does not validate GCP-specific route selection or Cloud DNS forwarding behavior.

## Add only when needed for production parity

| Add-on | Placement |
|---|---|
| F5 BIG-IP ingress, public frontend, and public DNS changes | Not part of this lab baseline. Add only for a separate public-ingress test. |
| West Europe-independent path to Sweden | Design and validate separately before any West Europe retirement rehearsal; the baseline Sweden path depends on West Europe. |

References: [Azure VPN Gateway with BGP](https://learn.microsoft.com/en-us/azure/vpn-gateway/configure-bgp) · [Azure hybrid DNS](https://learn.microsoft.com/en-us/azure/dns/private-resolver-hybrid-dns) · [Azure Firewall monitoring](https://learn.microsoft.com/en-us/azure/firewall/monitor-firewall) · [Foundry private networking](https://learn.microsoft.com/en-us/azure/foundry/how-to/configure-private-link) · [Content Understanding regions](https://learn.microsoft.com/en-us/azure/ai-services/content-understanding/language-region-support) · [Terraform remote state](https://developer.hashicorp.com/terraform/language/backend/azurerm)
