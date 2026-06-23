import models.io.upbound.dev.meta.v1alpha1 as metav1alpha1
import models.io.upbound.platform.aws.v1alpha1 as platformawsv1alpha1
import models.io.upbound.awsm.v1beta1 as awsv1beta1
import models.k8s.apimachinery.pkg.apis.meta.v1 as metav1

# E2E test for Ingress (AWS Load Balancer Controller).
# NOTE: the cluster manifest is still kind EKS because this package resolves the
# currently-published eks package; it flips to kind Compute as part of the
# coordinated v3 republish (see plan task 9).
_items = [
    metav1alpha1.E2ETest{
        metadata.name: "e2etest-awslbcontroller"
        spec = {
            crossplane.autoUpgrade.channel: "None"
            crossplane.version = "2.0.2-up.5"
            defaultConditions: ["Ready"]
            manifests: [
                # Ingress - the resource being tested
                platformawsv1alpha1.Ingress{
                    metadata: {
                        name: "configuration-aws-lb-controller"
                        labels: {
                            "platform.upbound.io/deletion-ordering": "enabled"
                        }
                        namespace: "default"
                    }
                    spec: {
                        parameters: {
                            type: "alb"
                            region: "eu-central-1"
                            computeRef: {
                                id: "configuration-aws-lb-controller"
                            }
                        }
                    }
                }
                # Network - prerequisite networking (v3 contract)
                platformawsv1alpha1.Network{
                    metadata: {
                        name: "configuration-aws-lb-controller"
                        namespace = "default"
                    }
                    spec: {
                        parameters: {
                            region: "eu-central-1"
                        }
                    }
                }
                # Cluster - publishes the connection config the Ingress consumes
                platformawsv1alpha1.EKS{
                    metadata: {
                        name: "configuration-aws-lb-controller"
                        labels: {
                            "platform.upbound.io/deletion-ordering": "enabled"
                        }
                        namespace = "default"
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
