# Hetzner Talos K8s

Setup for K8s development cluster on Hetzner Cloud with Talos Linux.

## Prerequisites

- [Hashicorp Packer](https://developer.hashicorp.com/packer)
- [Terraform](https://developer.hashicorp.com/terraform) >= 1.5
- [talosctl](https://docs.siderolabs.com/talos/v1.11/getting-started/talosctl)
- [jq](https://jqlang.github.io/jq/)

## Setup

### 1. Create Hetzner API Token

- In the Hetzner console: Access → Security → Create new token
- Reference: [Hetzner Cloud CLI](https://community.hetzner.com/tutorials/howto-hcloud-cli)

### 2. Configure Environment

```bash
cp .env.example .env  # or create manually
```

Add your token, email, and domain to `.env`:
```
HCLOUD_TOKEN=your_token_here
ACME_EMAIL=your@email.com
DOMAIN=example.com
```

### 3. Build Talos Image

Edit [instances.pkrvars.hcl](packer/instances.pkrvars.hcl) for your architecture (amd64/arm).

```bash
make build-image
```

The image snapshot ID is saved to `manifest.json` and automatically passed to Terraform.

### 4. Provision Infrastructure

```bash
make init       # Initialize Terraform
make plan       # Preview what will be created
make apply      # Create servers, network, firewall, load balancer
```

Customize the cluster by passing Terraform variables:
```bash
# HA setup: 3 control planes + 3 workers
terraform -chdir=terraform apply \
  -var="control_plane_count=3" \
  -var="worker_count=3"
```

#### Firewall

By default, the Talos API (50000) and Kubernetes API (6443) are open to all IPs. To restrict management access to your IP:

```bash
terraform -chdir=terraform apply \
  -var='operator_cidrs=["YOUR.PUBLIC.IP/32"]'
```

Or set `operator_cidrs` in a `terraform.tfvars` file.

| Port | Protocol | Source | Purpose |
|------|----------|--------|---------|
| 50000 | TCP | `operator_cidrs` | Talos API (talosctl) |
| 6443 | TCP | `operator_cidrs` | Kubernetes API |

Internal traffic (etcd 2379-2380, kubelet 10250, Flannel VXLAN 4789) uses the private network. [Hetzner Cloud Firewalls don't apply to private network traffic](https://docs.hetzner.com/cloud/firewalls/faq/#can-firewalls-secure-traffic-to-my-private-hetzner-cloud-networks), so no firewall rules are needed for these. Flannel is configured with `--iface-regex=10\.0\..*\..*` to ensure VXLAN uses private interfaces.

### 5. Bootstrap Cluster

```bash
make gen-config      # Generate Talos machine configs
make apply-config    # Apply configs to all nodes
make bootstrap       # Bootstrap first control plane
make get-kubeconfig  # Retrieve kubeconfig
```

Or run the full workflow end-to-end (includes deploy-services):
```bash
make cluster
```

### 6. Deploy Cluster Services

If you bootstrapped step-by-step (not via `make cluster`), deploy the CCM, ingress controller, and cert-manager:

```bash
make deploy-services
```

This installs:
- **hcloud-ccm** — enables Hetzner Load Balancers for `Service type: LoadBalancer`
- **nginx ingress** — routes external HTTP/HTTPS traffic into the cluster
- **cert-manager** — automated TLS certificates via Let's Encrypt

### 7. Configure DNS

After `deploy-services` completes, the ingress controller gets a Hetzner Load Balancer with a public IP. Point your domain to it.

Get the ingress LB IP:
```bash
kubectl --kubeconfig=./kubeconfig --context=admin@talos \
  -n ingress-nginx get svc ingress-nginx-controller \
  -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

Create a wildcard DNS A record so all subdomains resolve to the ingress:
```
*.example.com  →  <ingress-lb-ip>
```

Wait for DNS propagation before requesting TLS certificates. You can verify with:
```bash
dig +short hello.example.com
```

### 8. Deploy Hello World (Test)

Deploy the included hello-world app to verify TLS and ingress are working:

```bash
make deploy-hello-world
```

This creates a Deployment, Service, and Ingress at `hello.<DOMAIN>` with a Let's Encrypt TLS certificate. cert-manager provides two ClusterIssuers — use `letsencrypt-staging` first to test (higher rate limits), then switch to `letsencrypt-prod` in `k8s/hello-world.yaml`.

### 9. Use the Cluster

```bash
export KUBECONFIG=./kubeconfig
kubectl --context=admin@talos get nodes
```

## Teardown

```bash
make destroy
```

## Available Commands

Run `make help` to see all targets.

## Reference

- [Talos on Hetzner Cloud](https://docs.siderolabs.com/talos/v1.11/platform-specific-installations/cloud-platforms/hetzner)
