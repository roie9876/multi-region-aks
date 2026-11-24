variable "inter_hub_psk" {
  type      = string
  sensitive = true
  default   = null
  validation {
    condition     = var.inter_hub_psk == null ? true : can(regex("^[0-9A-Fa-f]{64}$", var.inter_hub_psk))
    error_message = "Supply a 64-character hexadecimal PSK generated for the inter-hub VPN."
  }
}

data "azurerm_virtual_network_gateway" "west" {
  name                = "vpngw-aks-migration-lab-we"
  resource_group_name = "rg-aks-migration-lab-we"
}

locals {
  inter_hub_gateways = {
    we = data.azurerm_virtual_network_gateway.west
    il = data.azurerm_virtual_network_gateway.israel
  }
}

resource "azurerm_virtual_network_gateway_connection" "inter_hub" {
  for_each                   = nonsensitive(var.inter_hub_psk != null) ? toset(["we", "il"]) : toset([])
  name                       = "conn-aks-migration-lab-inter-hub-${each.key}"
  resource_group_name        = local.inter_hub_gateways[each.key].resource_group_name
  location                   = local.inter_hub_gateways[each.key].location
  type                       = "Vnet2Vnet"
  virtual_network_gateway_id = local.inter_hub_gateways[each.key].id
  peer_virtual_network_gateway_id = local.inter_hub_gateways[
    each.key == "we" ? "il" : "we"
  ].id
  bgp_enabled = true
  shared_key  = var.inter_hub_psk
}
