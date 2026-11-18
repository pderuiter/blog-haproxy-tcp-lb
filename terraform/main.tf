resource "proxmox_download_file" "ubuntu_noble" {
  content_type = "iso"
  datastore_id = var.image_datastore_id
  node_name    = var.node_name
  url          = var.image_url
  file_name    = "noble-server-cloudimg-amd64.img"
}

resource "proxmox_virtual_environment_vm" "this" {
  for_each = var.vms

  name      = each.key
  node_name = var.node_name
  tags      = sort(each.value.groups)

  cpu {
    cores = each.value.cores
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  disk {
    datastore_id = var.vm_datastore_id
    file_id      = proxmox_download_file.ubuntu_noble.id
    interface    = "virtio0"
    size         = each.value.disk_size
  }

  network_device {
    bridge = var.bridge
  }

  operating_system {
    type = "l26"
  }

  serial_device {}

  initialization {
    datastore_id = var.vm_datastore_id

    ip_config {
      ipv4 {
        address = each.value.ip
        gateway = var.gateway
      }
    }

    dns {
      servers = var.dns_servers
    }

    user_account {
      username = var.vm_user
      keys     = [trimspace(var.ssh_public_key)]
    }
  }
}
