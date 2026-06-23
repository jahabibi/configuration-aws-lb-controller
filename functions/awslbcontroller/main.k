import models.io.crossplane.helmm.v1beta1 as helmv1beta1
import models.k8s.apimachinery.pkg.apis.meta.v1 as metav1

oxr = option("params").oxr # observed composite resource
_ocds = option("params").ocds # observed composed resources
_dxr = option("params").dxr # desired composite resource
dcds = option("params").dcds # desired composed resources

params = oxr.spec.parameters

_metadata = lambda name: str -> any {
    {
        name = name
        annotations = { "krm.kcl.dev/composition-resource-name" = name }
    }
}

# reclaimPolicy (PV vocabulary) -> Crossplane management policies.
_reclaimPolicy = params?.reclaimPolicy or "Delete"
_managementPolicies = ["Create", "Observe", "Update", "LateInitialize"] if _reclaimPolicy == "Retain" else ["*"]
_region = params?.region or ""
_type = params?.type or "alb"

# Inter-domain wiring: resolve the cluster from Compute's published status via
# extra-resources — the in-cluster connection config (Helm target), the vpc id,
# and the cluster name. No hardcoded ProviderConfig name, no raw vpcId.
_computeRefId = params?.computeRef?.id or ""
_extra = option("params").extraResources or {}
_computeXRs = _extra?["compute"] or []
_computeXR = _computeXRs[0] if len(_computeXRs) > 0 else {}
_computeStatus = _computeXR?.Resource?.status or _computeXR?.status or {}
_clusterName = _computeStatus?.clusterName or ""
_connectionConfigName = _computeStatus?.connectionConfigName or ""
_vpcId = _computeStatus?.networkId or ""

# Readiness: scale the controller up only once its identity is established.
_readyCondition = [c for c in (_ocds?.identity?.Resource?.status?.conditions or []) if c.type == "Ready" and c.status == "True"]
_isIdentityReady = len(_readyCondition) > 0

# L3 chart pin — an implementation detail, never a consumer-facing field.
_chart = {
    name = "aws-load-balancer-controller"
    repository = "https://aws.github.io/eks-charts"
    version = "1.8.3"
}

_items: [any] = [
    # Identity for the controller's ServiceAccount. Ingress owns this identity
    # need (a genuine ownership boundary), so it composes a nested Identity with
    # the curated aws-lb-controller role. Constructed untyped so this package
    # does not need the Identity model at build time.
    {
        apiVersion = "aws.platform.upbound.io/v1alpha1"
        kind = "Identity"
        metadata = _metadata("identity")
        spec = {
            parameters = {
                federationType = "pod-identity"
                role = "aws-lb-controller"
                reclaimPolicy = _reclaimPolicy
                if _region:
                    region = _region
                if _computeRefId:
                    computeRef = {id = _computeRefId}
            }
        }
    }

    # Helm Release for the controller.
    helmv1beta1.Release {
        metadata: _metadata("helmrelease")
        spec = {
            forProvider: {
                chart = _chart
                namespace: "kube-system"
                values: {
                    serviceAccount: {
                        name: "aws-load-balancer-controller"
                    }
                    # scale up once the identity is ready
                    replicaCount: 2 if _isIdentityReady else 0
                    # from Compute's published status (resolved via extra-resources)
                    if _clusterName:
                        clusterName = _clusterName
                    if _vpcId:
                        vpcId = _vpcId
                }
            }
            rollbackLimit: 3
            managementPolicies = _managementPolicies
            # in-cluster ProviderConfig published by Compute — not a hardcoded name
            if _connectionConfigName:
                providerConfigRef: {
                    kind = "ProviderConfig"
                    name = _connectionConfigName
                }
        }
    }

    # Usage: the Release must be deleted before the Compute (cluster).
    {
        apiVersion: "protection.crossplane.io/v1beta1"
        kind: "Usage"
        metadata: _metadata("usage-eks-by-awslbcontroller") | {
            namespace: oxr.metadata.namespace
        }
        spec: {
            replayDeletion: True
            by: {
                apiVersion: "helm.m.crossplane.io/v1beta1"
                kind: "Release"
                resourceSelector = {
                    matchControllerRef: True
                }
            }
            of: {
                apiVersion: "aws.platform.upbound.io/v1alpha1"
                kind: "Compute"
                resourceSelector: {
                    matchLabels: {
                        "platform.upbound.io/deletion-ordering": "enabled"
                    }
                }
            }
        }
    }
]

# Request the referenced Compute so its published status can be read.
if _computeRefId:
    _items += [{
        apiVersion: "meta.krm.kcl.dev/v1alpha1"
        kind: "ExtraResources"
        requirements: {
            "compute": {
                apiVersion: "aws.platform.upbound.io/v1alpha1"
                kind: "Compute"
                matchName: _computeRefId
            }
        }
    }]

# Structured status.
_dxr = _dxr | {
    status: {
        ready = _isIdentityReady
        roleArn = _ocds?.identity?.Resource?.status?.roleArn
    }
}
_items += [_dxr]
items = _items
