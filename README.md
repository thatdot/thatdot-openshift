# thatdot-openshift

Reference deployment of [Quine Enterprise](https://www.thatdot.com/quine-enterprise) onto Red Hat OpenShift, with Cassandra as its persistor and Keycloak for OIDC-based RBAC.

> **Status:** in progress. This repo is being built up incrementally — see [`IMPLEMENTATION_PLAN.md`](./IMPLEMENTATION_PLAN.md) for the step-by-step plan and progress checklist.

## What's here

- **[`IMPLEMENTATION_PLAN.md`](./IMPLEMENTATION_PLAN.md)** — prerequisites, step-by-step deployment plan with verification at each step, and a TL;DR checklist at the bottom.
- **[`CLAUDE.md`](./CLAUDE.md)** — context for engineers (and Claude Code) picking up the work.
- `manifests/` — Kubernetes/OpenShift manifests, organized by deployment step. *(Coming as steps complete.)*

## Target environment

Single-node [OpenShift Local](https://developers.redhat.com/products/openshift-local) (formerly CRC) for dev iteration. Same OpenShift Container Platform bits as a production cluster.

## Architectural decisions

| | Choice |
|---|---|
| GitOps engine | OpenShift GitOps Operator (Red Hat–packaged ArgoCD) |
| In-cluster TLS | OpenShift `service-ca` (no cert-manager) |
| Cassandra auth | Plaintext (out of scope for v1) |

## Public-repo notice

This repository is public. **No license keys, admin passwords, internal cluster details, or TLS private material are committed here.** All secrets flow in at deploy time via environment variables and `oc create secret` commands, documented in `IMPLEMENTATION_PLAN.md`.

## Out of scope for v1

- Novelty
- Kafka

These may be added in a follow-up.
