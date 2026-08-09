output "ci_runner_ip" {
  description = "IP раннера в LAN 192.168.100.0/24, как его отрепортил guest agent (dhcp-адрес)."
  value = try(
    [for ip in module.ci_runner.ipv4_addresses :
      ip[0] if length(ip) > 0 && startswith(ip[0], "192.168.100.")
    ][0],
    null
  )
}
