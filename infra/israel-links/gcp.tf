variable "gcp_israel_psk" {
  type      = string
  sensitive = true
  validation {
    condition     = can(regex("^[0-9A-Fa-f]{64}$", var.gcp_israel_psk))
    error_message = "Supply a 64-character hexadecimal PSK generated for this tunnel."
  }
}

locals {
  gcp_bgp_ip = "10.70.1.5"
  gcp_asn    = 65070
}

data "azurerm_public_ip" "gcp" {
  name                = "pip-aks-migration-lab-gcp-router"
  resource_group_name = local.emulators_group
}

data "azurerm_virtual_machine" "gcp" {
  name                = "vm-aks-migration-lab-gcp-router"
  resource_group_name = local.emulators_group
}

resource "azurerm_local_network_gateway" "gcp" {
  name                = "lng-aks-migration-lab-gcp-il"
  resource_group_name = local.israel_group
  location            = data.azurerm_virtual_network_gateway.israel.location
  gateway_address     = data.azurerm_public_ip.gcp.ip_address
  # Match West Europe so the GCP client prefix starts with equal AS-path lengths.
  address_space = ["10.70.0.0/24"]

  bgp_settings {
    asn                 = local.gcp_asn
    bgp_peering_address = local.gcp_bgp_ip
  }
}

resource "azurerm_virtual_network_gateway_connection" "gcp" {
  name                       = "conn-aks-migration-lab-gcp-il"
  resource_group_name        = local.israel_group
  location                   = data.azurerm_virtual_network_gateway.israel.location
  type                       = "IPsec"
  connection_mode            = "ResponderOnly"
  virtual_network_gateway_id = data.azurerm_virtual_network_gateway.israel.id
  local_network_gateway_id   = azurerm_local_network_gateway.gcp.id
  bgp_enabled                = true
  shared_key                 = var.gcp_israel_psk

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

resource "azurerm_virtual_machine_run_command" "gcp" {
  name               = "configure-gcp-israel-vpn"
  location           = data.azurerm_virtual_machine.gcp.location
  virtual_machine_id = data.azurerm_virtual_machine.gcp.id

  source {
    script = templatefile("${path.module}/router-israel.sh.tftpl", {
      israel_public_ip = data.azurerm_public_ip.israel.ip_address
      israel_bgp_ip    = var.israel_bgp_ip
      israel_asn       = data.azurerm_virtual_network_gateway.israel.bgp_settings[0].asn
      router_ip        = local.gcp_bgp_ip
      router_public_ip = data.azurerm_public_ip.gcp.ip_address
      router_asn       = local.gcp_asn
    })
  }

  protected_parameter {
    name  = "VPN_PSK"
    value = var.gcp_israel_psk
  }

  depends_on = [azurerm_virtual_network_gateway_connection.gcp]
}
