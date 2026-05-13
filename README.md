# UniEvent — Scalable University Event Management System on AWS

![AWS](https://img.shields.io/badge/AWS-Cloud-orange?logo=amazonaws)
![Python](https://img.shields.io/badge/Python-3.9+-blue?logo=python)
![Flask](https://img.shields.io/badge/Flask-3.x-black?logo=flask)
![License](https://img.shields.io/badge/Course-CE%20308%2F408-green)

> **Course:** CE 308/408 Cloud Computing — Assignment 1
> **Institution:** Ghulam Ishaq Khan Institute of Engineering Sciences and Technology
> **Topic:** Deployment of a Scalable University Event Management System on AWS

---

## Table of Contents
1. [Overview](#overview)
2. [Architecture](#architecture)
3. [AWS Services Used](#aws-services-used)
4. [Open API Choice](#open-api-choice)
5. [Repository Structure](#repository-structure)
6. [Prerequisites](#prerequisites)
7. [Deployment Guide](#deployment-guide)
8. [Verifying the Six Requirements](#verifying-the-six-requirements)
9. [Fault-Tolerance Demonstration](#fault-tolerance-demonstration)
10. [Teardown](#teardown)
11. [Cost Estimate](#cost-estimate)
12. [Security Considerations](#security-considerations)
13. [Future Improvements](#future-improvements)
14. [Author](#author)

---

## Overview

**UniEvent** is a cloud-hosted web application where students can browse the
university events portal. Rather than manual entry, the system automatically
fetches event data from the **Ticketmaster Discovery API** (a public Open API)
and renders those events as "University Events" on the UniEvent platform.
Event poster images are cached to a private, encrypted **Amazon S3** bucket.

The platform is built to be:
- **Secure** — private subnets, least-privilege IAM, encrypted S3, defence-in-depth security groups
- **Scalable** — Auto Scaling Group with `min=2`, `max=4` instances
- **Fault-tolerant** — multi-AZ deployment, ALB health checks, systemd auto-restart
- **Cost-aware** — `t3.micro` instances, AES-256 SSE-S3 (free) instead of KMS

---

## Architecture

```
                          Internet
                              │
                       [ Internet Gateway ]
                              │
       ┌──────────────────────┴──────────────────────┐
       │                                             │
   Public Subnet A (10.0.1.0/24)               Public Subnet B (10.0.2.0/24)
   ┌───────────────┐                           ┌───────────────┐
   │  ALB Node     │ ◄────────────────────────►│  ALB Node     │
   │  + NAT GW     │                           │               │
   └───────┬───────┘                           └───────┬───────┘
           │       (defence-in-depth SGs)              │
           ▼                                           ▼
   Private Subnet A (10.0.3.0/24)              Private Subnet B (10.0.4.0/24)
   ┌───────────────┐                           ┌───────────────┐
   │ EC2 (Flask)   │                           │ EC2 (Flask)   │
   │ systemd svc   │                           │ systemd svc   │
   └───────┬───────┘                           └───────┬───────┘
           └───────────────────┬───────────────────────┘
                               │ (egress via NAT GW)
                               ▼
                  Ticketmaster Discovery API
                               │
                               ▼
                       ┌──────────────┐
                       │  S3 Bucket   │
                       │  AES-256 SSE │
                       │  Block PubAcc│
                       │  (posters)   │
                       └──────────────┘
```

For full design justification, see
**[`architecture/ARCHITECTURE.md`](architecture/ARCHITECTURE.md)**.

---

## AWS Services Used

| Service                    | Role in UniEvent                                                   |
| -------------------------- | ------------------------------------------------------------------ |
| **VPC**                    | Custom `10.0.0.0/16` network with 2 public + 2 private subnets across two AZs (us-east-1a, us-east-1b) |
| **Internet Gateway**       | Allows the ALB to receive public traffic                            |
| **NAT Gateway**            | Allows private EC2 instances to call the external Ticketmaster API |
| **IAM**                    | Instance role + profile granting least-privilege S3 access only    |
| **EC2 (Amazon Linux 2023)**| Hosts the Flask application as a `systemd` service                  |
| **Auto Scaling Group**     | Maintains 2 healthy instances (`max=4`), spread across both AZs    |
| **Application Load Balancer** | Public entry point; health-checks `/health` on each target      |
| **S3**                     | Stores event posters; SSE-AES256 + Block Public Access enforced   |
| **Security Groups**        | ALB-SG (public:80) and EC2-SG (only from ALB-SG) — layered defence |

---

## Open API Choice

We chose the **Ticketmaster Discovery API** for the following reasons:

| Criterion         | Why Ticketmaster                                                  |
| ----------------- | ----------------------------------------------------------------- |
| **Free tier**     | 5,000 calls/day — comfortably enough for periodic polling         |
| **Data quality**  | Returns `name`, `dates.start.localDate`, venue, info, image URLs  |
| **Format**        | Structured JSON, trivial to parse with Python's `requests`        |
| **Auth model**    | Simple `apikey` query parameter — no OAuth handshake needed       |
| **Reliability**   | Production-grade API used by major ticketing partners worldwide   |

Endpoint used: `GET https://app.ticketmaster.com/discovery/v2/events.json`

---

## Repository Structure

```
unievent/
├── README.md                       ← this file
├── .gitignore
│
├── app/
│   ├── app.py                      ← Flask app (event fetch + poster cache + UI)
│   └── requirements.txt            ← Python dependencies
│
├── infrastructure/
│   ├── deploy.sh                   ← AWS CLI script — provisions everything
│   ├── teardown.sh                 ← AWS CLI script — deletes everything
│   └── userdata.sh                 ← EC2 user-data template (installed by deploy.sh)
│
└── architecture/
    └── ARCHITECTURE.md             ← detailed design justification
```

---

## Prerequisites

Before deploying, make sure you have:

1. **An AWS account** with permissions to create IAM, VPC, EC2, S3, and ELB resources
   (the `AdministratorAccess` managed policy is fine for the assignment, then revoke after).

2. **AWS CLI v2** installed on macOS:
   ```bash
   curl "https://awscli.amazonaws.com/AWSCLIV2.pkg" -o AWSCLIV2.pkg
   sudo installer -pkg AWSCLIV2.pkg -target /
   aws --version
   ```

3. **Configured credentials:**
   ```bash
   aws configure
   # AWS Access Key ID:     <from IAM console>
   # AWS Secret Access Key: <from IAM console>
   # Default region name:   us-east-1
   # Default output format: json
   ```

4. **A Ticketmaster API key** (free):
   - Sign up at https://developer.ticketmaster.com
   - Copy the *Consumer Key* from your app

5. **`python3`** available locally (used by the deploy script to render user-data).

---

## Deployment Guide

```bash
# 1. Clone the repository
git clone https://github.com/<your-username>/unievent.git
cd unievent/infrastructure

# 2. Provide your Ticketmaster API key
export TM_KEY="your-ticketmaster-consumer-key"

# 3. Make scripts executable
chmod +x deploy.sh teardown.sh

# 4. Deploy
./deploy.sh
```

The script prints the **ALB DNS name** at the end:

```
============================================================
DEPLOYMENT COMPLETE
============================================================
VPC:        vpc-0abc123
S3 Bucket:  unievent-posters-1715712345
ALB DNS:    http://unievent-alb-123456789.us-east-1.elb.amazonaws.com

Allow ~4 minutes for EC2 instances to boot and register
with the target group, then visit the URL above.
============================================================
```

Wait ~4 minutes (EC2 boot + `pip install` + service start), then open the URL
in your browser. You should see the **University Events** page rendered from
live Ticketmaster data.

---

## Verifying the Six Requirements

| # | Requirement                                       | How to Verify                                                                                                  |
| - | ------------------------------------------------- | -------------------------------------------------------------------------------------------------------------- |
| 1 | App runs on multiple EC2 instances in private subnets | `aws ec2 describe-instances --filters "Name=tag:aws:autoscaling:groupName,Values=unievent-asg"` — look at `SubnetId`s (they are private) and the absence of public IPs |
| 2 | App periodically fetches event data from an Open API | See [`app/app.py`](app/app.py) → `fetch_events()` — every page render calls Ticketmaster                       |
| 3 | Retrieved data processed and stored                | JSON parsed in `fetch_events()`, posters PUT to S3 in `cache_poster_to_s3()`                                   |
| 4 | Event posters stored securely in S3                | `aws s3api get-bucket-encryption --bucket unievent-posters-…` returns AES256; PAB blocks all public access     |
| 5 | App displays events as "University Events"         | Page heading is literally "University Events" — open the ALB URL in a browser                                  |
| 6 | System continues operating if one EC2 instance fails | See [Fault-Tolerance Demonstration](#fault-tolerance-demonstration) below                                      |

---

## Fault-Tolerance Demonstration

Manually terminate one instance and confirm the app keeps serving:

```bash
# Pick one of the running instances
INST=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names unievent-asg \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)

# Kill it
aws ec2 terminate-instances --instance-ids "$INST"

# Refresh the ALB URL in your browser - the app is STILL up,
# served by the surviving instance in the other AZ.

# Within 2-3 minutes, the ASG launches a replacement
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names unievent-asg \
  --query 'AutoScalingGroups[0].Instances'
```

This is the screenshot you want for **requirement #6**.

---

## Teardown

The deployment provisions billable resources (NAT Gateway ≈ \$1.08/day, ALB ≈
\$0.54/day). **Run the teardown script after grading** to avoid charges:

```bash
cd infrastructure
./teardown.sh
```

The script deletes the ASG, Launch Template, ALB, Target Group, NAT Gateway,
Elastic IPs, S3 bucket (including objects), IAM role + profile, subnets,
route tables, IGW, and finally the VPC itself.

---

## Cost Estimate

For a single day of running this assignment:

| Resource           | Approx. Cost / day | Notes                           |
| ------------------ | ------------------ | ------------------------------- |
| NAT Gateway        | \$1.08             | $0.045/hr + data-processing     |
| Application LB     | \$0.54             | $0.0225/hr + LCU                |
| 2× t3.micro EC2    | Free tier eligible | Otherwise ≈ \$0.50/day total    |
| S3 storage         | < \$0.01           | A few MB of posters             |
| Elastic IP (NAT)   | Free while attached |                                |
| **Total**          | **≈ \$1.60/day**   | Without free tier               |

---

## Security Considerations

- **Defence in depth at the network layer** — EC2 instances are unreachable
  from the internet because (a) they live in private subnets with no public IPs
  and (b) their security group only allows traffic *from the ALB security group*,
  not from `0.0.0.0/0`.
- **Least-privilege IAM** — the EC2 instance role can only `PutObject`,
  `GetObject`, and `ListBucket` on the UniEvent bucket. No wildcards, no
  `AmazonS3FullAccess`.
- **No long-lived AWS credentials on disk** — `boto3` uses the IMDSv2 instance
  role for authentication; no access keys are baked into the AMI or code.
- **API key isolation** — the Ticketmaster key lives in a systemd `Environment=`
  directive on the EC2 instance only. It is never committed to git
  (`.gitignore` covers `.env`).
- **Encryption at rest** — S3 objects are encrypted with AES-256 (SSE-S3) by
  default. KMS is not used to stay within free-tier billing.
- **Block Public Access** is enforced on the S3 bucket with all four flags ON,
  so even an accidental ACL change cannot make objects public.

---

## Future Improvements

- **CloudFront + ACM** for HTTPS termination at the edge
- **CloudWatch Alarms** to scale the ASG on `CPUUtilization > 70%`
- **Secrets Manager** to store the Ticketmaster key instead of an env var
- **ElastiCache (Redis)** to cache the Ticketmaster JSON for a 5-min TTL
- **CodeDeploy / blue-green deployments** for zero-downtime app releases
- **WAF** on the ALB to filter common web attacks
- **Terraform / CloudFormation** to make the deploy script declarative

---

## Author

Built for **CE 308/408 Cloud Computing — Assignment 1** at
Ghulam Ishaq Khan Institute of Engineering Sciences and Technology.
