# tf-aws-ec2-static-demo

Minimal Terraform: **VPC**, **EC2 (Amazon Linux 2023)** with **nginx** and **`robots.txt`**, optional **internet-facing ALB**, and by default **Session Manager**. With **`use_alb = true`**: **`az_count`** **public** subnets for the **ALB**, **`az_count`** **private** subnets, and **`az_count` EC2 instances** (one per AZ), each registered to the same target group, plus one **NAT Gateway** (hourly + data charges) for outbound traffic from private subnets. With **`use_alb = false`**: a **single public** subnet and **one EC2** with a **public IP** for direct **:80**. Not a substitute for **S3 + CloudFront** for production static hosting.

## Prerequisites

- Terraform `>= 1.5`
- AWS credentials with permission to create VPC, subnets, IGW, routes, **NAT Gateway + EIP** (if `use_alb = true`), security groups, EC2, ELB (if `use_alb = true`), IAM role + instance profile (if `enable_ssm = true`), and read EC2 AMIs / AZs.
- **Session Manager:** [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html) for `aws ssm start-session` from your laptop (optional if you use only the EC2 console **Connect** tab).

## Quick start

```bash
cd tf-aws-ec2-static-demo
terraform init
terraform apply
```

Optional: enable the load balancer.

```bash
terraform apply -var="use_alb=true"
```

Two subnets in two AZs (minimum for an ALB):

```bash
terraform apply -var="use_alb=true" -var="az_count=2"
```

## Variables

| Name | Default | Description |
|------|---------|-------------|
| `aws_region` | `us-east-1` | AWS region |
| `use_alb` | `false` | If `true`, create an internet-facing ALB; HTTP from the internet hits the ALB only, not the instance directly |
| `az_count` | `3` | **Only when `use_alb=true`:** number of **public** subnets (ALB) and **private** subnets (EC2), one per AZ. Must be **≥ 2**. **Ignored when `use_alb=false`**. Your region must have at least **`az_count`** enabled AZs. |
| `allowed_http_cidr` | `0.0.0.0/0` | CIDR allowed on port 80 (to the instance when `use_alb=false`, or to the ALB when `use_alb=true`) |
| `enable_ssm` | `true` | Attach `AmazonSSMManagedInstanceCore` for **Session Manager** (no inbound SSH). Set `false` to skip IAM role/profile. |

## Session Manager (default on)

The instance gets an instance profile with **`AmazonSSMManagedInstanceCore`**. On **Amazon Linux 2023**, **`user_data`** runs **`dnf install -y amazon-ssm-agent`** and **`systemctl enable --now amazon-ssm-agent`** when **`enable_ssm`** is true—the agent package may be present on the AMI, but the **service must be installed and running** to show **Online** in Fleet Manager. **Egress:** with **`use_alb=false`**, the instance reaches the internet directly; with **`use_alb=true`**, use the **NAT Gateway** (same as **`dnf`**), or add **VPC endpoints** for SSM if you remove NAT later.

After `apply`, wait until instances are **Online** under **Systems Manager → Fleet Manager** (often a few minutes). With **`use_alb=true`** you have **`az_count`** instances—use **`terraform output instance_ids`** and pick an ID, or start with the first:

```bash
terraform output -raw ssm_start_session_command | bash
# or:
aws ssm start-session --target "$(terraform output -raw instance_id)" --region "$(terraform output -raw aws_region)"
```

Use **`-var="enable_ssm=false"`** if you do not want the IAM role (you would need another way to administer the host, e.g. SSH with a key and SG rule, not included here).

**SSM still “Offline” in the console?** (1) **Replace** the instance after changing **`user_data`** (`terraform apply` with replacement, or taint). (2) **Private subnets:** confirm **NAT** is **available** and private route table has **`0.0.0.0/0` → NAT**. (3) On the box (serial/console if needed): **`sudo systemctl status amazon-ssm-agent`** and **`sudo tail -50 /var/log/amazon/ssm/amazon-ssm-agent.log`**.

## Verify

After `apply`, wait for **user_data** to finish (nginx install), typically 1–2 minutes. Then use `terraform output verify_commands` or:

- **Direct (`use_alb=false`):** `curl -sS http://<instance_public_ip>/` and `curl -sS http://<instance_public_ip>/robots.txt`
- **ALB (`use_alb=true`):** same paths using the ALB DNS name from `terraform output website_url_alb`

**ALB target health:** The target group uses an **HTTP** check on **`/`** (traffic port **80**) with matcher **200**, **15s** interval, **10s** timeout. The instance security group allows **:80** from the **ALB security group** and from the **VPC CIDR** so load balancer health probes reach nginx. If targets stay **Unhealthy** or you see **502**, check **`/var/log/cloud-init-output.log`**: **`dnf install curl`** on **AL2023** can conflict with **`curl-minimal`** and abort **`user_data`** before **nginx** installs—the bootstrap uses the AMI’s **`curl`** only. After a good boot, **`curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1/`** on the instance (e.g. via SSM) should print **200**.

The **`index.html`** page includes **availability zone** and **private IPv4** from **IMDSv2**. With the **ALB** and **one instance per AZ**, repeated **`curl`** to the ALB URL can show **different AZ / private IP** values as the load balancer picks different targets.

## IAM (rough)

Your Terraform principal needs broad **`ec2:*`**, **`elasticloadbalancing:*`** when using the ALB, and when **`enable_ssm`** is true: **`iam:CreateRole`**, **`iam:CreateInstanceProfile`**, **`iam:PassRole`** (for the EC2 service on that role), **`iam:AttachRolePolicy`**, plus **`iam:GetInstanceProfile`** / **`iam:AddRoleToInstanceProfile`** as needed.

Your **user or role** running **`aws ssm start-session`** needs **`ssm:StartSession`** on the instance (often via `arn:aws:ec2:region:account:instance/*` or narrower) and **`ssm:TerminateSession`**; AWS managed policy **AmazonSSMFullAccess** is heavy-handed but common in dev accounts.

## User data changes

Bootstrap lives in **`user_data.tftpl`** (column-0 shebang; do not paste that script into an indented Terraform `heredoc` or **`#!/bin/bash` may not run** and SSM/nginx will never configure). The instance sets **`user_data_replace_on_change = true`**: edit the template and **`apply`** to **replace** instances so the script runs again.

## Cleanup

```bash
terraform destroy
```

## License

MIT
