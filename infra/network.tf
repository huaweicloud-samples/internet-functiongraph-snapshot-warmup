# ============================================================================
# Layer 1 — Network: VPC + Subnet + Security Group
# ============================================================================
# A single VPC/subnet holds APIG, FGS and GeminiDB. The security group allows
# GeminiDB traffic from the VPC CIDR (10.0.0.0/16) and ingress 80/443 from
# the internet (APIG public ingress).
# ============================================================================

data "huaweicloud_availability_zones" "current" {
  region = var.region
}

resource "huaweicloud_vpc" "main" {
  name                  = "${var.project_name}-vpc"
  cidr                  = "10.0.0.0/16"
  enterprise_project_id = null
}

resource "huaweicloud_vpc_subnet" "main" {
  name       = "${var.project_name}-subnet"
  vpc_id     = huaweicloud_vpc.main.id
  cidr       = "10.0.1.0/24"
  gateway_ip = "10.0.1.1"
  # AZ pinned to the first available AZ in the chosen region.
  availability_zone = try(data.huaweicloud_availability_zones.current.names[0], null)
}

# NOTE: FGS shares the main subnet (10.0.1.0/24) with GeminiDB — Huawei Cloud
# requires clients of a GeminiDB DynamoDB-compatible instance to sit in the
# same VPC AND same subnet (verified 2026-09-07: a separate FGS subnet did NOT
# fix VIP reachability; the real fix was using LB port 80, not node port 8000).

resource "huaweicloud_networking_secgroup" "main" {
  name        = "${var.project_name}-sg"
  description = "Security group for ${var.project_name} (FGS/APIG/GeminiDB)"
}

# Default egress rule (allow all out) is implied; add only the ingress we need.
resource "huaweicloud_networking_secgroup_rule" "allow_apig_https" {
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 443
  port_range_max    = 443
  remote_ip_prefix  = "0.0.0.0/0"
  security_group_id = huaweicloud_networking_secgroup.main.id
}

resource "huaweicloud_networking_secgroup_rule" "allow_geminidb_vpc" {
  description       = "GeminiDB DynamoDB-compatible data-node port from VPC"
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 8000
  port_range_max    = 8000
  remote_ip_prefix  = "10.0.0.0/16"
  security_group_id = huaweicloud_networking_secgroup.main.id
}

# The DynamoDB-compatible load balancer forwards client traffic on port 80 to the
# data nodes on port 8000. Allow ingress on 80 from the VPC so functions (and
# other VPC clients) can reach the LB VIP.
resource "huaweicloud_networking_secgroup_rule" "allow_geminidb_lb_http" {
  description       = "GeminiDB DynamoDB-compatible load-balancer port from VPC"
  direction         = "ingress"
  ethertype         = "IPv4"
  protocol          = "tcp"
  port_range_min    = 80
  port_range_max    = 80
  remote_ip_prefix  = "10.0.0.0/16"
  security_group_id = huaweicloud_networking_secgroup.main.id
}