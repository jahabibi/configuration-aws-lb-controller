"""Composition function for the Ingress (AWS LB Controller) cell.

Python port of the former KCL function. The reason this exists in Python: the
cross-domain lookup of the *namespaced* Compute XR must be namespace-scoped, and
the function-kcl server baked into `up` is too old to honour `matchNamespace`
(see repo ISSUE-matchnamespace-function-kcl.md). The Python SDK
(crossplane-function-sdk-python) speaks the Crossplane v2 `required_resources`
mechanism, whose ResourceSelector carries a `namespace` field, so it resolves the
namespaced Compute correctly.
"""

from crossplane.function import request, resource, response
from crossplane.function.proto.v1 import run_function_pb2 as fnv1

# L3 chart pin — an implementation detail, never a consumer-facing field.
_CHART = {
    "name": "aws-load-balancer-controller",
    "repository": "https://aws.github.io/eks-charts",
    "version": "1.8.3",
}


def _resolved_compute(req: fnv1.RunFunctionRequest):
    """Return the resolved Compute as a dict, or None on the first pass.

    Primary path is the v2 required_resources map. The fallback reads the
    deprecated extra_resources map directly off the proto so the offline
    CompositionTest harness (which injects via `extraResources`) still works.
    """
    compute = request.get_required_resource(req, "compute")
    if compute is not None:
        return compute
    extra = req.extra_resources
    if "compute" in extra and len(extra["compute"].items) > 0:
        return resource.struct_to_dict(extra["compute"].items[0].resource)
    return None


def _observed(req: fnv1.RunFunctionRequest, name: str) -> dict:
    """Return an observed composed resource as a dict (empty if absent)."""
    resources = req.observed.resources
    if name in resources:
        return resource.struct_to_dict(resources[name].resource)
    return {}


def compose(req: fnv1.RunFunctionRequest, rsp: fnv1.RunFunctionResponse):
    oxr = resource.struct_to_dict(req.observed.composite.resource)
    namespace = oxr.get("metadata", {}).get("namespace", "")
    params = oxr.get("spec", {}).get("parameters", {})

    reclaim_policy = params.get("reclaimPolicy", "Delete")
    management_policies = (
        ["Create", "Observe", "Update", "LateInitialize"]
        if reclaim_policy == "Retain"
        else ["*"]
    )
    region = params.get("region", "")
    compute_ref_id = (params.get("computeRef") or {}).get("id", "")

    # Inter-domain wiring: request the referenced Compute so its published status
    # (the in-cluster connection config, cluster name, vpc id) can be read. The
    # namespace scope is what the legacy KCL runtime could not express.
    if compute_ref_id:
        response.require_resources(
            rsp,
            name="compute",
            api_version="aws.platform.upbound.io/v1alpha1",
            kind="Compute",
            match_name=compute_ref_id,
            namespace=namespace,
        )

    compute_status = (_resolved_compute(req) or {}).get("status", {})
    cluster_name = compute_status.get("clusterName", "")
    connection_config_name = compute_status.get("connectionConfigName", "")
    vpc_id = compute_status.get("networkId", "")
    # Region for --aws-region: under pod-identity, IMDS region introspection is
    # blocked (401), so the controller must be told the region explicitly.
    aws_region = region or compute_status.get("region", "")

    # Readiness: scale the controller up only once its identity is established.
    identity = _observed(req, "identity")
    identity_ready = any(
        c.get("type") == "Ready" and c.get("status") == "True"
        for c in (identity.get("status", {}).get("conditions") or [])
    )

    # Identity for the controller's ServiceAccount (curated aws-lb-controller role).
    identity_params = {
        "federationType": "pod-identity",
        "role": "aws-lb-controller",
        "reclaimPolicy": reclaim_policy,
    }
    if region:
        identity_params["region"] = region
    if compute_ref_id:
        identity_params["computeRef"] = {"id": compute_ref_id}
    resource.update(
        rsp.desired.resources["identity"],
        {
            "apiVersion": "aws.platform.upbound.io/v1alpha1",
            "kind": "Identity",
            "metadata": {"name": "identity"},
            "spec": {"parameters": identity_params},
        },
    )

    # Helm Release for the controller.
    values = {
        "serviceAccount": {"name": "aws-load-balancer-controller"},
        "replicaCount": 2 if identity_ready else 0,
    }
    if cluster_name:
        values["clusterName"] = cluster_name
    if vpc_id:
        values["vpcId"] = vpc_id
    if aws_region:
        values["region"] = aws_region
    release_spec = {
        "forProvider": {
            "chart": _CHART,
            "namespace": "kube-system",
            "values": values,
        },
        "rollbackLimit": 3,
        "managementPolicies": management_policies,
    }
    # in-cluster ProviderConfig published by Compute — not a hardcoded name
    if connection_config_name:
        release_spec["providerConfigRef"] = {
            "kind": "ProviderConfig",
            "name": connection_config_name,
        }
    resource.update(
        rsp.desired.resources["helmrelease"],
        {
            "apiVersion": "helm.m.crossplane.io/v1beta1",
            "kind": "Release",
            "metadata": {"name": "helmrelease"},
            "spec": release_spec,
        },
    )

    # Usage: the Release must be deleted before the Compute (cluster).
    resource.update(
        rsp.desired.resources["usage-eks-by-awslbcontroller"],
        {
            "apiVersion": "protection.crossplane.io/v1beta1",
            "kind": "Usage",
            "metadata": {"name": "usage-eks-by-awslbcontroller", "namespace": namespace},
            "spec": {
                "replayDeletion": True,
                "by": {
                    "apiVersion": "helm.m.crossplane.io/v1beta1",
                    "kind": "Release",
                    "resourceSelector": {"matchControllerRef": True},
                },
                "of": {
                    "apiVersion": "aws.platform.upbound.io/v1alpha1",
                    "kind": "Compute",
                    "resourceSelector": {
                        "matchLabels": {
                            "platform.upbound.io/deletion-ordering": "enabled"
                        }
                    },
                },
            },
        },
    )

    # Structured status. roleArn is typed `string` in the XRD; emitting an
    # explicit null fails status validation, so only set it when present.
    status = {"ready": identity_ready}
    role_arn = identity.get("status", {}).get("roleArn")
    if role_arn:
        status["roleArn"] = role_arn
    resource.update(
        rsp.desired.composite,
        {
            "apiVersion": oxr.get("apiVersion"),
            "kind": oxr.get("kind"),
            "status": status,
        },
    )
