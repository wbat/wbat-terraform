#!/usr/bin/env python3
"""
WBAT primary EBS shrink migration orchestrator (600 GB -> 200 GB, Option 1).

Run on OLD production server as root for rsync/SSH/validation steps.
Run from laptop (with --profile) for AWS EIP/tag/SSM recovery steps.

Examples:
  python3 shrink_migration.py status
  python3 shrink_migration.py validate rsync-diff
  python3 shrink_migration.py rsync live
  python3 shrink_migration.py cutover preflight
  python3 shrink_migration.py cutover final --yes
  python3 shrink_migration.py aws fix-new-ssh
  python3 shrink_migration.py aws eip-flip --yes
  python3 shrink_migration.py aws rollback --yes
"""

from __future__ import annotations

import argparse
import json
import os
import shlex
import subprocess
import sys
import textwrap
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Iterable, Sequence

try:
    import yaml
except ImportError:
    yaml = None  # type: ignore


SCRIPT_DIR = Path(__file__).resolve().parent
DEFAULT_CONFIG = SCRIPT_DIR / "shrink-migration.config.yaml"


class MigrationError(Exception):
    pass


@dataclass
class Config:
    aws_profile: str = "wbat"
    aws_region: str = "us-east-1"
    old_instance_id: str = ""
    old_private_ip: str = ""
    new_instance_id: str = ""
    new_private_ip: str = ""
    eip_allocation_id: str = ""
    eip_association_id: str = ""
    eip_public_ip: str = ""
    ssh_user: str = "ec2-user"
    ssh_options: list[str] = field(default_factory=list)
    rsync_flags: list[str] = field(default_factory=list)
    rsync_excludes: list[str] = field(default_factory=list)
    validate_script: str = "/usr/local/sbin/shrink-migration-validate.sh"
    rsync_log_live: str = "/var/log/shrink-rsync-live.log"
    rsync_log_final: str = "/var/log/shrink-rsync-final.log"
    migration_pubkey: str = ""
    s3_bucket: str = ""
    s3_prefix: str = "migration"
    expected_hostname: str = "server.wbat.net"
    old_name_tag: str = "WBAT Primary Server"
    new_name_tag_temp: str = "WBAT-Primary-200-temp"
    new_name_tag_final: str = "WBAT Primary Server"
    old_name_retired: str = "WBAT Primary Server OLD-retired"

    @classmethod
    def load(cls, path: Path) -> Config:
        if not path.exists():
            raise MigrationError(f"Config not found: {path}")
        raw = path.read_text()
        if yaml is not None:
            data = yaml.safe_load(raw)
        else:
            # Minimal fallback if PyYAML missing — expect JSON-compatible YAML subset
            raise MigrationError("PyYAML required: dnf install python3-pyyaml")
        return cls.from_dict(data)

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> Config:
        ssh = data.get("ssh", {})
        rsync = data.get("rsync", {})
        paths = data.get("paths", {})
        return cls(
            aws_profile=data.get("aws_profile", "wbat"),
            aws_region=data.get("aws_region", "us-east-1"),
            old_instance_id=data["old"]["instance_id"],
            old_private_ip=data["old"]["private_ip"],
            new_instance_id=data["new"]["instance_id"],
            new_private_ip=data["new"]["private_ip"],
            eip_allocation_id=data["eip"]["allocation_id"],
            eip_association_id=data["eip"]["association_id"],
            eip_public_ip=data["eip"]["public_ip"],
            ssh_user=ssh.get("user", "ec2-user"),
            ssh_options=list(ssh.get("options", [])),
            rsync_flags=list(rsync.get("flags", [])),
            rsync_excludes=list(rsync.get("excludes", [])),
            validate_script=paths.get("validate_script", "/usr/local/sbin/shrink-migration-validate.sh"),
            rsync_log_live=paths.get("rsync_log_live", "/var/log/shrink-rsync-live.log"),
            rsync_log_final=paths.get("rsync_log_final", "/var/log/shrink-rsync-final.log"),
            migration_pubkey=data.get("migration_pubkey", ""),
            s3_bucket=data.get("s3", {}).get("bucket", ""),
            s3_prefix=data.get("s3", {}).get("prefix", "migration"),
            expected_hostname=data.get("expected", {}).get("hostname", "server.wbat.net"),
            old_name_tag=data["old"].get("name_tag", "WBAT Primary Server"),
            new_name_tag_temp=data["new"].get("name_tag_temp", "WBAT-Primary-200-temp"),
            new_name_tag_final=data["new"].get("name_tag_final", "WBAT Primary Server"),
        )


def log(msg: str) -> None:
    print(msg, flush=True)


def run(
    cmd: Sequence[str],
    *,
    check: bool = True,
    capture: bool = False,
    input_text: str | None = None,
) -> subprocess.CompletedProcess[str]:
    display = " ".join(shlex.quote(c) for c in cmd)
    log(f"$ {display}")
    return subprocess.run(
        list(cmd),
        check=check,
        text=True,
        capture_output=capture,
        input=input_text,
    )


def aws_base(cfg: Config) -> list[str]:
    return ["aws", "--profile", cfg.aws_profile, "--region", cfg.aws_region]


def ssh_target(cfg: Config, ip: str | None = None) -> str:
    return f"{cfg.ssh_user}@{ip or cfg.new_private_ip}"


def ssh_cmd(cfg: Config, remote_cmd: str, *, ip: str | None = None) -> list[str]:
    opts = [f"-o {o}" for o in cfg.ssh_options]
    return ["ssh", *opts, ssh_target(cfg, ip), remote_cmd]


def rsync_cmd(cfg: Config, *, delete: bool = False, log_path: str | None = None) -> list[str]:
    opts = [f"-o {o}" for o in cfg.ssh_options]
    cmd = [
        "rsync",
        *cfg.rsync_flags,
        *([] if not delete else ["--delete"]),
        *sum([["--exclude", e] for e in cfg.rsync_excludes], []),
        "-e",
        " ".join(["ssh", *opts]),
        "/",
        f"{ssh_target(cfg)}:/",
    ]
    return cmd


def require_root() -> None:
    if os.geteuid() != 0:
        raise MigrationError("This command must run as root on OLD server")


def confirm(prompt: str, yes: bool) -> None:
    if yes:
        log(f"CONFIRMED: {prompt}")
        return
    try:
        answer = input(f"{prompt} [y/N]: ").strip().lower()
    except EOFError:
        answer = "n"
    if answer not in ("y", "yes"):
        raise MigrationError("Aborted by user")


def ssm_run(cfg: Config, instance_id: str, commands: list[str], timeout: int = 120) -> str:
    params = json.dumps({"commands": commands})
    out = run(
        [
            *aws_base(cfg),
            "ssm",
            "send-command",
            "--instance-ids",
            instance_id,
            "--document-name",
            "AWS-RunShellScript",
            "--timeout-seconds",
            str(timeout),
            "--parameters",
            params,
            "--query",
            "Command.CommandId",
            "--output",
            "text",
        ],
        capture=True,
    )
    cmd_id = out.stdout.strip()
    log(f"SSM command id: {cmd_id}")
    for _ in range(30):
        time.sleep(2)
        inv = run(
            [
                *aws_base(cfg),
                "ssm",
                "get-command-invocation",
                "--command-id",
                cmd_id,
                "--instance-id",
                instance_id,
                "--output",
                "json",
            ],
            capture=True,
            check=False,
        )
        data = json.loads(inv.stdout or "{}")
        status = data.get("Status", "")
        if status in ("Success", "Failed", "Cancelled", "TimedOut"):
            stdout = data.get("StandardOutputContent", "")
            stderr = data.get("StandardErrorContent", "")
            log(stdout)
            if stderr:
                log(stderr)
            if status != "Success":
                raise MigrationError(f"SSM command {status}")
            return cmd_id
    raise MigrationError("SSM command timed out waiting for completion")


def cmd_status(cfg: Config) -> None:
    log("=== OLD disk ===")
    run(["df", "-h", "/"])
    run(["du", "-xsh", "/home", "/usr/local/directadmin", "/var/lib/mysql"], check=False)

    log("\n=== SSH to NEW ===")
    try:
        run(ssh_cmd(cfg, "echo SSH_OK && df -h / && test -x /usr/local/directadmin/directadmin && echo DA_OK"))
    except subprocess.CalledProcessError as exc:
        log(f"SSH FAILED (run: aws fix-new-ssh): exit {exc.returncode}")

    log("\n=== rsync-diff gate ===")
    run([cfg.validate_script, "rsync-diff", cfg.new_private_ip], check=False)


def cmd_validate(cfg: Config, mode: str) -> None:
    args = [cfg.validate_script, mode]
    if mode in ("rsync-diff", "compare-counts", "pre-cutover", "xattrs"):
        args.append(cfg.new_private_ip)
    run(args)


def cmd_rsync(cfg: Config, phase: str, yes: bool) -> None:
    require_root()
    delete = phase == "final"
    log_path = cfg.rsync_log_final if delete else cfg.rsync_log_live
    if delete:
        confirm("Final rsync STOPS production on OLD first. Continue?", yes)
        run([cfg.validate_script, "stop-services"])
        run([cfg.validate_script, "verify-stopped"])

    cmd = rsync_cmd(cfg, delete=delete)
    log(f"=== rsync {phase} -> {log_path} ===")
    with open(log_path, "a", encoding="utf-8") as fh:
        fh.write(f"\n=== shrink_migration.py {phase} start ===\n")
        fh.flush()
        proc = subprocess.run(cmd, stdout=fh, stderr=subprocess.STDOUT)
    if proc.returncode not in (0, 23):
        raise MigrationError(f"rsync failed with exit {proc.returncode}")
    log(f"rsync exit={proc.returncode}")

    if delete:
        run([cfg.validate_script, "pre-cutover", cfg.new_private_ip])


def cmd_cutover_preflight(cfg: Config) -> None:
    run([cfg.validate_script, "rsync-diff", cfg.new_private_ip])
    run(ssh_cmd(cfg, "sudo du -xsh / /home /usr/local/directadmin /var/lib/mysql"), check=False)
    log("Preflight OK — safe to run: cutover final")


def cmd_cutover_boot_prep(cfg: Config) -> None:
    run(ssh_cmd(cfg, f"sudo {cfg.validate_script} post-rsync-new"))
    run(
        ssh_cmd(
            cfg,
            "sudo grub2-install /dev/nvme0n1 && sudo dracut -f --regenerate-all && echo BOOT_PREP_OK",
        )
    )
    log("Reboot NEW manually, verify SSH, then: aws eip-flip")


def cmd_aws_fix_new_ssh(cfg: Config, yes: bool) -> None:
    confirm(f"Reboot NEW {cfg.new_instance_id} and restore SSH keys via SSM?", yes)
    run([*aws_base(cfg), "ec2", "reboot-instances", "--instance-ids", cfg.new_instance_id])
    log("Waiting 90s for reboot...")
    time.sleep(90)
    pubkey = cfg.migration_pubkey
    wbat_rsa = (
        "ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQDAbfdIFRhw+NFOytsJgWNRuCwpDSIrYm1g0UOpMQ1N8/"
        "yNiYKnREARbah2p8RMqnf0Hu054DEwfdtR836STs2txbFnZmfZgiVfAfjZQSqCuxMNmccJD3kQSOVHXU5L/"
        "2t+XIw8IDDzB+4EuWoOuO1BlYTu+GdTPgVDcHyhlqE2BfD329DoJ2CTui1EE14OupmPDztW8Rl1Hwz7ud4TJ0"
        "hhWZb07fFP35yvjDdKaknwcPzsa/IH2V4eZ7gDDQUl+TppTB9Ohx8tfMWwjFBNR86C2UqJxUCz3VAA/YRoPY7BCxsJ1"
        "Iu+GhNmM9pPlmIkFXbI+DRS6sgrJ9W3ouRkTpzL WBAT"
    )
    commands = [
        "setenforce 0 2>/dev/null || true",
        "mkdir -p /home/ec2-user/.ssh && chmod 700 /home/ec2-user/.ssh",
        f'printf "%s\\n%s\\n" "{wbat_rsa}" "{pubkey}" > /home/ec2-user/.ssh/authorized_keys',
        "chmod 600 /home/ec2-user/.ssh/authorized_keys",
        "chown -R ec2-user:ec2-user /home/ec2-user/.ssh",
        'printf "ec2-user ALL=(ALL) NOPASSWD: /usr/bin/rsync\\nec2-user ALL=(ALL) NOPASSWD: /usr/bin/find\\nec2-user ALL=(ALL) NOPASSWD: /usr/bin/getfattr\\n" > /etc/sudoers.d/shrink-migrate',
        "chmod 440 /etc/sudoers.d/shrink-migrate",
        "visudo -cf /etc/sudoers.d/shrink-migrate",
        "systemctl restart sshd",
        "echo SSH_FIXED",
    ]
    ssm_run(cfg, cfg.new_instance_id, commands)
    log("On OLD run: ssh-keygen -R {ip}; ssh-keyscan -H {ip} >> /root/.ssh/known_hosts".format(ip=cfg.new_private_ip))
    log(f"Then test: ssh -o StrictHostKeyChecking=no {ssh_target(cfg)} 'echo OK'")


def cmd_aws_eip_flip(cfg: Config, yes: bool) -> None:
    confirm(
        f"Disassociate EIP {cfg.eip_public_ip} from OLD and attach to NEW {cfg.new_instance_id}?",
        yes,
    )
    run([*aws_base(cfg), "ec2", "disassociate-address", "--association-id", cfg.eip_association_id])
    run(
        [
            *aws_base(cfg),
            "ec2",
            "create-tags",
            "--resources",
            cfg.old_instance_id,
            "--tags",
            f"Key=Name,Value={cfg.old_name_retired}",
        ]
    )
    run(
        [
            *aws_base(cfg),
            "ec2",
            "create-tags",
            "--resources",
            cfg.new_instance_id,
            "--tags",
            f"Key=Name,Value={cfg.new_name_tag_final}",
        ]
    )
    run(
        [
            *aws_base(cfg),
            "ec2",
            "associate-address",
            "--allocation-id",
            cfg.eip_allocation_id,
            "--instance-id",
            cfg.new_instance_id,
        ]
    )
    log(f"EIP {cfg.eip_public_ip} now on NEW. Run: cutover post-start")


def cmd_aws_rollback(cfg: Config, yes: bool) -> None:
    confirm(f"Rollback EIP to OLD {cfg.old_instance_id}?", yes)
    run(
        [
            *aws_base(cfg),
            "ec2",
            "associate-address",
            "--allocation-id",
            cfg.eip_allocation_id,
            "--instance-id",
            cfg.old_instance_id,
        ]
    )
    run(
        [
            *aws_base(cfg),
            "ec2",
            "create-tags",
            "--resources",
            cfg.old_instance_id,
            "--tags",
            f"Key=Name,Value={cfg.old_name_tag}",
        ]
    )
    log("Start services on OLD manually")


def cmd_post_start(cfg: Config) -> None:
    ip = cfg.eip_public_ip
    run(ssh_cmd(cfg, f"sudo {cfg.validate_script} start-services", ip=ip))
    run(ssh_cmd(cfg, f"sudo {cfg.validate_script} post-cutover", ip=ip))
    run(ssh_cmd(cfg, "sudo setenforce 1; sudo restorecon -Rv /home /var/www /usr/local/directadmin", ip=ip), check=False)


def cmd_deploy_scripts(cfg: Config) -> None:
    require_root()
    if not cfg.s3_bucket:
        raise MigrationError("s3.bucket not configured")
    for name in ("shrink-migration-validate.sh", "shrink-rsync-live.sh", "shrink_migration.py", "shrink-migration.config.yaml"):
        src = f"s3://{cfg.s3_bucket}/{cfg.s3_prefix}/{name}"
        dst = f"/usr/local/sbin/{name}" if name.endswith(".sh") else f"/usr/local/sbin/{name}"
        if name.endswith(".yaml"):
            dst = str(SCRIPT_DIR / name)
        run([*aws_base(cfg), "s3", "cp", src, dst], check=False)
    log("Deploy complete (upload scripts to S3 first from repo)")


def cmd_cutover_final(cfg: Config, yes: bool) -> None:
    """Full frozen cutover on OLD: stop -> final rsync -> pre-cutover gate."""
    cmd_rsync(cfg, "final", yes)


def build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description="WBAT primary EBS shrink migration orchestrator",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=textwrap.dedent(
            """
            AM cutover (typical):
              python3 shrink_migration.py cutover preflight
              python3 shrink_migration.py cutover final --yes
              python3 shrink_migration.py cutover boot-prep
              # reboot NEW, verify SSH
              python3 shrink_migration.py aws eip-flip --yes   # from laptop
              python3 shrink_migration.py cutover post-start   # after EIP
            """
        ),
    )
    p.add_argument("--config", type=Path, default=DEFAULT_CONFIG, help="Path to YAML config")
    p.add_argument("--yes", action="store_true", help="Skip interactive confirmation")
    sub = p.add_subparsers(dest="command", required=True)

    sub.add_parser("status", help="Disk, SSH, rsync-diff summary")

    v = sub.add_parser("validate", help="Run shrink-migration-validate.sh mode")
    v.add_argument(
        "mode",
        choices=[
            "stop-services",
            "verify-stopped",
            "rsync-diff",
            "compare-counts",
            "pre-cutover",
            "post-rsync-new",
            "post-cutover",
            "start-services",
        ],
    )

    r = sub.add_parser("rsync", help="Run rsync to NEW")
    r.add_argument("phase", choices=["live", "final"], help="live=incremental; final=--delete after stop")

    c = sub.add_parser("cutover", help="Cutover sub-steps")
    csub = c.add_subparsers(dest="cutover_step", required=True)
    csub.add_parser("preflight", help="rsync-diff + remote du")
    csub.add_parser("final", help="stop services + final rsync + pre-cutover gate")
    csub.add_parser("boot-prep", help="post-rsync-new + grub/dracut on NEW")
    csub.add_parser("post-start", help="start-services + post-cutover after EIP")

    aws = sub.add_parser("aws", help="AWS API steps (laptop or OLD with profile)")
    asub = aws.add_subparsers(dest="aws_step", required=True)
    asub.add_parser("fix-new-ssh", help="Reboot NEW + SSM restore SSH/sudoers")
    asub.add_parser("eip-flip", help="Disassociate EIP from OLD, associate to NEW, DLM tags")
    asub.add_parser("rollback", help="Reassociate EIP to OLD")

    sub.add_parser("deploy", help="Pull scripts from S3 to /usr/local/sbin")

    return p


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    cfg = Config.load(args.config)

    try:
        if args.command == "status":
            cmd_status(cfg)
        elif args.command == "validate":
            cmd_validate(cfg, args.mode)
        elif args.command == "rsync":
            cmd_rsync(cfg, args.phase, args.yes)
        elif args.command == "cutover":
            if args.cutover_step == "preflight":
                cmd_cutover_preflight(cfg)
            elif args.cutover_step == "final":
                cmd_cutover_final(cfg, args.yes)
            elif args.cutover_step == "boot-prep":
                cmd_cutover_boot_prep(cfg)
            elif args.cutover_step == "post-start":
                cmd_post_start(cfg)
        elif args.command == "aws":
            if args.aws_step == "fix-new-ssh":
                cmd_aws_fix_new_ssh(cfg, args.yes)
            elif args.aws_step == "eip-flip":
                cmd_aws_eip_flip(cfg, args.yes)
            elif args.aws_step == "rollback":
                cmd_aws_rollback(cfg, args.yes)
        elif args.command == "deploy":
            cmd_deploy_scripts(cfg)
        else:
            raise MigrationError(f"Unknown command: {args.command}")
    except MigrationError as exc:
        log(f"ERROR: {exc}")
        return 1
    except subprocess.CalledProcessError as exc:
        log(f"ERROR: command failed with exit {exc.returncode}")
        return exc.returncode
    return 0


if __name__ == "__main__":
    sys.exit(main())
