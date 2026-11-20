"""Prepare and operate two one-replica RTX 5090 Salad Container Groups."""
import argparse
import json
import os
import re
import sys

from http_client import Client, RequestError

API = "https://api.salad.com/api/public"
ROLES = ("encoder", "render")
SLUG = re.compile(r"[a-z][a-z0-9-]{0,61}[a-z0-9]")
RTX_5090 = re.compile(r"\bRTX 5090(?:\s*\([^)]*\))?$", re.I)
GIB = 1024**3
PORT = 8188


def groups(args, gpu):
    cpu = max(4, gpu.get("min_vcpu") or 0)
    memory = max(32768, gpu.get("min_ram") or 0)
    storage = max(64 * GIB, gpu.get("min_storage") or 0)
    for name, value, limit in (
        ("vCPU", cpu, gpu.get("max_vcpu")),
        ("RAM", memory, gpu.get("max_ram")),
        ("storage", storage, gpu.get("max_storage")),
    ):
        if limit and value > limit:
            raise ValueError(f"The RTX 5090 class cannot allocate the planned {name}")
    probe = {"path": "/system_stats", "port": PORT, "scheme": "http",
             "headers": [{"name": "Accept", "value": "application/json"}]}
    return [
        {
            "name": f"{args.prefix}-{role}",
            "autostart_policy": False,
            "replicas": 1,
            "restart_policy": "on_failure",
            "container": {
                "image": args.image,
                "image_caching": True,
                "priority": args.priority,
                "resources": {"cpu": cpu, "memory": memory, "shm_size": 1024,
                              "storage_amount": storage, "gpu_classes": [gpu["id"]]},
                "environment_variables": ({"H3_ROLE": role, "H3_ENCODER_PROFILE": args.encoder_profile}
                                          if role == "encoder" else {"H3_ROLE": role}),
            },
            "networking": {"auth": True, "port": PORT, "protocol": "http",
                           "client_request_timeout": 100000, "server_response_timeout": 100000},
            "startup_probe": {"http": probe, "initial_delay_seconds": 0,
                              "period_seconds": 120, "timeout_seconds": 10,
                              "success_threshold": 1, "failure_threshold": 20},
            "readiness_probe": {"http": probe, "initial_delay_seconds": 0,
                                "period_seconds": 10, "timeout_seconds": 5,
                                "success_threshold": 1, "failure_threshold": 3},
        }
        for role in ROLES
    ]


def gpu_class(client, org, requested):
    result = client.json(f"/organizations/{org}/gpu-classes")
    matches = [item for item in result["items"] if RTX_5090.search(item["name"])
               and item.get("gpu_count", 1) == 1
               and (not requested or item["id"] == requested)]
    if len(matches) != 1:
        detail = ", ".join(f'{gpu["name"]}: {gpu["id"]}' for gpu in matches)
        raise ValueError("Select exactly one listed RTX 5090 class with --gpu-class. "
                         f"Matches: {detail or 'none'}")
    return matches[0]


def assert_group(current, role):
    container = current["container"]
    env = container.get("environment_variables") or {}
    network = current.get("networking") or {}
    if (env.get("H3_ROLE") != role or network.get("auth") is not True
            or network.get("port") != PORT or current["replicas"] != 1):
        raise ValueError("Existing group differs from the expected one-replica H3 deployment")


def describe(group, role):
    assert_group(group, role)
    name = group["name"]
    status = group.get("current_state", {}).get("status", "unknown")
    dns = group["networking"].get("dns")
    url = (dns if dns.startswith("https://") else "https://" + dns) if dns else ""
    print(f"{name}: {status}")
    if url:
        print(f"H3_{role.upper()}_URL={url}")
    if role == "encoder":
        profile = group["container"]["environment_variables"].get("H3_ENCODER_PROFILE", "compact")
        print(f"H3_ENCODER_PROFILE={profile}")


def create_group(client, root, plan, role):
    path = f'{root}/{plan["name"]}'
    try:
        actual = client.json(path)
    except RequestError as err:
        if err.status != 404:
            raise
        client.json(root, plan)
        actual = client.json(path)
    assert_group(actual, role)
    current = actual["container"]
    wanted = plan["container"]
    if (current.get("image") != wanted["image"]
            or (actual.get("priority") or current.get("priority")) != wanted["priority"]):
        raise ValueError(f'{plan["name"]} exists with a different image or priority')
    if role == "encoder" and current["environment_variables"].get(
            "H3_ENCODER_PROFILE", "compact") != wanted["environment_variables"]["H3_ENCODER_PROFILE"]:
        raise ValueError(f'{plan["name"]} exists with a different encoder profile')
    existing = current["resources"]
    for key, value in wanted["resources"].items():
        if existing.get(key) != value:
            raise ValueError(f'{plan["name"]} exists with different {key}')
    describe(actual, role)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("plan", "create", "start", "status", "stop"))
    parser.add_argument("--org", default=os.environ.get("SALAD_ORG"))
    parser.add_argument("--project", default=os.environ.get("SALAD_PROJECT"))
    parser.add_argument("--prefix", default="eros-h3")
    parser.add_argument("--image", default=os.environ.get("H3_IMAGE"))
    parser.add_argument("--gpu-class")
    parser.add_argument("--encoder-profile", choices=("compact", "int8"),
                        default=os.environ.get("H3_ENCODER_PROFILE", "compact"))
    parser.add_argument("--priority", choices=("batch", "low", "medium", "high"), default="batch")
    args = parser.parse_args()
    if args.encoder_profile not in ("compact", "int8"):
        parser.error("H3_ENCODER_PROFILE must be compact or int8")
    key = os.environ.get("SALAD_API_KEY")
    if not key:
        parser.error("Set SALAD_API_KEY in the local environment")
    if (not args.org or not args.project or any(not SLUG.fullmatch(slug) for slug
        in (args.org, args.project, *(f"{args.prefix}-{role}" for role in ROLES)))):
        parser.error("Set valid Salad organization, project, and group names")
    try:
        client = Client(API, key)
        root = f"/organizations/{args.org}/projects/{args.project}/containers"
        if args.action in ("plan", "create"):
            if not args.image or not re.fullmatch(r"[^\s@]+@sha256:[0-9a-f]{64}", args.image):
                raise ValueError("Set H3_IMAGE to the immutable registry image digest")
            plans = groups(args, gpu_class(client, args.org, args.gpu_class))
            if args.action == "plan":
                print(json.dumps(plans, indent=2))
                return
            for role, plan in zip(ROLES, plans):
                create_group(client, root, plan, role)
            return
        for role in ROLES:
            path = f"{root}/{args.prefix}-{role}"
            group = client.json(path)
            assert_group(group, role)
            if args.action in ("start", "stop"):
                # A failed or ambiguous write stops the command. Inspect status before retrying.
                client.json(f"{path}/{args.action}", method="POST")
                group = client.json(path)
            describe(group, role)
    except (RuntimeError, OSError, ValueError, KeyError) as err:
        sys.exit(str(err))


if __name__ == "__main__":
    main()
