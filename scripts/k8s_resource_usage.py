#!/usr/bin/env python3
import json
import subprocess
import sys


def run(command: list[str]) -> str:
    return subprocess.check_output(command, text=True, stderr=subprocess.STDOUT)


def parse_cpu(value: str | None) -> float | None:
    if not value:
        return None

    value = str(value)
    if value.endswith("n"):
        return float(value[:-1]) / 1_000_000_000
    if value.endswith("u"):
        return float(value[:-1]) / 1_000_000
    if value.endswith("m"):
        return float(value[:-1]) / 1000
    return float(value)


def parse_memory(value: str | None) -> float | None:
    if not value:
        return None

    value = str(value)
    units = {
        "Ki": 1024,
        "Mi": 1024**2,
        "Gi": 1024**3,
        "Ti": 1024**4,
        "K": 1000,
        "M": 1000**2,
        "G": 1000**3,
        "T": 1000**4,
    }

    for suffix, multiplier in units.items():
        if value.endswith(suffix):
            return float(value[: -len(suffix)]) * multiplier

    return float(value)


def percent(used: float | None, base: float | None) -> str:
    if used is None or base is None or base == 0:
        return "n/a"
    return f"{used / base * 100:5.1f}%"


def fmt_cpu(cores: float | None) -> str:
    if cores is None:
        return "n/a"
    return f"{cores * 1000:.0f}m"


def fmt_memory(bytes_value: float | None) -> str:
    if bytes_value is None:
        return "n/a"
    return f"{bytes_value / 1024 / 1024:.0f}Mi"


def collect_top_usage(namespace: str) -> dict[str, dict[str, float | None]]:
    top_output = run(["kubectl", "top", "pods", "-n", namespace, "--no-headers"])
    usage_by_pod = {}

    for line in top_output.splitlines():
        parts = line.split()
        if len(parts) >= 3:
            usage_by_pod[parts[0]] = {
                "cpu": parse_cpu(parts[1]),
                "memory": parse_memory(parts[2]),
            }

    return usage_by_pod


def collect_pod_rows(namespace: str) -> list[list[str]]:
    pods_json = json.loads(run(["kubectl", "get", "pods", "-n", namespace, "-o", "json"]))
    usage_by_pod = collect_top_usage(namespace)

    rows = []
    for pod in pods_json.get("items", []):
        name = pod["metadata"]["name"]
        phase = pod.get("status", {}).get("phase", "")
        containers = pod.get("spec", {}).get("containers", [])

        cpu_request = 0.0
        cpu_limit = 0.0
        memory_request = 0.0
        memory_limit = 0.0
        has_cpu_request = False
        has_cpu_limit = False
        has_memory_request = False
        has_memory_limit = False

        for container in containers:
            resources = container.get("resources", {})
            requests = resources.get("requests", {})
            limits = resources.get("limits", {})

            cpu = parse_cpu(requests.get("cpu"))
            if cpu is not None:
                cpu_request += cpu
                has_cpu_request = True

            cpu = parse_cpu(limits.get("cpu"))
            if cpu is not None:
                cpu_limit += cpu
                has_cpu_limit = True

            memory = parse_memory(requests.get("memory"))
            if memory is not None:
                memory_request += memory
                has_memory_request = True

            memory = parse_memory(limits.get("memory"))
            if memory is not None:
                memory_limit += memory
                has_memory_limit = True

        usage = usage_by_pod.get(name, {})
        used_cpu = usage.get("cpu")
        used_memory = usage.get("memory")

        rows.append(
            [
                name,
                phase,
                fmt_cpu(used_cpu),
                percent(used_cpu, cpu_request if has_cpu_request else None),
                percent(used_cpu, cpu_limit if has_cpu_limit else None),
                fmt_memory(used_memory),
                percent(used_memory, memory_request if has_memory_request else None),
                percent(used_memory, memory_limit if has_memory_limit else None),
            ]
        )

    return rows


def print_table(namespace: str, rows: list[list[str]]) -> None:
    headers = [
        "POD",
        "STATUS",
        "CPU",
        "CPU/REQ",
        "CPU/LIMIT",
        "MEM",
        "MEM/REQ",
        "MEM/LIMIT",
    ]

    widths = [len(header) for header in headers]
    for row in rows:
        for index, value in enumerate(row):
            widths[index] = max(widths[index], len(value))

    print(f"Resource usage in namespace {namespace}")
    print(" ".join(header.ljust(widths[index]) for index, header in enumerate(headers)))
    print(" ".join("-" * width for width in widths))
    for row in rows:
        print(" ".join(value.ljust(widths[index]) for index, value in enumerate(row)))

    print()
    print("CPU/REQ and MEM/REQ show usage relative to Kubernetes requests.")
    print("CPU/LIMIT and MEM/LIMIT show usage relative to Kubernetes limits.")
    print("n/a means the pod has no request or limit for that resource.")


def main() -> int:
    namespace = sys.argv[1] if len(sys.argv) > 1 else "lab8-spark"

    try:
        print_table(namespace, collect_pod_rows(namespace))
    except subprocess.CalledProcessError as exc:
        output = exc.output.strip()
        if "metrics" in output.lower() or "metrics.k8s.io" in output.lower():
            print("Resource metrics are not available yet.")
            print("Enable metrics-server and wait 1-2 minutes:")
            print("  minikube addons enable metrics-server")
            print(f"  kubectl top pods -n {namespace}")
            if output:
                print()
                print(output)
            return 0

        if output:
            print(output)
        return exc.returncode

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
