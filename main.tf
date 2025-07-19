############################################
# providers.tf
############################################
terraform {
  required_version = ">= 1.5.7"
  required_providers {
    google      = { source = "hashicorp/google", version = "~> 5.28" }
    google-beta = { source = "hashicorp/google-beta", version = "~> 5.28" }
    kubernetes  = { source = "hashicorp/kubernetes", version = "~> 2.30" }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
}

############################################
# variables.tf
############################################
variable "project_id" { type = string }
variable "region" {
  type    = string
  default = "us-central1"
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}

############################################
# GKE Autopilot cluster + “blue” service
############################################
resource "google_container_cluster" "autopilot" {
  name = "autopilot-demo"
  # create a zonal cluster, this simplifies NEG/Backend configuration
  location = var.zone
  # enable_autopilot = true
  # default mode is VPC_NATIVE with ip-aliasing
  # autopilot clusters are regional, not zonal.
  initial_node_count = 1
  node_config {
    tags = ["gke-node"]
  }
  deletion_protection = false
}

data "google_client_config" "me" {}

provider "kubernetes" {
  host  = "https://${google_container_cluster.autopilot.endpoint}"
  token = data.google_client_config.me.access_token
  cluster_ca_certificate = base64decode(
    google_container_cluster.autopilot.master_auth[0].cluster_ca_certificate
  )
}

# Simple Deployment
resource "kubernetes_deployment_v1" "blue" {
  metadata { name = "blue" }
  spec {
    selector { match_labels = { app = "blue" } }
    replicas = 1
    template {
      metadata { labels = { app = "blue" } }
      spec {
        container {
          name  = "blue"
          image = "gcr.io/google-samples/hello-app:1.0"
          port { container_port = 8080 }
        }
      }
    }
  }
}

# Service with NEG annotation (GKE creates the NEG for us)
resource "kubernetes_service_v1" "blue" {
  metadata {
    name = "blue-svc"
    annotations = {
      "cloud.google.com/neg" = "{\"exposed_ports\":{\"80\":{\"name\":\"blue-neg\"}}}"
    }
  }
  spec {
    selector = { app = "blue" }
    port {
      port        = 80
      target_port = 8080
      protocol    = "TCP"
    }
    type = "ClusterIP"
  }
}

# Fetch the auto-provisioned NEG after the Service exists
# data "google_compute_region_network_endpoint_group" "blue_neg" {
data "google_compute_network_endpoint_group" "blue_neg" {
  provider = google-beta
  name     = "blue-neg"
  zone     = var.zone

  depends_on = [kubernetes_service_v1.blue]
}

/*
data "google_compute_network_endpoint_group" "blue_neg" {
  for_each = toset(google_container_cluster.autopilot.node_locations)

  name = "${kubernetes_service_v1.blue.metadata[0].name}"
  zone = each.value
}
*/

############################################
# Cloud Run “red” service + serverless NEG
############################################
resource "google_cloud_run_service" "red" {
  name     = "red"
  location = var.region

  template {
    spec {
      containers {
        image = "gcr.io/cloudrun/hello"
        ports { container_port = 8080 }
      }
    }
  }

  traffic {
    percent         = 100
    latest_revision = true
  }
}

# Make the service public
resource "google_cloud_run_service_iam_member" "red_invoker" {
  service  = google_cloud_run_service.red.name
  location = var.region
  role     = "roles/run.invoker"
  member   = "allUsers"
}

# Serverless NEG for Cloud Run
resource "google_compute_region_network_endpoint_group" "red_neg" {
  provider              = google-beta
  name                  = "red-neg"
  region                = var.region
  network_endpoint_type = "SERVERLESS"

  cloud_run { service = google_cloud_run_service.red.name }
}

############################################
# Health check for the GKE (‘blue’) backend
############################################
resource "google_compute_health_check" "blue_hc" {
  name = "blue-hc"

  http_health_check {
    request_path       = "/"
    port_specification = "USE_SERVING_PORT"
  }

  log_config {
    enable = true
  }
}

############################################
# Backend services (HTTP)
############################################
resource "google_compute_backend_service" "blue_backend" {
  provider              = google-beta
  name                  = "blue-backend"
  protocol              = "HTTP"
  load_balancing_scheme = "EXTERNAL"

  backend {
    group                 = data.google_compute_network_endpoint_group.blue_neg.id
    balancing_mode        = "RATE" # or "CONNECTION"
    max_rate_per_endpoint = 100    # pick a sensible per-Pod RPS cap    
  }

  health_checks = [google_compute_health_check.blue_hc.id]
}

resource "google_compute_backend_service" "red_backend" {
  provider              = google-beta
  name                  = "red-backend"
  protocol              = "HTTP"
  load_balancing_scheme = "EXTERNAL"

  backend { group = google_compute_region_network_endpoint_group.red_neg.id }
}

############################################
# Global HTTP load balancer
############################################
resource "google_compute_global_address" "lb_ip" {
  name = "lb-ipv4"
}

resource "google_compute_url_map" "lb_map" {
  name            = "global-map"
  default_service = google_compute_backend_service.blue_backend.id

  host_rule {
    hosts        = ["*"]
    path_matcher = "paths"
  }

  path_matcher {
    name            = "paths"
    default_service = google_compute_backend_service.blue_backend.id

    path_rule {
      paths   = ["/blue", "/blue/*"]
      service = google_compute_backend_service.blue_backend.id
    }

    path_rule {
      paths   = ["/red", "/red/*"]
      service = google_compute_backend_service.red_backend.id
    }
  }
}

resource "google_compute_target_http_proxy" "lb_proxy" {
  name    = "http-proxy"
  url_map = google_compute_url_map.lb_map.id
}

resource "google_compute_global_forwarding_rule" "lb_forwarding_rule" {
  name                  = "http-forwarding-rule"
  ip_protocol           = "TCP"
  port_range            = "80"
  target                = google_compute_target_http_proxy.lb_proxy.id
  load_balancing_scheme = "EXTERNAL"
  ip_address            = google_compute_global_address.lb_ip.address
}

############################################
# outputs.tf
############################################
output "load_balancer_ip" {
  description = "Global HTTP LB IPv4 address"
  value       = google_compute_global_address.lb_ip.address
}

output "blue_endpoint" {
  value = "http://${google_compute_global_address.lb_ip.address}/blue"
}

output "red_endpoint" {
  value = "http://${google_compute_global_address.lb_ip.address}/red"
}

# ensure that the health check probes can reach to nodes
resource "google_compute_firewall" "allow_gcp_hc" {
  name      = "allow-gcp-healthcheck"
  network   = "default"
  direction = "INGRESS"
  priority  = 1000

  allow {
    protocol = "tcp"
    ports    = ["80", "8080"]
  }

  # Official health-check ranges
  source_ranges = [
    "35.191.0.0/16",
    "130.211.0.0/22"
  ]
  target_tags = ["gke-node"] # applies to Autopilot nodes
}