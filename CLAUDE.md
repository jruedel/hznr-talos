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
make cluster         # Full end-to-end: apply → gen-config → apply-config → bootstrap → get-kubeconfig
make destroy         # Terraform destroy
```

## Architecture

### Packer (image build)
- `packer/hcloud.pkr.hcl` — Hetzner Cloud provider config, downloads Talos from factory.talos.dev
- `packer/instances.pkr.hcl` — Variables: architecture (amd64/arm), server type, location, Talos version

### Terraform (infrastructure)
- `terraform/main.tf` — All resources: dummy SSH key, private network + subnet, firewall, placement groups, CP/worker servers, load balancer
- `terraform/variables.tf` — Cluster topology is configurable: `control_plane_count` (1 or 3), `worker_count` (1-10), server types, location
- `terraform/outputs.tf` — Node IPs and LB endpoint, consumed by Makefile for talosctl commands
- Load balancer is always created (even for single CP) so the API endpoint stays stable when scaling

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
- Firewall restricts etcd/kubelet to private subnet; Talos API and K8s API open externally
