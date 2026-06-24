# ============================================================
# Proxmox connection
# ============================================================

variable "proxmox_endpoint" {
  description = "URL of the Proxmox VE API, e.g. https://192.168.1.10:8006"
  type        = string
}

variable "proxmox_api_token" {
  description = <<-EOT
    Proxmox API token in the format 'user@realm!token-id=token-secret'.
    Example: 'root@pam!terraform=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx'
    Create one in Proxmox: Datacenter → Permissions → API Tokens.
    Grant the token the 'PVEVMAdmin' and 'PVEDatastoreAdmin' roles at minimum.
  EOT
  type        = string
  sensitive   = true
}

variable "proxmox_tls_insecure" {
  description = "Skip TLS certificate verification. Set to false if you have a valid certificate."
  type        = bool
  default     = true
}

variable "proxmox_node" {
  description = "Name of the Proxmox node to deploy VMs on (visible in the Proxmox UI, usually 'pve')"
  type        = string
  default     = "pve"
}

variable "proxmox_datastore_id" {
  description = "Proxmox storage pool for VM disks (must support the 'images' content type, e.g. 'local-lvm')"
  type        = string
  default     = "local-lvm"
}

variable "proxmox_iso_datastore_id" {
  description = "Proxmox storage pool for ISO images (must support the 'iso' content type, usually 'local')"
  type        = string
  default     = "local"
}

# ============================================================
# Talos image
# ============================================================

variable "talos_version" {
  description = "Talos Linux version to deploy. See https://github.com/siderolabs/talos/releases"
  type        = string
  default     = "v1.9.5"
}

variable "talos_schematic_id" {
  description = <<-EOT
    Talos image factory schematic ID. Default includes qemu-guest-agent only,
    which is all that is needed for Proxmox. Override only if you need
    additional system extensions — regenerate at https://factory.talos.dev/
  EOT
  type        = string
  default     = "ce4c980550dd2ab1b17bbf2b08801c7eb59418eafe8f279833297925d67c7515"
}

# ============================================================
# Cluster definition (passed to talhelper / talconfig.yaml)
# ============================================================

variable "cluster_name" {
  description = "Name of the Kubernetes cluster. Used in kubeconfig context names and Talos configs."
  type        = string
  default     = "homelab"
}

variable "kubernetes_version" {
  description = <<-EOT
    Kubernetes version to install. Must be compatible with your Talos version —
    check the Talos release notes for the supported range.
    Talos v1.9.x supports Kubernetes v1.29–v1.32.
  EOT
  type        = string
  default     = "v1.32.3"
}

variable "cluster_vip" {
  description = <<-EOT
    Virtual IP (VIP) for the Kubernetes API server. Talos has a built-in VIP that
    floats between healthy control plane nodes. kubectl and cluster components use
    this address to reach the API server.

    Only needed for HA (3+ control planes). Leave empty to use the first
    control plane node's IP as the cluster endpoint instead.
  EOT
  type        = string
  default     = ""
}

variable "install_disk" {
  description = <<-EOT
    Block device Talos installs itself to on first boot.
    On Proxmox with VirtIO storage (virtio0 disk), this is '/dev/vda'.
    Run 'talosctl disks' on a booted node to confirm if unsure.
  EOT
  type        = string
  default     = "/dev/vda"
}

variable "control_plane_nodes" {
  description = <<-EOT
    Control plane node definitions. Each needs:
    - name:        hostname (must be unique across the cluster)
    - ip:          the static IP this node will use
    - vm_id:       Proxmox VM ID (unique per Proxmox instance, 100–999999)
    - mac_address: optional static MAC for DHCP reservations (e.g. "BC:24:11:AA:BB:CC")

    Use 1 node for simplicity, 3 for HA (etcd needs an odd number for quorum).
    Set up DHCP reservations (MAC → IP) in your router to ensure each VM
    always boots with its intended IP.
  EOT
  type = list(object({
    name        = string
    ip          = string
    vm_id       = number
    mac_address = optional(string, "")
  }))
  default = [
    { name = "cp-0", ip = "192.168.1.110", vm_id = 110 },
  ]
}

variable "worker_nodes" {
  description = "Worker node definitions. Same shape as control_plane_nodes."
  type = list(object({
    name        = string
    ip          = string
    vm_id       = number
    mac_address = optional(string, "")
  }))
  default = [
    { name = "worker-0", ip = "192.168.1.120", vm_id = 120 },
    { name = "worker-1", ip = "192.168.1.121", vm_id = 121 },
  ]
}

# ============================================================
# Network
# ============================================================

variable "node_network_gateway" {
  description = "Default gateway for the LAN subnet your nodes live on"
  type        = string
  default     = "192.168.1.1"
}

variable "node_network_prefix_length" {
  description = "Subnet prefix length (24 means /24 = 255.255.255.0)"
  type        = number
  default     = 24
}

variable "dns_servers" {
  description = "DNS servers for cluster nodes"
  type        = list(string)
  default     = ["1.1.1.1", "8.8.8.8"]
}

variable "network_bridge" {
  description = "Proxmox network bridge VMs attach to (check under Proxmox → System → Network)"
  type        = string
  default     = "vmbr0"
}

# ============================================================
# VM sizing — control plane
# ============================================================

variable "control_plane_cpu_cores" {
  description = "vCPU cores per control plane node. 2 is the Talos minimum."
  type        = number
  default     = 2
}

variable "control_plane_memory_mb" {
  description = "RAM in MB for each control plane node. 4096 (4 GB) is a comfortable minimum."
  type        = number
  default     = 4096
}

variable "control_plane_disk_gb" {
  description = "Boot disk size in GB for control plane nodes. Talos needs ~10 GB; 20 gives etcd headroom."
  type        = number
  default     = 20
}

# ============================================================
# VM sizing — workers
# ============================================================

variable "worker_cpu_cores" {
  description = "vCPU cores per worker node. Increase for Crossplane + Backstage workloads."
  type        = number
  default     = 4
}

variable "worker_memory_mb" {
  description = "RAM in MB per worker node. 8192 (8 GB) supports Crossplane + ArgoCD comfortably."
  type        = number
  default     = 8192
}

variable "worker_disk_gb" {
  description = "Boot disk size in GB for worker nodes. Workers store container images, so give them room."
  type        = number
  default     = 50
}

# ============================================================
# ArgoCD bootstrap
# ============================================================

variable "argocd_github_repo" {
  description = <<-EOT
    GitHub repository for your mono repo in 'owner/repo' format.
    Example: "yourname/homelab"

    When set, Terraform will:
      1. Generate an ED25519 SSH key pair
      2. Upload the public key as a read-only deploy key to this repo
      3. Store the private key as a Kubernetes Secret in the cluster
      4. Create an ArgoCD Application pointing at the repo

    Requires GITHUB_TOKEN to be set in your environment:
      export GITHUB_TOKEN=$(gh auth token)

    Leave empty to skip all GitHub and ArgoCD Application setup.
  EOT
  type    = string
  default = ""
}

variable "argocd_repo_revision" {
  description = "Branch, tag, or commit SHA for ArgoCD to track in your mono repo."
  type        = string
  default     = "HEAD"
}

