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

variable "subscription_id" {
  type = string
}

variable "onprem_israel_psk" {
  type      = string
  sensitive = true
  validation {
    condition     = can(regex("^[0-9A-Fa-f]{64}$", var.onprem_israel_psk))
    error_message = "Supply a 64-character hexadecimal PSK generated for this tunnel."
  }
}

variable "israel_bgp_ip" {
  type        = string
  description = "The deployed Israel gateway's default BGP peering address."
}

provider "azurerm" {
  features {}
  subscription_id                 = var.subscription_id
  use_msi                         = true
  resource_provider_registrations = "none"
}

locals {
  israel_group    = "rg-aks-migration-lab-il"
  emulators_group = "rg-aks-migration-lab-emulators"
  onprem_bgp_ip   = "10.60.1.4"
  onprem_asn      = 65060
}

data "azurerm_virtual_network_gateway" "israel" {
  name                = "vpngw-aks-migration-lab-il"
  resource_group_name = local.israel_group
}

data "azurerm_public_ip" "israel" {
  name                = "pip-aks-migration-lab-il-vpngw"
  resource_group_name = local.israel_group
}

data "azurerm_public_ip" "onprem" {
  name                = "pip-aks-migration-lab-onprem-router"
  resource_group_name = local.emulators_group
}

data "azurerm_virtual_machine" "onprem" {
  name                = "vm-aks-migration-lab-onprem-router"
  resource_group_name = local.emulators_group
}

resource "azurerm_local_network_gateway" "onprem" {
  name                = "lng-aks-migration-lab-onprem-il"
  resource_group_name = local.israel_group
  location            = data.azurerm_virtual_network_gateway.israel.location
  gateway_address     = data.azurerm_public_ip.onprem.ip_address

  bgp_settings {
    asn                 = local.onprem_asn
    bgp_peering_address = local.onprem_bgp_ip
  }
}

resource "azurerm_virtual_network_gateway_connection" "onprem" {
  name                       = "conn-aks-migration-lab-onprem-il"
  resource_group_name        = local.israel_group
  location                   = data.azurerm_virtual_network_gateway.israel.location
  type                       = "IPsec"
  connection_mode            = "ResponderOnly"
  virtual_network_gateway_id = data.azurerm_virtual_network_gateway.israel.id
  local_network_gateway_id   = azurerm_local_network_gateway.onprem.id
  bgp_enabled                = true
  shared_key                 = var.onprem_israel_psk

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

resource "azurerm_virtual_machine_run_command" "onprem" {
  name               = "configure-onprem-israel-vpn"
  location           = data.azurerm_virtual_machine.onprem.location
  virtual_machine_id = data.azurerm_virtual_machine.onprem.id

  source {
    script = templatefile("${path.module}/router-israel.sh.tftpl", {
      israel_public_ip = data.azurerm_public_ip.israel.ip_address
      israel_bgp_ip    = var.israel_bgp_ip
      israel_asn       = data.azurerm_virtual_network_gateway.israel.bgp_settings[0].asn
      router_ip        = local.onprem_bgp_ip
      router_public_ip = data.azurerm_public_ip.onprem.ip_address
      router_asn       = local.onprem_asn
    })
  }

  protected_parameter {
    name  = "VPN_PSK"
    value = var.onprem_israel_psk
  }

  depends_on = [azurerm_virtual_network_gateway_connection.onprem]
}
