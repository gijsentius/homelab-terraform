output "vm_id" {
  description = "Proxmox VM ID"
  value       = proxmox_virtual_environment_vm.this.vm_id
}

output "name" {
  description = "VM hostname"
  value       = proxmox_virtual_environment_vm.this.name
}

# The MAC address is auto-assigned by Proxmox on creation.
# You can use this to configure DHCP reservations in your router so that
# the VM always gets the IP address you've defined in var.control_plane_nodes / var.worker_nodes.
output "mac_address" {
  description = "MAC address of the VM's first network interface"
  value       = proxmox_virtual_environment_vm.this.network_device[0].mac_address
}
