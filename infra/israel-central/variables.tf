variable "subscription_id" {
  type        = string
  description = "Target Azure subscription ID."
}

variable "admin_ssh_public_key" {
  type        = string
  description = "Public SSH key for the Linux HTTP probe VM and AKS nodes. Never supply a private key."
}

variable "windows_admin_password" {
  type        = string
  sensitive   = true
  description = "Administrator password for the hub Windows test VM."
}

variable "location" {
  type        = string
  default     = "israelcentral"
  description = "Azure region for the Israel Central staging deployment."
}

variable "resource_group_name" {
  type        = string
  default     = "rg-aks-migration-lab-il"
  description = "Precreated Israel Central lab resource group name."
}

variable "management_resource_group_name" {
  type        = string
  default     = "rg-aks-migration-lab-mgmt"
  description = "Existing management resource group name in Sweden Central."
}

variable "management_vnet_name" {
  type        = string
  default     = "vnet-aks-migration-lab-mgmt"
  description = "Existing management VNet name."
}

variable "management_log_analytics_name" {
  type        = string
  default     = "log-aks-migration-lab-mgmt"
  description = "Existing shared Log Analytics workspace name in the management resource group."
}

variable "blob_private_dns_zone_name" {
  type        = string
  default     = "privatelink.blob.core.windows.net"
  description = "Existing Blob Storage Private DNS zone name in the management resource group."
}

variable "vault_private_dns_zone_name" {
  type        = string
  default     = "privatelink.vaultcore.azure.net"
  description = "Existing Key Vault Private DNS zone name in the management resource group."
}

variable "admin_username" {
  type        = string
  default     = "labadmin"
  description = "Administrator username for VMs and AKS Linux nodes."
}

variable "windows_vm_size" {
  type        = string
  default     = "Standard_D2s_v5"
  description = "VM size for the hub Windows test VM."
}

variable "probe_vm_size" {
  type        = string
  default     = "Standard_D2s_v5"
  description = "VM size for the private HTTP Linux probe VM."
}

variable "aks_node_vm_size" {
  type        = string
  default     = "Standard_D2s_v5"
  description = "VM size for the replacement AKS 1 system node pool."
}

variable "aks_node_count" {
  type        = number
  default     = 1
  description = "System node count for the replacement AKS 1 cluster."
}

variable "vpn_gateway_sku" {
  type        = string
  default     = "VpnGw1AZ"
  description = "SKU for the Israel Central route-based VPN Gateway."
}

variable "vpn_gateway_asn" {
  type        = number
  default     = 65020
  description = "BGP ASN for the Israel Central VPN Gateway, distinct from West Europe (65010) and emulators."
}

variable "key_vault_purge_protection_enabled" {
  type        = bool
  default     = true
  description = "Enable purge protection on the Israel Central Key Vault."
}

variable "key_vault_suffix" {
  type        = string
  default     = ""
  description = "Optional suffix for a fresh Key Vault name when rebuilding after soft delete with purge protection enabled."
}
