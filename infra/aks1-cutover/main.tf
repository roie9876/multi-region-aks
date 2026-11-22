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

variable "hub" {
  type = object({ id = string, name = string, resource_group = string })
}

variable "spoke" {
  type = object({ id = string, name = string, resource_group = string })
}

variable "attached" {
  type        = bool
  description = "Set false and verify route withdrawal before changing the active site."
}

data "azurerm_virtual_network" "management" {
  name                = "vnet-aks-migration-lab-mgmt"
  resource_group_name = "rg-aks-migration-lab-mgmt"
}

resource "azurerm_virtual_network_peering" "hub_to_spoke" {
  count                        = var.attached ? 1 : 0
  name                         = "hub-to-aks1"
  resource_group_name          = var.hub.resource_group
  virtual_network_name         = var.hub.name
  remote_virtual_network_id    = var.spoke.id
  allow_gateway_transit        = true
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true
}

resource "azurerm_virtual_network_peering" "spoke_to_hub" {
  count                        = var.attached ? 1 : 0
  name                         = "aks1-to-hub"
  resource_group_name          = var.spoke.resource_group
  virtual_network_name         = var.spoke.name
  remote_virtual_network_id    = var.hub.id
  use_remote_gateways          = true
  allow_forwarded_traffic      = true
  allow_virtual_network_access = true
  depends_on                   = [azurerm_virtual_network_peering.hub_to_spoke]
}

resource "azurerm_virtual_network_peering" "management_to_spoke" {
  count                        = var.attached ? 1 : 0
  name                         = "management-to-active-aks1"
  resource_group_name          = data.azurerm_virtual_network.management.resource_group_name
  virtual_network_name         = data.azurerm_virtual_network.management.name
  remote_virtual_network_id    = var.spoke.id
  allow_virtual_network_access = true
}

resource "azurerm_virtual_network_peering" "spoke_to_management" {
  count                        = var.attached ? 1 : 0
  name                         = "aks1-to-management"
  resource_group_name          = var.spoke.resource_group
  virtual_network_name         = var.spoke.name
  remote_virtual_network_id    = data.azurerm_virtual_network.management.id
  allow_virtual_network_access = true
  depends_on                   = [azurerm_virtual_network_peering.management_to_spoke]
}
