# Israel Central staging layer (`infra/israel-central`)

This Terraform root provisions the **isolated Israel Central staging environment** (`rg-aks-migration-lab-il`) before any coexistence links or `/17` BGP cutover.

## Scope and isolation boundaries

- **Hub VNet (`10.42.16.0/23`, `10.42.19.0/24`):**
  - `GatewaySubnet` (`10.42.16.0/26`) with route-based VPN Gateway (`VpnGw1AZ`, BGP ASN `65020`).
  - `AzureFirewallSubnet` (`10.42.16.64/26`) with Azure Firewall Standard, Firewall Policy, and diagnostic settings to the shared Log Analytics workspace.
  - `workloads` hub test subnet (`10.42.17.0/24`) outside the duplicate `/17`, hosting the private Windows test VM (`10.42.17.4`) and private Linux HTTP probe VM (`http://10.42.17.10/`, heading **Israel Central**).
  - `private-endpoints` subnet (`10.42.19.0/24`) hosting private endpoints for the regional Blob Storage account and Key Vault (registered in the shared `privatelink.blob.core.windows.net` and `privatelink.vaultcore.azure.net` zones).
- **DNS spoke VNet (`10.42.18.0/24`):**
  - Peered to the Israel Central hub VNet with gateway transit.
  - Hosts the regional Azure DNS Private Resolver with static inbound endpoint `10.42.18.4`, outbound endpoint (`10.42.18.16/28`), and forwarding ruleset for `onprem.lab.internal.` and `gcp.lab.internal.`.
- **Disconnected replacement AKS 1 spoke (`10.42.128.0/17`):**
  - Stages the replacement private AKS cluster (`aks-aks-migration-lab-il-aks1`) in `aks-system` (`10.42.129.0/24`) with Azure CNI Overlay and Cilium.
  - **Intentionally unpeered** from the Israel hub VNet and the Sweden management VNet while West Europe still originates `10.42.128.0/17`.
- **Not included in this root:**
  - Site-to-site VPN connections to the on-premises/GCP emulators, inter-region VPN connections, management VNet peerings, and emulator conditional-forwarder changes belong to `israel-links`.
  - Attaching the replacement `10.42.128.0/17` spoke after West Europe withdrawal belongs to `aks1-cutover`.
