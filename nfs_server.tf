# ============================================================
# NFS server (optional) — storage for csi-driver-nfs
# ============================================================
#
# A small Debian VM that exports a data disk over NFS. The cluster's
# csi-driver-nfs (infrastructure/csi-driver-nfs in homelab-apps) mounts it
# for shared volumes such as the media library used by sonarr, radarr,
# sabnzbd and plex. Only created when var.nfs_server is set: sites with
# other NFS storage (e.g. a Synology) leave it null.
#
# Disks:
#   virtio0  OS, from the Debian cloud image, on var.proxmox_datastore_id
#   virtio1  data, on the ZFS pool (nfs_server.data_datastore_id), formatted
#            XFS on first setup and mounted at /srv/nfs
#
# Network and the login key are set through Proxmox cloud-init (no snippet
# upload, so the API token is enough). Packages and exports are configured
# over SSH by terraform_data.nfs_server_setup below, which re-runs whenever
# the setup script or its inputs change. The script never reformats a disk
# that already has a filesystem.

locals {
  nfs_enabled = var.nfs_server != null

  # Default export: the node network the cluster lives on.
  nfs_export_cidr = local.nfs_enabled ? coalesce(
    var.nfs_server.export_cidr,
    "${cidrhost("${var.nfs_server.ip}/${var.node_network_prefix_length}", 0)}/${var.node_network_prefix_length}",
  ) : null

  nfs_setup_script = local.nfs_enabled ? templatefile("${path.module}/templates/nfs-server-setup.sh.tftpl", {
    data_disk   = "/dev/disk/by-id/virtio-nfs-data"
    export_cidr = local.nfs_export_cidr
    media_owner = var.nfs_server.media_owner
  }) : null
}

# Debian cloud image, downloaded once as an 'import' image. The disk below
# imports it with import_from, which goes through the Proxmox API. (file_id
# would run qm importdisk over SSH on the node instead.) Needs the Import
# content type enabled on the storage: Datacenter → Storage → <storage> →
# Content.
resource "proxmox_download_file" "debian_cloud_image" {
  count = local.nfs_enabled ? 1 : 0

  node_name    = var.proxmox_node
  content_type = "import"
  datastore_id = var.proxmox_iso_datastore_id

  url       = "https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2"
  file_name = "debian-13-genericcloud-amd64.qcow2"
  # 'latest' moves; keep the first download instead of replacing it (and
  # re-triggering a diff) every time Debian publishes a new build.
  overwrite = false
}

# Terraform's own login to the VM, for the setup provisioner.
resource "tls_private_key" "nfs_server" {
  count     = local.nfs_enabled ? 1 : 0
  algorithm = "ED25519"
}

resource "proxmox_virtual_environment_vm" "nfs_server" {
  count = local.nfs_enabled ? 1 : 0

  vm_id     = var.nfs_server.vm_id
  name      = var.nfs_server.name
  node_name = var.proxmox_node

  # Start with the Proxmox host, so the share is back after a host reboot.
  on_boot = true

  cpu {
    cores = var.nfs_server.cpu_cores
    type  = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.nfs_server.memory_mb
  }

  disk {
    datastore_id = var.proxmox_datastore_id
    import_from  = proxmox_download_file.debian_cloud_image[0].id
    interface    = "virtio0"
    size         = var.nfs_server.os_disk_gb
    discard      = "on"
  }

  disk {
    datastore_id = var.nfs_server.data_datastore_id
    interface    = "virtio1"
    size         = var.nfs_server.data_disk_gb
    file_format  = "raw"
    discard      = "on"
    # Shows up in the guest as /dev/disk/by-id/virtio-nfs-data, so the setup
    # script finds the data disk by name instead of by probe order.
    serial = "nfs-data"
  }

  initialization {
    datastore_id = var.proxmox_datastore_id

    ip_config {
      ipv4 {
        address = "${var.nfs_server.ip}/${var.node_network_prefix_length}"
        gateway = var.node_network_gateway
      }
    }

    dns {
      servers = var.dns_servers
    }

    user_account {
      username = "debian"
      keys     = concat([trimspace(tls_private_key.nfs_server[0].public_key_openssh)], var.nfs_server.ssh_public_keys)
    }
  }

  network_device {
    bridge = var.network_bridge
    model  = "virtio"
  }

  operating_system {
    type = "l26"
  }

  # Debian cloud images log to the serial console; without one the Proxmox
  # console stays blank.
  serial_device {}

  # The cloud image doesn't ship qemu-guest-agent, and the provider would wait
  # for it on every create/refresh.
  agent {
    enabled = false
  }

  lifecycle {
    ignore_changes = [
      network_device,
      # The image only matters on create; a re-downloaded image must not
      # replace the VM (and its data disk).
      disk[0].import_from,
    ]
  }
}

resource "terraform_data" "nfs_server_setup" {
  count = local.nfs_enabled ? 1 : 0

  triggers_replace = [
    proxmox_virtual_environment_vm.nfs_server[0].id,
    sha256(local.nfs_setup_script),
    # Re-run after growing the data disk, so xfs_growfs picks up the space.
    var.nfs_server.data_disk_gb,
  ]

  connection {
    type        = "ssh"
    host        = var.nfs_server.ip
    user        = "debian"
    private_key = tls_private_key.nfs_server[0].private_key_openssh
    timeout     = "10m"
  }

  provisioner "file" {
    content     = local.nfs_setup_script
    destination = "/tmp/nfs-server-setup.sh"
  }

  provisioner "remote-exec" {
    inline = ["sudo bash /tmp/nfs-server-setup.sh"]
  }
}
