# UniEvent — AWS Architecture & Design Justification

## 1. High-Level Diagram

```
                          Internet
                              |
                       [ Internet Gateway ]
                              |
            +-----------------+-----------------+
            |                                   |
        Public Subnet A (10.0.1.0/24)      Public Subnet B (10.0.2.0/24)
        ┌──────────────┐                   ┌──────────────┐
        │  ALB Node    │ <----------------►│  ALB Node    │   (Application
        │  + NAT GW    │                   │              │    Load Balancer
        └──────┬───────┘                   └──────┬───────┘    spans both AZs)
               │                                  │
               │  (private traffic, SG-locked)    │
               ▼                                  ▼
        Private Subnet A (10.0.3.0/24)     Private Subnet B (10.0.4.0/24)
        ┌──────────────┐                   ┌──────────────┐
        │  EC2 (Flask) │                   │  EC2 (Flask) │
        └──────┬───────┘                   └──────┬───────┘
               │                                  │
               └───────────────┬──────────────────┘
                               │  (NAT GW egress)
                               ▼
                  Ticketmaster Discovery API
                               │
                               ▼
                       ┌───────────────┐
                       │  S3 (private, │
                       │  AES-256 SSE) │
                       │   posters     │
                       └───────────────┘
```

## 2. Service-by-Service Justification

### VPC
- Custom VPC `10.0.0.0/16` isolates UniEvent from default AWS networking.
- **Four subnets across two Availability Zones** (us-east-1a, us-east-1b):
  - 2 public (10.0.1.0/24, 10.0.2.0/24) — hold the ALB nodes + NAT Gateway.
  - 2 private (10.0.3.0/24, 10.0.4.0/24) — hold the application EC2 instances.
- **Why two AZs?** Requirement #6 ("system must continue operating even if one EC2 instance fails"). Spreading across AZs survives both instance and AZ failure.

### IAM
- A dedicated EC2 instance role `unievent-role` is attached to all application instances via an instance profile.
- Inline policy grants **only** `s3:PutObject`, `s3:GetObject`, and `s3:ListBucket` on the UniEvent bucket — least privilege, no wildcard ARNs.
- The Flask app obtains AWS credentials automatically from the instance-metadata service (IMDSv2), so no long-lived keys are baked into the AMI or code.

### EC2
- Application runs on **Amazon Linux 2023** `t3.micro` instances launched from a versioned **Launch Template**.
- A **systemd service** (`unievent.service` with `Restart=always`) supervises the Flask process so a crash auto-recovers without ASG intervention.
- Instances live **only in private subnets** — they have no public IPs and are unreachable from the internet directly (requirement #1).
- **Auto Scaling Group** maintains `desired=2`, `min=2`, `max=4` across both AZs. ELB health checks drive replacement (requirement #6).

### S3
- Bucket `unievent-posters-*` stores event posters fetched from the Ticketmaster API.
- **Block Public Access** is enabled (all four flags) so the bucket is unreachable from the public internet (requirement #4 — "stored securely").
- **Server-Side Encryption (AES-256, SSE-S3)** is enabled by default on every object.
- Versioning could be added for additional defense in depth (not enabled here to keep within free-tier costs).

### Elastic Load Balancing
- **Application Load Balancer** in the public subnets, with two security groups acting as a defence-in-depth boundary:
  - `unievent-alb-sg`: allows port 80 from `0.0.0.0/0` (entry point for users).
  - `unievent-ec2-sg`: allows port 80 **only from `unievent-alb-sg`** — direct EC2 access from the internet is impossible even if a route were misconfigured.
- Target Group health check on `/health` (HTTP 200) decides whether each instance gets traffic.
- The ALB distributes requests across all healthy targets, satisfying scalability + fault tolerance.

## 3. Open API Choice — Ticketmaster Discovery API

| Criterion       | Why Ticketmaster                                                        |
| --------------- | ----------------------------------------------------------------------- |
| Free tier       | 5,000 calls/day, sufficient for periodic polling.                       |
| Data fields     | Provides `name`, `dates.start.localDate`, venue, info, images — exactly what the assignment requires. |
| Format          | Structured JSON, easy to parse in Python with `requests`.               |
| Auth model      | Simple `apikey` query parameter, no OAuth dance.                        |
| Reliability     | Production API used by major ticketing partners.                        |

Image URLs returned by the API are downloaded once per event and cached to S3 by the application (see `cache_poster_to_s3` in `app/app.py`).

## 4. How Each Assignment Requirement Is Satisfied

| # | Requirement                                              | Implementation                                                                    |
| - | -------------------------------------------------------- | --------------------------------------------------------------------------------- |
| 1 | App runs on multiple EC2 instances inside private subnets | ASG with 2 instances across private subnets in two AZs                            |
| 2 | App periodically fetches data from an Open API           | Flask handler calls Ticketmaster Discovery API on each request (and re-renders)   |
| 3 | Retrieved data processed and stored                      | JSON parsed in `app.py`; HTML cards generated on the fly                          |
| 4 | Event posters stored securely in S3                      | `cache_poster_to_s3()` puts posters into the AES-256-encrypted, private S3 bucket |
| 5 | App displays events as "University Events"               | Page heading is "University Events" — rendered server-side                        |
| 6 | System continues if one EC2 instance fails               | ASG (multi-AZ) + ALB health checks replace any failed instance automatically      |

## 5. Cost & Cleanup
- NAT Gateway (~$0.045/hr) and ALB (~$0.0225/hr) dominate the bill.
- Run `infrastructure/teardown.sh` after grading to delete every resource.

## 6. Possible Extensions
- Add **CloudWatch alarms** to scale the ASG horizontally on `CPUUtilization > 70%`.
- Front the ALB with **CloudFront + ACM** to terminate HTTPS at the edge.
- Move the API key into **AWS Secrets Manager** instead of a systemd env var.
- Cache the Ticketmaster JSON in **ElastiCache (Redis)** with a 5-minute TTL.
