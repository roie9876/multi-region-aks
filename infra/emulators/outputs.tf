output "onprem" {
  description = "On-premises emulator site connection and VM details."
  value = {
    router_public_ip           = azurerm_public_ip.router["onprem"].ip_address
    bgp_peer_ip                = local.sites["onprem"].bgp_peer_ip
    asn                        = local.sites["onprem"].asn
    advertised_client_dns_cidr = local.sites["onprem"].client_subnet_cidr
    router_subnet_cidr         = local.sites["onprem"].router_subnet_cidr
    dns_private_ip             = local.sites["onprem"].dns_private_ip
    client_private_ip          = local.sites["onprem"].client_private_ip
    web_private_ip             = local.sites["onprem"].web_private_ip
    vm_names = {
      router = azurerm_linux_virtual_machine.router["onprem"].name
      dns    = azurerm_windows_virtual_machine.onprem_dns.name
      client = azurerm_windows_virtual_machine.client["onprem"].name
      web    = azurerm_linux_virtual_machine.web["onprem"].name
    }
    url = "http://${local.sites["onprem"].web_private_ip}/"
  }
}

output "gcp" {
  description = "GCP emulator site connection and VM details."
  value = {
    router_public_ip           = azurerm_public_ip.router["gcp"].ip_address
    bgp_peer_ip                = local.sites["gcp"].bgp_peer_ip
    asn                        = local.sites["gcp"].asn
    advertised_client_dns_cidr = local.sites["gcp"].client_subnet_cidr
    router_subnet_cidr         = local.sites["gcp"].router_subnet_cidr
    dns_private_ip             = local.sites["gcp"].dns_private_ip
    client_private_ip          = local.sites["gcp"].client_private_ip
    web_private_ip             = local.sites["gcp"].web_private_ip
    vm_names = {
      router = azurerm_linux_virtual_machine.router["gcp"].name
      dns    = azurerm_linux_virtual_machine.gcp_dns.name
      client = azurerm_windows_virtual_machine.client["gcp"].name
      web    = azurerm_linux_virtual_machine.web["gcp"].name
    }
    url = "http://${local.sites["gcp"].web_private_ip}/"
  }
}

output "router_public_ips" {
  description = "Public IPv4 addresses of the emulator VPN routers keyed by site."
  value = {
    for k, pip in azurerm_public_ip.router : k => pip.ip_address
  }
}

output "bgp_peer_ips" {
  description = "Private BGP peer IPv4 addresses of the emulator VPN routers keyed by site."
  value = {
    for k, site in local.sites : k => site.bgp_peer_ip
  }
}

output "asns" {
  description = "BGP ASNs of the emulator sites keyed by site."
  value = {
    for k, site in local.sites : k => site.asn
  }
}

output "advertised_client_dns_cidrs" {
  description = "Advertised client/DNS subnet CIDRs keyed by site."
  value = {
    for k, site in local.sites : k => site.client_subnet_cidr
  }
}

output "vm_names" {
  description = "All emulator VM names keyed by site and role."
  value = {
    onprem = {
      router = azurerm_linux_virtual_machine.router["onprem"].name
      dns    = azurerm_windows_virtual_machine.onprem_dns.name
      client = azurerm_windows_virtual_machine.client["onprem"].name
      web    = azurerm_linux_virtual_machine.web["onprem"].name
    }
    gcp = {
      router = azurerm_linux_virtual_machine.router["gcp"].name
      dns    = azurerm_linux_virtual_machine.gcp_dns.name
      client = azurerm_windows_virtual_machine.client["gcp"].name
      web    = azurerm_linux_virtual_machine.web["gcp"].name
    }
  }
}

output "test_page_urls" {
  description = "Private HTTP test page URLs keyed by site."
  value = {
    for k, site in local.sites : k => "http://${site.web_private_ip}/"
  }
}
