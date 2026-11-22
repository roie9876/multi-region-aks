variable "subscription_id" {
  type        = string
  description = "Azure subscription ID hosting the emulator resource group."
}

variable "resource_group_name" {
  type        = string
  default     = "rg-aks-migration-lab-emulators"
  description = "Precreated Azure resource group for the on-premises and GCP emulators."
}

variable "location" {
  type        = string
  default     = "swedencentral"
  description = "Azure region for all emulator resources."
}

variable "west_vpn_public_ip" {
  type        = string
  description = "Public IPv4 address of the West Europe Azure VPN Gateway."
}

variable "west_vpn_bgp_ip" {
  type        = string
  description = "Private BGP peer IPv4 address of the West Europe Azure VPN Gateway."
}

variable "remote_asn" {
  type        = number
  default     = 65010
  description = "BGP ASN of the remote West Europe Azure VPN Gateway."
}

variable "resolver_ip" {
  type        = string
  default     = "10.42.2.4"
  description = "Inbound endpoint IPv4 address of the West Europe Azure DNS Private Resolver."
}

variable "onprem_vpn_psk" {
  type        = string
  sensitive   = true
  description = "IPsec pre-shared key for the on-premises emulator to West Europe VPN connection."
}

variable "gcp_vpn_psk" {
  type        = string
  sensitive   = true
  description = "IPsec pre-shared key for the GCP emulator to West Europe VPN connection."
}

variable "windows_admin_password" {
  type        = string
  sensitive   = true
  description = "Administrator password for all Windows Server VMs (on-premises DNS and both Windows test clients)."
}

variable "admin_ssh_public_key" {
  type        = string
  description = "Public SSH key for the labadmin user on all Linux VMs."
}

variable "linux_vm_size" {
  type        = string
  default     = "Standard_D2s_v5"
  description = "VM SKU for Linux router, DNS, and web VMs."
}

variable "windows_vm_size" {
  type        = string
  default     = "Standard_D2s_v5"
  description = "VM SKU for Windows Server DNS and client test VMs."
}

variable "remote_lab_cidrs" {
  type        = list(string)
  default     = ["10.42.0.0/16", "10.43.0.0/16", "10.44.0.0/16"]
  description = "Remote Azure lab CIDRs routed from each emulator client/DNS subnet through its local VPN router VM."
}
