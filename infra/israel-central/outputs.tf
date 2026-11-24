output "hub_vnet_name" {
  value = azurerm_virtual_network.hub.name
}

output "hub_vnet_id" {
  value = azurerm_virtual_network.hub.id
}

output "dns_vnet_name" {
  value = azurerm_virtual_network.dns.name
}

output "dns_vnet_id" {
  value = azurerm_virtual_network.dns.id
}

output "aks1_vnet_name" {
  value = azurerm_virtual_network.aks1.name
}

output "aks1_vnet_id" {
  value = azurerm_virtual_network.aks1.id
}

output "vpn_gateway_name" {
  value = azurerm_virtual_network_gateway.hub.name
}

output "vpn_gateway_id" {
  value = azurerm_virtual_network_gateway.hub.id
}

output "vpn_gateway_public_ip" {
  value = azurerm_public_ip.hub["vpngw"].ip_address
}

output "vpn_gateway_bgp_asn" {
  value = local.vpn_gateway_asn
}

output "vpn_gateway_bgp_ip" {
  value = try(azurerm_virtual_network_gateway.hub.bgp_settings[0].peering_addresses[0].default_addresses[0], null)
}

output "firewall_name" {
  value = azurerm_firewall.hub.name
}

output "firewall_id" {
  value = azurerm_firewall.hub.id
}

output "firewall_private_ip" {
  value = azurerm_firewall.hub.ip_configuration[0].private_ip_address
}

output "firewall_public_ip" {
  value = azurerm_public_ip.hub["firewall"].ip_address
}

output "dns_inbound_ip" {
  value = azurerm_private_dns_resolver_inbound_endpoint.main.ip_configurations[0].private_ip_address
}

output "dns_outbound_endpoint_id" {
  value = azurerm_private_dns_resolver_outbound_endpoint.main.id
}

output "dns_forwarding_ruleset_id" {
  value = azurerm_private_dns_resolver_dns_forwarding_ruleset.main.id
}

output "storage_account_name" {
  value = azurerm_storage_account.il.name
}

output "storage_account_id" {
  value = azurerm_storage_account.il.id
}

output "storage_blob_private_ip" {
  value = azurerm_private_endpoint.blob.private_service_connection[0].private_ip_address
}

output "key_vault_name" {
  value = azurerm_key_vault.il.name
}

output "key_vault_id" {
  value = azurerm_key_vault.il.id
}

output "key_vault_private_ip" {
  value = azurerm_private_endpoint.vault.private_service_connection[0].private_ip_address
}

output "aks1_name" {
  value = azurerm_kubernetes_cluster.aks["aks1"].name
}

output "aks1_id" {
  value = azurerm_kubernetes_cluster.aks["aks1"].id
}

output "aks1_private_fqdn" {
  value = azurerm_kubernetes_cluster.aks["aks1"].private_fqdn
}

output "windows_vm_name" {
  value = azurerm_windows_virtual_machine.stationary.name
}

output "windows_vm_id" {
  value = azurerm_windows_virtual_machine.stationary.id
}

output "windows_vm_private_ip" {
  value = azurerm_network_interface.windows.private_ip_address
}

output "probe_vm_name" {
  value = azurerm_linux_virtual_machine.probe.name
}

output "probe_vm_id" {
  value = azurerm_linux_virtual_machine.probe.id
}

output "probe_vm_private_ip" {
  value = azurerm_network_interface.probe.private_ip_address
}

output "probe_site_url" {
  value = "http://${azurerm_network_interface.probe.private_ip_address}/"
}

output "hub_vnet" {
  value = {
    id             = azurerm_virtual_network.hub.id
    name           = azurerm_virtual_network.hub.name
    resource_group = data.azurerm_resource_group.israel_central.name
  }
}

output "dns_vnet" {
  value = {
    id             = azurerm_virtual_network.dns.id
    name           = azurerm_virtual_network.dns.name
    resource_group = data.azurerm_resource_group.israel_central.name
  }
}

output "aks1_vnet" {
  value = {
    id             = azurerm_virtual_network.aks1.id
    name           = azurerm_virtual_network.aks1.name
    resource_group = data.azurerm_resource_group.israel_central.name
  }
}
