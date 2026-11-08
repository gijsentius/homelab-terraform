# ============================================================
# VM MAC addresses
# ============================================================
#
# Use these to configure DHCP reservations (MAC → IP) in your router.
# This ensures each VM always boots with the IP you defined in your variables,
# so that Terraform can reach the Talos API at the expected address.

output "control_plane_mac_addresses" {
  description = "MAC addresses of control plane VMs. Use these for DHCP reservations."
  value = {
    for name, vm in module.control_plane_vms : name => vm.mac_address
  }
}

output "worker_mac_addresses" {
  description = "MAC addresses of worker VMs. Use these for DHCP reservations."
  value = {
    for name, vm in module.worker_vms : name => vm.mac_address
  }
}

# ============================================================
# Cluster access
# ============================================================

output "kubeconfig_path" {
  description = "Path to the generated kubeconfig file (created after 'tofu apply' completes)"
  value       = "${path.module}/kubeconfig${local.site_suffix}"
}

output "talosconfig_path" {
  description = "Path to the generated talosconfig file (use with talosctl --talosconfig)"
  value       = "${path.module}/talosconfig${local.site_suffix}"
}

# ============================================================
# NFS server
# ============================================================

output "nfs_export" {
  description = "NFS server and export path for clusters/<site>/cluster.yaml (nfs.server / nfs.share) in homelab-apps. null when nfs_server isn't set."
  value = var.nfs_server != null ? {
    server = var.nfs_server.ip
    share  = "/srv/nfs"
  } : null
}
