import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1
import models.io.crossplane.helmm.v1beta1 as helmv1beta1
import models.k8s.apimachinery.pkg.apis.meta.v1 as metav1

# Stand-in for the referenced Compute's published status, supplied as an extra
# resource so the composition resolves the Helm target (connectionConfigName),
# the vpc id (networkId) and the cluster name via the same extra-resources path
# it uses in-cluster. Untyped dict — the Compute model is not a dependency here.
_computeExtra = {
    apiVersion = "aws.platform.upbound.io/v1alpha1"
    kind = "Compute"
    metadata = {
        name = "my-compute"
        namespace = "default"
    }
    status = {
        clusterName = "my-cluster"
        connectionConfigName = "my-compute"
        networkId = "vpc-12345678"
        region = "us-west-2"
    }
}

_items = [
    metav1alpha1.CompositionTest{
        metadata.name: "test-ingress"
        spec = {
            assertResources: [
                # Nested Identity for the controller's ServiceAccount (curated role).
                {
                    apiVersion: "aws.platform.upbound.io/v1alpha1"
                    kind: "Identity"
                    metadata.name: "identity"
                    spec = {
                        parameters = {
                            federationType: "pod-identity"
                            role: "aws-lb-controller"
                            reclaimPolicy: "Delete"
                            region: "us-west-2"
                            computeRef = {
                                id: "my-compute"
                            }
                        }
                    }
                }
                # Helm Release — chart is an L3 constant; placement resolved from Compute.
                helmv1beta1.Release{
                    metadata.name: "helmrelease"
                    spec = {
                        forProvider = {
                            chart = {
                                name: "aws-load-balancer-controller"
                                repository: "https://aws.github.io/eks-charts"
                                version: "1.8.3"
                            }
                            namespace: "kube-system"
                            values = {
                                clusterName: "my-cluster"
                                serviceAccount = {
                                    name: "aws-load-balancer-controller"
                                }
                                replicaCount: 0
                                vpcId: "vpc-12345678"
                                region: "us-west-2"
                            }
                        }
                        rollbackLimit: 3
                        managementPolicies: ["*"]
                        providerConfigRef = {
                            kind: "ProviderConfig"
                            name: "my-compute"
                        }
                    }
                }
                # Usage resource for deletion ordering (Release before Compute).
                {
                    apiVersion: "protection.crossplane.io/v1beta1"
                    kind: "Usage"
                    metadata.name: "usage-eks-by-awslbcontroller"
                    spec = {
                        replayDeletion: True
                        by = {
                            apiVersion: "helm.m.crossplane.io/v1beta1"
                            kind: "Release"
                            resourceSelector = {
                                matchControllerRef: True
                            }
                        }
                        of = {
                            apiVersion: "aws.platform.upbound.io/v1alpha1"
                            kind: "Compute"
                            resourceSelector = {
                                matchLabels = {
                                    "platform.upbound.io/deletion-ordering": "enabled"
                                }
                            }
                        }
                    }
                }
            ]
            compositionPath: "apis/awslbcontrollers/composition.yaml"
            xrPath: "examples/awslbcontroller/example.yaml"
            xrdPath: "apis/awslbcontrollers/definition.yaml"
            extraResources: [_computeExtra]
            timeoutSeconds: 60
            validate: False
        }
    }
]
items = _items
