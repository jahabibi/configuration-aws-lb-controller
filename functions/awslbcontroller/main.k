import models.io.upbound.platform.aws.v1alpha1 as awsv1alpha1
import models.io.crossplane.helmm.v1beta1 as helmv1beta1
import models.k8s.apimachinery.pkg.apis.meta.v1 as metav1

import json
import iam_policy


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

_defaults = {
    managementPolicies = params.managementPolicies
    if params.providerConfigName:
        providerConfigRef = {
            kind = "ProviderConfig"
            name = params.providerConfigName
        }
}

# Get cluster name from observed PodIdentity (only available after it's created)
_observedClusterName = _ocds?.podidentity?.Resource?.status?.podIdentity?.clusterName

# Check if PodIdentity is ready by checking if Ready condition exists with True status
_readyCondition = [condition for condition in (_ocds?.podidentity?.Resource?.status?.conditions or []) if condition.type == "Ready" and condition.status == "True"]
_isPodIdentityReady = len(_readyCondition) > 0

# Convert imported KCL policy data back to JSON string
_awsLbControllerPolicy = json.encode(iam_policy.aws_lb_controller_policy)

_items = [
    # Pod Identity for AWS Load Balancer Controller
    awsv1alpha1.PodIdentity {
        metadata: _metadata("podidentity")
        spec.parameters = _defaults | {
            region: params.region
            serviceAccount: {
                name: "aws-load-balancer-controller"
                namespace: "kube-system"
            }
            inlinePolicy: [
                {
                    name: "aws-lb-controller-policy"
                    policy: _awsLbControllerPolicy
                }
            ]
            managementPolicies = params.managementPolicies
            
            if params.clusterName: 
                clusterName = params.clusterName
            if params.clusterNameRef: 
                clusterNameRef = params.clusterNameRef
            if params.clusterNameSelector: 
                clusterNameSelector = params.clusterNameSelector
        }
    },

    # Helm Release for AWS Load Balancer Controller
    helmv1beta1.Release {
        metadata: _metadata("helmrelease")
        spec = {
            forProvider: {
                chart = {
                    name = params.helm.chart.name 
                    repository = params.helm.chart.repo 
                    version = params.helm.chart.version 
                }
                namespace: "kube-system"
                values: {
                    serviceAccount: {
                        name: "aws-load-balancer-controller"
                    }
                    # Set replicaCount to 2 when PodIdentity is ready, otherwise 0
                    replicaCount: 2 if _isPodIdentityReady else 0
                    
                    # Only set clusterName if available from observed PodIdentity
                    if _observedClusterName:
                        clusterName = _observedClusterName
                    
                    # Set VPC ID if provided to avoid EC2 metadata discovery
                    if params.vpcId: vpcId = params.vpcId
                }
            }
            rollbackLimit: 3
            managementPolicies = params.managementPolicies or ["*"]

            if params.helm.providerConfigName:
                providerConfigRef: {
                    kind = "ProviderConfig"
                    name = params.helm.providerConfigName
                }
        }
    },
    
    # Usage resource to ensure proper deletion ordering with EKS clusters
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
                resourceSelector: {
                    matchControllerRef: True
                }
            }
            of: {
                apiVersion: "aws.platform.upbound.io/v1alpha1"
                kind: "EKS"
                resourceSelector: {
                    matchLabels: {
                        "platform.upbound.io/deletion-ordering": "enabled"
                    }
                }
            }
        }
    }
]

items = _items
