# One-time imports for pre-existing GitHub repositories.
# Currently none pending — add blocks back when importing, then remove them
# after a successful wbat-terraform-github apply (per repository convention).
#
# Import blocks must live in the root module (not repos/) and must not set
# provider — the target resource's provider mapping is used automatically.
# github_repository import id is the repository name; github_branch_default
# import id is also the repository name (not repo:branch).
