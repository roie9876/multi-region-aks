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
  type        = string
  description = "Target Azure subscription ID."
}

variable "resource_group_name" {
  type        = string
  default     = "rg-aks-migration-lab-se"
  description = "Precreated Sweden Central workload resource group name."
}

variable "management_resource_group_name" {
  type        = string
  default     = "rg-aks-migration-lab-mgmt"
  description = "Persistent management resource group hosting shared Private DNS zones (Blob exists; Key Vault zone created by parent before apply)."
}

variable "vnet_address_space" {
  type        = list(string)
  default     = ["10.44.1.0/24"]
  description = "Address space for the Sweden Central workload VNet."
}

variable "workloads_subnet_cidr" {
  type        = string
  default     = "10.44.1.0/26"
  description = "Subnet CIDR for the private Windows test VM and private Linux HTTP probe VM."
}

variable "private_endpoints_subnet_cidr" {
  type        = string
  default     = "10.44.1.64/26"
  description = "Subnet CIDR for Blob, Key Vault, and optional Foundry private endpoints."
}

variable "windows_vm_private_ip" {
  type        = string
  default     = "10.44.1.4"
  description = "Static private IP address for the Sweden Central Windows test VM inside workloads_subnet_cidr."
}

variable "web_probe_private_ip" {
  type        = string
  default     = "10.44.1.5"
  description = "Static private IP address for the Sweden Central Linux HTTP probe VM inside workloads_subnet_cidr."
}

variable "allowed_client_cidrs" {
  type = list(string)
  default = [
    "10.42.0.0/16",
    "10.44.1.0/24",
    "10.45.0.0/24",
    "10.60.0.0/24",
    "10.70.0.0/24"
  ]
  description = "Lab client CIDRs permitted to reach TCP/80 on the Linux HTTP probe VM and admin ports (RDP/SSH) from lab networks."
}

variable "admin_username" {
  type        = string
  default     = "labadmin"
  description = "Administrator username for the Windows test VM and Linux HTTP probe VM."
}

variable "windows_admin_password" {
  type        = string
  sensitive   = true
  description = "Administrator password for the private Windows test VM."
}

variable "admin_ssh_public_key" {
  type        = string
  description = "Public SSH key for the private Linux HTTP probe VM operator. Never supply a private key."
}

variable "windows_vm_size" {
  type        = string
  default     = "Standard_D2s_v5"
  description = "VM SKU for the private Windows test VM."
}

variable "linux_vm_size" {
  type        = string
  default     = "Standard_D2s_v5"
  description = "VM SKU for the private Linux HTTP probe VM."
}

variable "key_vault_purge_protection_enabled" {
  type        = bool
  default     = true
  description = "Enable purge protection on the Sweden Central Key Vault."
}

# Optional Microsoft Foundry gate:
# Keep enable_foundry = false until Sweden Central model availability, Content Understanding
# model compatibility, subscription quota, and private service-to-service dependencies are
# explicitly verified. Enabling this gate provisions a private AIServices account, project,
# private endpoint, and only the caller-verified model deployments in foundry_model_deployments.
variable "enable_foundry" {
  type        = bool
  default     = false
  description = "Optional gate to provision the private Microsoft Foundry (AIServices) account, project, and private endpoint after quota and model validation."
}

variable "foundry_resolver_vnet_ids" {
  type        = map(string)
  default     = {}
  description = "Additional VNets (management, regional resolvers and clients) that need Foundry private DNS."
}

variable "foundry_model_deployments" {
  type = map(object({
    model_format  = string
    model_name    = string
    model_version = string
    sku_name      = optional(string, "GlobalStandard")
    sku_capacity  = optional(number, 1)
  }))
  default     = {}
  description = "Verified model deployments to create when enable_foundry = true. Must only be populated after confirming Sweden Central quota and Content Understanding model requirements."
}

locals {
  name        = "aks-migration-lab-se"
  location    = "swedencentral"
  name_suffix = substr(sha256("${var.subscription_id}-${var.resource_group_name}"), 0, 10)
  tags = {
    workload  = "multi-region-aks"
    region    = "swedencentral"
    layer     = "sweden-workload"
    lifecycle = "baseline"
  }
}

data "azurerm_client_config" "current" {}

data "azurerm_resource_group" "workload" {
  name = var.resource_group_name
}

data "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = var.management_resource_group_name
}

data "azurerm_private_dns_zone" "vault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = var.management_resource_group_name
}

resource "azurerm_virtual_network" "workload" {
  name                = "vnet-${local.name}"
  resource_group_name = data.azurerm_resource_group.workload.name
  location            = local.location
  address_space       = var.vnet_address_space
  tags                = local.tags
}

resource "azurerm_subnet" "workloads" {
  name                            = "workloads"
  resource_group_name             = data.azurerm_resource_group.workload.name
  virtual_network_name            = azurerm_virtual_network.workload.name
  address_prefixes                = [var.workloads_subnet_cidr]
  default_outbound_access_enabled = false
}

resource "azurerm_subnet" "endpoints" {
  name                              = "private-endpoints"
  resource_group_name               = data.azurerm_resource_group.workload.name
  virtual_network_name              = azurerm_virtual_network.workload.name
  address_prefixes                  = [var.private_endpoints_subnet_cidr]
  default_outbound_access_enabled   = false
  private_endpoint_network_policies = "Disabled"
}

resource "azurerm_network_security_group" "workloads" {
  name                = "nsg-${local.name}-workloads"
  resource_group_name = data.azurerm_resource_group.workload.name
  location            = local.location
  tags                = local.tags

  security_rule {
    name                       = "AllowLabClientsHttpToWebProbe"
    priority                   = 100
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "80"
    source_address_prefixes    = var.allowed_client_cidrs
    destination_address_prefix = var.web_probe_private_ip
  }

  security_rule {
    name                       = "AllowLabAdminRdpToWindowsVm"
    priority                   = 110
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "3389"
    source_address_prefixes    = var.allowed_client_cidrs
    destination_address_prefix = var.windows_vm_private_ip
  }

  security_rule {
    name                       = "AllowLabAdminSshToWebProbe"
    priority                   = 120
    direction                  = "Inbound"
    access                     = "Allow"
    protocol                   = "Tcp"
    source_port_range          = "*"
    destination_port_range     = "22"
    source_address_prefixes    = var.allowed_client_cidrs
    destination_address_prefix = var.web_probe_private_ip
  }

  security_rule {
    name                       = "DenyOtherInbound"
    priority                   = 4000
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
  subnet_id                 = azurerm_subnet.workloads.id
  network_security_group_id = azurerm_network_security_group.workloads.id
}

resource "azurerm_network_interface" "windows" {
  name                = "nic-${local.name}-win"
  resource_group_name = data.azurerm_resource_group.workload.name
  location            = local.location
  tags                = local.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.workloads.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.windows_vm_private_ip
  }
}

resource "azurerm_windows_virtual_machine" "test" {
  name                  = "vm-${local.name}-win"
  computer_name         = "se-test-win"
  resource_group_name   = data.azurerm_resource_group.workload.name
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

  depends_on = [
    azurerm_subnet_network_security_group_association.workloads
  ]
}

resource "azurerm_network_interface" "web_probe" {
  name                = "nic-${local.name}-web"
  resource_group_name = data.azurerm_resource_group.workload.name
  location            = local.location
  tags                = local.tags

  ip_configuration {
    name                          = "primary"
    subnet_id                     = azurerm_subnet.workloads.id
    private_ip_address_allocation = "Static"
    private_ip_address            = var.web_probe_private_ip
  }
}

resource "azurerm_linux_virtual_machine" "web_probe" {
  name                            = "vm-${local.name}-web"
  computer_name                   = "se-web-probe"
  resource_group_name             = data.azurerm_resource_group.workload.name
  location                        = local.location
  size                            = var.linux_vm_size
  admin_username                  = var.admin_username
  disable_password_authentication = true
  network_interface_ids           = [azurerm_network_interface.web_probe.id]
  custom_data                     = filebase64("${path.module}/web-probe.cloud-init.yaml")
  tags                            = local.tags

  admin_ssh_key {
    username   = var.admin_username
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
    azurerm_subnet_network_security_group_association.workloads
  ]
}

resource "azurerm_storage_account" "workload" {
  name                            = "staksmigse${local.name_suffix}"
  resource_group_name             = data.azurerm_resource_group.workload.name
  location                        = local.location
  account_tier                    = "Standard"
  account_replication_type        = "LRS"
  min_tls_version                 = "TLS1_2"
  public_network_access           = "Disabled"
  shared_access_key_enabled       = false
  allow_nested_items_to_be_public = false
  tags                            = local.tags
}

resource "azurerm_private_endpoint" "blob" {
  name                = "pe-${local.name}-blob"
  resource_group_name = data.azurerm_resource_group.workload.name
  location            = local.location
  subnet_id           = azurerm_subnet.endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "blob"
    private_connection_resource_id = azurerm_storage_account.workload.id
    subresource_names              = ["blob"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "blob"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.blob.id]
  }
}

resource "azurerm_key_vault" "workload" {
  name                          = "kv-aksmigse-${local.name_suffix}"
  resource_group_name           = data.azurerm_resource_group.workload.name
  location                      = local.location
  sku_name                      = "standard"
  tenant_id                     = data.azurerm_client_config.current.tenant_id
  rbac_authorization_enabled    = true
  public_network_access_enabled = false
  purge_protection_enabled      = var.key_vault_purge_protection_enabled
  soft_delete_retention_days    = 7
  tags                          = local.tags

  network_acls {
    bypass         = "None"
    default_action = "Deny"
  }
}

resource "azurerm_private_endpoint" "vault" {
  name                = "pe-${local.name}-kv"
  resource_group_name = data.azurerm_resource_group.workload.name
  location            = local.location
  subnet_id           = azurerm_subnet.endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "vault"
    private_connection_resource_id = azurerm_key_vault.workload.id
    subresource_names              = ["vault"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "vault"
    private_dns_zone_ids = [data.azurerm_private_dns_zone.vault.id]
  }
}

# Optional Microsoft Foundry (AIServices) private account and project.
# Gated by var.enable_foundry (default false). Before setting enable_foundry = true:
# 1. Confirm Sweden Central regional availability and subscription quota for required Content Understanding models.
# 2. Confirm private service-to-service dependencies.
locals {
  foundry_zones = var.enable_foundry ? toset([
    "privatelink.cognitiveservices.azure.com",
    "privatelink.openai.azure.com",
    "privatelink.services.ai.azure.com",
  ]) : toset([])
  foundry_vnets = merge(var.foundry_resolver_vnet_ids, { sweden = azurerm_virtual_network.workload.id })
}

resource "azurerm_private_dns_zone" "foundry" {
  for_each            = local.foundry_zones
  name                = each.key
  resource_group_name = data.azurerm_resource_group.workload.name
}

resource "azurerm_private_dns_zone_virtual_network_link" "foundry" {
  for_each = {
    for pair in setproduct(local.foundry_zones, keys(local.foundry_vnets)) :
    "${pair[0]}/${pair[1]}" => { zone = pair[0], vnet = pair[1] }
  }
  name                = each.value.vnet
  private_dns_zone_id = azurerm_private_dns_zone.foundry[each.value.zone].id
  virtual_network_id  = local.foundry_vnets[each.value.vnet]
}

resource "azurerm_cognitive_account" "foundry" {
  count                              = var.enable_foundry ? 1 : 0
  name                               = "ais-aksmigse-${local.name_suffix}"
  resource_group_name                = data.azurerm_resource_group.workload.name
  location                           = local.location
  kind                               = "AIServices"
  sku_name                           = "S0"
  custom_subdomain_name              = "ais-aksmigse-${local.name_suffix}"
  project_management_enabled         = true
  public_network_access_enabled      = false
  local_auth_enabled                 = false
  outbound_network_access_restricted = false
  tags                               = local.tags

  identity {
    type = "SystemAssigned"
  }

  network_acls {
    default_action = "Deny"
  }
}

resource "azurerm_cognitive_account_project" "foundry" {
  count                = var.enable_foundry ? 1 : 0
  name                 = "proj-${local.name}"
  cognitive_account_id = azurerm_cognitive_account.foundry[0].id
  location             = local.location
  display_name         = "Sweden Central Content Understanding Project"
  description          = "Optional private Foundry project for Content Understanding validation; requires verified model quota and deployments."
  tags                 = local.tags

  identity {
    type = "SystemAssigned"
  }
}

resource "azurerm_private_endpoint" "foundry" {
  count               = var.enable_foundry ? 1 : 0
  name                = "pe-${local.name}-foundry"
  resource_group_name = data.azurerm_resource_group.workload.name
  location            = local.location
  subnet_id           = azurerm_subnet.endpoints.id
  tags                = local.tags

  private_service_connection {
    name                           = "foundry"
    private_connection_resource_id = azurerm_cognitive_account.foundry[0].id
    subresource_names              = ["account"]
    is_manual_connection           = false
  }

  private_dns_zone_group {
    name                 = "foundry"
    private_dns_zone_ids = [for zone in azurerm_private_dns_zone.foundry : zone.id]
  }
}

resource "azurerm_cognitive_deployment" "foundry" {
  for_each             = var.enable_foundry ? var.foundry_model_deployments : {}
  name                 = each.key
  cognitive_account_id = azurerm_cognitive_account.foundry[0].id

  model {
    format  = each.value.model_format
    name    = each.value.model_name
    version = each.value.model_version
  }

  sku {
    name     = each.value.sku_name
    capacity = each.value.sku_capacity
  }
}

output "resource_group_name" {
  value = data.azurerm_resource_group.workload.name
}

output "location" {
  value = local.location
}

output "vnet_id" {
  value = azurerm_virtual_network.workload.id
}

output "vnet_name" {
  value = azurerm_virtual_network.workload.name
}

output "vnet_address_space" {
  value = azurerm_virtual_network.workload.address_space
}

output "subnet_ids" {
  value = {
    workloads         = azurerm_subnet.workloads.id
    private_endpoints = azurerm_subnet.endpoints.id
  }
}

output "windows_vm_id" {
  value = azurerm_windows_virtual_machine.test.id
}

output "windows_vm_name" {
  value = azurerm_windows_virtual_machine.test.name
}

output "windows_vm_private_ip" {
  value = azurerm_network_interface.windows.private_ip_address
}

output "web_probe_vm_id" {
  value = azurerm_linux_virtual_machine.web_probe.id
}

output "web_probe_vm_name" {
  value = azurerm_linux_virtual_machine.web_probe.name
}

output "web_probe_private_ip" {
  value = azurerm_network_interface.web_probe.private_ip_address
}

output "web_probe_url" {
  value = "http://${azurerm_network_interface.web_probe.private_ip_address}/"
}

output "storage_account_id" {
  value = azurerm_storage_account.workload.id
}

output "storage_account_name" {
  value = azurerm_storage_account.workload.name
}

output "storage_blob_endpoint" {
  value = azurerm_storage_account.workload.primary_blob_endpoint
}

output "storage_private_endpoint_id" {
  value = azurerm_private_endpoint.blob.id
}

output "storage_private_endpoint_ip" {
  value = azurerm_private_endpoint.blob.private_service_connection[0].private_ip_address
}

output "key_vault_id" {
  value = azurerm_key_vault.workload.id
}

output "key_vault_name" {
  value = azurerm_key_vault.workload.name
}

output "key_vault_uri" {
  value = azurerm_key_vault.workload.vault_uri
}

output "key_vault_private_endpoint_id" {
  value = azurerm_private_endpoint.vault.id
}

output "key_vault_private_endpoint_ip" {
  value = azurerm_private_endpoint.vault.private_service_connection[0].private_ip_address
}

output "foundry" {
  value = {
    enabled              = var.enable_foundry
    account_id           = var.enable_foundry ? azurerm_cognitive_account.foundry[0].id : null
    account_name         = var.enable_foundry ? azurerm_cognitive_account.foundry[0].name : null
    endpoint             = var.enable_foundry ? azurerm_cognitive_account.foundry[0].endpoint : null
    project_id           = var.enable_foundry ? azurerm_cognitive_account_project.foundry[0].id : null
    project_name         = var.enable_foundry ? azurerm_cognitive_account_project.foundry[0].name : null
    private_endpoint_id  = var.enable_foundry ? azurerm_private_endpoint.foundry[0].id : null
    private_endpoint_ip  = var.enable_foundry ? azurerm_private_endpoint.foundry[0].private_service_connection[0].private_ip_address : null
    model_deployment_ids = { for k, v in azurerm_cognitive_deployment.foundry : k => v.id }
  }
}
