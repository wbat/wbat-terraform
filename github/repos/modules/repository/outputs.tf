output "name" {
  description = "Repository name."
  value       = github_repository.this.name
}

output "node_id" {
  description = "GraphQL node ID of the repository."
  value       = github_repository.this.node_id
}
