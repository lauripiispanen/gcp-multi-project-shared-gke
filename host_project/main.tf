provider "google" {}
provider "random" {}

variable "org_domain" {
    type = string
}

variable "service_project_apis" {
    type = set(string)
    default = ["compute.googleapis.com"]
}

variable "dev_teams" {
    type = map(object({
        name = string,
        group_email = string
    }))
}

locals {
    apis_to_enable = {
        for p in setproduct(values(var.dev_teams), var.service_project_apis): "${p[0].name}/${p[1]}" => {
            team = p[0]
            service = p[1]
        }
    }
}

resource "random_id" "project_id_suffix" {
  byte_length = 2
}

variable "billing_account_id" {
    type = string
}

data "google_organization" "org" {
  domain = var.org_domain
}

resource "google_folder" "team" {
  for_each = var.dev_teams

  display_name = each.value.name
  parent       = data.google_organization.org.name
}

data "google_iam_policy" "editor" {
  for_each = var.dev_teams

  binding {
    role = "roles/editor"

    members = [
      "group:${each.value.group_email}"
    ]
  }
}

resource "google_folder_iam_policy" "folder_admin_policy" {
  for_each = var.dev_teams

  folder      = google_folder.team[each.value.name].name
  policy_data = data.google_iam_policy.editor[each.key].policy_data
}

resource "google_project" "host_project" {
  name       = "Shared VPC Host Project"
  project_id = "host-project-${random_id.project_id_suffix.dec}"
  billing_account = var.billing_account_id
  auto_create_network = false
}

resource "google_project" "team_project" {
  for_each = var.dev_teams

  name       = "${each.value.name} Project"
  project_id = "${replace(lower(each.value.name), " ", "-")}-project-${random_id.project_id_suffix.dec}"
  billing_account = var.billing_account_id
  folder_id  = google_folder.team[each.value.name].name
  auto_create_network = false
}

resource "google_compute_shared_vpc_host_project" "host" {
    project = google_project.host_project.project_id
}

resource "google_compute_shared_vpc_service_project" "service_team" {
    host_project = google_compute_shared_vpc_host_project.host.id
    for_each = google_project.team_project

    service_project = each.value.project_id
}

resource "google_project_service" "service" {
  for_each = local.apis_to_enable

  project = google_project.team_project[each.value.team.name].project_id
  service = each.value.service
}

resource "google_compute_network" "shared_network" {
  name = "shared-network"
  project = google_project.host_project.project_id
  auto_create_subnetworks = false
  delete_default_routes_on_create = true
}