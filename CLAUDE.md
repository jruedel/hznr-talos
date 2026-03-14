# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Infrastructure-as-code project for provisioning a Kubernetes development cluster on Hetzner Cloud using Talos Linux. Two-stage workflow: Packer builds Talos OS images, Terraform provisions infrastructure, Makefile wraps talosctl for cluster bootstrap.

## Prerequisites

- Hashicorp Packer
- Terraform >= 1.5
- talosctl
- jq
- A `.env` file at project root with `HCLOUD_TOKEN=<token>`

## Commands

```bash
make help            # List all targets
make build-image     # Build Talos image via Packer
make init            # Terraform init
make plan            # Terraform plan
make apply           # Terraform apply (creates servers, network, LB, firewall)
make gen-config      # Generate Talos machine configs via talosctl
make apply-config    # Apply configs to all nodes
make bootstrap       # Bootstrap first control plane node
make get-kubeconfig  # Retrieve kubeconfig
make deploy-services # Deploy CCM + nginx ingress + cert-manager
make patch-config    # Apply patches/ to running nodes via talosctl
make cluster         # Full end-to-end: apply → bootstrap → deploy-services
make destroy         # Terraform destroy
```

## Architecture

### Packer (image build)
- `packer/hcloud.pkr.hcl` — Hetzner Cloud provider config, downloads Talos from factory.talos.dev
- `packer/instances.pkrvars.hcl` — Variables: architecture (amd64/arm), server type, location, Talos version

### Terraform (infrastructure)
- `terraform/main.tf` — All resources: dummy SSH key, private network + subnet, firewall, placement groups, CP/worker servers, load balancer
- `terraform/variables.tf` — Cluster topology is configurable: `control_plane_count` (1 or 3), `worker_count` (1-10), server types, location
- `terraform/outputs.tf` — Node IPs and LB endpoint, consumed by Makefile for talosctl commands
- Load balancer is only created for HA (3+ CP nodes); single CP uses the node's public IP directly

### Data Flow
1. Packer builds image → snapshot ID saved in `manifest.json`
2. Makefile reads `IMAGE_ID` from `manifest.json` → passes to Terraform as `TF_VAR_image_id`
3. Terraform provisions infra → outputs node IPs and LB IP
4. Makefile reads Terraform outputs → feeds them to talosctl commands

## Formatting & Validation

```bash
packer fmt packer/
packer validate packer/
terraform -chdir=terraform fmt
terraform -chdir=terraform validate
```

## Key Details

- Hetzner provider auth: `HCLOUD_TOKEN` env var (auto-read by provider, no secret in code)
- Talos ignores SSH; dummy key is created via `tls_private_key` to satisfy Hetzner's requirement
- Generated Talos configs go to `talos/` (gitignored), kubeconfig to `./kubeconfig` (gitignored)
- Talos machine config patches live in `patches/` (cloud-provider, node-private-ip, flannel-private-iface)
- `gen-config` applies all patches automatically via `--config-patch`
- Kubectl context for this cluster: `admin@talos`

## Firewall

- Talos API (50000) and K8s API (6443): restricted to `var.operator_cidrs` (default: open)
- etcd (2379-2380), kubelet (10250), Flannel VXLAN (4789): no rules needed — private network traffic, firewalls don't apply
- Set `operator_cidrs` to your IP/CIDR to lock down management access

## Cluster Services (Helm via Makefile)

- **hcloud-ccm** — Hetzner Cloud Controller Manager, enables `Service type: LoadBalancer`
- **nginx ingress** — ingress controller with Hetzner LB annotations and proxy protocol
- **cert-manager** — Let's Encrypt TLS via ClusterIssuers (`letsencrypt-staging`, `letsencrypt-prod`)
- Values files in `helm/`, K8s manifests in `k8s/`

## Hetzner + Talos Gotchas

- Flannel uses VXLAN on port **4789** (not 8472); defaults to public IPs unless `--iface-regex` is set
- `patches/flannel-private-iface.yaml` forces Flannel to use private network IPs via `--iface-regex`
- Kubelet needs `--cloud-provider=external` for CCM to set `providerID` on nodes
- `kubelet.nodeIP.validSubnets` must be set to private subnet for CCM LB target attachment
- Hetzner Cloud Firewalls can silently drop overlay traffic if the wrong port/source is allowed
- Talos enforces `restricted` Pod Security Standard — all pods need full security context
