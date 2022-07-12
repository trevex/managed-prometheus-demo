provider "google" {
  project = var.project
  region  = var.region
}

provider "google-beta" {
  project = var.project
  region  = var.region
}


# First we need the network for our VPC-native cluster

resource "google_compute_network" "cluster" {
  name                    = "cluster"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "cluster" {
  name    = "cluster-${var.region}"
  network = google_compute_network.cluster.id
  region  = var.region

  private_ip_google_access = true
  ip_cidr_range            = "10.0.0.0/20"
  purpose                  = "PRIVATE"
  secondary_ip_range = [{
    range_name    = "pods"
    ip_cidr_range = "10.0.32.0/19"
    }, {
    range_name    = "services"
    ip_cidr_range = "10.0.16.0/20"
  }]
}

resource "google_compute_router" "cluster" {
  name    = "cluster-${var.region}"
  network = google_compute_network.cluster.id
  region  = var.region
}

resource "google_compute_router_nat" "cluster" {
  name   = "cluster-${var.region}"
  router = google_compute_router.cluster.name
  region = var.region

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

# Let's create our VPC-native cluster (without nodepool)

data "http" "myip" {
  url = "https://ipinfo.io/ip"
}

resource "google_container_cluster" "cluster" {
  provider = google-beta

  name     = "cluster"
  project  = var.project
  location = var.region

  remove_default_node_pool  = true
  initial_node_count        = 1
  default_max_pods_per_node = 110

  network         = google_compute_network.cluster.id
  subnetwork      = google_compute_subnetwork.cluster.id
  networking_mode = "VPC_NATIVE"

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods"
    services_secondary_range_name = "services"
  }

  release_channel {
    channel = "RAPID"
  }

  private_cluster_config {
    enable_private_nodes    = true
    enable_private_endpoint = false
    master_ipv4_cidr_block  = "172.16.0.0/28"
    master_global_access_config {
      enabled = true
    }
  }

  master_authorized_networks_config {
    cidr_blocks {
      # We limit master access to our own IP only
      cidr_block   = "${chomp(data.http.myip.body)}/32"
      display_name = "My IP"
    }
  }

  pod_security_policy_config {
    enabled = false # intentionally for simplicity set to false (this is a demo)
  }

  workload_identity_config {
    workload_pool = "${var.project}.svc.id.goog"
  }

  lifecycle {
    ignore_changes = [
      node_pool,
      initial_node_count,
    ]
    prevent_destroy = false
  }

  timeouts {
    create = "45m"
    update = "45m"
    delete = "45m"
  }
}

# Let's create a container registry

resource "google_container_registry" "registry" {
  project  = var.project
  location = "EU"
}

# We need to properly setup the service account for our nodes to write logs, metrics etc.

resource "google_service_account" "node" {
  project      = var.project
  account_id   = "cluster-node"
  display_name = "SA used by GKE cluster nodes"
}

resource "google_project_iam_member" "node_log_writer" {
  project = var.project
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.node.email}"
}

resource "google_project_iam_member" "node_metric_writer" {
  project = var.project
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.node.email}"
}

resource "google_project_iam_member" "node_monitoring_viewer" {
  project = var.project
  role    = "roles/monitoring.viewer"
  member  = "serviceAccount:${google_service_account.node.email}"
}

resource "google_project_iam_member" "node_metadata_writer" {
  project = var.project
  role    = "roles/stackdriver.resourceMetadata.writer"
  member  = "serviceAccount:${google_service_account.node.email}"
}

resource "google_storage_bucket_iam_member" "node_pull_gcr" {
  bucket = google_container_registry.registry.id
  role   = "roles/storage.objectViewer"
  member = "serviceAccount:${google_service_account.node.email}"
}

# Finally we create our private nodes

locals {
  node_network_tag = "cluster"
}

resource "google_container_node_pool" "default" {
  provider = google-beta

  name     = "default"
  project  = var.project
  location = var.region
  cluster  = google_container_cluster.cluster.name

  initial_node_count = 1

  autoscaling {
    min_node_count = 1
    max_node_count = 5
  }

  management {
    auto_repair  = true
    auto_upgrade = true
  }

  upgrade_settings {
    max_surge       = 1
    max_unavailable = 1
  }

  node_config {
    image_type   = "COS_CONTAINERD"
    machine_type = "n1-standard-2"
    preemptible  = false
    tags         = [local.node_network_tag]

    metadata = {
      "disable-legacy-endpoints" = true
    }

    local_ssd_count = 0
    disk_size_gb    = 80
    disk_type       = "pd-standard"

    service_account = google_service_account.node.email

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    shielded_instance_config {
      enable_secure_boot          = true
      enable_integrity_monitoring = true
    }

    oauth_scopes = [
      "https://www.googleapis.com/auth/cloud-platform",
      "https://www.googleapis.com/auth/monitoring"
    ]
  }

  lifecycle {
    ignore_changes  = [initial_node_count]
    prevent_destroy = false
  }

  timeouts {
    create = "45m"
    update = "45m"
    delete = "45m"
  }
}

# For the GMP admission controller we need to allow ingress on 8443

resource "google_compute_firewall" "admission" {
  project     = var.project
  name        = "allow-gke-cp-access-admission-controller"
  network     = google_compute_network.cluster.id
  description = "Allow ingress on 8443 from GKE Control-Plane"

  allow {
    protocol = "tcp"
    # ports    = ["8443"]
  }

  source_ranges = [google_container_cluster.cluster.private_cluster_config[0].master_ipv4_cidr_block]
  target_tags   = [local.node_network_tag]
}
