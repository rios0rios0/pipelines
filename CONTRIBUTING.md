# Contributing

We welcome contributions from everyone. By participating in this project, you agree to abide by our Code of Conduct.

## How to Contribute

### Reporting Bugs

If you find a bug, please report it by opening an issue on our GitHub repository. Include as much detail as possible to help us understand and reproduce the issue.

### Suggesting Enhancements

We welcome suggestions for new features or improvements. Please open an issue on our GitHub repository and describe your idea in detail.

### Compatibility Between Azure DevOps, GitLab, and GitHub

- **Ensure Compatibility**: When making changes, ensure that the pipelines remain compatible with Azure DevOps, GitLab, and GitHub. Test your changes across all three platforms.

### Pipeline Security Best Practices

1. **Secure Coding Practices**: Follow secure coding standards to avoid common vulnerabilities such as SQL injection and cross-site scripting (XSS)⁴(https://www.crowdstrike.com/en-us/cybersecurity-101/cloud-security/ci-cd-security-best-practices/).
2. **Regular Security Audits**: Perform regular security audits and assessments to identify and mitigate vulnerabilities⁴(https://www.crowdstrike.com/en-us/cybersecurity-101/cloud-security/ci-cd-security-best-practices/).
3. **Access Controls**: Implement strict access controls to manage who can access tools and resources within the CI/CD pipeline⁴(https://www.crowdstrike.com/en-us/cybersecurity-101/cloud-security/ci-cd-security-best-practices/).
4. **Environment Separation**: Maintain separate development, testing, and production environments to prevent cross-environment contamination⁵(https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/secure/best-practices/secure-devops).
5. **Secure Secrets Management**: Use secure methods to manage secrets and credentials, avoiding hard-coded secrets in the codebase⁵(https://learn.microsoft.com/en-us/azure/cloud-adoption-framework/secure/best-practices/secure-devops).

### Supply Chain Security

1. **Monitor Dependencies**: Regularly monitor and update dependencies to ensure they are free from known vulnerabilities⁶(https://www.nist.gov/news-events/news/2022/05/nist-updates-cybersecurity-guidance-supply-chain-risk-management).
2. **Vendor Assessment**: Assess and monitor the security practices of third-party vendors and suppliers⁷(https://csrc.nist.gov/pubs/sp/800/161/r1/final).
3. **Incident Response**: Have a plan in place for responding to security incidents related to the supply chain⁸(https://www.bluevoyant.com/knowledge-center/supply-chain-security-why-its-important-7-best-practices).
4. **Compliance**: Ensure compliance with relevant security standards and regulations⁶(https://www.nist.gov/news-events/news/2022/05/nist-updates-cybersecurity-guidance-supply-chain-risk-management).

### Documentation

Update documentation to reflect any changes or new features you add. This includes updating README files, comments, and any other relevant documentation.

### Testing Requirements

Before submitting any changes to pipeline scripts or templates:

1. **Run the test suite**: Execute `make test` to run all validation tests
2. **Test Go script changes**: For changes to `global/scripts/languages/golang/test/run.sh`, run `make test-go-script`
3. **Create test scenarios**: When adding new features, create corresponding test scenarios in the validation scripts
4. **Validate across platforms**: Test pipeline templates across GitHub Actions, GitLab CI, and Azure DevOps
5. **Coverage verification**: Ensure that coverage reporting includes all packages, not just those with tests

### Required Documentation Updates

**MANDATORY**: When making any changes, you MUST update the following:

1. **CHANGELOG.md**: Add your changes to the appropriate version section
2. **Documentation**: Update relevant README files and comments
3. **Test scenarios**: Update or add test cases for new functionality

## Review Process

All contributions will be reviewed by project maintainers. We aim to provide feedback within a week. Please be patient as we review your contributions.
