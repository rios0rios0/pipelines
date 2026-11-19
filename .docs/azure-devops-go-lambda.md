# Azure DevOps Go Lambda Pipeline

This document describes how to use the Go Lambda pipeline templates for Azure DevOps.

## Table of Contents

- [Overview](#overview)
- [IAM Permissions](#iam-permissions)
- [Credential Lifetime](#credential-lifetime)
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

## Credential Lifetime

The SAM delivery builds the function (`sam build`) in a step of its own, which holds no AWS credentials, and only then packages it (`sam package`) in the step that does: the `AWSShellScript@1` task of `AWS_SERVICE_CONNECTION`, or the environment-variable step when no service connection is set. The task takes the service connection's credentials once, as it starts, and when the connection assumes a role they last 15 minutes unless the pipeline sets the `aws.rolecredential.maxduration` variable (in seconds, up to the role's maximum session duration). A build that takes nearly that long therefore no longer leaves the packaging with expired credentials (`ExpiredToken`).

The deployment's `sam deploy` holds credentials of the same lifetime while it waits for the CloudFormation stack update, so a stack whose update can take longer than 15 minutes needs `aws.rolecredential.maxduration` raised.

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
