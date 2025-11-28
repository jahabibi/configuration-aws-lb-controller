
import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1
import models.io.upbound.platform.aws.v1alpha1 as platformawsv1alpha1
import models.io.upbound.aws.v1beta1 as awsv1beta1
import models.k8s.apimachinery.pkg.apis.meta.v1 as metav1

# E2E test for AWSLBController - based on original examples
# EKS will automatically create the Helm ProviderConfig
_items = [
    metav1alpha1.E2ETest{
        metadata.name: "e2etest-awslbcontroller"
        spec = {
            crossplane.autoUpgrade.channel: "None"
            crossplane.version = "2.0.2-up.5"
            defaultConditions: ["Ready"]
            manifests: [
                # Network - prerequisite networking for EKS cluster
                platformawsv1alpha1.Network{
                    metadata: {
                        name: "configuration-aws-lb-controller"
                    }
                    spec: {
                        parameters: {
                            id: "configuration-aws-lb-controller"
                            region: "eu-central-1"
                            subnets: [
                                {
                                    availabilityZone: "eu-central-1a"
                                    type: "public"
                                    cidrBlock: "192.168.0.0/18"
                                },
                                {
                                    availabilityZone: "eu-central-1b"
                                    type: "public"
                                    cidrBlock: "192.168.64.0/18"
                                },
                                {
                                    availabilityZone: "eu-central-1a"
                                    type: "private"
                                    cidrBlock: "192.168.128.0/18"
                                },
                                {
                                    availabilityZone: "eu-central-1b"
                                    type: "private"
                                    cidrBlock: "192.168.192.0/18"
                                }
                            ]
                        }
                    }
                },
                # EKS - EKS cluster that will create Helm ProviderConfig automatically
                platformawsv1alpha1.EKS{
                    metadata: {
                        name: "configuration-aws-lb-controller"
                        labels: {
                            "platform.upbound.io/deletion-ordering": "enabled"
                        }
                    }
                    spec: {
                        parameters: {
                            id: "configuration-aws-lb-controller"
                            region: "eu-central-1"
                            version: "1.33"
                            nodes: {
                                count: 2
                                instanceType: "t3.small"
                            }
                        }
                    }
                },
                # AWSLBController - the main resource being tested
                # EKS will create Helm ProviderConfig "configuration-aws-lb-controller"
                platformawsv1alpha1.AWSLBController{
                    metadata: {
                        name: "configuration-aws-lb-controller"
                        labels: {
                            "platform.upbound.io/deletion-ordering": "enabled"
                        }
                    }
                    spec: {
                        parameters: {
                            region: "eu-central-1"
                            helm: {
                                providerConfigName: "configuration-aws-lb-controller"
                            }
                            clusterNameSelector: {
                                matchLabels: {
                                    "crossplane.io/composite": "configuration-aws-lb-controller"
                                }
                            }
                        }
                    }
                }
            ]
            extraResources = [
                # Define the provider configuration
                awsv1beta1.ProviderConfig{
                    metadata = {
                        name = "default"
                        namespace = "default"
                    }
                    spec = {
                        credentials = {
                            source = "Upbound"
                            upbound = {
                                webIdentity = {
                                    roleARN = "arn:aws:iam::609897127049:role/solutions-e2e-provider-aws"
                                }
                            }
                        }
                    }
                }
            ]
            skipDelete: False
            timeoutSeconds: 3600  # 60 minutes for full stack deployment
        }
    }
]
items = _items
