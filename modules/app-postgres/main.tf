terraform {
  required_providers {
    kubectl = {
      source  = "alekc/kubectl"
      version = "~> 2.1"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
    bitwarden-secrets = {
      source  = "bitwarden/bitwarden-secrets"
      version = "~> 1.0"
    }
  }
}

locals {
  db_name     = coalesce(var.db_name, replace(var.app_name, "-", "_"))
  role_name   = local.db_name
  bws_key     = coalesce(var.bws_key, "${var.app_name}-postgres-password")
  secret_name = "${var.app_name}-postgres"
  host        = "${var.cluster_name}-rw.${var.cluster_namespace}.svc"

  external_secret_source = {
    secretStoreRef = {
      name = "bitwarden-secretsmanager"
      kind = "ClusterSecretStore"
    }
    data = [{
      secretKey = "password"
      remoteRef = {
        key                = local.bws_key
        conversionStrategy = "Default"
        decodingStrategy   = "None"
        metadataPolicy     = "None"
      }
    }]
  }
}

resource "random_password" "db" {
  length  = 40
  special = false
}

resource "bitwarden-secrets_secret" "db_password" {
  key        = local.bws_key
  value      = random_password.db.result
  project_id = var.bws_project_id
}

# DB namespace: basic-auth Secret the DatabaseRole's passwordSecret points at.
resource "kubectl_manifest" "role_secret" {
  depends_on = [bitwarden-secrets_secret.db_password]
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata   = { name = "${local.secret_name}-role", namespace = var.cluster_namespace }
    spec = merge(local.external_secret_source, {
      refreshInterval = "1h0m0s"
      target = {
        name           = "${local.secret_name}-role"
        creationPolicy = "Owner"
        deletionPolicy = "Retain"
        template = {
          type          = "kubernetes.io/basic-auth"
          engineVersion = "v2"
          mergePolicy   = "Replace"
          metadata      = {}
          data = {
            username = local.role_name
            password = "{{ .password }}"
          }
        }
      }
    })
  })
}

resource "kubectl_manifest" "role" {
  depends_on = [kubectl_manifest.role_secret]
  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "DatabaseRole"
    metadata   = { name = "${var.app_name}", namespace = var.cluster_namespace }
    spec = {
      cluster                   = { name = var.cluster_name }
      name                      = local.role_name
      ensure                    = "present"
      login                     = true
      databaseRoleReclaimPolicy = "retain"
      passwordSecret            = { name = "${local.secret_name}-role" }
    }
  })
}

resource "kubectl_manifest" "database" {
  depends_on = [kubectl_manifest.role]
  yaml_body = yamlencode({
    apiVersion = "postgresql.cnpg.io/v1"
    kind       = "Database"
    metadata   = { name = var.app_name, namespace = var.cluster_namespace }
    spec = {
      cluster               = { name = var.cluster_name }
      name                  = local.db_name
      owner                 = local.role_name
      ensure                = "present"
      databaseReclaimPolicy = "retain"
      extensions            = [for e in var.extensions : { name = e, ensure = "present" }]
    }
  })
}

# App namespace: the credential the app consumes. Built by ESO from the same BWS secret, so no
# operator-generated Secret is copied across namespaces.
resource "kubectl_manifest" "app_secret" {
  depends_on = [bitwarden-secrets_secret.db_password]
  yaml_body = yamlencode({
    apiVersion = "external-secrets.io/v1"
    kind       = "ExternalSecret"
    metadata   = { name = local.secret_name, namespace = var.app_namespace }
    spec = merge(local.external_secret_source, {
      refreshInterval = "1h0m0s"
      target = {
        name           = local.secret_name
        creationPolicy = "Owner"
        deletionPolicy = "Retain"
        template = {
          engineVersion = "v2"
          mergePolicy   = "Replace"
          metadata      = {}
          data = {
            host     = local.host
            port     = "5432"
            dbname   = local.db_name
            username = local.role_name
            password = "{{ .password }}"
            uri      = "postgresql://${local.role_name}:{{ .password }}@${local.host}:5432/${local.db_name}"
          }
        }
      }
    })
  })
}
