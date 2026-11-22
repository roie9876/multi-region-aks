$ErrorActionPreference = "Stop"

if (-not (Get-NetFirewallRule -Name "Allow-Lab-ICMPv4" -ErrorAction SilentlyContinue)) {
  New-NetFirewallRule -Name "Allow-Lab-ICMPv4" -DisplayName "Allow Lab ICMPv4 Echo" -Direction Inbound -Protocol ICMPv4 -IcmpType 8 -Action Allow | Out-Null
}

Clear-DnsClientCache
