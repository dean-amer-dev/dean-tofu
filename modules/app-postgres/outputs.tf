output "secret_name" {
  description = "Secret in the app namespace holding host, port, dbname, username, password, uri"
  value       = local.secret_name
}

output "db_name" {
  value = local.db_name
}
