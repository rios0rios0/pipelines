# Go Lambda Example Configuration

This directory contains example configuration files for deploying a Go Lambda function using Azure DevOps pipelines.

## Files

- `template.yaml` - AWS SAM template defining the Lambda function and API Gateway
- `samconfig.toml` - SAM CLI configuration for different environments (dev, prod)
- `azure-pipelines.yml` - Azure DevOps pipeline configuration

## Usage

### For SAM Deployment

1. Copy these files to your Go Lambda project root directory
2. Update `template.yaml` with your function specifications
3. Update `samconfig.toml` with your S3 bucket names and stack names
4. Update `azure-pipelines.yml` with your service connection names
5. Commit and push to trigger the pipeline

### For ZIP Deployment

If you prefer ZIP deployment instead of SAM, use this `azure-pipelines.yml`:

```yaml
trigger:
  branches:
    include: [ main ]

pool:
  vmImage: 'ubuntu-latest'

variables:
  - group: 'aws-production'

resources:
  repositories:
    - repository: 'pipelines'
      type: 'github'
      name: 'rios0rios0/pipelines'
      endpoint: 'YOUR_GITHUB_SERVICE_CONNECTION'

stages:
  - template: 'azure-devops/golang/go-lambda.yaml@pipelines'
    parameters:
      LAMBDA_FUNCTION_NAME: 'my-go-lambda-function'
      AWS_REGION: 'us-east-1'
      AWS_SERVICE_CONNECTION: 'AWS-Service-Connection'
      DEPLOY_STRATEGY: 'zip'
```

## Required Setup

### Azure DevOps

1. **GitHub Service Connection**
   - Go to Project Settings → Service Connections
   - Create new GitHub service connection
   - Authorize access to the pipelines repository

2. **AWS Service Connection**
   - Go to Project Settings → Service Connections
   - Create new AWS service connection
   - Provide AWS credentials or configure assume role

3. **Variable Groups**
   - Create variable groups for different environments:
     - `aws-development` (for dev branch deployments)
     - `aws-production` (for main branch and tag deployments)
   - Add variables as needed (optional if using service connection)

### AWS

1. **S3 Bucket** (for SAM deployment)
   - Create S3 bucket for SAM artifacts
   - Update bucket name in `samconfig.toml`

2. **IAM Permissions**
   - Ensure the AWS credentials/role has permissions to:
     - Deploy CloudFormation stacks
     - Create/update Lambda functions
     - Upload to S3
     - Create API Gateway resources (if using API events)

See the main documentation at `.docs/azure-devops-go-lambda.md` for detailed IAM policies.

## Testing Locally

Before deploying, you can test the SAM template locally:

```bash
# Build the function
sam build

# Test locally
sam local invoke

# Test with API Gateway
sam local start-api
curl http://localhost:3000/hello
```

## Additional Resources

- [Full Documentation](../../azure-devops-go-lambda.md)
- [AWS SAM Documentation](https://docs.aws.amazon.com/serverless-application-model/)
- [Azure DevOps Pipelines](https://docs.microsoft.com/en-us/azure/devops/pipelines/)
