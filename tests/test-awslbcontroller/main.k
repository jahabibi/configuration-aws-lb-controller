
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1
import models.io.upbound.platform.aws.v1alpha1 as awsv1alpha1
import models.io.crossplane.helmm.v1beta1 as helmv1beta1
import models.k8s.apimachinery.pkg.apis.meta.v1 as metav1


_items = [
    metav1alpha1.CompositionTest{
        metadata.name: "test-awslbcontroller"
        spec = {
            assertResources: [
                # PodIdentity for AWS Pod Identity
                awsv1alpha1.PodIdentity{
                    metadata.name: "podidentity"
                    spec = {
                        parameters = {
                            region: "us-west-2"
                            serviceAccount = {
                                name: "aws-load-balancer-controller"
                                namespace: "kube-system"
                            }
                        }
                    }
                },
                # Helm Release for AWS Load Balancer Controller
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
                                clusterName: "configuration-aws-lb-controller-c8ck8"
                                serviceAccount = {
                                    name: "aws-load-balancer-controller"
                                }
                                replicaCount: 2
                                vpcId: "vpc-12345678"
                            }
                        }
                        rollbackLimit: 3
                    }
                },
                # Usage resource for deletion ordering
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
                            kind: "EKS"
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
            observedResources: [
                awsv1alpha1.PodIdentity{
                    metadata = {
                        name = "podidentity"
                        annotations = {
                              "crossplane.io/composition-resource-name" = "podidentity"
                        }
                    }
                    spec = {
                        parameters = {
                            region: "eu-central-1"
                            serviceAccount = {
                                name: "aws-load-balancer-controller"
                                namespace: "kube-system"
                            }
                        }
                    }
                    status = {
                        conditions = [
                            {
                                type = "Ready"
                                status = "True"
                                reason = "Available"
                                lastTransitionTime = "2025-08-13T17:25:33Z"
                            }
                        ]
                        podIdentity = {
                            clusterName = "configuration-aws-lb-controller-c8ck8" # Important for proper Release spec test
                        }
                    }
                }
            ]
            timeoutSeconds: 60
            validate: False
        }
    }
]
items = _items