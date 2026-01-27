# configuration-aws-lb-controller

This repository provides a Crossplane configuration to install the AWS Load Balancer Controller in an EKS cluster, leveraging IAM Roles for Service Accounts (IRSA) for secure access to AWS without static credentials.

## Overview

This configuration creates a complete AWS Load Balancer Controller deployment with the following components:

- **AWSLBController**: The main composite resource that orchestrates the deployment of the AWS Load Balancer Controller
- **PodIdentity**: Creates IAM roles and pod identity associations for secure AWS API access using IRSA
- **Helm Release**: Deploys the AWS Load Balancer Controller Helm chart with proper configuration
- **Usage Resources**: Ensures proper deletion ordering between the controller and EKS cluster resources

The AWS Load Balancer Controller enables you to:
- Provision Application Load Balancers (ALB) for Kubernetes Ingress resources
- Provision Network Load Balancers (NLB) for Kubernetes Service resources of type LoadBalancer
- Support advanced ALB features like SSL termination, routing rules, and AWS WAF integration
- Automatically manage target registration and health checks

## Architecture

### Resource Dependencies

```
AWSLBController
├── PodIdentity (IAM Role + Pod Identity Association)
│   ├── IAM Role (with AWS Load Balancer Controller policy)
│   └── PodIdentityAssociation (links service account to IAM role)
├── Helm Release (AWS Load Balancer Controller chart)
│   └── Depends on: cluster name from PodIdentity status
└── Usage (ensures proper deletion ordering with EKS)
```

### Key Features

- **Security**: Uses IRSA (IAM Roles for Service Accounts) instead of static AWS credentials
- **Dependency Management**: Automatically waits for EKS cluster name before deploying the controller
- **Official Policy**: Uses the exact IAM policy from AWS Load Balancer Controller v2.8.3 repository
- **Proper Cleanup**: Usage resources ensure the controller is deleted before the EKS cluster

## Deployment

### Prerequisites

- An EKS cluster created by [configuration-aws-eks](https://github.com/upbound/configuration-aws-eks)
- Or any EKS resource with proper labels for selector matching

### Basic Deployment

1. **Create the AWSLBController resource:**

```yaml
apiVersion: aws.platform.upbound.io/v1alpha1
kind: AWSLBController
metadata:
  name: my-lb-controller
  labels:
    platform.upbound.io/deletion-ordering: enabled
spec:
  parameters:
    region: us-west-2
    clusterNameSelector:
      matchLabels:
        crossplane.io/composite: my-eks-cluster
    helm:
      providerConfigName: my-helm-provider-config
```

2. **The controller will automatically:**
   - Create an IAM role with the required permissions
   - Set up pod identity association for the service account
   - Deploy the AWS Load Balancer Controller when the cluster is ready
   - Configure proper cleanup ordering

### Advanced Configuration

You can customize the deployment with additional parameters:

```yaml
apiVersion: aws.platform.upbound.io/v1alpha1
kind: AWSLBController
metadata:
  name: my-lb-controller
spec:
  parameters:
    region: us-west-2
    # Specify cluster name directly (alternative to selector)
    clusterName: my-specific-cluster
    
    # Or use cluster reference
    clusterNameRef:
      name: my-cluster-resource
    
    # Customize Helm chart
    helm:
      providerConfigName: my-helm-config
      chart:
        version: "1.8.3"  # Specific chart version
    
    # Control resource cleanup
    deletionPolicy: Delete  # or "Orphan"
    
    # Specify AWS provider config
    providerConfigName: my-aws-provider-config
```

### Integration with EKS Configuration

This configuration is designed to work seamlessly with the Upbound EKS configuration:

```yaml
# Deploy EKS cluster first
apiVersion: aws.platform.upbound.io/v1alpha1
kind: EKS
metadata:
  name: my-cluster
  labels:
    platform.upbound.io/deletion-ordering: enabled
spec:
  parameters:
    id: my-cluster
    region: us-west-2
    # ... other EKS parameters

---
# Then deploy Load Balancer Controller
apiVersion: aws.platform.upbound.io/v1alpha1
kind: AWSLBController
metadata:
  name: my-lb-controller
  labels:
    platform.upbound.io/deletion-ordering: enabled
spec:
  parameters:
    region: us-west-2
    clusterNameSelector:
      matchLabels:
        crossplane.io/composite: my-cluster
    helm:
      providerConfigName: my-cluster  # EKS creates this automatically
```

## Testing

### Composition Tests

Run composition tests to validate the resource generation:

```bash
up test run tests/test-xawslbcontroller
```

This test verifies:
- PodIdentity resource is created with correct IAM policy
- Helm Release resource is created with proper configuration
- Usage resource is created for deletion ordering

### End-to-End Tests

Run full end-to-end tests with real AWS resources:

```bash
# Set up credentials
export UPTEST_CLOUD_CREDENTIALS=$(cat ~/.aws/credentials)

# Run E2E tests
up test run tests/e2etest-xawslbcontroller --e2e
```

The E2E test creates:
- Network (VPC, subnets, security groups)
- EKS (EKS cluster with node groups)
- AWSLBController (Load Balancer Controller)

### Manual Verification

After deployment, verify the controller is working:

```bash
# Check controller pods
kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-load-balancer-controller

# Check controller logs
kubectl logs -n kube-system deployment/aws-load-balancer-controller

# Test ALB creation with an Ingress
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: test-alb
  annotations:
    kubernetes.io/ingress.class: alb
    alb.ingress.kubernetes.io/scheme: internet-facing
    alb.ingress.kubernetes.io/target-type: ip
spec:
  rules:
  - http:
      paths:
      - path: /
        pathType: Prefix
        backend:
          service:
            name: my-service
            port:
              number: 80
EOF
```

## Troubleshooting

### Common Issues

1. **"Chart cannot be installed without a valid clusterName!"**
   - The controller waits for the PodIdentity to provide the actual cluster name
   - Check that your EKS cluster is ready and the pod identity is configured

2. **IAM permission errors**
   - The configuration uses the official AWS Load Balancer Controller IAM policy
   - Ensure your AWS provider has sufficient permissions to create IAM roles

3. **Helm provider configuration missing**
   - If using EKS, the Helm provider config is created automatically
   - For custom setups, ensure the Helm provider config exists

### Debugging

```bash
# Check AWSLBController status
kubectl describe xawslbcontroller my-lb-controller

# Check PodIdentity status
kubectl describe xpodidentity

# Check Helm Release status
kubectl describe release

# Check controller deployment
kubectl describe deployment aws-load-balancer-controller -n kube-system
```

## Dependencies

This configuration depends on:

- **configuration-aws-eks-pod-identity** (v0.8.1): Provides PodIdentity for IRSA setup
- **provider-helm**: Deploys the AWS Load Balancer Controller Helm chart
- **function-auto-ready**: Ensures resources are marked ready when appropriate

## Version Information

- **Helm Chart**: aws-load-balancer-controller v1.8.3
- **Application**: AWS Load Balancer Controller v2.8.3
- **IAM Policy**: From kubernetes-sigs/aws-load-balancer-controller v2.8.3

## Next Steps

Consider these enhancements for production use:

1. **Monitoring Integration**: Add ServiceMonitor resources for Prometheus monitoring
2. **Custom Webhook Configuration**: Configure admission webhooks for advanced validation
3. **Multi-Region Support**: Extend for multi-region EKS deployments
4. **Resource Tagging**: Add comprehensive tagging for cost management and governance
5. **Network Policy Integration**: Configure network policies for additional security

## Contributing

This configuration follows the Upbound DevEx patterns. For contributions:

1. Test changes with `up test run tests/*`
2. Ensure examples are updated to match any API changes
3. Update documentation for new parameters or features
4. Follow RFC 1123 naming conventions for all resources

For more information about Crossplane and Upbound configurations, visit:
- [Crossplane Documentation](https://docs.crossplane.io/)
- [Upbound Documentation](https://docs.upbound.io/)
- [AWS Load Balancer Controller Documentation](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
