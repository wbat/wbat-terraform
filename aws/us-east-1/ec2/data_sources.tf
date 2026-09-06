data "aws_iam_role" "AWSDataLifecycleManagerDefaultRole" {
  name = "AWSDataLifecycleManagerDefaultRole"
}

# Source snapshots for the DR AMIs and launch templates.
#
# These previously selected `tag:Name = "WBAT ... Server - First"` with
# `volume-size = 300`, which is the very first snapshot each policy ever took -- since
# withdrawn from rotation and kept permanently, so a fossil rather than a live backup.
# The AMI named "Primary-M_W_F-2AM_ET" was therefore pinned to a 2023 image of the
# pre-shrink 300 GB volume: verified to be a snapshot of vol-0d5064ffa1256b9fa, a volume
# that no longer exists, belonging to a previous primary instance. A rebuild would have
# come up with that disk and years-old data, which is worse than having no DR artifact,
# because it looks like one.
#
# Selection is now "newest completed snapshot whose Name matches the instance exactly":
#
#   - The DLM policies set copy_tags = true, so every snapshot they create inherits the
#     instance's Name ("WBAT Primary Server"). The permanent one-offs are all named
#     something else ("... - First", "primary-pre-shrink-cutover", "12/31/25 backup",
#     "Primary 2024/06/26"), and tag filters are exact-match, so they are excluded.
#   - `status = completed` matters: DLM snapshots appear immediately and fill in over
#     minutes, and registering an AMI from a pending snapshot fails. A plan that lands
#     mid-snapshot would otherwise break.
#   - The volume-size filter is gone on purpose. Hardcoding it is what let the source go
#     stale silently through the 300 -> 200 GB shrink; size now follows the snapshot.
#
# Deliberately NOT filtered on `tag:aws:dlm:lifecycle-policy-id`: it would tie every plan
# to the policy's current ID, so recreating the DLM policy would leave zero matching
# snapshots until its next scheduled run and *every* apply on this workspace would fail
# hard in the meantime.
#
# Note that it would also not have helped. The "- First" fossils *do* carry
# aws:dlm:lifecycle-policy-id tags, because they were produced by these very policies on
# their first run in 2023 before being pinned permanently. Provenance does not distinguish
# them; only the exact Name match does. Worth knowing before anyone "tightens" this filter
# and assumes the fossils are excluded by lineage.
#
# Assumes one EBS volume per instance, which holds today -- both declare only
# root_block_device. Add a volume filter here if a data volume is ever attached, since
# the DLM policies target INSTANCE and would then produce sibling snapshots.
data "aws_ebs_snapshot" "primary" {
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "status"
    values = ["completed"]
  }

  filter {
    name   = "tag:Name"
    values = ["WBAT Primary Server"]
  }
}

data "aws_ebs_snapshot" "secondary" {
  most_recent = true
  owners      = ["self"]

  filter {
    name   = "status"
    values = ["completed"]
  }

  filter {
    name   = "tag:Name"
    values = ["WBAT Secondary Server"]
  }
}

data "aws_security_group" "default" {
  id = "sg-0e674f4e2937c6392"
}

data "aws_subnet" "selected" {
  id = "subnet-0cd389d67c7cee3af"
}
