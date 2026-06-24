resource "proxmox_virtual_environment_vm" "this" {
  vm_id     = var.vm_id
  name      = var.name
  node_name = var.proxmox_node

  # Use UEFI firmware — Talos requires UEFI (or BIOS, but UEFI is recommended)
  bios = "ovmf"

  # EFI disk is required when using UEFI firmware
  efi_disk {
    datastore_id = var.datastore_id
    file_format  = "raw"
    type         = "4m"
  }

  cpu {
    cores = var.cpu_cores
    # x86-64-v2-AES: modern CPU profile with AES-NI for faster TLS/etcd encryption
    type = "x86-64-v2-AES"
  }

  memory {
    dedicated = var.memory_mb
  }

  # Primary boot disk — Talos installs itself here on first boot
  disk {
    datastore_id = var.datastore_id
    size         = var.disk_gb
    interface    = "virtio0"
    file_format  = "raw"
    # discard: passes TRIM commands to the underlying storage for better SSD performance
    discard = "on"
  }

  # Talos ISO — mounted as a virtual CD-ROM for the initial boot
  # After Talos installs itself to the disk, you can remove this (or leave it — Talos won't boot from it again)
  cdrom {
    enabled   = true
    file_id   = var.talos_iso_file_id
    interface = "ide2"
  }

  network_device {
    bridge      = var.network_bridge
    model       = "virtio"
    mac_address = var.mac_address != "" ? var.mac_address : null
  }

  # QEMU guest agent allows Proxmox to see the VM's IP, do graceful shutdown, etc.
  # This only works if the 'siderolabs/qemu-guest-agent' extension is in your Talos image schematic
  agent {
    enabled = true
  }

  operating_system {
    type = "l26" # Linux kernel 2.6+ (the correct type for any modern Linux)
  }

  lifecycle {
    # Proxmox may change some fields (like MAC address) after VM creation.
    # Telling Terraform to ignore those prevents unnecessary re-creation.
    ignore_changes = [
      network_device,
      cdrom,
    ]
  }
}
