Aurora Cross-Account Migration Tool
====================================

> Automated script for migrating Amazon Aurora PostgreSQL databases across AWS accounts with support for encrypted clusters.

---

🎯 Purpose
----------

This tool automates the complex process of migrating Aurora PostgreSQL clusters from one AWS account to another, handling:
- Encrypted and unencrypted clusters
- Cross-account snapshot sharing
- KMS key management for encrypted snapshots
- Automatic re-encryption with target account's default RDS KMS key
- Network configuration (VPC, subnets, security groups)

🔄 Migration Flow
-----------------

For Encrypted Clusters:
1. Create snapshot in source account
2. Detect encryption - Check if source uses AWS managed or customer-managed KMS key
3. Create customer-managed KMS key (if source uses AWS managed key)
4. Copy snapshot with customer-managed KMS key in source account
5. Share snapshot with target account
6. Grant KMS access to target account
7. Copy snapshot in target account with target's default RDS KMS key (alias/aws/rds)
8. Restore cluster in target account from copied snapshot
9. Create DB instance in target account

For Unencrypted Clusters:
1. Create snapshot in source account
2. Share snapshot with target account
3. Restore cluster in target account
4. Create DB instance in target account

⚙️ Prerequisites
----------------

- Bash 4.0+
- AWS CLI installed and configured
- jq (for JSON processing)
- IAM credentials for both source and target accounts

🔐 Required IAM Permissions
---------------------------

Source Account User

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "rds:DescribeDBClusters",
        "rds:DescribeDBClusterSnapshots",
        "rds:CreateDBClusterSnapshot",
        "rds:CopyDBClusterSnapshot",
        "rds:DeleteDBClusterSnapshot",
        "rds:ModifyDBClusterSnapshotAttribute",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "kms:CreateKey",
        "kms:CreateGrant",
        "kms:DescribeKey",
        "kms:GetKeyPolicy",
        "kms:PutKeyPolicy",
        "kms:Decrypt"
      ],
      "Resource": "*"
    }
  ]
}
```

Target Account User

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "rds:DescribeDBClusterSnapshots",
        "rds:CopyDBClusterSnapshot",
        "rds:RestoreDBClusterFromSnapshot",
        "rds:CreateDBInstance",
        "rds:DescribeDBClusters",
        "rds:DescribeDBInstances",
        "rds:DescribeDBSubnetGroups",
        "rds:CreateDBSubnetGroup",
        "ec2:DescribeVpcs",
        "ec2:DescribeSubnets",
        "ec2:DescribeSecurityGroups",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
```

🚀 Usage
--------

Download the script:
```bash
wget https://raw.githubusercontent.com/YOUR_USERNAME/aurora-migration/main/aurora-migration.sh
chmod +x aurora-migration.sh
```

Run the script:
```bash
bash aurora-migration.sh
```

Follow the interactive prompts:
- Enter source account AWS credentials
- Select source Aurora cluster
- Enter target account AWS credentials
- Select target VPC
- Select or create DB subnet group
- Select security groups
- Configure target cluster name and instance class
- Confirm migration

📝 Interactive Steps
--------------------

The script will guide you through:

1. Source Account Configuration - AWS credentials and region
2. Source Cluster Selection - Choose from available Aurora clusters
3. Target Account Configuration - AWS credentials and region
4. Target VPC Selection - Choose destination VPC
5. DB Subnet Group - Select existing or create new
6. Security Groups - Select security groups for the cluster
7. Migration Configuration - Set cluster name and instance class
8. Confirmation - Review and confirm migration

⚠️ Important Notes
------------------

Encryption Handling
- AWS Managed Keys: Script automatically creates a customer-managed KMS key for migration
- Customer-Managed Keys: Script uses existing key and grants access to target account
- Target Re-encryption: Target account automatically re-encrypts with its default RDS KMS key

Security Best Practices
- Credentials are only stored temporarily in AWS CLI profiles
- Profiles are cleared at the end of the script
- Always rotate credentials after migration
- Use IAM users with minimum required permissions

Limitations
- Only supports Aurora PostgreSQL
- Requires bash 4.0+ (macOS users may need to upgrade)
- Cross-region migration supported (specify different target region)
- Downtime required during snapshot creation

🔧 Troubleshooting
------------------

KMS Permission Errors

If you encounter KMS permission errors:
```bash
aws kms create-grant \
  --key-id <SOURCE_KMS_KEY_ID> \
  --grantee-principal arn:aws:iam::<TARGET_ACCOUNT_ID>:root \
  --operations Decrypt DescribeKey CreateGrant \
  --region <SOURCE_REGION>
```

Bash Version Check
```bash
bash --version
```

Install jq
```bash
# macOS
brew install jq

# Amazon Linux/RHEL
sudo yum install jq

# Ubuntu/Debian
sudo apt-get install jq
```

📊 Example Output
-----------------

```
╔════════════════════════════════════════════════╗
║   Aurora Cross-Account Migration Tool         ║
╔════════════════════════════════════════════════╗

Step 1: Source Account Credentials
✓ Source Account: 123456789012

Step 2: Select Source Aurora Cluster
✓ Selected: production-aurora-cluster

...

✓ Snapshot created
✓ Source copy complete
✓ Snapshot shared
✓ KMS grant created
✓ Target snapshot copied with default RDS KMS
✓ Cluster restored
✓ Instance created

╔════════════════════════════════════════════════╗
║         Migration Completed Successfully!     ║
╚════════════════════════════════════════════════╝

Target Cluster: restored-production-aurora-cluster
Target Instance: restored-production-aurora-cluster-instance-1
```

🤝 Contributing
---------------

Contributions are welcome! Please open an issue or submit a pull request.

📄 License
----------

MIT License - See LICENSE file for details

⚠️ Disclaimer
-------------

This tool is provided as-is. Always test in a non-production environment first. Ensure you have proper backups before migration.
