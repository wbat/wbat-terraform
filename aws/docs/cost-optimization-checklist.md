# Cost Optimization Checklist

## Current Findings (2026-01-06)

### CPU Analysis ✅
**Instance**: WBAT Primary Server (`i-0572702f0a58f6dcd`)
**Actual type**: `t3a.large` (8GB RAM) - **Note: Terraform says t3a.medium**

| Metric | Value | Assessment |
|--------|-------|------------|
| CPU Average (14 days) | 7-13% | Well below 30% baseline |
| CPU Max (14 days) | 67-100% | Brief spikes only |
| Credit Balance | 864/864 (always max) | Not using burst capacity |

**Recommendation**: ✅ Safe to use `standard` CPU credits (saves potential overage charges)

### Memory Analysis ⚠️
No CloudWatch Agent installed - memory metrics not available.
SSH to server and run `free -h` to check actual usage.

### Instance Type Drift ⚠️
- **Terraform**: `t3a.medium` ($27/month)
- **AWS Reality**: `t3a.large` ($54/month)

This is either manual drift or state mismatch. **Potential savings: ~$27/month** if you can downsize.

---

## 1. Review CPU Utilization

### T3a baseline reference:
| Instance | Baseline | Max Credits |
|----------|----------|-------------|
| t3a.micro | 10% | 144 |
| t3a.small | 20% | 288 |
| t3a.medium | 20% | 576 |
| t3a.large | 30% | 864 |

### To check CPU credit balance:
```bash
aws cloudwatch get-metric-statistics --profile wbat \
  --namespace AWS/EC2 \
  --metric-name CPUCreditBalance \
  --dimensions Name=InstanceId,Value=i-0572702f0a58f6dcd \
  --start-time $(date -u -v-24H +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 3600 \
  --statistics Average
```

If credit balance is consistently high (near max), you're not using burst capacity and `standard` mode is fine.

---

## 2. Review Memory Utilization

### Via SSH to your server:
```bash
# Current memory usage
free -h

# Memory usage over time (if you have sar installed)
sar -r

# Top memory consumers
ps aux --sort=-%mem | head -10
```

### WordPress typical memory requirements:
- **PHP-FPM**: 50-150MB per worker
- **MySQL**: 500MB-2GB depending on config
- **Nginx/Apache**: 50-100MB
- **OS overhead**: 200-500MB

### Sizing recommendations:
| Memory Usage | Recommended Instance | Monthly Cost |
|--------------|---------------------|--------------|
| < 1.5GB average | t3a.small (2GB) | ~$14/month |
| 1.5-3GB average | t3a.medium (4GB) | ~$27/month |
| > 3GB average | t3a.large (8GB) | ~$54/month |

---

## 3. Estimated Current Costs

Based on actual AWS configuration:
| Resource | Current | Monthly Cost |
|----------|---------|--------------|
| EC2 Primary | t3a.large | ~$54 |
| EC2 Secondary | t3a.small | ~$14 |
| EBS storage | gp3 | ~$8-16 |
| CloudFront | PriceClass_100 | ~$0-5 |
| Snapshots (6x) | DLM | ~$2-5 |
| **Total** | | **~$78-94** |

If you downsize primary to t3a.medium: **~$51-67/month**

---

## 4. Recommended Actions

### ✅ Action 1: Switch to Standard CPU Credits
Based on findings, you're not using burst capacity. Change in launch template:
```hcl
# In aws/us-east-1/ec2/primary-launch_template.tf
credit_specification {
  cpu_credits = "standard"  # Changed from "unlimited"
}
```

### ⚠️ Action 2: Investigate Instance Type Drift
Terraform says `t3a.medium` but AWS has `t3a.large`. Options:
1. **Run terraform plan** to see if Terraform will downsize it
2. **Update locals.tf** to match reality if intentional
3. **Check memory usage** before any downsize

### 💡 Action 3: Check Memory Before Downsizing
SSH to server and run `free -h`. If using < 3GB, t3a.medium is fine.

### 💰 Action 4: Consider Savings Plans
For 24/7 workloads, AWS Compute Savings Plans save 30-40%:
- Go to AWS Console → Cost Management → Savings Plans
- Review recommendations based on your usage

---

## Quick Commands Reference

```bash
# Check current instance type
aws ec2 describe-instances --profile wbat \
  --filters "Name=tag:Name,Values=WBAT Primary Server" \
  --query 'Reservations[0].Instances[0].InstanceType'

# Get last 7 days CPU average
aws cloudwatch get-metric-statistics --profile wbat \
  --namespace AWS/EC2 \
  --metric-name CPUUtilization \
  --dimensions Name=InstanceId,Value=i-0572702f0a58f6dcd \
  --start-time $(date -u -v-7d +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 86400 \
  --statistics Average Maximum
```
