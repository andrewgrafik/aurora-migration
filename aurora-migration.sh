#!/usr/bin/env bash

# Aurora Cross-Account Migration Script - Interactive Version
# Single script with menu-driven selections
# Requires bash 4.0+ for associative arrays

set -e

# Check bash version
if [ "${BASH_VERSINFO[0]}" -lt 4 ]; then
    echo "Error: This script requires bash 4.0 or higher"
    echo "Current version: $BASH_VERSION"
    echo "Please upgrade bash or run with: bash aurora-migration.sh"
    exit 1
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

configure_aws_profile() {
    local profile_name="$1"
    local access_key="$2"
    local secret_key="$3"
    local region="$4"
    
    aws configure set aws_access_key_id "$access_key" --profile "$profile_name"
    aws configure set aws_secret_access_key "$secret_key" --profile "$profile_name"
    aws configure set region "$region" --profile "$profile_name"
    aws configure set output json --profile "$profile_name"
}

echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║   Aurora Cross-Account Migration Tool         ║${NC}"
echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo

# Step 1: Configure Source Account
echo -e "${BLUE}Step 1: Source Account Credentials${NC}"
while true; do
    read -p "Source AWS Access Key: " SOURCE_ACCESS_KEY
    read -s -p "Source AWS Secret Key: " SOURCE_SECRET_KEY
    echo
    read -p "Source Region [us-east-1]: " SOURCE_REGION
    SOURCE_REGION=${SOURCE_REGION:-us-east-1}
    
    configure_aws_profile "source-account" "$SOURCE_ACCESS_KEY" "$SOURCE_SECRET_KEY" "$SOURCE_REGION"
    
    # Validate credentials
    if SOURCE_ACCOUNT_ID=$(aws sts get-caller-identity --profile source-account --query Account --output text 2>/dev/null); then
        echo -e "${GREEN}✓ Source Account: $SOURCE_ACCOUNT_ID${NC}"
        break
    else
        echo -e "${RED}✗ Invalid credentials. Please try again.${NC}"
        echo
    fi
done
echo

# Step 2: List and Select Source Cluster
echo -e "${BLUE}Step 2: Select Source Aurora Cluster${NC}"
echo "Scanning for Aurora clusters..."

CLUSTERS=$(aws rds describe-db-clusters --profile source-account --region $SOURCE_REGION \
    --query 'DBClusters[*].[DBClusterIdentifier,Engine,Status,StorageEncrypted]' --output text)

if [ -z "$CLUSTERS" ]; then
    echo -e "${RED}No Aurora clusters found in source account${NC}"
    exit 1
fi

echo
echo "Available Aurora Clusters:"
echo "─────────────────────────────────────────────────"
i=1
declare -A CLUSTER_MAP
while IFS=$'\t' read -r id engine status encrypted; do
    echo "$i) $id ($engine) - Status: $status - Encrypted: $encrypted"
    CLUSTER_MAP[$i]=$id
    ((i++))
done <<< "$CLUSTERS"

echo
read -p "Select cluster number: " CLUSTER_NUM
SOURCE_CLUSTER_ID=${CLUSTER_MAP[$CLUSTER_NUM]}

if [ -z "$SOURCE_CLUSTER_ID" ]; then
    echo -e "${RED}Invalid selection${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Selected: $SOURCE_CLUSTER_ID${NC}"

# Get cluster encryption status
SOURCE_ENCRYPTED=$(aws rds describe-db-clusters \
    --db-cluster-identifier "$SOURCE_CLUSTER_ID" \
    --profile source-account \
    --region $SOURCE_REGION \
    --query 'DBClusters[0].StorageEncrypted' \
    --output text)

echo

# Step 3: Configure Target Account
echo -e "${BLUE}Step 3: Target Account Credentials${NC}"
while true; do
    read -p "Target AWS Access Key: " TARGET_ACCESS_KEY
    read -s -p "Target AWS Secret Key: " TARGET_SECRET_KEY
    echo
    read -p "Target Region [$SOURCE_REGION]: " TARGET_REGION
    TARGET_REGION=${TARGET_REGION:-$SOURCE_REGION}
    
    configure_aws_profile "target-account" "$TARGET_ACCESS_KEY" "$TARGET_SECRET_KEY" "$TARGET_REGION"
    
    # Validate credentials
    if TARGET_ACCOUNT_ID=$(aws sts get-caller-identity --profile target-account --query Account --output text 2>/dev/null); then
        echo -e "${GREEN}✓ Target Account: $TARGET_ACCOUNT_ID${NC}"
        break
    else
        echo -e "${RED}✗ Invalid credentials. Please try again.${NC}"
        echo
    fi
done
echo

# Step 4: Select Target VPC
echo -e "${BLUE}Step 4: Select Target VPC${NC}"
echo "Scanning VPCs in target account..."

VPCS=$(aws ec2 describe-vpcs --profile target-account --region $TARGET_REGION \
    --query 'Vpcs[*].[VpcId,CidrBlock,Tags[?Key==`Name`].Value|[0]]' --output text)

echo
echo "Available VPCs:"
echo "─────────────────────────────────────────────────"
i=1
declare -A VPC_MAP
while IFS=$'\t' read -r vpc_id cidr name; do
    name=${name:-"(no name)"}
    echo "$i) $vpc_id - $cidr - $name"
    VPC_MAP[$i]=$vpc_id
    ((i++))
done <<< "$VPCS"

echo
read -p "Select VPC number: " VPC_NUM
TARGET_VPC_ID=${VPC_MAP[$VPC_NUM]}

if [ -z "$TARGET_VPC_ID" ]; then
    echo -e "${RED}Invalid selection${NC}"
    exit 1
fi

echo -e "${GREEN}✓ Selected VPC: $TARGET_VPC_ID${NC}"
echo

# Step 5: Select or Create DB Subnet Group
echo -e "${BLUE}Step 5: DB Subnet Group${NC}"
echo "Checking existing DB subnet groups..."

SUBNET_GROUPS=$(aws rds describe-db-subnet-groups --profile target-account --region $TARGET_REGION \
    --query "DBSubnetGroups[?VpcId=='$TARGET_VPC_ID'].[DBSubnetGroupName,SubnetIds|length(@)]" --output text 2>/dev/null || echo "")

if [ -n "$SUBNET_GROUPS" ]; then
    echo
    echo "Existing DB Subnet Groups in selected VPC:"
    echo "─────────────────────────────────────────────────"
    i=1
    declare -A SUBNET_GROUP_MAP
    SUBNET_GROUP_MAP[0]="CREATE_NEW"
    echo "0) Create new subnet group"
    while IFS=$'\t' read -r name subnet_count; do
        echo "$i) $name ($subnet_count subnets)"
        SUBNET_GROUP_MAP[$i]=$name
        ((i++))
    done <<< "$SUBNET_GROUPS"
    
    echo
    read -p "Select option: " SG_NUM
    TARGET_SUBNET_GROUP=${SUBNET_GROUP_MAP[$SG_NUM]}
else
    TARGET_SUBNET_GROUP="CREATE_NEW"
fi

if [ "$TARGET_SUBNET_GROUP" = "CREATE_NEW" ]; then
    echo
    echo "Creating new DB subnet group..."
    
    # Get subnets in the VPC
    SUBNETS=$(aws ec2 describe-subnets --profile target-account --region $TARGET_REGION \
        --filters "Name=vpc-id,Values=$TARGET_VPC_ID" \
        --query 'Subnets[*].[SubnetId,AvailabilityZone,CidrBlock]' --output text)
    
    echo "Available subnets (select at least 2 in different AZs):"
    echo "─────────────────────────────────────────────────"
    i=1
    declare -A SUBNET_MAP
    while IFS=$'\t' read -r subnet_id az cidr; do
        echo "$i) $subnet_id - $az - $cidr"
        SUBNET_MAP[$i]=$subnet_id
        ((i++))
    done <<< "$SUBNETS"
    
    echo
    read -p "Enter subnet numbers (comma-separated, e.g., 1,2,3): " SUBNET_NUMS
    
    SELECTED_SUBNETS=""
    IFS=',' read -ra NUMS <<< "$SUBNET_NUMS"
    for num in "${NUMS[@]}"; do
        num=$(echo $num | xargs)
        if [ -n "${SUBNET_MAP[$num]}" ]; then
            SELECTED_SUBNETS="$SELECTED_SUBNETS ${SUBNET_MAP[$num]}"
        fi
    done
    
    SUBNET_GROUP_NAME="aurora-migration-$(date +%Y%m%d-%H%M%S)"
    
    aws rds create-db-subnet-group \
        --db-subnet-group-name "$SUBNET_GROUP_NAME" \
        --db-subnet-group-description "Aurora migration subnet group" \
        --subnet-ids $SELECTED_SUBNETS \
        --profile target-account \
        --region $TARGET_REGION > /dev/null
    
    TARGET_SUBNET_GROUP=$SUBNET_GROUP_NAME
    echo -e "${GREEN}✓ Created subnet group: $SUBNET_GROUP_NAME${NC}"
else
    echo -e "${GREEN}✓ Using subnet group: $TARGET_SUBNET_GROUP${NC}"
fi

echo

# Step 6: Select Security Groups
echo -e "${BLUE}Step 6: Select Security Groups${NC}"
echo "Scanning security groups..."

SECURITY_GROUPS=$(aws ec2 describe-security-groups --profile target-account --region $TARGET_REGION \
    --filters "Name=vpc-id,Values=$TARGET_VPC_ID" \
    --query 'SecurityGroups[*].[GroupId,GroupName,Description]' --output text)

echo
echo "Available Security Groups:"
echo "─────────────────────────────────────────────────"
i=1
declare -A SG_MAP
while IFS=$'\t' read -r sg_id sg_name sg_desc; do
    echo "$i) $sg_id - $sg_name - $sg_desc"
    SG_MAP[$i]=$sg_id
    ((i++))
done <<< "$SECURITY_GROUPS"

echo
read -p "Enter security group numbers (comma-separated): " SG_NUMS

SELECTED_SGS=""
IFS=',' read -ra NUMS <<< "$SG_NUMS"
for num in "${NUMS[@]}"; do
    num=$(echo $num | xargs)
    if [ -n "${SG_MAP[$num]}" ]; then
        SELECTED_SGS="$SELECTED_SGS,${SG_MAP[$num]}"
    fi
done
SELECTED_SGS=${SELECTED_SGS:1}

echo -e "${GREEN}✓ Selected security groups: $SELECTED_SGS${NC}"
echo

# Step 7: Migration Configuration
echo -e "${BLUE}Step 7: Migration Configuration${NC}"

# Get source instance count
SOURCE_INSTANCE_INFO=$(aws rds describe-db-instances \
    --profile source-account \
    --region $SOURCE_REGION \
    --query "DBInstances[?DBClusterIdentifier=='$SOURCE_CLUSTER_ID'].[DBInstanceIdentifier,DBInstanceClass]" \
    --output text)

SOURCE_INSTANCE_COUNT=$(echo "$SOURCE_INSTANCE_INFO" | wc -l | xargs)
echo "Source cluster has $SOURCE_INSTANCE_COUNT instance(s):"
while IFS=$'\t' read -r id class; do
    echo "  - $id ($class)"
done <<< "$SOURCE_INSTANCE_INFO"
echo

read -p "Target Cluster Name [restored-$SOURCE_CLUSTER_ID]: " TARGET_CLUSTER_ID
TARGET_CLUSTER_ID=${TARGET_CLUSTER_ID:-restored-$SOURCE_CLUSTER_ID}

SNAPSHOT_ID="aurora-migration-$(date +%Y%m%d-%H%M%S)"
TEMP_SNAPSHOT_ID="${SNAPSHOT_ID}-temp"

echo
echo -e "${YELLOW}Migration Summary:${NC}"
echo "─────────────────────────────────────────────────"
echo "Source: $SOURCE_CLUSTER_ID ($SOURCE_ACCOUNT_ID)"
echo "Target: $TARGET_CLUSTER_ID ($TARGET_ACCOUNT_ID)"
echo "VPC: $TARGET_VPC_ID"
echo "Subnet Group: $TARGET_SUBNET_GROUP"
echo "Security Groups: $SELECTED_SGS"
echo "Instances to migrate: $SOURCE_INSTANCE_COUNT"
echo "─────────────────────────────────────────────────"
echo
read -p "Proceed with migration? (yes/no): " CONFIRM

if [ "$CONFIRM" != "yes" ]; then
    echo "Migration cancelled"
    exit 0
fi

echo
echo -e "${GREEN}Starting migration...${NC}"
echo

# Create snapshot
echo "Creating snapshot..."
aws rds create-db-cluster-snapshot \
    --db-cluster-identifier "$SOURCE_CLUSTER_ID" \
    --db-cluster-snapshot-identifier "$TEMP_SNAPSHOT_ID" \
    --profile source-account \
    --region $SOURCE_REGION > /dev/null

# Wait for snapshot
echo "Waiting for snapshot to complete..."
while true; do
    STATUS=$(aws rds describe-db-cluster-snapshots \
        --db-cluster-snapshot-identifier $TEMP_SNAPSHOT_ID \
        --profile source-account \
        --region $SOURCE_REGION \
        --query 'DBClusterSnapshots[0].Status' \
        --output text)
    
    if [ "$STATUS" = "available" ]; then
        break
    elif [ "$STATUS" = "failed" ]; then
        echo -e "${RED}Snapshot creation failed${NC}"
        exit 1
    fi
    
    echo "  Status: $STATUS..."
    sleep 30
done

echo -e "${GREEN}✓ Snapshot created${NC}"

# Share snapshot with target account first
echo "Sharing snapshot with target account..."
aws rds modify-db-cluster-snapshot-attribute \
    --db-cluster-snapshot-identifier $TEMP_SNAPSHOT_ID \
    --attribute-name restore \
    --values-to-add $TARGET_ACCOUNT_ID \
    --profile source-account \
    --region $SOURCE_REGION > /dev/null

echo -e "${GREEN}✓ Snapshot shared${NC}"

if [ "$SOURCE_ENCRYPTED" = "True" ]; then
    echo "Cluster is encrypted. Processing encrypted migration..."
    
    SOURCE_KMS_ARN=$(aws rds describe-db-cluster-snapshots \
        --db-cluster-snapshot-identifier $TEMP_SNAPSHOT_ID \
        --profile source-account \
        --region $SOURCE_REGION \
        --query 'DBClusterSnapshots[0].KmsKeyId' \
        --output text)
    
    echo "Source KMS key: $SOURCE_KMS_ARN"
    SOURCE_KMS_KEY_ID=$(echo $SOURCE_KMS_ARN | awk -F'/' '{print $NF}')
    
    # Check if it's AWS managed key
    KEY_MANAGER=$(aws kms describe-key --key-id $SOURCE_KMS_KEY_ID --profile source-account --region $SOURCE_REGION --query 'KeyMetadata.KeyManager' --output text 2>/dev/null || echo "CUSTOMER")
    
    if [ "$KEY_MANAGER" = "AWS" ]; then
        echo -e "${YELLOW}Source uses AWS managed RDS key - creating customer-managed key for migration${NC}"
        
        KMS_POLICY='{"Version":"2012-10-17","Statement":[{"Sid":"Enable IAM User Permissions","Effect":"Allow","Principal":{"AWS":"arn:aws:iam::'$SOURCE_ACCOUNT_ID':root"},"Action":"kms:*","Resource":"*"},{"Sid":"AllowTargetAccount","Effect":"Allow","Principal":{"AWS":"arn:aws:iam::'$TARGET_ACCOUNT_ID':root"},"Action":["kms:Decrypt","kms:CreateGrant","kms:DescribeKey"],"Resource":"*"}]}'
        
        CUSTOM_KEY_ARN=$(aws kms create-key \
            --description "Aurora cross-account migration key" \
            --policy "$KMS_POLICY" \
            --profile source-account \
            --region $SOURCE_REGION \
            --query 'KeyMetadata.Arn' \
            --output text)
        
        echo "Created customer-managed key with target account access: $CUSTOM_KEY_ARN"
        SOURCE_KMS_ARN=$CUSTOM_KEY_ARN
        SOURCE_KMS_KEY_ID=$(echo $CUSTOM_KEY_ARN | awk -F'/' '{print $NF}')
        echo -e "${GREEN}✓ KMS key created with target account access${NC}"
    fi
    
    # Copy in source with customer-managed KMS
    SOURCE_COPY_ID="${SNAPSHOT_ID}-src"
    echo "Copying snapshot with customer-managed KMS: $SOURCE_KMS_ARN"
    
    aws rds copy-db-cluster-snapshot \
        --source-db-cluster-snapshot-identifier $TEMP_SNAPSHOT_ID \
        --target-db-cluster-snapshot-identifier $SOURCE_COPY_ID \
        --kms-key-id $SOURCE_KMS_ARN \
        --profile source-account \
        --region $SOURCE_REGION > /dev/null
    
    echo "Waiting for source copy..."
    while true; do
        STATUS=$(aws rds describe-db-cluster-snapshots \
            --db-cluster-snapshot-identifier $SOURCE_COPY_ID \
            --profile source-account \
            --region $SOURCE_REGION \
            --query 'DBClusterSnapshots[0].Status' \
            --output text 2>/dev/null || echo "copying")
        [ "$STATUS" = "available" ] && break
        [ "$STATUS" = "failed" ] && echo -e "${RED}Copy failed${NC}" && exit 1
        echo "  Status: $STATUS..."
        sleep 30
    done
    
    echo -e "${GREEN}✓ Source copy complete${NC}"
    
    aws rds delete-db-cluster-snapshot --db-cluster-snapshot-identifier $TEMP_SNAPSHOT_ID --profile source-account --region $SOURCE_REGION > /dev/null 2>&1 || true
    
    echo "Sharing copied snapshot..."
    aws rds modify-db-cluster-snapshot-attribute \
        --db-cluster-snapshot-identifier $SOURCE_COPY_ID \
        --attribute-name restore \
        --values-to-add $TARGET_ACCOUNT_ID \
        --profile source-account \
        --region $SOURCE_REGION > /dev/null
    
    echo -e "${GREEN}✓ Snapshot shared${NC}"
    
    echo "Configuring KMS access..."
    
    # Try grant first
    if aws kms create-grant \
        --key-id "$SOURCE_KMS_KEY_ID" \
        --grantee-principal "arn:aws:iam::${TARGET_ACCOUNT_ID}:root" \
        --operations Decrypt DescribeKey CreateGrant \
        --profile source-account \
        --region $SOURCE_REGION 2>/dev/null; then
        echo -e "${GREEN}✓ KMS grant created${NC}"
    else
        # Try policy update
        echo "Grant failed, trying policy update..."
        POLICY=$(aws kms get-key-policy --key-id "$SOURCE_KMS_KEY_ID" --policy-name default --profile source-account --region $SOURCE_REGION --query Policy --output text 2>/dev/null)
        
        if [ -n "$POLICY" ]; then
            NEW_STMT='{"Sid":"AllowTargetAccount","Effect":"Allow","Principal":{"AWS":"arn:aws:iam::'$TARGET_ACCOUNT_ID':root"},"Action":["kms:Decrypt","kms:CreateGrant","kms:DescribeKey"],"Resource":"*"}'
            UPDATED=$(echo "$POLICY" | jq ".Statement += [$NEW_STMT]" 2>/dev/null)
            
            if [ -n "$UPDATED" ] && aws kms put-key-policy \
                --key-id "$SOURCE_KMS_KEY_ID" \
                --policy-name default \
                --policy "$UPDATED" \
                --profile source-account \
                --region $SOURCE_REGION 2>/dev/null; then
                echo -e "${GREEN}✓ KMS policy updated${NC}"
            else
                echo -e "${RED}ERROR: Cannot configure KMS access automatically${NC}"
                echo -e "${YELLOW}Source account credentials lack kms:CreateGrant and kms:PutKeyPolicy permissions${NC}"
                echo ""
                echo "Run this with source account admin credentials:"
                echo "aws kms create-grant --key-id $SOURCE_KMS_KEY_ID --grantee-principal arn:aws:iam::${TARGET_ACCOUNT_ID}:root --operations Decrypt DescribeKey CreateGrant --region $SOURCE_REGION"
                exit 1
            fi
        else
            echo -e "${RED}ERROR: Cannot access KMS key policy${NC}"
            echo "Source account credentials need kms:CreateGrant or kms:PutKeyPolicy permission"
            exit 1
        fi
    fi
    
    echo "Target copying snapshot with default RDS KMS..."
    TARGET_SNAPSHOT_ID="$SNAPSHOT_ID"
    
    aws rds copy-db-cluster-snapshot \
        --source-db-cluster-snapshot-identifier "arn:aws:rds:${SOURCE_REGION}:${SOURCE_ACCOUNT_ID}:cluster-snapshot:${SOURCE_COPY_ID}" \
        --target-db-cluster-snapshot-identifier $TARGET_SNAPSHOT_ID \
        --kms-key-id alias/aws/rds \
        --source-region $SOURCE_REGION \
        --profile target-account \
        --region $TARGET_REGION > /dev/null
    
    echo "Waiting for target copy..."
    while true; do
        STATUS=$(aws rds describe-db-cluster-snapshots \
            --db-cluster-snapshot-identifier $TARGET_SNAPSHOT_ID \
            --profile target-account \
            --region $TARGET_REGION \
            --query 'DBClusterSnapshots[0].Status' \
            --output text 2>/dev/null || echo "copying")
        [ "$STATUS" = "available" ] && break
        [ "$STATUS" = "failed" ] && echo -e "${RED}Copy failed${NC}" && exit 1
        echo "  Status: $STATUS..."
        sleep 30
    done
    
    echo -e "${GREEN}✓ Target snapshot copied with default RDS KMS${NC}"
    FINAL_SNAPSHOT_ID=$TARGET_SNAPSHOT_ID
else
    FINAL_SNAPSHOT_ID="arn:aws:rds:${SOURCE_REGION}:${SOURCE_ACCOUNT_ID}:cluster-snapshot:${TEMP_SNAPSHOT_ID}"
fi

# Restore in target
echo "Restoring cluster in target account..."

aws rds restore-db-cluster-from-snapshot \
    --db-cluster-identifier $TARGET_CLUSTER_ID \
    --snapshot-identifier $FINAL_SNAPSHOT_ID \
    --engine aurora-postgresql \
    --db-subnet-group-name $TARGET_SUBNET_GROUP \
    --vpc-security-group-ids $SELECTED_SGS \
    --profile target-account \
    --region $TARGET_REGION > /dev/null

# Wait for cluster
echo "Waiting for cluster to be available..."
while true; do
    STATUS=$(aws rds describe-db-clusters \
        --db-cluster-identifier $TARGET_CLUSTER_ID \
        --profile target-account \
        --region $TARGET_REGION \
        --query 'DBClusters[0].Status' \
        --output text 2>/dev/null || echo "creating")
    
    if [ "$STATUS" = "available" ]; then
        break
    elif [ "$STATUS" = "failed" ]; then
        echo -e "${RED}Cluster restore failed${NC}"
        exit 1
    fi
    
    echo "  Status: $STATUS..."
    sleep 60
done

echo -e "${GREEN}✓ Cluster restored${NC}"

# Get source cluster instances
echo "Detecting source cluster instances..."
SOURCE_INSTANCES=$(aws rds describe-db-instances \
    --profile source-account \
    --region $SOURCE_REGION \
    --query "DBInstances[?DBClusterIdentifier=='$SOURCE_CLUSTER_ID'].[DBInstanceIdentifier,DBInstanceClass,Engine]" \
    --output text)

INSTANCE_COUNT=$(echo "$SOURCE_INSTANCES" | wc -l | xargs)
echo "Found $INSTANCE_COUNT instance(s) in source cluster"
echo

# Create instances
INSTANCE_NUM=1
while IFS=$'\t' read -r instance_id instance_class engine; do
    TARGET_INSTANCE_ID="${TARGET_CLUSTER_ID}-instance-${INSTANCE_NUM}"
    
    echo "Creating instance $INSTANCE_NUM: $TARGET_INSTANCE_ID (class: $instance_class)..."
    
    aws rds create-db-instance \
        --db-instance-identifier "$TARGET_INSTANCE_ID" \
        --db-cluster-identifier $TARGET_CLUSTER_ID \
        --db-instance-class "$instance_class" \
        --engine aurora-postgresql \
        --profile target-account \
        --region $TARGET_REGION > /dev/null
    
    ((INSTANCE_NUM++))
done <<< "$SOURCE_INSTANCES"

echo
echo "Waiting for all instances to be available..."
INSTANCE_NUM=1
while [ $INSTANCE_NUM -lt $((INSTANCE_COUNT + 1)) ]; do
    TARGET_INSTANCE_ID="${TARGET_CLUSTER_ID}-instance-${INSTANCE_NUM}"
    
    while true; do
        STATUS=$(aws rds describe-db-instances \
            --db-instance-identifier "$TARGET_INSTANCE_ID" \
            --profile target-account \
            --region $TARGET_REGION \
            --query 'DBInstances[0].DBInstanceStatus' \
            --output text 2>/dev/null || echo "creating")
        
        if [ "$STATUS" = "available" ]; then
            echo -e "${GREEN}✓ Instance $INSTANCE_NUM available${NC}"
            break
        fi
        
        echo "  Instance $INSTANCE_NUM status: $STATUS..."
        sleep 30
    done
    
    ((INSTANCE_NUM++))
done
echo
echo -e "${GREEN}╔════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║         Migration Completed Successfully!     ║${NC}"
echo -e "${GREEN}╚════════════════════════════════════════════════╝${NC}"
echo
echo "Target Cluster: $TARGET_CLUSTER_ID"
echo "Target Instances:"
for ((i=1; i<=$INSTANCE_COUNT; i++)); do
    echo "  - ${TARGET_CLUSTER_ID}-instance-$i"
done
echo
echo -e "${YELLOW}IMPORTANT: Rotate the AWS credentials used in this migration${NC}"
echo
echo "Cleaning up AWS profiles..."
aws configure --profile source-account set aws_access_key_id "" 2>/dev/null || true
aws configure --profile target-account set aws_access_key_id "" 2>/dev/null || true
