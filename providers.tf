provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_tls_insecure
}

provider "github" {
  # Authenticates via the GITHUB_TOKEN environment variable.
  # Pull it from your existing gh CLI session before running terraform:
  #   export GITHUB_TOKEN=$(gh auth token)
  #
  # The token needs the 'repo' scope to manage deploy keys.
  # Check current scopes: gh auth status
  owner = local.github_owner
}

# Credentials come straight from talos_cluster_kubeconfig rather than the
# ./kubeconfig file: config_path is checked during plan, before the cluster
# (and the file) exist, which fails the whole run.
provider "helm" {
  kubernetes {
    host                   = talos_cluster_kubeconfig.this.kubernetes_client_configuration.host
    cluster_ca_certificate = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate)
    client_certificate     = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate)
    client_key             = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key)
  }
}

provider "kubernetes" {
  host                   = talos_cluster_kubeconfig.this.kubernetes_client_configuration.host
  cluster_ca_certificate = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.ca_certificate)
  client_certificate     = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_certificate)
  client_key             = base64decode(talos_cluster_kubeconfig.this.kubernetes_client_configuration.client_key)
}

# The talos provider needs no static config — client credentials are passed
# per-resource via talos_machine_secrets.this.client_configuration.
provider "talos" {}

# hashicorp/tls, hashicorp/local, and terraform_data need no provider block
