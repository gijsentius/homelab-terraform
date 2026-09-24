# ============================================================
# Locals — derived values used across resources
# ============================================================

locals {
  # Use the VIP as the cluster endpoint when configured; otherwise fall back to
  # the first control plane node's IP. kubectl and Talos use this address to
  # reach the API server.
  cluster_endpoint = var.cluster_vip != "" ? var.cluster_vip : var.control_plane_nodes[0].ip

  # When there are no workers, control plane nodes must also run workloads
  allow_scheduling_on_cp = length(var.worker_nodes) == 0

  # Parse "owner/repo" into the two parts the GitHub provider needs separately
  github_owner = var.argocd_github_repo != "" ? split("/", var.argocd_github_repo)[0] : ""
  github_repo  = var.argocd_github_repo != "" ? split("/", var.argocd_github_repo)[1] : ""

  # SSH URL derived from the repo variable — ArgoCD uses this to clone
  argocd_repo_url = var.argocd_github_repo != "" ? "git@github.com:${var.argocd_github_repo}.git" : ""

  # Scratch directory the mono repo is cloned into on every apply — see
  # terraform_data.homelab_apps_checkout below.
  homelab_apps_checkout_dir = "${path.module}/.homelab-apps-checkout"
}

# ============================================================
# Talos ISO — downloaded once to Proxmox storage
# ============================================================
#
# The Talos image factory at factory.talos.dev builds custom ISOs based on a
# "schematic" — a list of system extensions baked into the image. Proxmox then
# downloads the ISO directly (you don't need to download it yourself).

resource "proxmox_download_file" "talos_iso" {
  node_name    = var.proxmox_node
  content_type = "iso"
  datastore_id = var.proxmox_iso_datastore_id

  url       = "https://factory.talos.dev/image/${var.talos_schematic_id}/${var.talos_version}/metal-amd64.iso"
  file_name = "talos-${var.talos_version}-${substr(var.talos_schematic_id, 0, 8)}.iso"
  overwrite = false
}

# ============================================================
# Proxmox VMs — control plane nodes
# ============================================================
#
# for_each iterates over the list of control plane configs as a map keyed by
# node name. This is preferred over count because if you add/remove a node
# from the middle of the list, only that node is affected — not all nodes
# after it (which would happen with count).

module "control_plane_vms" {
  source   = "./modules/proxmox_vm"
  for_each = { for node in var.control_plane_nodes : node.name => node }

  vm_id             = each.value.vm_id
  name              = each.value.name
  proxmox_node      = var.proxmox_node
  datastore_id      = var.proxmox_datastore_id
  iso_datastore_id  = var.proxmox_iso_datastore_id
  talos_iso_file_id = proxmox_download_file.talos_iso.id
  cpu_cores         = var.control_plane_cpu_cores
  memory_mb         = var.control_plane_memory_mb
  disk_gb           = var.control_plane_disk_gb
  network_bridge    = var.network_bridge
  mac_address       = each.value.mac_address
}

# ============================================================
# Proxmox VMs — worker nodes
# ============================================================

module "worker_vms" {
  source   = "./modules/proxmox_vm"
  for_each = { for node in var.worker_nodes : node.name => node }

  vm_id             = each.value.vm_id
  name              = each.value.name
  proxmox_node      = var.proxmox_node
  datastore_id      = var.proxmox_datastore_id
  iso_datastore_id  = var.proxmox_iso_datastore_id
  talos_iso_file_id = proxmox_download_file.talos_iso.id
  cpu_cores         = var.worker_cpu_cores
  memory_mb         = var.worker_memory_mb
  disk_gb           = var.worker_disk_gb
  network_bridge    = var.network_bridge
  mac_address       = each.value.mac_address
}

# ============================================================
# Talos machine secrets — cluster CA, bootstrap token, etc.
# ============================================================
#
# Generated once and stored only in Terraform state (never committed — same
# trust model this repo already uses for the Proxmox API token and the
# ArgoCD deploy key's private key). To rotate: `terraform taint
# talos_machine_secrets.this` and re-apply.

resource "talos_machine_secrets" "this" {
  talos_version = var.talos_version
}

# ============================================================
# Machine config patches
# ============================================================
#
# Raw Talos machine config fragments, built from your variables instead of
# talhelper's talconfig.yaml. Patches applied uniformly to every node
# (control plane and worker alike) vs. the control-plane-only scheduling
# flag vs. per-node network identity are kept as separate locals so each can
# be wired into the right data source / resource below.

locals {
  # Applied to both control plane and worker machine configs.
  common_config_patches = [
    yamlencode({
      machine = {
        time    = { servers = ["time.cloudflare.com"] }
        network = { nameservers = var.dns_servers }
      }
    }),
    # MetalLB L2 mode requires strictARP so only the elected node responds to
    # ARP for a given IP, preventing duplicate announcements from multiple nodes.
    yamlencode({
      cluster = {
        proxy = {
          extraArgs = {
            proxy-mode      = "ipvs"
            ipvs-strict-arp = "true"
          }
        }
      }
    }),
  ]

  # allowSchedulingOnControlPlanes only makes sense on the controlplane config.
  allow_scheduling_patch = yamlencode({
    cluster = { allowSchedulingOnControlPlanes = local.allow_scheduling_on_cp }
  })

  # Per-node hostname/install-disk/network identity, keyed by node name so
  # each talos_machine_configuration_apply instance can look up its own patch.
  control_plane_network_patches = {
    for node in var.control_plane_nodes : node.name => yamlencode({
      machine = {
        network = {
          hostname = node.name
          interfaces = [
            merge(
              {
                deviceSelector = { driver = "virtio_net" }
                dhcp           = false
                addresses      = ["${node.ip}/${var.node_network_prefix_length}"]
                routes         = [{ network = "0.0.0.0/0", gateway = var.node_network_gateway }]
              },
              var.cluster_vip != "" ? { vip = { ip = var.cluster_vip } } : {}
            )
          ]
        }
        install = { disk = var.install_disk }
      }
    })
  }

  worker_network_patches = {
    for node in var.worker_nodes : node.name => yamlencode({
      machine = {
        network = {
          hostname = node.name
          interfaces = [
            {
              deviceSelector = { driver = "virtio_net" }
              dhcp           = false
              addresses      = ["${node.ip}/${var.node_network_prefix_length}"]
              routes         = [{ network = "0.0.0.0/0", gateway = var.node_network_gateway }]
            }
          ]
        }
        install = { disk = var.install_disk }
      }
    })
  }
}

# ============================================================
# Machine configuration — one rendered config per machine type
# ============================================================

data "talos_machine_configuration" "controlplane" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = "https://${local.cluster_endpoint}:6443"
  machine_type       = "controlplane"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  kubernetes_version = var.kubernetes_version
  talos_version      = var.talos_version
  config_patches     = concat(local.common_config_patches, [local.allow_scheduling_patch])
}

data "talos_machine_configuration" "worker" {
  cluster_name       = var.cluster_name
  cluster_endpoint   = "https://${local.cluster_endpoint}:6443"
  machine_type       = "worker"
  machine_secrets    = talos_machine_secrets.this.machine_secrets
  kubernetes_version = var.kubernetes_version
  talos_version      = var.talos_version
  config_patches     = local.common_config_patches
}

# ============================================================
# Apply machine configs to nodes
# ============================================================
#
# The provider handles both a freshly-booted node (insecure maintenance-mode
# API) and an already-installed one (secure API via the cluster CA) itself —
# no more manual "try secure, fall back to insecure, wait, retry, reboot"
# shell dance.
#
# depends_on the VM modules: nodes must be powered on and reachable. If a VM
# isn't up yet, this apply fails and simply isn't recorded in state — the
# next 'terraform apply' retries automatically.

resource "talos_machine_configuration_apply" "control_plane" {
  for_each = { for node in var.control_plane_nodes : node.name => node }

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.controlplane.machine_configuration
  node                        = each.value.ip
  config_patches              = [local.control_plane_network_patches[each.key]]

  depends_on = [module.control_plane_vms]
}

resource "talos_machine_configuration_apply" "worker" {
  for_each = { for node in var.worker_nodes : node.name => node }

  client_configuration        = talos_machine_secrets.this.client_configuration
  machine_configuration_input = data.talos_machine_configuration.worker.machine_configuration
  node                        = each.value.ip
  config_patches              = [local.worker_network_patches[each.key]]

  depends_on = [module.worker_vms]
}

# ============================================================
# Bootstrap etcd
# ============================================================
#
# Bootstraps etcd on the first control plane node. Only needs to happen
# once — Terraform tracks it in state and won't repeat it.

resource "talos_machine_bootstrap" "this" {
  node                 = var.control_plane_nodes[0].ip
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [talos_machine_configuration_apply.control_plane]
}

# ============================================================
# Retrieve kubeconfig and talosconfig
# ============================================================
#
# local_file re-wraps the provider's in-state output onto disk so downstream
# consumers (helm/kubernetes providers below, talosctl on the CLI) keep
# working the same way they did with talhelper's generated files.

data "talos_client_configuration" "this" {
  cluster_name         = var.cluster_name
  client_configuration = talos_machine_secrets.this.client_configuration
  nodes                = concat([for node in var.control_plane_nodes : node.ip], [for node in var.worker_nodes : node.ip])
  endpoints            = [for node in var.control_plane_nodes : node.ip]
}

resource "talos_cluster_kubeconfig" "this" {
  node                 = var.control_plane_nodes[0].ip
  client_configuration = talos_machine_secrets.this.client_configuration

  depends_on = [talos_machine_bootstrap.this]
}

resource "local_file" "kubeconfig" {
  filename        = "${path.module}/kubeconfig"
  file_permission = "0600"
  content         = talos_cluster_kubeconfig.this.kubeconfig_raw
}

resource "local_file" "talosconfig" {
  filename        = "${path.module}/talosconfig"
  file_permission = "0600"
  content         = data.talos_client_configuration.this.talos_config
}

# ============================================================
# SSH deploy key — generated by Terraform, uploaded to GitHub
# ============================================================
#
# Terraform generates an ED25519 key pair. The public key is uploaded to GitHub
# as a read-only deploy key (ArgoCD only needs to pull, never push). The private
# key is passed into the bootstrap chart and stored as an ArgoCD repo Secret.
#
# The private key lives only in Terraform state (gitignored and local).

resource "tls_private_key" "argocd_deploy_key" {
  count     = var.argocd_github_repo != "" ? 1 : 0
  algorithm = "ED25519"
}

resource "github_repository_deploy_key" "argocd" {
  count = var.argocd_github_repo != "" ? 1 : 0

  title      = "ArgoCD — ${var.cluster_name}"
  repository = local.github_repo
  key        = tls_private_key.argocd_deploy_key[0].public_key_openssh
  read_only  = true
}

# ============================================================
# ArgoCD — installed directly from the upstream chart
# ============================================================
#
# Installed on its own, separate from the AppProject/ApplicationSet below.
# Reason: AppProject and ApplicationSet are instances of CRDs that this chart
# installs. Helm sorts CRDs before custom resources within a single release,
# but does not wait for the API server to finish registering a freshly-created
# CRD before moving on to apply the rest — so creating the CRDs and instances
# of them in one release races, and intermittently fails with "no matches for
# kind" / CRD-not-found errors. Splitting into two Helm releases (this one,
# then homelab_bootstrap below, depends_on-ed after it) gives the API server
# time to register the CRDs before anything tries to use them.
#
# ignore_changes = all: this is a one-time bootstrap install. Once
# infrastructure/argocd/ (in the mono repo) is picked up by the
# ApplicationSet below, ArgoCD reconciles its own Helm release from git —
# Terraform stops touching it after the initial create so the two don't fight.

resource "helm_release" "argocd" {
  count = var.argocd_github_repo != "" ? 1 : 0

  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.argocd_chart_version
  namespace        = "argocd"
  create_namespace = true
  wait             = true
  timeout          = 600

  set {
    name  = "server.service.type"
    value = "ClusterIP"
  }

  lifecycle {
    ignore_changes = all
  }

  depends_on = [local_file.kubeconfig]
}

# ============================================================
# homelab-apps checkout — cloned fresh from GitHub on every apply
# ============================================================
#
# helm_release.homelab_bootstrap needs the mono repo's apps/ chart on local
# disk (the Helm provider doesn't support a bare git repo as a chart source).
# Rather than assuming a manually-maintained sibling checkout exists next to
# this repo — fragile across machines: directory naming has to match exactly,
# a stale checkout silently serves outdated content, and gitignored local
# artifacts (e.g. a vendored charts/ dir from a since-removed dependency) can
# leak into the render — clone the repo into a scratch directory here instead.
#
# Auth: HTTPS with GITHUB_TOKEN (already required for the github provider
# above), not SSH, so this doesn't depend on the host's SSH agent/keys.
#
# triggers_replace = [timestamp()]: re-clone on every apply, so this always
# deploys whatever is currently on argocd_repo_revision — the same freshness
# ArgoCD's own git generator has, instead of tracking local filesystem state.

resource "terraform_data" "homelab_apps_checkout" {
  count = var.argocd_github_repo != "" ? 1 : 0

  triggers_replace = [timestamp()]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      rm -rf "${local.homelab_apps_checkout_dir}"
      git clone --quiet "https://x-access-token:$GITHUB_TOKEN@github.com/${var.argocd_github_repo}.git" \
        "${local.homelab_apps_checkout_dir}"
      git -C "${local.homelab_apps_checkout_dir}" checkout --quiet "${var.argocd_repo_revision}"
    EOT
  }
}

# ============================================================
# homelab-bootstrap — repo credentials + AppProject + ApplicationSet
# ============================================================
#
# A Helm release that creates:
#   1. The ArgoCD repo credential Secret with the SSH deploy key
#   2. The AppProject and ApplicationSet that discover the mono repo
#
# After this apply ArgoCD immediately begins syncing all infrastructure apps,
# including infrastructure/argocd/ itself — from that point on ArgoCD manages
# its own Helm release from git, not Terraform (see helm_release.argocd above).
#
# Access ArgoCD while it bootstraps:
#   kubectl port-forward svc/argocd-server -n argocd 8080:443 --kubeconfig kubeconfig
# Initial admin password:
#   kubectl get secret argocd-initial-admin-secret -n argocd \
#     --kubeconfig kubeconfig -o jsonpath="{.data.password}" | base64 -d

resource "helm_release" "homelab_bootstrap" {
  count = var.argocd_github_repo != "" ? 1 : 0

  name             = "homelab-bootstrap"
  chart            = "${local.homelab_apps_checkout_dir}/apps"
  namespace        = "argocd"
  create_namespace = true
  wait             = true
  timeout          = 600

  set {
    name  = "repoURL"
    value = local.argocd_repo_url
  }

  set {
    name  = "revision"
    value = var.argocd_repo_revision
  }

  set_sensitive {
    name  = "sshPrivateKey"
    value = tls_private_key.argocd_deploy_key[0].private_key_openssh
  }

  depends_on = [
    helm_release.argocd,
    github_repository_deploy_key.argocd,
    terraform_data.homelab_apps_checkout,
  ]
}

# ============================================================
# Tailscale operator OAuth credentials
# ============================================================
#
# tailscale-operator (installed by ArgoCD via infrastructure/tailscale-operator/
# in the mono repo) needs this Secret to authenticate to the Tailscale API. The
# mono repo intentionally doesn't create it — that would mean committing OAuth
# credentials in the clear, and there's no encryption setup for arbitrary app
# secrets there. Terraform creates it directly instead.
#
# Optional: only created when tailscale_oauth_client_id is set. If left empty,
# create operator-oauth-secret.yaml.example manually and apply it — see the
# variable's description.

resource "kubernetes_namespace" "tailscale" {
  count = var.tailscale_oauth_client_id != "" ? 1 : 0

  metadata {
    name = "tailscale"
  }

  depends_on = [local_file.kubeconfig]
}

resource "kubernetes_secret" "tailscale_operator_oauth" {
  count = var.tailscale_oauth_client_id != "" ? 1 : 0

  metadata {
    name      = "operator-oauth"
    namespace = "tailscale"
  }

  data = {
    client_id     = var.tailscale_oauth_client_id
    client_secret = var.tailscale_oauth_client_secret
  }

  depends_on = [kubernetes_namespace.tailscale]
}
