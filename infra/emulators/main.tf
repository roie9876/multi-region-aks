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
  resource_provider_registrations = "none"
  use_msi                         = true
}

locals {
  name_prefix = "aks-migration-lab"
  tags        = { workload = "multi-region-aks", layer = "emulators" }

  sites = {
    onprem = {
      vnet_cidr          = "10.60.0.0/16"
      client_subnet_cidr = "10.60.0.0/24"
      router_subnet_cidr = "10.60.1.0/24"
      router_gateway_ip  = "10.60.1.1"
      bgp_peer_ip        = "10.60.1.4"
      dns_private_ip     = "10.60.0.10"
      client_private_ip  = "10.60.0.11"
      web_private_ip     = "10.60.0.12"
      asn                = 65060
      site_heading       = "On-Premises"
      peer_emulator_cidr = "10.70.0.0/16"
    }
    gcp = {
      vnet_cidr          = "10.70.0.0/16"
      client_subnet_cidr = "10.70.0.0/24"
      router_subnet_cidr = "10.70.1.0/24"
      router_gateway_ip  = "10.70.1.1"
      bgp_peer_ip        = "10.70.1.5"
      dns_private_ip     = "10.70.0.10"
      client_private_ip  = "10.70.0.11"
      web_private_ip     = "10.70.0.12"
      asn                = 65070
      site_heading       = "GCP"
      peer_emulator_cidr = "10.60.0.0/16"
    }
  }

  lab_all_cidrs    = distinct(concat(var.remote_lab_cidrs, ["10.60.0.0/16", "10.70.0.0/16"]))
  lab_client_cidrs = distinct(concat(var.remote_lab_cidrs, ["10.60.0.0/24", "10.70.0.0/24"]))
}

resource "azurerm_virtual_network" "site" {
  for_each            = local.sites
  name                = "vnet-${local.name_prefix}-${each.key}"
  resource_group_name = var.resource_group_name
  location            = var.location
  address_space       = [each.value.vnet_cidr]
  tags                = merge(local.tags, { site = each.key })
}

resource "azurerm_subnet" "client" {
  for_each                        = local.sites
  name                            = "client"
  resource_group_name             = var.resource_group_name
  virtual_network_name            = azurerm_virtual_network.site[each.key].name
  address_prefixes                = [each.value.client_subnet_cidr]
  default_outbound_access_enabled = false
}

resource "azurerm_public_ip" "client_egress" {
  for_each            = local.sites
  name                = "pip-${local.name_prefix}-${each.key}-egress"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = merge(local.tags, { site = each.key })

  lifecycle {
    ignore_changes = [ip_tags]
  }
}

resource "azurerm_nat_gateway" "client" {
  for_each            = local.sites
  name                = "nat-${local.name_prefix}-${each.key}"
  resource_group_name = var.resource_group_name
  location            = var.location
  sku_name            = "Standard"
  tags                = merge(local.tags, { site = each.key })
}

resource "azurerm_nat_gateway_public_ip_association" "client" {
  for_each             = local.sites
  nat_gateway_id       = azurerm_nat_gateway.client[each.key].id
  public_ip_address_id = azurerm_public_ip.client_egress[each.key].id
}

resource "azurerm_subnet_nat_gateway_association" "client" {
  for_each       = local.sites
  subnet_id      = azurerm_subnet.client[each.key].id
  nat_gateway_id = azurerm_nat_gateway.client[each.key].id
  depends_on     = [azurerm_nat_gateway_public_ip_association.client]
}

resource "azurerm_subnet" "router" {
  for_each             = local.sites
  name                 = "router"
  resource_group_name  = var.resource_group_name
  virtual_network_name = azurerm_virtual_network.site[each.key].name
  address_prefixes     = [each.value.router_subnet_cidr]
}

resource "azurerm_route_table" "client" {
  for_each                      = local.sites
  name                          = "rt-${local.name_prefix}-${each.key}-client"
  resource_group_name           = var.resource_group_name
  location                      = var.location
  bgp_route_propagation_enabled = false
  tags                          = merge(local.tags, { site = each.key })

  dynamic "route" {
    for_each = toset(distinct(concat(var.remote_lab_cidrs, [each.value.peer_emulator_cidr])))
    content {
      name                   = "to-lab-${replace(replace(route.value, ".", "-"), "/", "-")}"
      address_prefix         = route.value
      next_hop_type          = "VirtualAppliance"
      next_hop_in_ip_address = each.value.bgp_peer_ip
    }
  }
}

resource "azurerm_subnet_route_table_association" "client" {
  for_each       = local.sites
  subnet_id      = azurerm_subnet.client[each.key].id
  route_table_id = azurerm_route_table.client[each.key].id
}

resource "azurerm_network_security_group" "router" {
  for_each            = local.sites
  name                = "nsg-${local.name_prefix}-${each.key}-router"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = merge(local.tags, { site = each.key })

  security_rule {
    name                       = "AllowWestEuropeIkeUdp500"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_range     = "500"
    source_address_prefix      = var.west_vpn_public_ip
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "AllowWestEuropeNatTUdp4500"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_range     = "4500"
    source_address_prefix      = var.west_vpn_public_ip
    destination_address_prefix = "*"
  }

  security_rule {
    name                         = "AllowPrivateLabTransit"
    priority                     = 200
    direction                    = "Inbound"
    access                       = "Allow"
    protocol                     = "*"
    source_port_range            = "*"
    destination_port_range       = "*"
    source_address_prefixes      = local.lab_all_cidrs
    destination_address_prefixes = local.lab_all_cidrs
  }

  security_rule {
    name                       = "AllowAzureLoadBalancer"
    priority                   = 300
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "DenyAllOtherInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_network_security_group" "client" {
  for_each            = local.sites
  name                = "nsg-${local.name_prefix}-${each.key}-client"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = merge(local.tags, { site = each.key })

  security_rule {
    name                       = "AllowHttpToWebFromLabClients"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefixes    = local.lab_client_cidrs
    destination_address_prefix = each.value.web_private_ip
  }

  security_rule {
    name                       = "DenyOtherHttpToWeb"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefix      = "*"
    destination_address_prefix = each.value.web_private_ip
  }

  security_rule {
    name                       = "AllowDnsUdpFromLab"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Udp"
    source_port_range          = "*"
    destination_port_range     = "53"
    source_address_prefixes    = local.lab_all_cidrs
    destination_address_prefix = each.value.dns_private_ip
  }

  security_rule {
    name                       = "AllowDnsTcpFromLab"
    priority                   = 130
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "53"
    source_address_prefixes    = local.lab_all_cidrs
    destination_address_prefix = each.value.dns_private_ip
  }

  security_rule {
    name                         = "AllowPrivateLabClientSubnet"
    priority                     = 200
    direction                    = "Inbound"
    access                       = "Allow"
    protocol                     = "*"
    source_port_range            = "*"
    destination_port_range       = "*"
    source_address_prefixes      = local.lab_all_cidrs
    destination_address_prefixes = [each.value.client_subnet_cidr]
  }

  security_rule {
    name                       = "AllowAzureLoadBalancer"
    priority                   = 300
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "AzureLoadBalancer"
    destination_address_prefix = "*"
  }

  security_rule {
    name                       = "DenyAllOtherInbound"
    priority                   = 4096
    direction                  = "Inbound"
    access                     = "Deny"
    protocol                   = "*"
    source_port_range          = "*"
    destination_port_range     = "*"
    source_address_prefix      = "*"
    destination_address_prefix = "*"
  }
}

resource "azurerm_subnet_network_security_group_association" "router" {
  for_each                  = local.sites
  subnet_id                 = azurerm_subnet.router[each.key].id
  network_security_group_id = azurerm_network_security_group.router[each.key].id
}

resource "azurerm_subnet_network_security_group_association" "client" {
  for_each                  = local.sites
  subnet_id                 = azurerm_subnet.client[each.key].id
  network_security_group_id = azurerm_network_security_group.client[each.key].id
}

resource "azurerm_public_ip" "router" {
  for_each            = local.sites
  name                = "pip-${local.name_prefix}-${each.key}-router"
  resource_group_name = var.resource_group_name
  location            = var.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = merge(local.tags, { site = each.key })

  lifecycle {
    ignore_changes = [ip_tags]
  }
}

resource "azurerm_network_interface" "router" {
  for_each              = local.sites
  name                  = "nic-${local.name_prefix}-${each.key}-router"
  resource_group_name   = var.resource_group_name
  location              = var.location
  ip_forwarding_enabled = true
  tags                  = merge(local.tags, { site = each.key, role = "router" })

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.router[each.key].id
    private_ip_address_allocation = "Static"
    private_ip_address            = each.value.bgp_peer_ip
    public_ip_address_id          = azurerm_public_ip.router[each.key].id
  }
}

resource "azurerm_network_interface_security_group_association" "router" {
  for_each                  = local.sites
  network_interface_id      = azurerm_network_interface.router[each.key].id
  network_security_group_id = azurerm_network_security_group.router[each.key].id
}

resource "azurerm_network_interface" "dns" {
  for_each            = local.sites
  name                = "nic-${local.name_prefix}-${each.key}-dns"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = merge(local.tags, { site = each.key, role = "dns" })

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.client[each.key].id
    private_ip_address_allocation = "Static"
    private_ip_address            = each.value.dns_private_ip
  }
}

resource "azurerm_network_interface_security_group_association" "dns" {
  for_each                  = local.sites
  network_interface_id      = azurerm_network_interface.dns[each.key].id
  network_security_group_id = azurerm_network_security_group.client[each.key].id
}

resource "azurerm_network_interface" "client" {
  for_each            = local.sites
  name                = "nic-${local.name_prefix}-${each.key}-client"
  resource_group_name = var.resource_group_name
  location            = var.location
  dns_servers         = [each.value.dns_private_ip]
  tags                = merge(local.tags, { site = each.key, role = "client" })

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.client[each.key].id
    private_ip_address_allocation = "Static"
    private_ip_address            = each.value.client_private_ip
  }
}

resource "azurerm_network_interface_security_group_association" "client" {
  for_each                  = local.sites
  network_interface_id      = azurerm_network_interface.client[each.key].id
  network_security_group_id = azurerm_network_security_group.client[each.key].id
}

resource "azurerm_network_interface" "web" {
  for_each            = local.sites
  name                = "nic-${local.name_prefix}-${each.key}-web"
  resource_group_name = var.resource_group_name
  location            = var.location
  tags                = merge(local.tags, { site = each.key, role = "web" })

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.client[each.key].id
    private_ip_address_allocation = "Static"
    private_ip_address            = each.value.web_private_ip
  }
}

resource "azurerm_network_interface_security_group_association" "web" {
  for_each                  = local.sites
  network_interface_id      = azurerm_network_interface.web[each.key].id
  network_security_group_id = azurerm_network_security_group.client[each.key].id
}

resource "azurerm_linux_virtual_machine" "router" {
  for_each                        = local.sites
  name                            = "vm-${local.name_prefix}-${each.key}-router"
  computer_name                   = "${each.key}-router"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  size                            = var.linux_vm_size
  admin_username                  = "labadmin"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.router[each.key].id]
  custom_data                     = filebase64("${path.module}/router.cloud-init.yaml")
  tags                            = merge(local.tags, { site = each.key, role = "router" })

  admin_ssh_key {
    username   = "labadmin"
    public_key = trimspace(var.admin_ssh_public_key)
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

  depends_on = [
    azurerm_network_interface_security_group_association.router,
    azurerm_subnet_network_security_group_association.router
  ]
}

resource "azurerm_virtual_machine_run_command" "router" {
  for_each           = local.sites
  name               = "configure-${each.key}-router"
  location           = var.location
  virtual_machine_id = azurerm_linux_virtual_machine.router[each.key].id
  tags               = merge(local.tags, { site = each.key, role = "router" })

  source {
    script = templatefile("${path.module}/router-configure.sh.tftpl", {
      site_key           = each.key
      router_private_ip  = each.value.bgp_peer_ip
      bgp_peer_ip        = each.value.bgp_peer_ip
      router_public_ip   = azurerm_public_ip.router[each.key].ip_address
      router_gateway_ip  = each.value.router_gateway_ip
      client_subnet_cidr = each.value.client_subnet_cidr
      dns_private_ip     = each.value.dns_private_ip
      router_subnet_cidr = each.value.router_subnet_cidr
      local_vnet_cidr    = each.value.vnet_cidr
      local_asn          = each.value.asn
      west_vpn_public_ip = var.west_vpn_public_ip
      west_vpn_bgp_ip    = var.west_vpn_bgp_ip
      remote_asn         = var.remote_asn
    })
  }

  protected_parameter {
    name  = "VPN_PSK"
    value = each.key == "onprem" ? var.onprem_vpn_psk : var.gcp_vpn_psk
  }
}

resource "azurerm_windows_virtual_machine" "onprem_dns" {
  name                  = "vm-${local.name_prefix}-onprem-dns"
  computer_name         = "onprem-dns"
  resource_group_name   = var.resource_group_name
  location              = var.location
  size                  = var.windows_vm_size
  admin_username        = "labadmin"
  admin_password        = var.windows_admin_password
  network_interface_ids = [azurerm_network_interface.dns["onprem"].id]
  tags                  = merge(local.tags, { site = "onprem", role = "dns" })

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

  depends_on = [
    azurerm_network_interface_security_group_association.dns["onprem"],
    azurerm_subnet_network_security_group_association.client["onprem"],
    azurerm_subnet_route_table_association.client["onprem"],
    azurerm_subnet_nat_gateway_association.client["onprem"]
  ]
}

resource "azurerm_virtual_machine_run_command" "onprem_dns" {
  name               = "configure-onprem-dns"
  location           = var.location
  virtual_machine_id = azurerm_windows_virtual_machine.onprem_dns.id
  tags               = merge(local.tags, { site = "onprem", role = "dns" })

  source {
    script = templatefile("${path.module}/onprem-dns.ps1.tftpl", {
      resolver_ip       = var.resolver_ip
      dns_private_ip    = local.sites["onprem"].dns_private_ip
      client_private_ip = local.sites["onprem"].client_private_ip
      web_private_ip    = local.sites["onprem"].web_private_ip
      bgp_peer_ip       = local.sites["onprem"].bgp_peer_ip
    })
  }
}

resource "azurerm_linux_virtual_machine" "gcp_dns" {
  name                            = "vm-${local.name_prefix}-gcp-dns"
  computer_name                   = "gcp-dns"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  size                            = var.linux_vm_size
  admin_username                  = "labadmin"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.dns["gcp"].id]
  custom_data = base64encode(templatefile("${path.module}/gcp-dns.cloud-init.yaml.tftpl", {
    resolver_ip       = var.resolver_ip
    dns_private_ip    = local.sites["gcp"].dns_private_ip
    client_private_ip = local.sites["gcp"].client_private_ip
    web_private_ip    = local.sites["gcp"].web_private_ip
    bgp_peer_ip       = local.sites["gcp"].bgp_peer_ip
  }))
  tags = merge(local.tags, { site = "gcp", role = "dns" })

  admin_ssh_key {
    username   = "labadmin"
    public_key = trimspace(var.admin_ssh_public_key)
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

  depends_on = [
    azurerm_network_interface_security_group_association.dns["gcp"],
    azurerm_subnet_network_security_group_association.client["gcp"],
    azurerm_subnet_route_table_association.client["gcp"],
    azurerm_subnet_nat_gateway_association.client["gcp"]
  ]
}

resource "azurerm_windows_virtual_machine" "client" {
  for_each              = local.sites
  name                  = "vm-${local.name_prefix}-${each.key}-client"
  computer_name         = "${each.key}-client"
  resource_group_name   = var.resource_group_name
  location              = var.location
  size                  = var.windows_vm_size
  admin_username        = "labadmin"
  admin_password        = var.windows_admin_password
  network_interface_ids = [azurerm_network_interface.client[each.key].id]
  tags                  = merge(local.tags, { site = each.key, role = "client" })

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

  depends_on = [
    azurerm_network_interface_security_group_association.client,
    azurerm_subnet_network_security_group_association.client,
    azurerm_subnet_route_table_association.client,
    azurerm_subnet_nat_gateway_association.client
  ]
}

resource "azurerm_virtual_machine_run_command" "client" {
  for_each           = local.sites
  name               = "configure-${each.key}-client"
  location           = var.location
  virtual_machine_id = azurerm_windows_virtual_machine.client[each.key].id
  tags               = merge(local.tags, { site = each.key, role = "client" })

  source {
    script = file("${path.module}/windows-client.ps1")
  }
}

resource "azurerm_linux_virtual_machine" "web" {
  for_each                        = local.sites
  name                            = "vm-${local.name_prefix}-${each.key}-web"
  computer_name                   = "${each.key}-web"
  resource_group_name             = var.resource_group_name
  location                        = var.location
  size                            = var.linux_vm_size
  admin_username                  = "labadmin"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.web[each.key].id]
  custom_data = base64encode(templatefile("${path.module}/web.cloud-init.yaml.tftpl", {
    site_heading = each.value.site_heading
  }))
  tags = merge(local.tags, { site = each.key, role = "web" })

  admin_ssh_key {
    username   = "labadmin"
    public_key = trimspace(var.admin_ssh_public_key)
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

  depends_on = [
    azurerm_network_interface_security_group_association.web,
    azurerm_subnet_network_security_group_association.client,
    azurerm_subnet_route_table_association.client,
    azurerm_subnet_nat_gateway_association.client
  ]
}
