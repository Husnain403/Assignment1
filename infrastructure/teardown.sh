#!/bin/bash
# UniEvent - tears down every resource created by deploy.sh.
# Run this after the assignment is graded to stop incurring AWS charges
# (NAT Gateway, ALB, and EC2 are the big-ticket items).

set +e
export AWS_PAGER=""
PROJECT="${PROJECT:-unievent}"
REGION="${REGION:-us-east-1}"

echo "==> Deleting Auto Scaling Group"
aws autoscaling delete-auto-scaling-group \
  --auto-scaling-group-name "$PROJECT-asg" --force-delete

echo "==> Deleting Launch Template"
aws ec2 delete-launch-template --launch-template-name "$PROJECT-lt"

echo "==> Deleting Load Balancer + Target Group"
ALB_ARN=$(aws elbv2 describe-load-balancers --names "$PROJECT-alb" \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null)
[ -n "$ALB_ARN" ] && aws elbv2 delete-load-balancer --load-balancer-arn "$ALB_ARN"
sleep 30
TG_ARN=$(aws elbv2 describe-target-groups --names "$PROJECT-tg" \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null)
[ -n "$TG_ARN" ] && aws elbv2 delete-target-group --target-group-arn "$TG_ARN"

echo "==> Deleting NAT Gateway + releasing Elastic IP"
NAT=$(aws ec2 describe-nat-gateways \
  --filter "Name=state,Values=available" \
  --query 'NatGateways[?VpcId!=`null`]|[0].NatGatewayId' --output text)
[ "$NAT" != "None" ] && aws ec2 delete-nat-gateway --nat-gateway-id "$NAT"
sleep 60

echo "==> Emptying + deleting S3 buckets"
for BKT in $(aws s3api list-buckets --query "Buckets[?starts_with(Name,'$PROJECT-posters-')].Name" --output text); do
  aws s3 rm "s3://$BKT" --recursive
  aws s3api delete-bucket --bucket "$BKT"
done

echo "==> Deleting IAM role + instance profile"
aws iam remove-role-from-instance-profile \
  --instance-profile-name "$PROJECT-prof" --role-name "$PROJECT-role"
aws iam delete-instance-profile --instance-profile-name "$PROJECT-prof"
aws iam delete-role-policy --role-name "$PROJECT-role" --policy-name s3-posters
aws iam delete-role --role-name "$PROJECT-role"

echo "==> Deleting VPC + dependencies"
VPC=$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=$PROJECT-vpc" \
  --query 'Vpcs[0].VpcId' --output text)
if [ "$VPC" != "None" ]; then
  for SG in $(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" \
      --query "SecurityGroups[?GroupName!='default'].GroupId" --output text); do
    aws ec2 delete-security-group --group-id "$SG"
  done
  for SN in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" \
      --query 'Subnets[*].SubnetId' --output text); do
    aws ec2 delete-subnet --subnet-id "$SN"
  done
  for RT in $(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" \
      --query "RouteTables[?Associations[0].Main!=\`true\`].RouteTableId" --output text); do
    aws ec2 delete-route-table --route-table-id "$RT"
  done
  IGW=$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC" \
    --query 'InternetGateways[0].InternetGatewayId' --output text)
  if [ "$IGW" != "None" ]; then
    aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC"
    aws ec2 delete-internet-gateway --internet-gateway-id "$IGW"
  fi
  aws ec2 delete-vpc --vpc-id "$VPC"
fi

for EIP in $(aws ec2 describe-addresses --query 'Addresses[?AssociationId==null].AllocationId' --output text); do
  aws ec2 release-address --allocation-id "$EIP"
done

echo "Teardown complete."
