terraform {
  required_version = ">= 1.15.7, < 2.0"

  required_providers {
    azurerm = {
      source  = "hashicorp/azurerm"
      version = "5.14.0"
    }
  }
}

provider "azurerm" {
  features {}
  subscription_id = var.subscription_id
}

variable "subscription_id" {
  type = string
}

variable "admin_ssh_public_key" {
  type        = string
  description = "Public SSH key for the runner operator. Never supply a private key."
}

variable "runner_size" {
  type    = string
  default = "Standard_D2s_v5"
}

locals {
  name     = "aks-migration-lab-mgmt"
  location = "swedencentral"
  tags     = { workload = "multi-region-aks", lifecycle = "persistent" }
}

resource "azurerm_resource_group" "management" {
  name     = "rg-${local.name}"
  location = local.location
  tags     = local.tags
}

resource "azurerm_virtual_network" "management" {
  name                = "vnet-${local.name}"
  resource_group_name = azurerm_resource_group.management.name
  location            = local.location
  address_space       = ["10.45.0.0/24"]
  tags                = local.tags
}

resource "azurerm_subnet" "runner" {
  name                 = "runner"
  resource_group_name  = azurerm_resource_group.management.name
  virtual_network_name = azurerm_virtual_network.management.name
  address_prefixes     = ["10.45.0.0/26"]
}

resource "azurerm_subnet" "endpoints" {
  name                 = "private-endpoints"
  resource_group_name  = azurerm_resource_group.management.name
  virtual_network_name = azurerm_virtual_network.management.name
  address_prefixes     = ["10.45.0.64/26"]
}

resource "azurerm_subnet" "bastion" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.management.name
  virtual_network_name = azurerm_virtual_network.management.name
  address_prefixes     = ["10.45.0.128/26"]
}

resource "azurerm_public_ip" "management" {
  for_each            = toset(["bastion", "egress"])
  name                = "pip-${local.name}-${each.key}"
  resource_group_name = azurerm_resource_group.management.name
  location            = local.location
  allocation_method   = "Static"
  sku                 = "Standard"
  tags                = local.tags

  lifecycle {
    # Azure adds a service-managed FirstPartyUsage tag after creation.
    ignore_changes = [ip_tags]
  }
}

resource "azurerm_bastion_host" "management" {
  name                = "bas-${local.name}"
  resource_group_name = azurerm_resource_group.management.name
  location            = local.location
  sku                 = "Standard"
  tunneling_enabled   = true
  tags                = local.tags

  ip_configuration {
    name                 = "primary"
    subnet_id            = azurerm_subnet.bastion.id
    public_ip_address_id = azurerm_public_ip.management["bastion"].id
  }
}

resource "azurerm_nat_gateway" "runner" {
  name                = "nat-${local.name}"
  resource_group_name = azurerm_resource_group.management.name
  location            = local.location
  sku_name            = "Standard"
  tags                = local.tags
}

resource "azurerm_nat_gateway_public_ip_association" "runner" {
  nat_gateway_id       = azurerm_nat_gateway.runner.id
  public_ip_address_id = azurerm_public_ip.management["egress"].id
}

resource "azurerm_subnet_nat_gateway_association" "runner" {
  subnet_id      = azurerm_subnet.runner.id
  nat_gateway_id = azurerm_nat_gateway.runner.id
}

resource "azurerm_network_security_group" "runner" {
  name                = "nsg-${local.name}"
  resource_group_name = azurerm_resource_group.management.name
  location            = local.location
  tags                = local.tags

  security_rule {
    name                       = "AllowBastionSsh"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefix      = azurerm_subnet.bastion.address_prefixes[0]
    destination_address_prefix = "*"
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

resource "azurerm_network_interface" "runner" {
  name                = "nic-${local.name}"
  resource_group_name = azurerm_resource_group.management.name
  location            = local.location
  tags                = local.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.runner.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_network_interface_security_group_association" "runner" {
  network_interface_id      = azurerm_network_interface.runner.id
  network_security_group_id = azurerm_network_security_group.runner.id
}

resource "azurerm_user_assigned_identity" "runner" {
  name                = "id-${local.name}"
  resource_group_name = azurerm_resource_group.management.name
  location            = local.location
  tags                = local.tags
}

resource "azurerm_linux_virtual_machine" "runner" {
  name                            = "vm-${local.name}"
  computer_name                   = "terraform-runner"
  resource_group_name             = azurerm_resource_group.management.name
  location                        = local.location
  size                            = var.runner_size
  admin_username                  = "labadmin"
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.runner.id]
  custom_data                     = filebase64("${path.module}/runner.cloud-init.yaml")
  tags                            = local.tags

  admin_ssh_key {
    username   = "labadmin"
    public_key = trimspace(var.admin_ssh_public_key)
  }

  identity {
    type         = "UserAssigned"
    identity_ids = [azurerm_user_assigned_identity.runner.id]
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
    azurerm_network_interface_security_group_association.runner,
    azurerm_nat_gateway_public_ip_association.runner,
    azurerm_subnet_nat_gateway_association.runner
  ]
}

resource "azurerm_storage_account" "state" {
  name                            = "staksmig${substr(sha256(var.subscription_id), 0, 14)}"
  resource_group_name             = azurerm_resource_group.management.name
  location                        = local.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  public_network_access           = "Disabled"
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  tags                            = local.tags

  blob_properties {
    versioning_enabled = true

    delete_retention_policy {
      days = 14
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_storage_container" "state" {
  name                  = "tfstate"
  storage_account_id    = azurerm_storage_account.state.id
  container_access_type = "private"

  lifecycle {
    prevent_destroy = true
  }
}

resource "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = azurerm_resource_group.management.name
  tags                = local.tags
}

resource "azurerm_private_dns_zone_virtual_network_link" "management" {
  name                = "management"
  private_dns_zone_id = azurerm_private_dns_zone.blob.id
  virtual_network_id  = azurerm_virtual_network.management.id
}

resource "azurerm_private_endpoint" "state" {
  name                = "pe-${local.name}-state"
  resource_group_name = azurerm_resource_group.management.name
  location            = local.location
  subnet_id           = azurerm_subnet.endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "blob"
    private_connection_resource_id = azurerm_storage_account.state.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob"
    private_dns_zone_ids = [azurerm_private_dns_zone.blob.id]
  }
}

resource "azurerm_role_assignment" "state" {
  scope                = "${azurerm_storage_account.state.id}/blobServices/default/containers/${azurerm_storage_container.state.name}"
  role_definition_name = "Storage Blob Data Contributor"
  principal_id         = azurerm_user_assigned_identity.runner.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_log_analytics_workspace" "lab" {
  name                = "log-${local.name}"
  resource_group_name = azurerm_resource_group.management.name
  location            = local.location
  sku                 = "PerGB2018"
  retention_in_days   = 30
  tags                = local.tags
}

output "runner_id" {
  value = azurerm_linux_virtual_machine.runner.id
}

output "runner_private_ip" {
  value = azurerm_network_interface.runner.private_ip_address
}

output "backend" {
  value = {
    storage_account_name = azurerm_storage_account.state.name
    container_name       = azurerm_storage_container.state.name
    client_id            = azurerm_user_assigned_identity.runner.client_id
    use_msi              = true
    use_azuread_auth     = true
  }
}
