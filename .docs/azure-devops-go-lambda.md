# Azure DevOps Go Lambda Pipeline

This document describes how to use the Go Lambda pipeline templates for Azure DevOps.

## Table of Contents

- [Overview](#overview)
- [IAM Permissions](#iam-permissions)
- [Examples](#examples)

## Overview

The Go Lambda pipeline supports two deployment strategies:

- **ZIP deployment** (`go-lambda.yaml`) — Builds a Go binary, packages it as a ZIP, and deploys directly to AWS Lambda via the AWS CLI.
- **SAM deployment** (`go-lambda-sam.yaml`) — Uses AWS SAM to build, package, and deploy the Lambda function with CloudFormation.

Both strategies include the standard pipeline stages: code check, security, tests, management, delivery, and deployment.

## IAM Permissions

The pipeline requires AWS credentials with the following permissions:

- **Lambda** — `GetFunction`, `CreateFunction`, `UpdateFunctionCode`, `UpdateFunctionConfiguration`
- **S3** — `GetObject`, `PutObject`, `ListBucket` (for storing deployment artifacts)
- **CloudFormation** — `CreateStack`, `UpdateStack`, `DescribeStacks`, `CreateChangeSet`, `ExecuteChangeSet` (SAM deployments only)
- **IAM** — `PassRole` to `lambda.amazonaws.com` (when creating new functions)

See [`iam-policy-example.json`](.docs/examples/go-lambda-example/iam-policy-example.json) for a complete IAM policy.

## Examples

### ZIP Deployment

```yaml
stages:
  - template: 'azure-devops/golang/go-lambda.yaml@pipelines'
    parameters:
      LAMBDA_FUNCTION_NAME: 'my-go-function'
      AWS_REGION: 'us-east-1'
      AWS_SERVICE_CONNECTION: 'my-aws-connection'
```

### SAM Deployment

```yaml
stages:
  - template: 'azure-devops/golang/go-lambda-sam.yaml@pipelines'
    parameters:
      S3_BUCKET: 'my-deployment-bucket'
      SAM_CONFIG_ENV: 'default'
```

See the [complete example](.docs/examples/go-lambda-example/) for full pipeline configuration files.
