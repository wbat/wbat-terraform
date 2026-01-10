# Cost Optimization Checklist

## 1. Review CPU Utilization

### Via AWS Console
1. Go to **EC2** → **Instances** → Select "WBAT Primary Server"
2. Click **Monitoring** tab
3. Look at **CPU utilization** graph for the past 2 weeks

### What to look for:
- **Average < 20%**: You're under baseline for t3a.medium, `standard` credits would work fine
- **Spikes > 20% but brief**: Keep `unlimited` but spikes are covered by accrued credits
- **Sustained > 20%**: Keep `unlimited` - you're using burst capacity and paying for it

### T3a.medium baseline:
- **Baseline**: 20% CPU (2 vCPU × 20% = 0.4 vCPU equivalent)
- **Credits earned**: 24 credits/hour
- **Credits per burst**: 1 credit = 1 vCPU-minute at 100%

### To check CPU credit balance:
```bash
# On the EC2 instance or via AWS CLI:
aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 \
  --metric-name CPUCreditBalance \
  --dimensions Name=InstanceId,Value=YOUR_INSTANCE_ID \
  --start-time $(date -u -d '24 hours ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 3600 \
  --statistics Average
```

If credit balance is consistently high (>100), you're not using burst capacity and `standard` mode is fine.

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
| Memory Usage | Recommended Instance |
|--------------|---------------------|
| < 1.5GB average | t3a.small (2GB) - saves ~$13/month |
| 1.5-3GB average | t3a.medium (4GB) - current |
| > 3GB average | t3a.large (8GB) - consider optimizing first |

---

## 3. Check Current Costs

### AWS Cost Explorer
1. Go to **Billing** → **Cost Explorer**
2. Filter by service: EC2, CloudFront, etc.
3. Look at the past 3 months trend

### Key cost drivers for your setup:
- EC2 instance: ~$27/month (t3a.medium on-demand)
- EBS storage: ~$8/month (assuming 100GB gp3)
- CloudFront: $0-5/month (depending on traffic)
- Snapshots: ~$2-5/month (6 snapshots)
- Data transfer: Variable

---

## 4. Actions Based on Findings

### If CPU is consistently < 20%:
Change to `standard` credits in `locals.tf`:
```hcl
# In aws/us-east-1/ec2/primary-launch_template.tf
credit_specification {
  cpu_credits = "standard"  # Changed from "unlimited"
}
```

### If memory is consistently < 1.5GB:
Change instance type in `locals.tf`:
```hcl
# In aws/locals.tf
primary_instance_type = "t3a.small"  # Changed from "t3a.medium"
```

### For consistent 24/7 usage:
Consider a 1-year Compute Savings Plan in AWS Console (30-40% savings).

---

## Quick Commands Reference

```bash
# Check current instance type
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=WBAT Primary Server" \
  --query 'Reservations[0].Instances[0].InstanceType'

# Check CPU credit mode
aws ec2 describe-instances \
  --filters "Name=tag:Name,Values=WBAT Primary Server" \
  --query 'Reservations[0].Instances[0].CreditSpecification'

# Get last 7 days CPU average
aws cloudwatch get-metric-statistics \
  --namespace AWS/EC2 \
  --metric-name CPUUtilization \
  --dimensions Name=InstanceId,Value=YOUR_INSTANCE_ID \
  --start-time $(date -u -d '7 days ago' +%Y-%m-%dT%H:%M:%SZ) \
  --end-time $(date -u +%Y-%m-%dT%H:%M:%SZ) \
  --period 86400 \
  --statistics Average Maximum
```
