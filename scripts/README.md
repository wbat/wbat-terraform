# Migration scripts

Optional operational tooling for **EC2 root-volume shrink** via rsync and Elastic IP cutover. These scripts are **not** part of the normal Terraform workflow; most contributors only need the [`aws/`](../aws/) workspace.

## Files

| File | Purpose |
|------|---------|
| [`shrink_migration.py`](shrink_migration.py) | CLI orchestrator (status, rsync, cutover, AWS EIP steps) |
| [`shrink-migration.config.example.yaml`](shrink-migration.config.example.yaml) | Config schema with placeholder values — copy to local config |
| [`shrink-migration-validate.sh`](shrink-migration-validate.sh) | Validation gates (rsync-diff, pre/post-cutover, services) |
| [`shrink-rsync-live.sh`](shrink-rsync-live.sh) | Standalone incremental rsync helper |
| [`shrink-cleanup-old.sh`](shrink-cleanup-old.sh) | Post-bake cleanup of retired source instance and volume |
| [`directadmin/`](directadmin/) | DA ops: SES Gmail pipe (`ses_gmail_forward.md`) + post-backup S3 hooks |

## Setup

1. Install PyYAML on the source host:

   ```bash
   dnf install -y python3-pyyaml   # RHEL/Alma/Rocky
   # or: pip install pyyaml
   ```

2. Create a local config (gitignored):

   ```bash
   cp shrink-migration.config.example.yaml shrink-migration.config.yaml
   # Edit with your instance IDs, IPs, EIP allocation IDs, and S3 bucket
   ```

3. Install scripts on the source server (example paths):

   ```bash
   install -m 755 shrink_migration.py shrink-migration-validate.sh shrink-rsync-live.sh /usr/local/sbin/
   install -m 644 shrink-migration.config.yaml /usr/local/sbin/
   ```

   Alternatively, deploy from a private S3 prefix (`s3://<your-bucket>/migration/`) using `shrink_migration.py deploy` after configuring `s3.bucket` and `s3.prefix` in your local YAML.

## Commands

Run from the source host (as root) unless noted:

```bash
CONFIG=/usr/local/sbin/shrink-migration.config.yaml

# Pre-cutover
python3 shrink_migration.py --config "$CONFIG" status
python3 shrink_migration.py --config "$CONFIG" rsync live
python3 shrink_migration.py --config "$CONFIG" validate rsync-diff

# Cutover (downtime window)
python3 shrink_migration.py --config "$CONFIG" cutover preflight
python3 shrink_migration.py --config "$CONFIG" cutover final --yes
python3 shrink_migration.py --config "$CONFIG" cutover boot-prep
# Reboot target instance, verify SSH, then from a host with AWS CLI profile:
python3 shrink_migration.py --config "$CONFIG" aws eip-flip --yes
python3 shrink_migration.py --config "$CONFIG" cutover post-start

# Rollback
python3 shrink_migration.py --config "$CONFIG" aws rollback --yes

# After bake period
/usr/local/sbin/shrink-cleanup-old.sh --dry-run
/usr/local/sbin/shrink-cleanup-old.sh --yes
```

See `python3 shrink_migration.py --help` for the full command list.

## Security

- **`shrink-migration.config.yaml` is gitignored** — it contains environment-specific IDs, IPs, and bucket names.
- Only [`shrink-migration.config.example.yaml`](shrink-migration.config.example.yaml) is committed (placeholder values).
- Keep production config in private S3 or on the server under `/usr/local/sbin/`; never commit filled-in YAML to this public repository.
