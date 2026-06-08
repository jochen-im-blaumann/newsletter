terraform {
  required_version = ">= 1.5.0"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.46"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0.0"
    }
    local = {
      source  = "hashicorp/local"
      version = ">= 2.0.0"
    }
  }
}

provider "digitalocean" {
  token = var.do_token
}

resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "local_file" "private_key" {
  content         = tls_private_key.ssh.private_key_pem
  filename        = "${path.module}/id_rsa_dr_drill"
  file_permission = "0600"
}

resource "local_file" "public_key" {
  content  = tls_private_key.ssh.public_key_openssh
  filename = "${path.module}/id_rsa_dr_drill.pub"
}

resource "digitalocean_ssh_key" "dr_drill" {
  name       = "dr-drill-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

resource "digitalocean_droplet" "control_plane" {
  name     = "dr-drill-cp"
  image    = "ubuntu-24-04-x64"
  region   = var.region
  size     = var.droplet_size
  ssh_keys = [digitalocean_ssh_key.dr_drill.fingerprint]

  user_data = file("${path.module}/cloud-init.sh")

  tags = ["dr-drill", "control-plane"]
}

resource "digitalocean_droplet" "worker" {
  name     = "dr-drill-worker"
  image    = "ubuntu-24-04-x64"
  region   = var.region
  size     = var.droplet_size
  ssh_keys = [digitalocean_ssh_key.dr_drill.fingerprint]

  user_data = file("${path.module}/cloud-init.sh")

  tags = ["dr-drill", "worker"]
}
