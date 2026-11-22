terraform {
  required_version = ">= 1.15.7, < 2.0"
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

provider "azurerm" {
  features {}
  subscription_id                 = var.subscription_id
  resource_provider_registrations = "none"
}

data "azurerm_user_assigned_identity" "runner" {
  name                = "id-aks-migration-lab-mgmt"
  resource_group_name = "rg-aks-migration-lab-mgmt"
}

locals {
  groups = {
    we        = "westeurope"
    se        = "swedencentral"
    emulators = "swedencentral"
  }
}

resource "azurerm_resource_group" "baseline" {
  for_each = local.groups
  name     = "rg-aks-migration-lab-${each.key}"
  location = each.value
  tags     = { workload = "multi-region-aks" }
}

resource "azurerm_role_assignment" "provision" {
  for_each             = azurerm_resource_group.baseline
  scope                = each.value.id
  role_definition_name = "Contributor"
  principal_id         = data.azurerm_user_assigned_identity.runner.principal_id
  principal_type       = "ServicePrincipal"
}

data "azurerm_virtual_network" "management" {
  name                = "vnet-aks-migration-lab-mgmt"
  resource_group_name = "rg-aks-migration-lab-mgmt"
}

resource "azurerm_role_assignment" "aks_network_delegation" {
  scope                = azurerm_resource_group.baseline["we"].id
  role_definition_name = "Role Based Access Control Administrator"
  principal_id         = data.azurerm_user_assigned_identity.runner.principal_id
  principal_type       = "ServicePrincipal"
  condition_version    = "2.0"
  condition            = <<-CONDITION
    (
      (!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'}))
      OR (
        @Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {4d97b98b-1d4f-4787-a291-c67834d212e7}
        AND @Request[Microsoft.Authorization/roleAssignments:PrincipalType] StringEqualsIgnoreCase 'ServicePrincipal'
      )
    )
    AND
    (
      (!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'}))
      OR (
        @Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {4d97b98b-1d4f-4787-a291-c67834d212e7}
        AND @Resource[Microsoft.Authorization/roleAssignments:PrincipalType] StringEqualsIgnoreCase 'ServicePrincipal'
      )
    )
  CONDITION
}

resource "azurerm_role_assignment" "management_peering" {
  scope                = data.azurerm_virtual_network.management.id
  role_definition_name = "Network Contributor"
  principal_id         = data.azurerm_user_assigned_identity.runner.principal_id
  principal_type       = "ServicePrincipal"
}

resource "azurerm_private_dns_zone" "vault" {
  name                = "privatelink.vaultcore.azure.net"
  resource_group_name = "rg-aks-migration-lab-mgmt"
}

data "azurerm_private_dns_zone" "blob" {
  name                = "privatelink.blob.core.windows.net"
  resource_group_name = "rg-aks-migration-lab-mgmt"
}

resource "azurerm_private_dns_zone_virtual_network_link" "management_vault" {
  name                = "management"
  private_dns_zone_id = azurerm_private_dns_zone.vault.id
  virtual_network_id  = data.azurerm_virtual_network.management.id
}

resource "azurerm_role_assignment" "dns" {
  for_each = {
    blob  = data.azurerm_private_dns_zone.blob.id
    vault = azurerm_private_dns_zone.vault.id
  }
  scope                = each.value
  role_definition_name = "Private DNS Zone Contributor"
  principal_id         = data.azurerm_user_assigned_identity.runner.principal_id
  principal_type       = "ServicePrincipal"
}

data "azurerm_log_analytics_workspace" "lab" {
  name                = "log-aks-migration-lab-mgmt"
  resource_group_name = "rg-aks-migration-lab-mgmt"
}

resource "azurerm_role_assignment" "diagnostics" {
  scope                = data.azurerm_log_analytics_workspace.lab.id
  role_definition_name = "Log Analytics Contributor"
  principal_id         = data.azurerm_user_assigned_identity.runner.principal_id
  principal_type       = "ServicePrincipal"
}
