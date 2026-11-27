# ============================================================================
# Outputs
# ============================================================================

output "fgs_function_urn" {
  description = "URN of the broker FGS function"
  value       = huaweicloud_fgs_function.broker.urn
}

output "obs_function_code_url" {
  description = "OBS object URL of the FGS function jar"
  value       = "https://${huaweicloud_obs_bucket.function_code.bucket_domain_name}/${var.function_code_object_key}"
}

output "geminidb_lb_endpoint" {
  description = "GeminiDB DynamoDB-compatible load-balancer endpoint (host:port)"
  # The LB VIP forwards DynamoDB-compatible traffic on port 80; individual data
  # nodes use port 8000. Clients must use the LB VIP on port 80.
  value       = "${huaweicloud_geminidb_instance.main.lb_ip_address}:80"
  sensitive   = true
}

output "iam_agency_name" {
  description = "IAM agency used by the FGS function"
  value       = huaweicloud_identity_agency.functiongraph.name
}

output "vpc_id" {
  description = "VPC hosting APIG/FGS/GeminiDB"
  value       = huaweicloud_vpc.main.id
}

output "geminidb_available_flavors" {
  description = "GeminiDB Cassandra-family spec_codes available in the current region (for picking geminidb_flavor)"
  value       = data.huaweicloud_geminidb_flavors.available.flavors
}