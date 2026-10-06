variable "app_name" {
  description = "Application name (kebab-case); used for the database, role and BWS secret names"
  type        = string

  validation {
    condition     = !startswith(replace(var.app_name, "-", "_"), "pg_")
    error_message = "app_name must not start with pg_/pg- (PostgreSQL reserves role names starting with pg_)."
  }
}

variable "app_namespace" {
  description = "Namespace the app runs in; receives the <app_name>-postgres credential Secret"
  type        = string
}

variable "db_name" {
  description = "Database name (defaults to app_name with dashes turned into underscores)"
  type        = string
  default     = null
}

variable "extensions" {
  description = "PostgreSQL extensions to enable in the database"
  type        = list(string)
  default     = []
}

variable "cluster_name" {
  type    = string
  default = "pg"
}

variable "cluster_namespace" {
  type    = string
  default = "postgres"
}

variable "bws_project_id" {
  description = "BWS project UUID the generated password is written to"
  type        = string
  default     = "6353f589-39c0-45f2-9e9c-b36f00e0c282"
}

variable "bws_key" {
  description = "BWS secret name for the generated password (defaults to <app_name>-postgres-password)"
  type        = string
  default     = null
}
