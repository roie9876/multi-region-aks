variable "inspect_aks1_private_traffic" {
  type        = bool
  default     = false
  description = "Keep the West Europe AKS 1 inspection paths ready for migration or rollback."
}

variable "west_owns_aks1_prefix" {
  type        = bool
  default     = true
  description = "Install the gateway route to AKS 1 only while West Europe owns its prefix."
}

variable "inspect_browser_probe" {
  type    = bool
  default = false
}

variable "deny_onprem_browser_probe" {
  type    = bool
  default = false
}

resource "azurerm_route_table" "browser_inspection" {
  for_each = var.inspect_browser_probe ? {
    gateway = {
      subnet_id = azurerm_subnet.gateway.id
      prefixes = concat(
        ["${local.probe_vm_ip}/32"],
        var.inspect_aks1_private_traffic ? ["10.44.1.5/32"] : [],
        var.inspect_aks1_private_traffic && var.west_owns_aks1_prefix ? local.aks1_address_space : []
      )
    }
    workload = {
      subnet_id = azurerm_subnet.aks2_workloads.id
      prefixes  = concat(["10.60.0.0/24", "10.70.0.0/24"], var.inspect_aks1_private_traffic ? local.aks1_address_space : [])
    }
  } : {}

  name                          = "rt-${local.name}-browser-${each.key}"
  resource_group_name           = data.azurerm_resource_group.west_europe.name
  location                      = local.location
  bgp_route_propagation_enabled = true

  dynamic "route" {
    for_each = each.value.prefixes
    content {
      name                   = route.value == "10.44.1.5/32" ? "inspect-sweden-probe" : "inspect-${replace(replace(route.value, ".", "-"), "/", "-")}"
      address_prefix         = route.value
      next_hop_type          = "VirtualAppliance"
      next_hop_in_ip_address = azurerm_firewall.hub.ip_configuration[0].private_ip_address
    }
  }
}

resource "azurerm_route_table" "aks1_inspection" {
  count                         = var.inspect_aks1_private_traffic ? 1 : 0
  name                          = "rt-${local.name}-aks1-inspection"
  resource_group_name           = data.azurerm_resource_group.west_europe.name
  location                      = local.location
  bgp_route_propagation_enabled = true

  dynamic "route" {
    for_each = {
      onprem = "10.60.0.0/24"
      gcp    = "10.70.0.0/24"
      aks2   = "10.43.0.0/17"
      sweden = "10.44.1.5/32"
      israel = "10.42.17.10/32"
      dns    = "${local.dns_inbound_ip}/32"
    }
    content {
      name                   = route.key
      address_prefix         = route.value
      next_hop_type          = "VirtualAppliance"
      next_hop_in_ip_address = azurerm_firewall.hub.ip_configuration[0].private_ip_address
    }
  }

  lifecycle {
    precondition {
      condition     = var.inspect_browser_probe
      error_message = "Enable inspect_browser_probe for symmetric GatewaySubnet and probe return routes."
    }
  }
}

resource "azurerm_subnet_route_table_association" "aks1_inspection" {
  count          = var.inspect_aks1_private_traffic ? 1 : 0
  subnet_id      = azurerm_subnet.aks1_nodes.id
  route_table_id = azurerm_route_table.aks1_inspection[0].id
}

resource "azurerm_route_table" "aks1_dns_return" {
  count                         = var.inspect_aks1_private_traffic ? 1 : 0
  name                          = "rt-${local.name}-aks1-dns-return"
  resource_group_name           = data.azurerm_resource_group.west_europe.name
  location                      = local.location
  bgp_route_propagation_enabled = true

  route {
    name                   = "aks1"
    address_prefix         = "10.42.129.0/24"
    next_hop_type          = "VirtualAppliance"
    next_hop_in_ip_address = azurerm_firewall.hub.ip_configuration[0].private_ip_address
  }
}

resource "azurerm_subnet_route_table_association" "aks1_dns_return" {
  count          = var.inspect_aks1_private_traffic ? 1 : 0
  subnet_id      = azurerm_subnet.dns_inbound.id
  route_table_id = azurerm_route_table.aks1_dns_return[0].id
}

resource "azurerm_subnet_route_table_association" "browser_inspection" {
  for_each       = azurerm_route_table.browser_inspection
  subnet_id      = each.key == "gateway" ? azurerm_subnet.gateway.id : azurerm_subnet.aks2_workloads.id
  route_table_id = each.value.id
}

resource "azurerm_firewall_policy_rule_collection_group" "browser_deny" {
  count              = var.inspect_browser_probe && var.deny_onprem_browser_probe ? 1 : 0
  name               = "rcg-${local.name}-browser-deny"
  firewall_policy_id = azurerm_firewall_policy.hub.id
  priority           = 190

  network_rule_collection {
    name     = "deny-browser-test"
    priority = 190
    action   = "Deny"

    rule {
      name                  = "deny-onprem-client-to-west-probe"
      protocols             = ["TCP"]
      source_addresses      = ["10.60.0.11"]
      destination_addresses = [local.probe_vm_ip]
      destination_ports     = ["80"]
    }
  }
}
