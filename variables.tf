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
    Talos image factory schematic ID — encodes which system extensions are baked
    into the image. Generate one at https://factory.talos.dev/

    For Proxmox, include 'siderolabs/qemu-guest-agent' so Proxmox can communicate
    with VMs (IP detection, graceful shutdown, etc).

    The default is the schematic ID for: qemu-guest-agent only.
    To add Tailscale at the OS level, regenerate the schematic with
    'siderolabs/tailscale' added and update this value.
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
    - name:   hostname (must be unique across the cluster)
    - ip:     the static IP this node will use
    - vm_id:  Proxmox VM ID (unique per Proxmox instance, 100–999999)

    Use 1 node for simplicity, 3 for HA (etcd needs an odd number for quorum).
    Set up DHCP reservations (MAC → IP) in your router to ensure each VM
    always boots with its intended IP. MAC addresses appear in Terraform outputs
    after the VMs are created.
  EOT
  type = list(object({
    name  = string
    ip    = string
    vm_id = number
  }))
  default = [
    { name = "cp-0", ip = "192.168.1.110", vm_id = 110 },
  ]
}

variable "worker_nodes" {
  description = "Worker node definitions. Same shape as control_plane_nodes."
  type = list(object({
    name  = string
    ip    = string
    vm_id = number
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
# Tailscale
# ============================================================

variable "tailscale_auth_key" {
  description = <<-EOT
    Tailscale auth key for joining nodes to your tailnet. Generate one at
    https://login.tailscale.com/admin/settings/keys

    When set, each node runs the Tailscale system extension and gets a Tailscale
    IP. The node also advertises your home LAN subnet so you can reach ALL cluster
    nodes (and other home devices) from anywhere on your tailnet.

    Requires the 'siderolabs/tailscale' extension in your Talos schematic —
    regenerate the schematic at factory.talos.dev and update talos_schematic_id.

    After first apply, approve the advertised routes in the Tailscale admin
    console: https://login.tailscale.com/admin/machines
  EOT
  type      = string
  sensitive = true
  default   = ""
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

variable "argocd_app_path" {
  description = <<-EOT
    Path within the mono repo where your ArgoCD Application manifests live.
    This is the root 'app of apps' directory — the entry point ArgoCD uses
    to discover and deploy everything else (Teleport, Crossplane, Backstage, etc).
  EOT
  type    = string
  default = "apps"
}
