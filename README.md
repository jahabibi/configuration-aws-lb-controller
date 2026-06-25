# configuration-aws-lb-controller

This repository provides a Crossplane configuration that installs cluster
ingress / load-balancing into an EKS cluster. It exposes a single, intent-based
`Ingress` API and resolves everything else — the cluster connection, the VPC,
the IAM identity, and the controller chart — from the platform, so consumers
never touch implementation machinery.

The current implementation is the **AWS Load Balancer Controller** (deployed via
Helm), wired up with **IAM Roles for Service Accounts (IRSA)** via pod identity
for secure access to AWS without static credentials. That implementation is an
L3 detail, not part of the API.

## Overview

The composite resource is `Ingress`. From a single `Ingress`, the composition
produces:

- **Identity**: a nested `Identity` XR (`federationType: pod-identity`,
  curated `aws-lb-controller` role) that establishes the controller's IRSA
  identity. This replaces hand-rolled IAM policy + pod-identity-association
  resources.
- **Helm Release**: deploys the AWS Load Balancer Controller chart. Cluster
  name, VPC id, region, and the in-cluster ProviderConfig are all resolved from
  the referenced Compute — none are supplied by the consumer.
- **Usage**: ensures the Helm Release is deleted before the Compute (cluster).

The AWS Load Balancer Controller enables you to:
- Provision Application Load Balancers (ALB) for Kubernetes Ingress resources
- Provision Network Load Balancers (NLB) for Kubernetes Service resources of type LoadBalancer
- Support advanced ALB features like SSL termination, routing rules, and AWS WAF integration
- Automatically manage target registration and health checks

## API

The `Ingress` API is intentionally small. It describes intent, not plumbing.

| Field | Type | Description |
|-------|------|-------------|
| `parameters.type` | enum `[alb]`, default `alb` | Ingress type. Implemented in L3; adding nginx or Gateway API later is an additive enum value, not a new API. |
| `parameters.computeRef.id` | string, **required** | Platform id (metadata name) of the `Compute` this ingress installs into. L3 resolves its published status — connection config, vpc id, cluster name, region. |
| `parameters.region` | string | Cloud region the controller runs in. Under pod identity, IMDS region introspection is blocked, so the controller is told the region explicitly. Falls back to the Compute's region if unset. |
| `parameters.reclaimPolicy` | enum `[Delete, Retain]`, default `Delete` | Outcome intent, using Kubernetes PersistentVolume vocabulary. The mapping to Crossplane management policies is owned by the composition. |
| `parameters.overrides.providerConfigName` | string | Bounded escape hatch — ProviderConfig for account/credential selection. Defaults to `default`. |

Status fields:

| Field | Type | Description |
|-------|------|-------------|
| `status.ready` | boolean | Whether the ingress controller's identity is established. |
| `status.roleArn` | string | ARN of the controller's IAM role (from the nested Identity). |

### What is intentionally *not* in the API

Compared to earlier versions, the following have been removed because they
leaked Crossplane and implementation details into the consumer-facing surface:

- `vpcId`, `clusterName`, `clusterNameRef`, `clusterNameSelector` — replaced by
  `computeRef.id`, with the cluster's details resolved from its published status.
- `helm.chart.*` (chart name/repo/version) — the chart is an L3 constant.
- `managementPolicies` — replaced by `reclaimPolicy` (`Delete`/`Retain`).
- `providerConfigName` (top-level) — moved under `overrides`.

## Architecture

### Resource Dependencies

```
Ingress
├── Identity (IRSA via pod identity, curated aws-lb-controller role)
├── Helm Release (AWS Load Balancer Controller chart)
│   ├── Gated on: Identity Ready (replicaCount 0 → 2)
│   └── Resolved from Compute status: clusterName, vpcId, region, connectionConfig
└── Usage (Release deleted before Compute)
```

### Cross-domain resolution

The composition references the `Compute` XR by platform id and reads its
published `status` (`clusterName`, `connectionConfigName`, `networkId`,
`region`). This lookup must be **namespace-scoped**, which is why the
composition function is implemented in **Python**
(`functions/awslbcontroller-py`) rather than the previous KCL function: the
`function-kcl` server bundled into `up` is too old to honour `matchNamespace`,
while the Python SDK speaks the Crossplane v2 `required_resources` mechanism
whose `ResourceSelector` carries a `namespace` field.

### Key Features

- **Intent-based API**: consumers declare *what* (an ingress on a cluster), not
  *how* (charts, IAM policy, provider configs).
- **Security**: IRSA via pod identity instead of static AWS credentials.
- **Readiness gating**: the Helm release starts at `replicaCount: 0` and scales
  to `2` only once the Identity reports `Ready`.
- **Proper cleanup**: a Usage resource ensures the controller is deleted before
  the EKS cluster.

## Deployment

### Prerequisites

- A `Compute` (EKS) XR created by the EKS configuration, publishing its cluster
  name, connection config, vpc id, and region in its status.
- A configured AWS `ProviderConfig` (named `default`, or set via
  `overrides.providerConfigName`).

### Basic Deployment

Create the `Ingress` resource, referencing the Compute by platform id:

```yaml
apiVersion: aws.platform.upbound.io/v1alpha1
kind: Ingress
metadata:
  name: my-ingress
  namespace: default
  labels:
    platform.upbound.io/deletion-ordering: enabled
spec:
  parameters:
    type: alb
    region: us-west-2
    # Reference the cluster by platform id; the composition resolves its
    # published status (connection config, vpc id, cluster name) — no raw
    # vpcId, no label selectors, no hardcoded ProviderConfig name.
    computeRef:
      id: my-compute
```

The composition will automatically:
- Establish the controller's IRSA identity (nested `Identity`)
- Resolve cluster name, VPC id, region, and the in-cluster ProviderConfig from
  the referenced Compute's status
- Deploy the AWS Load Balancer Controller, scaling it up once identity is ready
- Configure proper cleanup ordering

### Advanced Configuration

```yaml
apiVersion: aws.platform.upbound.io/v1alpha1
kind: Ingress
metadata:
  name: my-ingress
  namespace: default
spec:
  parameters:
    type: alb
    region: us-west-2
    computeRef:
      id: my-compute
    # Retain resources on delete instead of removing them
    reclaimPolicy: Retain
    # Bounded escape hatch for account/credential selection
    overrides:
      providerConfigName: my-aws-provider-config
```

## Testing

### Composition Tests

Run composition tests to validate the resource generation:

```bash
up test run tests/test-awslbcontroller
```

This test verifies, using a stand-in Compute supplied as an extra resource:
- The nested `Identity` is created with the curated `aws-lb-controller` role
- The Helm Release is created with the chart constant and placement resolved
  from the Compute status (cluster name, vpc id, region, ProviderConfig)
- The Usage resource is created for deletion ordering (Release before Compute)

### End-to-End Tests

Run full end-to-end tests with real AWS resources:

```bash
# Set up credentials
export UPTEST_CLOUD_CREDENTIALS=$(cat ~/.aws/credentials)

# Run E2E tests
up test run tests/e2etest-awslbcontroller --e2e
```

The E2E test deploys the full stack:
- Network (VPC, subnets, security groups)
- EKS cluster (publishes the connection config the Ingress consumes)
- Ingress (the AWS Load Balancer Controller)

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

1. **Controller stays at `replicaCount: 0`**
   - The Helm release is gated on the nested `Identity` reporting `Ready`.
   - Check the `Identity` and confirm the pod identity association succeeded.

2. **Cluster name / VPC id not resolved**
   - The composition reads these from the referenced Compute's status. Confirm
     `computeRef.id` matches a `Compute` in the same namespace and that the
     Compute has published `clusterName`, `connectionConfigName`, `networkId`.

3. **IAM permission errors**
   - The IRSA identity is owned by the nested `Identity` (curated
     `aws-lb-controller` role). Ensure the AWS ProviderConfig has permission to
     create IAM roles and pod identity associations.

### Debugging

```bash
# Check Ingress status
kubectl describe ingress.aws.platform.upbound.io my-ingress

# Check the nested Identity status
kubectl describe identity

# Check Helm Release status
kubectl describe release

# Check controller deployment
kubectl describe deployment aws-load-balancer-controller -n kube-system
```

## Dependencies

This configuration depends on:

- **configuration-aws-eks-pod-identity** (v3.0.0-dev.11): provides the
  `Identity` abstraction for IRSA setup
- **provider-helm** (v1): deploys the AWS Load Balancer Controller Helm chart
- **function-auto-ready**: marks resources ready when appropriate

The composition function itself (`functions/awslbcontroller-py`) is a Python
function bundled with the configuration.

## Version Information

- **Helm Chart**: aws-load-balancer-controller v1.8.3
- **Application**: AWS Load Balancer Controller v2.8.3

## Contributing

This configuration follows the Upbound DevEx patterns. For contributions:

1. Test changes with `up test run tests/*`
2. Ensure examples are updated to match any API changes
3. Update documentation for new parameters or features
4. Keep the API intent-based — avoid leaking Crossplane or implementation
   machinery (chart versions, provider configs, management policies) into the
   `Ingress` surface
5. Follow RFC 1123 naming conventions for all resources

For more information about Crossplane and Upbound configurations, visit:
- [Crossplane Documentation](https://docs.crossplane.io/)
- [Upbound Documentation](https://docs.upbound.io/)
- [AWS Load Balancer Controller Documentation](https://kubernetes-sigs.github.io/aws-load-balancer-controller/)
</content>
</invoke>
