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

  age_key_file = "${path.module}/age.key"
}

# ============================================================
# Age key pair — generated once, stored in age.key (gitignored)
# ============================================================
#
# age-keygen writes the private key to age.key and prints the public key
# to stdout. We capture the public key and write it into .sops.yaml so
# SOPS knows which key to use for encryption.
#
# ignore_changes = all ensures this runs exactly once — the key is stable
# across all subsequent applies.

resource "terraform_data" "age_keygen" {
  lifecycle {
    ignore_changes = all
  }

  provisioner "local-exec" {
    command = <<-EOT
      if [ ! -f age.key ]; then
        age-keygen -o age.key
      fi
      PUBLIC_KEY=$(age-keygen -y age.key)
      cat > .sops.yaml <<SOPS
creation_rules:
  - path_regex: talsecret\.sops\.yaml$$
    age: >-
      $PUBLIC_KEY
SOPS
    EOT
    working_dir = path.module
  }
}

# ============================================================
# Cluster secrets — generated and encrypted once
# ============================================================
#
# talhelper gensecret generates fresh cluster CA keys and bootstrap tokens.
# sops encrypts the result using the age public key from .sops.yaml.
# The encrypted file is safe to commit — the private key (age.key) stays local.
#
# ignore_changes = all ensures secrets are never rotated unintentionally.
# To rotate: delete talsecret.sops.yaml and re-run terraform apply.

resource "terraform_data" "talsecret" {
  lifecycle {
    ignore_changes = all
  }

  provisioner "local-exec" {
    command = <<-EOT
      if [ ! -f talsecret.sops.yaml ]; then
        talhelper gensecret | \
          SOPS_AGE_KEY_FILE=age.key sops --encrypt --input-type yaml --output-type yaml /dev/stdin \
          > talsecret.sops.yaml
      fi
    EOT
    working_dir = path.module
  }

  depends_on = [terraform_data.age_keygen]
}

# ============================================================
# Talos ISO — downloaded once to Proxmox storage
# ============================================================
#
# The Talos image factory at factory.talos.dev builds custom ISOs based on a
# "schematic" — a list of system extensions baked into the image. Proxmox then
# downloads the ISO directly (you don't need to download it yourself).

resource "proxmox_virtual_environment_download_file" "talos_iso" {
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
  talos_iso_file_id = proxmox_virtual_environment_download_file.talos_iso.id
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
  talos_iso_file_id = proxmox_virtual_environment_download_file.talos_iso.id
  cpu_cores         = var.worker_cpu_cores
  memory_mb         = var.worker_memory_mb
  disk_gb           = var.worker_disk_gb
  network_bridge    = var.network_bridge
  mac_address       = each.value.mac_address
}

# ============================================================
# talconfig.yaml — written from template
# ============================================================
#
# Terraform renders talconfig.yaml from the .tftpl template using your variables.
# talhelper reads this file to know what cluster to build and what nodes to configure.
#
# Do not edit talconfig.yaml by hand — it will be overwritten on the next
# 'terraform apply'. Change your values in terraform.tfvars instead.

resource "local_file" "talconfig" {
  filename        = "${path.module}/talconfig.yaml"
  file_permission = "0644"

  content = templatefile("${path.module}/templates/talconfig.yaml.tftpl", {
    cluster_name           = var.cluster_name
    talos_version          = var.talos_version
    kubernetes_version     = var.kubernetes_version
    cluster_endpoint       = local.cluster_endpoint
    cluster_vip            = var.cluster_vip
    install_disk           = var.install_disk
    control_plane_nodes    = var.control_plane_nodes
    worker_nodes           = var.worker_nodes
    gateway                = var.node_network_gateway
    prefix_length          = var.node_network_prefix_length
    dns_servers            = var.dns_servers
    allow_scheduling_on_cp = local.allow_scheduling_on_cp
  })
}

# ============================================================
# talhelper genconfig — generate per-node Talos machine configs
# ============================================================
#
# talhelper reads talconfig.yaml + talsecret.sops.yaml and writes one machine
# config YAML per node into clusterconfig/. talhelper decrypts the SOPS file
# automatically using the age key at ~/.config/sops/age/keys.txt (or whichever
# key is configured in SOPS_AGE_KEY_FILE).
#
# triggers_replace: this resource re-runs whenever talconfig.yaml's content
# changes. Terraform detects the change, destroys the old resource, and runs
# the new one — causing genconfig to regenerate all machine configs.
#
# Prerequisite: talsecret.sops.yaml must exist in this directory.
# Generate and encrypt it once with:
#   talhelper gensecret > talsecret.sops.yaml
#   sops --encrypt --in-place talsecret.sops.yaml
# Then commit talsecret.sops.yaml — it is safe to store in git.

resource "terraform_data" "talhelper_genconfig" {
  triggers_replace = [local_file.talconfig.content]

  provisioner "local-exec" {
    command     = "talhelper genconfig --secret-file talsecret.sops.yaml --out-dir clusterconfig"
    working_dir = path.module
    environment = {
      SOPS_AGE_KEY_FILE = local.age_key_file
    }
  }

  depends_on = [terraform_data.talsecret]
}

# ============================================================
# Apply Talos machine configs to all nodes
# ============================================================
#
# talhelper gencommand apply generates the talosctl commands needed to push
# each node's machine config via the Talos API, then we pipe them to bash.
#
# --extra-flags "--insecure": skips certificate verification for the first
# apply, when nodes are in maintenance mode and don't have certificates yet.
#
# This step requires all VMs to be:
#   1. Powered on and booted from the Talos ISO
#   2. Reachable at their configured IP addresses
#
# If this step fails because VMs aren't ready, Terraform marks the resource as
# tainted. Re-run 'terraform apply' once the nodes are up — it will retry.

resource "terraform_data" "talos_apply" {
  triggers_replace = [
    terraform_data.talhelper_genconfig.id,
    # Re-apply configs if any VM is recreated (its ID changes)
    jsonencode({ for k, v in module.control_plane_vms : k => v.vm_id }),
    jsonencode({ for k, v in module.worker_vms : k => v.vm_id }),
  ]

  provisioner "local-exec" {
    # NODE_IPS: space-separated list of all node IPs — passed to the wait loop below.
    # Space-separated (not comma) so the POSIX for-loop can split it without arrays.
    environment = {
      NODE_IPS = join(" ", concat(
        [for n in var.control_plane_nodes : n.ip],
        [for n in var.worker_nodes : n.ip],
      ))
    }
    # Poll each node until it answers the Talos maintenance-mode API, then apply.
    # VMs are created in Proxmox before they finish booting, so we must wait here.
    # Uses only POSIX sh syntax — Terraform local-exec runs under /bin/sh (dash on Linux).
    command = <<-EOT
      for IP in $NODE_IPS; do
        echo "Waiting for $IP to enter Talos maintenance mode..."
        until talosctl version --insecure --nodes "$IP" >/dev/null 2>&1; do
          sleep 10
        done
        echo "$IP is ready"
      done
      talhelper gencommand apply \
        --config-file talconfig.yaml \
        --out-dir clusterconfig \
        --extra-flags "--insecure" \
        | bash
    EOT
    working_dir = path.module
  }

  depends_on = [module.control_plane_vms, module.worker_vms]
}

# ============================================================
# Bootstrap etcd
# ============================================================
#
# Bootstrap initialises etcd on the first control plane node. This only needs
# to happen once — Terraform tracks it in state and won't repeat it unless
# the talos_apply resource changes (e.g. after a cluster rebuild).
#
# After bootstrap, the other control plane nodes join etcd automatically,
# and workers join the cluster once their configs are applied.

resource "terraform_data" "talos_bootstrap" {
  triggers_replace = [terraform_data.talos_apply.id]

  provisioner "local-exec" {
    # FIRST_CP_IP: the node bootstrap targets — must be responsive before we proceed.
    # After config is applied, nodes reboot to install Talos to disk. We poll the
    # authenticated Talos API (not --insecure) until the node is fully back up.
    environment = {
      FIRST_CP_IP = var.control_plane_nodes[0].ip
    }
    command = <<-EOT
      echo "Waiting for $FIRST_CP_IP to come up after config apply and reboot..."
      until talosctl --talosconfig clusterconfig/talosconfig \
        --nodes "$FIRST_CP_IP" version >/dev/null 2>&1; do
        sleep 10
      done
      echo "$FIRST_CP_IP is up, bootstrapping etcd..."
      talhelper gencommand bootstrap \
        --config-file talconfig.yaml \
        --out-dir clusterconfig \
        | bash
    EOT
    working_dir = path.module
  }

  depends_on = [terraform_data.talos_apply]
}

# ============================================================
# Retrieve kubeconfig
# ============================================================
#
# Saves the cluster kubeconfig to ./kubeconfig in this directory.
# Copy it to ~/.kube/config (or use KUBECONFIG=./kubeconfig) to use kubectl.

resource "terraform_data" "talos_kubeconfig" {
  triggers_replace = [terraform_data.talos_bootstrap.id]

  provisioner "local-exec" {
    command = <<-EOT
      talhelper gencommand kubeconfig \
        --config-file talconfig.yaml \
        --out-dir clusterconfig \
        --extra-flags "--merge=false" \
        | bash -s -- ./kubeconfig
    EOT
    working_dir = path.module
  }

  depends_on = [terraform_data.talos_bootstrap]
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
# homelab-bootstrap — installs ArgoCD + AppProject + ApplicationSet
# ============================================================
#
# A single Helm release that:
#   1. Installs ArgoCD (as a chart dependency) and waits for it to be ready
#   2. Creates the ArgoCD repo credential Secret with the SSH deploy key
#   3. Creates the AppProject and ApplicationSet that discover the mono repo
#
# After this apply ArgoCD immediately begins syncing all infrastructure apps.
# ArgoCD manages its own config from the mono repo from this point on;
# ignore_changes = [values] prevents Terraform from fighting it on re-applies.
#
# Access ArgoCD while Teleport is bootstrapping:
#   kubectl port-forward svc/argocd-server -n argocd 8080:443 --kubeconfig kubeconfig
# Initial admin password:
#   kubectl get secret argocd-initial-admin-secret -n argocd \
#     --kubeconfig kubeconfig -o jsonpath="{.data.password}" | base64 -d

resource "helm_release" "homelab_bootstrap" {
  count = var.argocd_github_repo != "" ? 1 : 0

  name             = "homelab-bootstrap"
  chart            = "${path.module}/../homelab/apps"
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

  lifecycle {
    ignore_changes = [values]
  }

  depends_on = [
    terraform_data.talos_kubeconfig,
    github_repository_deploy_key.argocd,
  ]
}
