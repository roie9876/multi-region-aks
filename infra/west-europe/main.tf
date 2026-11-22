terraform {
  required_version = ">= 1.15.7, < 2.0"

  backend "azurerm" {}

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "5.14.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id                 = var.subscription_id
  use_msi                         = true
  resource_provider_registrations = "none"
  storage_use_azuread             = true
}

data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "west_europe" {
  name = var.resource_group_name
}

data "azurerm_virtual_network" "management" {
  name                = var.management_vnet_name
  resource_group_name = var.management_resource_group_name
}

data "azurerm_private_dns_zone" "blob" {
  name                = var.blob_private_dns_zone_name
  resource_group_name = var.management_resource_group_name
}

data "azurerm_private_dns_zone" "vault" {
  name                = var.vault_private_dns_zone_name
  resource_group_name = var.management_resource_group_name
}

data "azurerm_log_analytics_workspace" "lab" {
  name                = var.management_log_analytics_name
  resource_group_name = var.management_resource_group_name
}

locals {
  name     = "aks-migration-lab-we"
  location = var.location
  tags     = { workload = "multi-region-aks", region = "westeurope", lifecycle = "baseline" }

  hub_address_space  = ["10.42.0.0/23", "10.42.3.0/24"]
  dns_address_space  = ["10.42.2.0/24"]
  aks1_address_space = ["10.42.128.0/17"]
  aks2_address_space = ["10.43.0.0/17"]

  dns_inbound_ip   = "10.42.2.4"
  windows_vm_ip    = "10.43.2.4"
  probe_vm_ip      = "10.43.2.10"
  onprem_dns_ip    = "10.60.0.10"
  gcp_dns_ip       = "10.70.0.10"
  vpn_gateway_asn  = 65010
  ssh_public_key   = trimspace(var.admin_ssh_public_key)
  sub_hash_12      = substr(sha256(var.subscription_id), 0, 12)
  sub_hash_10      = substr(sha256(var.subscription_id), 0, 10)
  lab_client_cidrs = ["10.42.0.0/15", "10.44.0.0/16", "10.45.0.0/24", "10.60.0.0/24", "10.70.0.0/24"]

  aks_clusters = {
    aks1 = {
      vnet_id      = azurerm_virtual_network.aks1.id
      subnet_id    = azurerm_subnet.aks1_nodes.id
      pod_cidr     = "10.244.0.0/16"
      service_cidr = "10.240.0.0/16"
      dns_ip       = "10.240.0.10"
    }
    aks2 = {
      vnet_id      = azurerm_virtual_network.aks2.id
      subnet_id    = azurerm_subnet.aks2_nodes.id
      pod_cidr     = "10.245.0.0/16"
      service_cidr = "10.241.0.0/16"
      dns_ip       = "10.241.0.10"
    }
  }
}

resource "azurerm_virtual_network" "hub" {
  name                = "vnet-${local.name}-hub"
  resource_group_name = data.azurerm_resource_group.west_europe.name
  location            = local.location
  address_space       = local.hub_address_space
  tags                = local.tags
}

resource "azurerm_subnet" "gateway" {
  name                 = "GatewaySubnet"
  resource_group_name  = data.azurerm_resource_group.west_europe.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.42.0.0/26"]
}

resource "azurerm_subnet" "firewall" {
  name                 = "AzureFirewallSubnet"
  resource_group_name  = data.azurerm_resource_group.west_europe.name
  virtual_network_name = azurerm_virtual_network.hub.name
  address_prefixes     = ["10.42.0.64/26"]
}

resource "azurerm_subnet" "private_endpoints" {
  name                              = "private-endpoints"
  resource_group_name               = data.azurerm_resource_group.west_europe.name
  virtual_network_name              = azurerm_virtual_network.hub.name
  address_prefixes                  = ["10.42.3.0/24"]
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_virtual_network" "dns" {
  name                = "vnet-${local.name}-dns"
  resource_group_name = data.azurerm_resource_group.west_europe.name
  location            = local.location
  address_space       = local.dns_address_space
  tags                = local.tags
}

resource "azurerm_subnet" "dns_inbound" {
  name                 = "inbound"
  resource_group_name  = data.azurerm_resource_group.west_europe.name
  virtual_network_name = azurerm_virtual_network.dns.name
  address_prefixes     = ["10.42.2.0/28"]

  delegation {
    name = "dnsResolvers"
    service_delegation {
      name    = "Microsoft.Network/dnsResolvers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

resource "azurerm_subnet" "dns_outbound" {
  name                 = "outbound"
  resource_group_name  = data.azurerm_resource_group.west_europe.name
  virtual_network_name = azurerm_virtual_network.dns.name
  address_prefixes     = ["10.42.2.16/28"]

  delegation {
    name = "dnsResolvers"
    service_delegation {
      name    = "Microsoft.Network/dnsResolvers"
      actions = ["Microsoft.Network/virtualNetworks/subnets/join/action"]
    }
  }
}

# AKS 1 spoke (10.42.128.0/17) is intentionally NOT peered to the hub in this root.
# Its attachment is owned by the separate aks1-cutover root.
resource "azurerm_virtual_network" "aks1" {
  name                = "vnet-${local.name}-aks1"
  resource_group_name = data.azurerm_resource_group.west_europe.name
  location            = local.location
  address_space       = local.aks1_address_space
  tags                = local.tags
}

resource "azurerm_subnet" "aks1_nodes" {
  name                 = "aks-system"
  resource_group_name  = data.azurerm_resource_group.west_europe.name
  virtual_network_name = azurerm_virtual_network.aks1.name
  address_prefixes     = ["10.42.129.0/24"]
}

resource "azurerm_virtual_network" "aks2" {
  name                = "vnet-${local.name}-aks2"
  resource_group_name = data.azurerm_resource_group.west_europe.name
  location            = local.location
  address_space       = local.aks2_address_space
  tags                = local.tags
}

resource "azurerm_subnet" "aks2_nodes" {
  name                 = "aks-system"
  resource_group_name  = data.azurerm_resource_group.west_europe.name
  virtual_network_name = azurerm_virtual_network.aks2.name
  address_prefixes     = ["10.43.1.0/24"]
}

resource "azurerm_subnet" "aks2_workloads" {
  name                 = "workloads"
  resource_group_name  = data.azurerm_resource_group.west_europe.name
  virtual_network_name = azurerm_virtual_network.aks2.name
  address_prefixes     = ["10.43.2.0/24"]
}

resource "azurerm_public_ip" "hub" {
  for_each            = toset(["vpngw", "firewall"])
  name                = "pip-${local.name}-${each.key}"
  resource_group_name = data.azurerm_resource_group.west_europe.name
  location            = local.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags

  lifecycle {
    ignore_changes = [ip_tags]
  }
}

resource "azurerm_virtual_network_gateway" "hub" {
  name                = "vpngw-${local.name}"
  resource_group_name = data.azurerm_resource_group.west_europe.name
  location            = local.location
  type                = "Vpn"
  vpn_type            = "RouteBased"
  sku                 = var.vpn_gateway_sku
  active_active       = false
  bgp_enabled         = true
  tags                = local.tags

  ip_configuration {
    name                          = "default"
    private_ip_address_allocation = "Dynamic"
    subnet_id                     = azurerm_subnet.gateway.id
    public_ip_address_id          = azurerm_public_ip.hub["vpngw"].id
  }

  bgp_settings {
    asn = local.vpn_gateway_asn
  }
}

resource "azurerm_virtual_network_peering" "hub_to_dns" {
  name                         = "peer-hub-to-dns"
  resource_group_name          = data.azurerm_resource_group.west_europe.name
  virtual_network_name         = azurerm_virtual_network.hub.name
  remote_virtual_network_id    = azurerm_virtual_network.dns.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = true

  depends_on = [azurerm_virtual_network_gateway.hub]
}

resource "azurerm_virtual_network_peering" "dns_to_hub" {
  name                         = "peer-dns-to-hub"
  resource_group_name          = data.azurerm_resource_group.west_europe.name
  virtual_network_name         = azurerm_virtual_network.dns.name
  remote_virtual_network_id    = azurerm_virtual_network.hub.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  use_remote_gateways          = true

  depends_on = [
    azurerm_virtual_network_gateway.hub,
    azurerm_virtual_network_peering.hub_to_dns
  ]
}

resource "azurerm_virtual_network_peering" "hub_to_aks2" {
  name                         = "peer-hub-to-aks2"
  resource_group_name          = data.azurerm_resource_group.west_europe.name
  virtual_network_name         = azurerm_virtual_network.hub.name
  remote_virtual_network_id    = azurerm_virtual_network.aks2.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  allow_gateway_transit        = true

  depends_on = [azurerm_virtual_network_gateway.hub]
}

resource "azurerm_virtual_network_peering" "aks2_to_hub" {
  name                         = "peer-aks2-to-hub"
  resource_group_name          = data.azurerm_resource_group.west_europe.name
  virtual_network_name         = azurerm_virtual_network.aks2.name
  remote_virtual_network_id    = azurerm_virtual_network.hub.id
  allow_virtual_network_access = true
  allow_forwarded_traffic      = true
  use_remote_gateways          = true

  depends_on = [
    azurerm_virtual_network_gateway.hub,
    azurerm_virtual_network_peering.hub_to_aks2
  ]
}

resource "azurerm_firewall_policy" "hub" {
  name                     = "fwpol-${local.name}"
  resource_group_name      = data.azurerm_resource_group.west_europe.name
  location                 = local.location
  sku                      = "Standard"
  threat_intelligence_mode = "Alert"
  tags                     = local.tags

  dns {
    proxy_enabled = true
    servers       = [local.dns_inbound_ip]
  }
}

resource "azurerm_firewall_policy_rule_collection_group" "lab" {
  name               = "rcg-${local.name}-lab"
  firewall_policy_id = azurerm_firewall_policy.hub.id
  priority           = 200

  network_rule_collection {
    name     = "nrc-lab-traffic"
    priority = 200
    action   = "Allow"

    rule {
      name                  = "allow-emulator-to-aks-https"
      protocols             = ["TCP"]
      source_addresses      = ["10.60.0.0/24", "10.70.0.0/24", "10.42.0.0/15", "10.44.0.0/16"]
      destination_addresses = ["10.42.128.0/17", "10.43.0.0/17", "10.42.3.0/24"]
      destination_ports     = ["443"]
    }

    rule {
      name                  = "allow-lab-http-probes"
      protocols             = ["TCP"]
      source_addresses      = local.lab_client_cidrs
      destination_addresses = local.lab_client_cidrs
      destination_ports     = ["80"]
    }

    rule {
      name                  = "allow-lab-dns"
      protocols             = ["TCP", "UDP"]
      source_addresses      = local.lab_client_cidrs
      destination_addresses = [local.dns_inbound_ip, local.onprem_dns_ip, local.gcp_dns_ip]
      destination_ports     = ["53"]
    }

    rule {
      name                  = "allow-aks-to-emulators-https"
      protocols             = ["TCP"]
      source_addresses      = ["10.42.128.0/17", "10.43.0.0/17"]
      destination_addresses = ["10.60.0.0/24", "10.70.0.0/24", "10.44.0.0/16"]
      destination_ports     = ["443"]
    }

    rule {
      name                  = "allow-lab-icmp"
      protocols             = ["ICMP"]
      source_addresses      = local.lab_client_cidrs
      destination_addresses = local.lab_client_cidrs
      destination_ports     = ["*"]
    }
  }
}

resource "azurerm_firewall" "hub" {
  name                = "afw-${local.name}"
  resource_group_name = data.azurerm_resource_group.west_europe.name
  location            = local.location
  sku_name            = "AZFW_VNet"
  sku_tier            = "Standard"
  firewall_policy_id  = azurerm_firewall_policy.hub.id
  tags                = local.tags

  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.firewall.id
    public_ip_address_id = azurerm_public_ip.hub["firewall"].id
  }

  depends_on = [azurerm_firewall_policy_rule_collection_group.lab]
}

resource "azurerm_monitor_diagnostic_setting" "firewall" {
  name                           = "diag-${local.name}-afw"
  target_resource_id             = azurerm_firewall.hub.id
  log_analytics_workspace_id     = data.azurerm_log_analytics_workspace.lab.id
  log_analytics_destination_type = "Dedicated"

  enabled_log {
    category_group = "allLogs"
  }

  enabled_metric {
    category = "AllMetrics"
  }
}

resource "azurerm_private_dns_resolver" "main" {
  name                = "dnspr-${local.name}"
  resource_group_name = data.azurerm_resource_group.west_europe.name
  location            = local.location
  virtual_network_id  = azurerm_virtual_network.dns.id
  tags                = local.tags
}

resource "azurerm_private_dns_resolver_inbound_endpoint" "main" {
  name                    = "in-${local.name}"
  private_dns_resolver_id = azurerm_private_dns_resolver.main.id
  location                = local.location
  tags                    = local.tags

  ip_configurations {
    private_ip_allocation_method = "Static"
    private_ip_address           = local.dns_inbound_ip
    subnet_id                    = azurerm_subnet.dns_inbound.id
  }
}

resource "azurerm_private_dns_resolver_outbound_endpoint" "main" {
  name                    = "out-${local.name}"
  private_dns_resolver_id = azurerm_private_dns_resolver.main.id
  location                = local.location
  subnet_id               = azurerm_subnet.dns_outbound.id
  tags                    = local.tags
}

resource "azurerm_private_dns_resolver_dns_forwarding_ruleset" "main" {
  name                                       = "ruleset-${local.name}"
  resource_group_name                        = data.azurerm_resource_group.west_europe.name
  location                                   = local.location
  private_dns_resolver_outbound_endpoint_ids = [azurerm_private_dns_resolver_outbound_endpoint.main.id]
  tags                                       = local.tags
}

resource "azurerm_private_dns_resolver_forwarding_rule" "onprem" {
  name                      = "rule-onprem-lab-example"
  dns_forwarding_ruleset_id = azurerm_private_dns_resolver_dns_forwarding_ruleset.main.id
  domain_name               = "onprem.lab.internal."
  enabled                   = true

  target_dns_servers {
    ip_address = local.onprem_dns_ip
    port       = 53
  }
}

resource "azurerm_private_dns_resolver_forwarding_rule" "gcp" {
  name                      = "rule-gcp-lab-example"
  dns_forwarding_ruleset_id = azurerm_private_dns_resolver_dns_forwarding_ruleset.main.id
  domain_name               = "gcp.lab.internal."
  enabled                   = true

  target_dns_servers {
    ip_address = local.gcp_dns_ip
    port       = 53
  }
}

resource "azurerm_private_dns_resolver_virtual_network_link" "regional" {
  for_each = {
    hub  = azurerm_virtual_network.hub.id
    dns  = azurerm_virtual_network.dns.id
    aks1 = azurerm_virtual_network.aks1.id
    aks2 = azurerm_virtual_network.aks2.id
  }
  name                      = "vnl-ruleset-we-${each.key}"
  dns_forwarding_ruleset_id = azurerm_private_dns_resolver_dns_forwarding_ruleset.main.id
  virtual_network_id        = each.value
}

resource "azurerm_private_dns_zone_virtual_network_link" "blob_we" {
  for_each = {
    hub  = azurerm_virtual_network.hub.id
    dns  = azurerm_virtual_network.dns.id
    aks1 = azurerm_virtual_network.aks1.id
    aks2 = azurerm_virtual_network.aks2.id
  }
  name                = "we-${each.key}"
  private_dns_zone_id = data.azurerm_private_dns_zone.blob.id
  virtual_network_id  = each.value
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "vault_we" {
  for_each = {
    hub  = azurerm_virtual_network.hub.id
    dns  = azurerm_virtual_network.dns.id
    aks1 = azurerm_virtual_network.aks1.id
    aks2 = azurerm_virtual_network.aks2.id
  }
  name                = "we-${each.key}"
  private_dns_zone_id = data.azurerm_private_dns_zone.vault.id
  virtual_network_id  = each.value
  tags                = local.tags
}

resource "azurerm_storage_account" "we" {
  name                            = "staksmigwe${local.sub_hash_12}"
  resource_group_name             = data.azurerm_resource_group.west_europe.name
  location                        = local.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  public_network_access           = "Disabled"
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  default_to_oauth_authentication = true
  tags                            = local.tags
}

resource "azurerm_private_endpoint" "blob" {
  name                = "pe-${local.name}-blob"
  resource_group_name = data.azurerm_resource_group.west_europe.name
  location            = local.location
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "blob"
    private_connection_resource_id = azurerm_storage_account.we.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.blob.id]
  }
}

resource "azurerm_key_vault" "we" {
  name                          = "kv-aksmig-we-${local.sub_hash_10}"
  resource_group_name           = data.azurerm_resource_group.west_europe.name
  location                      = local.location
  sku_name                      = "standard"
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  rbac_authorization_enabled    = true
  public_network_access_enabled = false
  purge_protection_enabled      = false
  soft_delete_retention_days    = 7
  tags                          = local.tags

  network_acls {
    bypass         = "None"
    default_action = "Deny"
  }
}

resource "azurerm_private_endpoint" "vault" {
  name                = "pe-${local.name}-vault"
  resource_group_name = data.azurerm_resource_group.west_europe.name
  location            = local.location
  subnet_id           = azurerm_subnet.private_endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "vault"
    private_connection_resource_id = azurerm_key_vault.we.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "vault"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.vault.id]
  }
}

resource "azurerm_user_assigned_identity" "aks" {
  for_each            = local.aks_clusters
  name                = "id-${local.name}-${each.key}"
  resource_group_name = data.azurerm_resource_group.west_europe.name
  location            = local.location
  tags                = local.tags
}

resource "azurerm_role_assignment" "aks_network" {
  for_each             = local.aks_clusters
  scope                = each.value.vnet_id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.aks[each.key].principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_kubernetes_cluster" "aks" {
  for_each                          = local.aks_clusters
  name                              = "aks-${local.name}-${each.key}"
  resource_group_name               = data.azurerm_resource_group.west_europe.name
  location                          = local.location
  dns_prefix                        = "aks-${local.name}-${each.key}"
  node_resource_group               = "rg-${local.name}-${each.key}-nodes"
  private_cluster_enabled           = true
  private_dns_zone_id               = "System"
  role_based_access_control_enabled = true
  oidc_issuer_enabled               = true
  workload_identity_enabled         = true
  sku_tier                          = "Standard"
  tags                              = local.tags

  lifecycle {
    # Microsoft Defender is managed by subscription policy.
    ignore_changes = [microsoft_defender]
  }

  default_node_pool {
    name                         = "system"
    node_count                   = var.aks_node_count
    vm_size                      = var.aks_node_vm_size
    vnet_subnet_id               = each.value.subnet_id
    os_disk_type                 = "Managed"
    os_disk_size_gb              = 64
    only_critical_addons_enabled = false
    temporary_name_for_rotation  = "sysrot"

    upgrade_settings {
      max_surge                     = "10%"
      drain_timeout_in_minutes      = 0
      node_soak_duration_in_minutes = 0
    }
  }

  node_provisioning_profile {
    mode = "Manual"
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.aks[each.key].id]
  }

  linux_profile {
    admin_username = var.admin_username
    ssh_key {
      key_data = local.ssh_public_key
    }
  }

  azure_active_directory_role_based_access_control {
    azure_rbac_enabled = true
    tenant_id          = data.azurerm_client_config.current.tenant_id
  }

  network_profile {
    network_plugin      = "azure"
    network_plugin_mode = "overlay"
    network_policy      = "cilium"
    network_data_plane  = "cilium"
    load_balancer_sku   = "standard"
    outbound_type       = "loadBalancer"
    pod_cidr            = each.value.pod_cidr
    service_cidr        = each.value.service_cidr
    dns_service_ip      = each.value.dns_ip

    load_balancer_profile {
      managed_outbound_ip_count = 1
    }
  }

  depends_on = [azurerm_role_assignment.aks_network]
}

resource "azurerm_network_security_group" "workloads" {
  name                = "nsg-${local.name}-workloads"
  resource_group_name = data.azurerm_resource_group.west_europe.name
  location            = local.location
  tags                = local.tags

  security_rule {
    name                       = "AllowLabHttpToProbe"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefixes    = local.lab_client_cidrs
    destination_address_prefix = local.probe_vm_ip
  }

  security_rule {
    name                       = "AllowLabRdpAndSsh"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_ranges    = ["22", "3389"]
    source_address_prefixes    = [data.azurerm_virtual_network.management.address_space[0], "10.42.0.0/15", "10.44.0.0/16"]
    destination_address_prefix = "10.43.2.0/24"
  }

  security_rule {
    name                       = "AllowLabIcmp"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Icmp"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefixes    = local.lab_client_cidrs
    destination_address_prefix = "10.43.2.0/24"
  }

  security_rule {
    name                       = "DenyOtherInbound"
    priority                   = 200
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "workloads" {
  subnet_id                 = azurerm_subnet.aks2_workloads.id
  network_security_group_id = azurerm_network_security_group.workloads.id
}

resource "azurerm_network_interface" "windows" {
  name                = "nic-${local.name}-win"
  resource_group_name = data.azurerm_resource_group.west_europe.name
  location            = local.location
  tags                = local.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.aks2_workloads.id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.windows_vm_ip
  }
}

resource "azurerm_windows_virtual_machine" "stationary" {
  name                  = "vm-${local.name}-win"
  computer_name         = "vm-we-win"
  resource_group_name   = data.azurerm_resource_group.west_europe.name
  location              = local.location
  size                  = var.windows_vm_size
  admin_username        = var.admin_username
  admin_password        = var.windows_admin_password
  network_interface_ids = [azurerm_network_interface.windows.id]
  tags                  = local.tags

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "MicrosoftWindowsServer"
    offer     = "WindowsServer"
    sku       = "2022-datacenter-g2"
    version   = "latest"
  }

  depends_on = [azurerm_subnet_network_security_group_association.workloads]
}

resource "azurerm_network_interface" "probe" {
  name                = "nic-${local.name}-probe"
  resource_group_name = data.azurerm_resource_group.west_europe.name
  location            = local.location
  tags                = local.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.aks2_workloads.id
    private_ip_address_allocation = "Static"
    private_ip_address            = local.probe_vm_ip
  }
}

resource "azurerm_linux_virtual_machine" "probe" {
  name                            = "vm-${local.name}-probe"
  computer_name                   = "vm-we-probe"
  resource_group_name             = data.azurerm_resource_group.west_europe.name
  location                        = local.location
  size                            = var.probe_vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.probe.id]
  custom_data                     = filebase64("${path.module}/probe.cloud-init.yaml")
  tags                            = local.tags

  admin_ssh_key {
    username   = var.admin_username
    public_key = local.ssh_public_key
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "StandardSSD_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "ubuntu-24_04-lts"
    sku       = "server"
    version   = "latest"
  }

  depends_on = [azurerm_subnet_network_security_group_association.workloads]
}
