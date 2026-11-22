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
}

variable "subscription_id" {
  type = string
}

variable "west_gateway_id" {
  type = string
}

variable "west_hub" {
  type = object({ id = string, name = string })
}

variable "sweden_vnet" {
  type = object({ id = string, name = string })
}

variable "management_targets" {
  description = "Non-migrating workload or endpoint VNets requiring direct management access."
  type = map(object({
    id             = string
    name           = string
    resource_group = string
  }))
}

variable "sites" {
  type = map(object({
    public_ip = string
    peer_ip   = string
    asn       = number
    prefix    = string
  }))
}

variable "site_keys" {
  type      = map(string)
  sensitive = true
}

locals {
  west_group       = "rg-aks-migration-lab-we"
  sweden_group     = "rg-aks-migration-lab-se"
  management_group = "rg-aks-migration-lab-mgmt"
}

data "azurerm_virtual_network" "management" {
  name                = "vnet-aks-migration-lab-mgmt"
  resource_group_name = local.management_group
}

resource "azurerm_virtual_network_peering" "west_to_sweden" {
  name                         = "west-to-sweden"
  resource_group_name          = local.west_group
  virtual_network_name         = var.west_hub.name
  remote_virtual_network_id    = var.sweden_vnet.id
  allow_gateway_transit        = true
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true
}

resource "azurerm_virtual_network_peering" "sweden_to_west" {
  name                         = "sweden-to-west"
  resource_group_name          = local.sweden_group
  virtual_network_name         = var.sweden_vnet.name
  remote_virtual_network_id    = var.west_hub.id
  use_remote_gateways          = true
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true
  depends_on                   = [azurerm_virtual_network_peering.west_to_sweden]
}

resource "azurerm_virtual_network_peering" "management_out" {
  for_each                     = var.management_targets
  name                         = "management-to-${each.key}"
  resource_group_name          = local.management_group
  virtual_network_name         = data.azurerm_virtual_network.management.name
  remote_virtual_network_id    = each.value.id
  allow_virtual_network_access = true
}

resource "azurerm_virtual_network_peering" "management_return" {
  for_each                     = var.management_targets
  name                         = "${each.key}-to-management"
  resource_group_name          = each.value.resource_group
  virtual_network_name         = each.value.name
  remote_virtual_network_id    = data.azurerm_virtual_network.management.id
  allow_virtual_network_access = true
  depends_on                   = [azurerm_virtual_network_peering.management_out]
}

resource "azurerm_local_network_gateway" "site" {
  for_each            = var.sites
  name                = "lng-aks-migration-lab-${each.key}"
  resource_group_name = local.west_group
  location            = "westeurope"
  gateway_address     = each.value.public_ip
  address_space       = [each.value.prefix]

  bgp_settings {
    asn                 = each.value.asn
    bgp_peering_address = each.value.peer_ip
  }
}

resource "azurerm_virtual_network_gateway_connection" "site" {
  for_each                   = var.sites
  name                       = "conn-aks-migration-lab-${each.key}-we"
  resource_group_name        = local.west_group
  location                   = "westeurope"
  type                       = "IPsec"
  virtual_network_gateway_id = var.west_gateway_id
  local_network_gateway_id   = azurerm_local_network_gateway.site[each.key].id
  bgp_enabled                = true
  shared_key                 = var.site_keys[each.key]

  ipsec_policy {
    dh_group         = "DHGroup14"
    ike_encryption   = "AES256"
    ike_integrity    = "SHA256"
    ipsec_encryption = "AES256"
    ipsec_integrity  = "SHA256"
    pfs_group        = "PFS14"
    sa_lifetime      = 27000
    sa_datasize      = 102400000
  }
}
