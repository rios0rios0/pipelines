# Azure DevOps Go Lambda Deployment Guide

This guide explains how to use the Azure DevOps pipeline templates to build and deploy Go-based AWS Lambda functions.

## Table of Contents

- [Overview](#overview)
- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Deployment Strategies](#deployment-strategies)
- [Configuration Options](#configuration-options)
- [AWS Service Connection Setup](#aws-service-connection-setup)
- [IAM Permissions](#iam-permissions)
- [Examples](#examples)
- [Troubleshooting](#troubleshooting)

## Overview

The pipeline templates provide two main approaches for deploying Go Lambda functions:

1. **ZIP-based deployment** (`go-lambda.yaml`) - Direct deployment using AWS CLI
2. **SAM-based deployment** (`go-lambda-sam.yaml`) - Deployment using AWS SAM (Serverless Application Model)

Both templates include the full 5-stage pipeline:
1. 🔍 Code Check (linting, formatting)
2. 🔒 Security (SAST, secret scanning)
3. 🧪 Tests (unit tests, coverage)
4. 📊 Management (dependency tracking, SBOM)
5. 🚀 Delivery & Deployment (build and deploy to AWS Lambda)

## Prerequisites

### Required Software
- Azure DevOps project with pipelines enabled
- GitHub service connection (to access the pipelines repository)
- AWS service connection (recommended) or AWS credentials

### Project Structure
Your Go Lambda project should have:
- `go.mod` and `go.sum` files at the root
- Main package that serves as the Lambda handler
- (Optional for SAM) `template.yaml` - SAM template
- (Optional for SAM) `samconfig.toml` - SAM configuration

### Container Images
The templates use pre-built container images:
- **golang:1.19-awscli** - Includes Go 1.19, AWS CLI, and AWS SAM CLI
- **awscli:latest** - Includes AWS CLI and SAM CLI for deployment

## Quick Start

### 1. Create Azure Pipeline Configuration

Create `azure-pipelines.yml` in your repository:

```yaml
trigger:
  branches:
    include: [ main ]
  tags:
    include: [ '*' ]

pool:
  vmImage: 'ubuntu-latest'

variables:
  - group: 'aws-lambda-variables'

resources:
  repositories:
    - repository: 'pipelines'
      type: 'github'
      name: 'rios0rios0/pipelines'
      endpoint: 'YOUR_GITHUB_SERVICE_CONNECTION'

stages:
  - template: 'azure-devops/golang/go-lambda.yaml@pipelines'
    parameters:
      LAMBDA_FUNCTION_NAME: 'my-lambda-function'
      AWS_REGION: 'us-east-1'
      AWS_SERVICE_CONNECTION: 'AWS-Service-Connection'
      DEPLOY_STRATEGY: 'zip'
```

### 2. Configure Service Connection

In Azure DevOps:
1. Go to Project Settings → Service Connections
2. Create a new AWS service connection
3. Provide your AWS credentials or use IAM role
4. Name it (e.g., 'AWS-Service-Connection')

### 3. Run the Pipeline

Commit and push your changes. The pipeline will automatically:
- Lint and test your code
- Scan for security vulnerabilities
- Build the Lambda function for Linux
- Deploy to AWS Lambda

## Deployment Strategies

### ZIP Deployment

Best for simple Lambda functions without complex infrastructure.

```yaml
stages:
  - template: 'azure-devops/golang/go-lambda.yaml@pipelines'
    parameters:
      LAMBDA_FUNCTION_NAME: 'my-function'
      AWS_REGION: 'us-east-1'
      AWS_SERVICE_CONNECTION: 'AWS-Service-Connection'
      DEPLOY_STRATEGY: 'zip'
      GOARCH: 'amd64'  # or 'arm64' for ARM-based Lambda
```

**How it works:**
1. Compiles Go binary with `GOOS=linux` and specified `GOARCH`
2. Creates a ZIP file containing the binary
3. Deploys using `aws lambda update-function-code`

**Advantages:**
- Simple and fast
- No additional configuration needed
- Works with existing Lambda functions

**Limitations:**
- Requires function to already exist (unless `CREATE_IF_MISSING: true`)
- Manual configuration of Lambda settings outside pipeline

### SAM Deployment

Best for complex serverless applications with multiple functions, APIs, and infrastructure.

```yaml
stages:
  - template: 'azure-devops/golang/go-lambda-sam.yaml@pipelines'
    parameters:
      S3_BUCKET: 'my-deployment-bucket'
      AWS_REGION: 'us-east-1'
      AWS_SERVICE_CONNECTION: 'AWS-Service-Connection'
      SAM_CONFIG_ENV: 'default'
```

**How it works:**
1. Compiles Go binary using `sam build`
2. Packages artifacts and uploads to S3 using `sam package`
3. Deploys using CloudFormation via `sam deploy`

**Advantages:**
- Infrastructure as code (template.yaml)
- Manages entire serverless application
- Automatic rollback on failure
- Supports complex architectures (APIs, multiple functions, etc.)

**Requirements:**
- `template.yaml` - SAM/CloudFormation template
- `samconfig.toml` - SAM configuration
- S3 bucket for artifact storage
- CloudFormation permissions

## Configuration Options

### Common Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `LAMBDA_FUNCTION_NAME` | string | (required) | Name of the Lambda function |
| `AWS_REGION` | string | `us-east-1` | AWS region for deployment |
| `AWS_SERVICE_CONNECTION` | string | `''` | Azure DevOps AWS service connection name |
| `LAMBDA_HANDLER` | string | `bootstrap` | Handler name (use 'bootstrap' for custom runtime) |
| `LAMBDA_RUNTIME` | string | `provided.al2023` | Lambda runtime identifier |
| `GOARCH` | string | `amd64` | Target architecture (amd64 or arm64) |
| `BUILD_FLAGS` | string | `-ldflags='-w -s'` | Go build flags |

### ZIP Deployment Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `LAMBDA_TIMEOUT` | string | `30` | Function timeout in seconds |
| `LAMBDA_MEMORY_SIZE` | string | `128` | Memory allocation in MB |
| `LAMBDA_ENV_VARS` | string | `''` | Environment variables (format: KEY1=VAL1,KEY2=VAL2) |
| `CREATE_IF_MISSING` | boolean | `false` | Create function if it doesn't exist |

### SAM Deployment Parameters

| Parameter | Type | Default | Description |
|-----------|------|---------|-------------|
| `S3_BUCKET` | string | (required) | S3 bucket for SAM artifacts |
| `S3_KEY_PREFIX` | string | `''` | S3 key prefix for artifacts |
| `SAM_CONFIG_ENV` | string | `default` | Environment in samconfig.toml |

## AWS Service Connection Setup

### Option 1: AWS Service Connection (Recommended)

1. In Azure DevOps, go to Project Settings → Service Connections
2. Click "New service connection" → "AWS"
3. Choose authentication method:
   - **Access Key ID and Secret Access Key**: Provide AWS credentials
   - **Assume Role**: Use IAM role (recommended for security)
4. Name your connection (e.g., "AWS-Production")
5. Test the connection

### Option 2: Environment Variables

If not using service connection, set these variables in a variable group:

- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_SESSION_TOKEN` (if using temporary credentials)

**Note:** This is less secure; use service connections when possible.

## IAM Permissions

### Minimum Permissions for ZIP Deployment

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "lambda:UpdateFunctionCode",
        "lambda:UpdateFunctionConfiguration",
        "lambda:GetFunction"
      ],
      "Resource": "arn:aws:lambda:*:*:function:your-function-name"
    }
  ]
}
```

### Additional Permissions for Creating Functions

```json
{
  "Effect": "Allow",
  "Action": [
    "lambda:CreateFunction",
    "iam:PassRole"
  ],
  "Resource": [
    "arn:aws:lambda:*:*:function:your-function-name",
    "arn:aws:iam::*:role/your-lambda-execution-role"
  ]
}
```

### Permissions for SAM Deployment

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "cloudformation:CreateChangeSet",
        "cloudformation:DescribeChangeSet",
        "cloudformation:ExecuteChangeSet",
        "cloudformation:DescribeStacks",
        "cloudformation:GetTemplateSummary"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:GetObject"
      ],
      "Resource": "arn:aws:s3:::your-deployment-bucket/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "lambda:*"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "iam:PassRole"
      ],
      "Resource": "*"
    }
  ]
}
```

**Security Best Practice:** Restrict resource ARNs to specific functions/stacks rather than using `*`.

## Examples

### Example 1: Simple Lambda Function (ZIP)

**azure-pipelines.yml:**
```yaml
trigger:
  branches:
    include: [ main ]

pool:
  vmImage: 'ubuntu-latest'

resources:
  repositories:
    - repository: 'pipelines'
      type: 'github'
      name: 'rios0rios0/pipelines'
      endpoint: 'GitHub-Connection'

variables:
  - group: 'aws-production'

stages:
  - template: 'azure-devops/golang/go-lambda.yaml@pipelines'
    parameters:
      LAMBDA_FUNCTION_NAME: 'hello-world-function'
      AWS_REGION: 'us-west-2'
      AWS_SERVICE_CONNECTION: 'AWS-Prod'
      DEPLOY_STRATEGY: 'zip'
      LAMBDA_TIMEOUT: '10'
      LAMBDA_MEMORY_SIZE: '256'
```

### Example 2: ARM64 Lambda Function

**azure-pipelines.yml:**
```yaml
stages:
  - template: 'azure-devops/golang/go-lambda.yaml@pipelines'
    parameters:
      LAMBDA_FUNCTION_NAME: 'arm64-function'
      AWS_REGION: 'us-east-1'
      AWS_SERVICE_CONNECTION: 'AWS-Prod'
      GOARCH: 'arm64'
      LAMBDA_RUNTIME: 'provided.al2023'
```

### Example 3: Lambda with Environment Variables

**azure-pipelines.yml:**
```yaml
stages:
  - template: 'azure-devops/golang/go-lambda.yaml@pipelines'
    parameters:
      LAMBDA_FUNCTION_NAME: 'api-handler'
      AWS_REGION: 'eu-west-1'
      AWS_SERVICE_CONNECTION: 'AWS-Prod'
      LAMBDA_ENV_VARS: 'ENV=production,LOG_LEVEL=info,DB_HOST=db.example.com'
      LAMBDA_TIMEOUT: '30'
      LAMBDA_MEMORY_SIZE: '512'
```

### Example 4: SAM Deployment with Multiple Environments

**azure-pipelines.yml:**
```yaml
trigger:
  branches:
    include: [ main, develop ]

pool:
  vmImage: 'ubuntu-latest'

resources:
  repositories:
    - repository: 'pipelines'
      type: 'github'
      name: 'rios0rios0/pipelines'
      endpoint: 'GitHub-Connection'

variables:
  - ${{ if eq(variables['Build.SourceBranchName'], 'main') }}:
    - group: 'aws-production'
    - name: SAM_ENV
      value: 'prod'
  - ${{ else }}:
    - group: 'aws-development'
    - name: SAM_ENV
      value: 'dev'

stages:
  - template: 'azure-devops/golang/go-lambda-sam.yaml@pipelines'
    parameters:
      S3_BUCKET: 'my-sam-deployments'
      AWS_REGION: 'us-east-1'
      AWS_SERVICE_CONNECTION: 'AWS-Service-Connection'
      SAM_CONFIG_ENV: $(SAM_ENV)
```

**samconfig.toml:**
```toml
version = 0.1

[dev]
[dev.deploy.parameters]
stack_name = "my-app-dev"
region = "us-east-1"
capabilities = "CAPABILITY_IAM"
s3_bucket = "my-sam-deployments"
s3_prefix = "dev"

[prod]
[prod.deploy.parameters]
stack_name = "my-app-prod"
region = "us-east-1"
capabilities = "CAPABILITY_IAM"
s3_bucket = "my-sam-deployments"
s3_prefix = "prod"
```

### Example 5: Multi-Stage Pipeline with Manual Approval

**azure-pipelines.yml:**
```yaml
trigger:
  branches:
    include: [ main ]

pool:
  vmImage: 'ubuntu-latest'

resources:
  repositories:
    - repository: 'pipelines'
      type: 'github'
      name: 'rios0rios0/pipelines'
      endpoint: 'GitHub-Connection'

stages:
  # Deploy to staging automatically
  - template: 'azure-devops/golang/go-lambda.yaml@pipelines'
    parameters:
      LAMBDA_FUNCTION_NAME: 'my-function-staging'
      AWS_REGION: 'us-east-1'
      AWS_SERVICE_CONNECTION: 'AWS-Staging'
      DEPLOY_STRATEGY: 'zip'

  # Deploy to production with manual approval
  - stage: 'production_approval'
    displayName: 'Production Approval'
    dependsOn: 'deployment'
    jobs:
      - job: 'wait_for_approval'
        displayName: 'Wait for Production Approval'
        pool: server
        steps:
          - task: ManualValidation@0
            inputs:
              notifyUsers: 'team@example.com'
              instructions: 'Please approve production deployment'

  - template: 'azure-devops/golang/go-lambda.yaml@pipelines'
    parameters:
      LAMBDA_FUNCTION_NAME: 'my-function-production'
      AWS_REGION: 'us-east-1'
      AWS_SERVICE_CONNECTION: 'AWS-Production'
      DEPLOY_STRATEGY: 'zip'
```

## Troubleshooting

### Common Issues

#### Error: "Function not found"

**Problem:** Lambda function doesn't exist.

**Solution:**
- Set `CREATE_IF_MISSING: true` parameter
- Ensure `LAMBDA_ROLE_ARN` environment variable is set
- Or create the function manually in AWS Console first

#### Error: "Access Denied"

**Problem:** Insufficient IAM permissions.

**Solution:**
- Review and update IAM policy (see [IAM Permissions](#iam-permissions))
- Verify service connection credentials are correct
- Check if MFA or IP restrictions apply

#### Error: "Invalid parameter: Runtime"

**Problem:** Incorrect runtime specified.

**Solution:**
- For custom Go runtime, use `provided.al2023` or `provided.al2`
- For managed Go runtime (deprecated), use `go1.x`
- Ensure handler is set to `bootstrap` for custom runtime

#### SAM Build Fails

**Problem:** SAM cannot find template or build fails.

**Solution:**
- Ensure `template.yaml` exists in repository root
- Verify Go module structure is correct
- Check SAM template syntax with `sam validate`

#### Container Pull Errors

**Problem:** Cannot pull golang:1.19-awscli container.

**Solution:**
- Verify agent has internet access
- Check if container registry is accessible: `ghcr.io/rios0rios0/pipelines`
- Use alternative container version if needed

### Debugging Tips

1. **Enable Verbose Logging:**
   ```yaml
   - script: |
       set -x  # Enable bash debugging
       # Your commands here
   ```

2. **Check AWS CLI Configuration:**
   ```yaml
   - script: |
       aws --version
       aws sts get-caller-identity
       aws lambda list-functions --region us-east-1
   ```

3. **Verify Build Artifacts:**
   ```yaml
   - script: |
       ls -lah $(Build.ArtifactStagingDirectory)/
       file $(Build.ArtifactStagingDirectory)/lambda-function.zip
       unzip -l $(Build.ArtifactStagingDirectory)/lambda-function.zip
   ```

4. **Test Lambda Locally with SAM:**
   ```bash
   sam build
   sam local invoke
   ```

### Getting Help

- Check the main repository README: [rios0rios0/pipelines](https://github.com/rios0rios0/pipelines)
- Review Azure DevOps pipeline logs for detailed error messages
- Verify AWS CloudWatch Logs for Lambda execution errors
- Check AWS CloudFormation stack events for SAM deployment issues

## Additional Resources

- [AWS Lambda Go Documentation](https://docs.aws.amazon.com/lambda/latest/dg/lambda-golang.html)
- [AWS SAM Documentation](https://docs.aws.amazon.com/serverless-application-model/)
- [Azure DevOps YAML Schema](https://docs.microsoft.com/en-us/azure/devops/pipelines/yaml-schema)
- [Go Lambda Custom Runtime](https://github.com/aws/aws-lambda-go)
