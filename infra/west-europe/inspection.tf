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
      prefixes  = ["${local.probe_vm_ip}/32"]
    }
    workload = {
      subnet_id = azurerm_subnet.aks2_workloads.id
      prefixes  = ["10.60.0.0/24", "10.70.0.0/24"]
    }
  } : {}

  name                          = "rt-${local.name}-browser-${each.key}"
  resource_group_name           = data.azurerm_resource_group.west_europe.name
  location                      = local.location
  bgp_route_propagation_enabled = true

  dynamic "route" {
    for_each = each.value.prefixes
    content {
      name                   = "inspect-${replace(replace(route.value, ".", "-"), "/", "-")}"
      address_prefix         = route.value
      next_hop_type          = "VirtualAppliance"
      next_hop_in_ip_address = azurerm_firewall.hub.ip_configuration[0].private_ip_address
    }
  }
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
