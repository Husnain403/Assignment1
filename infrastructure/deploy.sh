#!/bin/bash
# UniEvent - End-to-end AWS deployment using AWS CLI
#
# Provisions:
#   * VPC (10.0.0.0/16) with 2 public + 2 private subnets across 2 AZs
#   * Internet Gateway + NAT Gateway (private subnets reach the API via NAT)
#   * IAM role + instance profile allowing EC2 to write to the S3 bucket
#   * Encrypted, private S3 bucket for event posters
#   * Application Load Balancer in public subnets (HTTP:80)
#   * Auto Scaling Group of 2 EC2 instances in private subnets
#
# Usage:
#   export TM_KEY="your-ticketmaster-api-key"
#   ./deploy.sh

set -euo pipefail
export AWS_PAGER=""

REGION="${REGION:-us-east-1}"
PROJECT="${PROJECT:-unievent}"
TM_KEY="${TM_KEY:?Set TM_KEY environment variable to your Ticketmaster API key}"

echo "==> Creating VPC"
VPC=$(aws ec2 create-vpc --cidr-block 10.0.0.0/16 --region "$REGION" \
  --tag-specifications "ResourceType=vpc,Tags=[{Key=Name,Value=$PROJECT-vpc}]" \
  --query 'Vpc.VpcId' --output text)
aws ec2 modify-vpc-attribute --vpc-id "$VPC" --enable-dns-hostnames

echo "==> Creating subnets across 2 AZs"
PUB1=$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.0.1.0/24 \
  --availability-zone "${REGION}a" --query 'Subnet.SubnetId' --output text)
PUB2=$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.0.2.0/24 \
  --availability-zone "${REGION}b" --query 'Subnet.SubnetId' --output text)
PRV1=$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.0.3.0/24 \
  --availability-zone "${REGION}a" --query 'Subnet.SubnetId' --output text)
PRV2=$(aws ec2 create-subnet --vpc-id "$VPC" --cidr-block 10.0.4.0/24 \
  --availability-zone "${REGION}b" --query 'Subnet.SubnetId' --output text)

echo "==> Internet Gateway + public route table"
IGW=$(aws ec2 create-internet-gateway --query 'InternetGateway.InternetGatewayId' --output text)
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC"
RT_PUB=$(aws ec2 create-route-table --vpc-id "$VPC" --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$RT_PUB" --destination-cidr-block 0.0.0.0/0 --gateway-id "$IGW"
aws ec2 associate-route-table --route-table-id "$RT_PUB" --subnet-id "$PUB1"
aws ec2 associate-route-table --route-table-id "$RT_PUB" --subnet-id "$PUB2"

echo "==> NAT Gateway + private route table"
EIP=$(aws ec2 allocate-address --domain vpc --query 'AllocationId' --output text)
NAT=$(aws ec2 create-nat-gateway --subnet-id "$PUB1" --allocation-id "$EIP" \
  --query 'NatGateway.NatGatewayId' --output text)
aws ec2 wait nat-gateway-available --nat-gateway-ids "$NAT"
RT_PRV=$(aws ec2 create-route-table --vpc-id "$VPC" --query 'RouteTable.RouteTableId' --output text)
aws ec2 create-route --route-table-id "$RT_PRV" --destination-cidr-block 0.0.0.0/0 --nat-gateway-id "$NAT"
aws ec2 associate-route-table --route-table-id "$RT_PRV" --subnet-id "$PRV1"
aws ec2 associate-route-table --route-table-id "$RT_PRV" --subnet-id "$PRV2"

echo "==> Encrypted private S3 bucket for posters"
BKT="$PROJECT-posters-$(date +%s)"
aws s3api create-bucket --bucket "$BKT" --region "$REGION"
aws s3api put-public-access-block --bucket "$BKT" --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
aws s3api put-bucket-encryption --bucket "$BKT" --server-side-encryption-configuration \
  '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'

echo "==> IAM role + instance profile (least-privilege S3 access)"
cat > /tmp/trust.json <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
  "Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON
aws iam create-role --role-name "$PROJECT-role" \
  --assume-role-policy-document file:///tmp/trust.json
cat > /tmp/policy.json <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
  "Action":["s3:PutObject","s3:GetObject","s3:ListBucket"],
  "Resource":["arn:aws:s3:::$BKT","arn:aws:s3:::$BKT/*"]}]}
JSON
aws iam put-role-policy --role-name "$PROJECT-role" \
  --policy-name s3-posters --policy-document file:///tmp/policy.json
aws iam create-instance-profile --instance-profile-name "$PROJECT-prof"
aws iam add-role-to-instance-profile \
  --instance-profile-name "$PROJECT-prof" --role-name "$PROJECT-role"
sleep 10

echo "==> Security groups (defence in depth)"
ALBSG=$(aws ec2 create-security-group --group-name "$PROJECT-alb-sg" \
  --description "ALB - public HTTP" --vpc-id "$VPC" --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$ALBSG" \
  --protocol tcp --port 80 --cidr 0.0.0.0/0
EC2SG=$(aws ec2 create-security-group --group-name "$PROJECT-ec2-sg" \
  --description "EC2 - only ALB" --vpc-id "$VPC" --query 'GroupId' --output text)
aws ec2 authorize-security-group-ingress --group-id "$EC2SG" \
  --protocol tcp --port 80 --source-group "$ALBSG"

echo "==> Application Load Balancer + target group"
ALB=$(aws elbv2 create-load-balancer --name "$PROJECT-alb" \
  --subnets "$PUB1" "$PUB2" --security-groups "$ALBSG" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text)
TG=$(aws elbv2 create-target-group --name "$PROJECT-tg" \
  --protocol HTTP --port 80 --vpc-id "$VPC" --target-type instance \
  --health-check-path /health \
  --query 'TargetGroups[0].TargetGroupArn' --output text)
aws elbv2 create-listener --load-balancer-arn "$ALB" --protocol HTTP --port 80 \
  --default-actions "Type=forward,TargetGroupArn=$TG"

echo "==> Rendering user-data with API key + bucket name"
APP_PY=$(cat "$(dirname "$0")/../app/app.py")
TEMPLATE=$(cat "$(dirname "$0")/userdata.sh")
USERDATA=$(python3 - <<PY
import os
tpl = """$TEMPLATE"""
app = """$APP_PY"""
print(tpl.replace("__APP_PY_PLACEHOLDER__", app)
         .replace("__TM_KEY__", "$TM_KEY")
         .replace("__S3_BUCKET__", "$BKT"))
PY
)
echo "$USERDATA" > /tmp/userdata_rendered.sh
UD64=$(base64 -i /tmp/userdata_rendered.sh)

echo "==> Launch template (Amazon Linux 2023)"
AMI=$(aws ssm get-parameters \
  --names /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query 'Parameters[0].Value' --output text)
LT=$(aws ec2 create-launch-template --launch-template-name "$PROJECT-lt" \
  --launch-template-data "{\"ImageId\":\"$AMI\",\"InstanceType\":\"t3.micro\",\
\"IamInstanceProfile\":{\"Name\":\"$PROJECT-prof\"},\
\"SecurityGroupIds\":[\"$EC2SG\"],\"UserData\":\"$UD64\"}" \
  --query 'LaunchTemplate.LaunchTemplateId' --output text)

echo "==> Auto Scaling Group across both private subnets"
aws autoscaling create-auto-scaling-group --auto-scaling-group-name "$PROJECT-asg" \
  --launch-template "LaunchTemplateId=$LT" \
  --min-size 2 --max-size 4 --desired-capacity 2 \
  --vpc-zone-identifier "$PRV1,$PRV2" \
  --target-group-arns "$TG" \
  --health-check-type ELB --health-check-grace-period 300

ALB_DNS=$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB" \
  --query 'LoadBalancers[0].DNSName' --output text)

cat <<DONE

============================================================
DEPLOYMENT COMPLETE
============================================================
VPC:        $VPC
S3 Bucket:  $BKT
ALB DNS:    http://$ALB_DNS

Allow ~4 minutes for EC2 instances to boot and register
with the target group, then visit the URL above.
============================================================
DONE
