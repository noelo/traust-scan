# Run Parameters — Full Campaign, All Steps

What must be passed to run the full ①–⑨ campaign with no step skipped.
Stage numbers follow [PROCESS.md](PROCESS.md). Everything on this page is a
**passed input** — nothing here is baked into the toolchain image.

Three layers:

1. **Per-stage arguments** — what each skill consumes
2. **Cross-cutting config** — identity, routing, and storage every ledger-writing stage needs
3. **Environment secrets** — credentials the run cannot proceed without

---

## 1. Per-stage parameters

### ① Repository Inventory

| Parameter | Required | Notes |
|---|---|---|
| Repo URLs or org segment | yes | discovery scope for `add-inputs` / `inventory-repositories` |
| `owners.csv` rows (repo → owner) | yes | consumed later by ⑨; register here or ⑨ falls back to weaker sources |
| Segment name | yes | portfolio segment or `adhoc/` |
| Corpus-config registration | yes | links the output tree in `$TRAUST_CONFIG_HOME/corpus-config.yaml` |

### ② Threat Model (`/threat-model`)

| Parameter | Required | Notes |
|---|---|---|
| `<target-dir>` | yes | local checkout |
| Mode token | yes | `bootstrap` (no owner) / `interview` / `bootstrap-then-interview` |
| `--vulns <file>` | for full coverage | CVE list, CSV, markdown pentest report, or JSON array — the vuln-file parser sub-agent only spawns when present |
| `--design-doc <file>` | for full coverage | architecture/design doc; read before Q1 |
| `--context <paths>` | for full coverage | API specs, SBOMs, IaC, prior threat models, SAR/pentest exports |
| `--seed <model-file>` | when chaining | seeds `interview` from a `bootstrap` draft |

The emitted `<repo>-threat-model.md` must be copied into the findings tree
(`analysis-results/findings/<product>/<repo>/`) — ③'s coverage diff resolves
it there, not from the checkout copy.

### ③ Security Audit (`/secure-code-audit`)

| Parameter | Required | Notes |
|---|---|---|
| Target repo path | yes | local checkout |
| Product name | yes | findings land at `analysis-results/findings/<product>/<repo>/` |
| ② threat model in the findings tree | yes | coverage diff consumes it — ② must precede ③ |
| Deterministic pre-scan outputs | auto | gitleaks, opengrep, osv-scanner, syft/grype, checkov, k8s-hardening run automatically and are recorded under `deterministic_steps` |
| Confidence pass | unless `--no-score` | needs a model (see routing below) |

### ④ Triage (`/triage <findings-path>`)

| Parameter | Required | Notes |
|---|---|---|
| Findings JSON path | yes | the ③ report |
| `--votes N` | for full verification | N-vote adversarial verification |
| `--fp-rules FILE` | if custom rules | false-positive rules |
| `--repo PATH` | yes | target checkout for evidence grounding |
| `--auto` | batch runs | skips interactive prompts |

### ⑤ Live Validation (`/validate-findings`, `/validate-browser-finding`)

| Parameter | Required | Notes |
|---|---|---|
| ③ audit + ② threat model + ④ triage reports | yes | attack plan is built from all three |
| Authorized live target | yes | cluster kubeconfig / ephemeral ROSA creds (always torn down) — **this stage cannot run without an authorized target** |
| Lab target URL + Playwright | browser findings only | `validate-browser-finding` |
| Deployment manifest | OLM operators | `analysis-results/validations/_manifest/` |
| Scope guard boundary | yes | the authorization scope; fail-closed |

### ⑥ Fuzzing (`/create-fuzzing`)

| Parameter | Required | Notes |
|---|---|---|
| `targets.json` entries | yes | target id, repo, language, entry-point identifiers |
| Parser/decoder/templater entry points | yes | flagged in the ③ audit report |
| Refuted register | standing input | FP-dismissed findings in fuzzable classes are priority targets |
| Harness templates | baked | `harnesses/_templates/` in the toolchain image |

### ⑦ Remediation & Verification

| Parameter | Required | Notes |
|---|---|---|
| Private fork access | yes | `/remediate-finding` builds patches on forks |
| Repo's own build/test suite | yes | runs in containment |
| Original finding IDs | yes | `/verify-remediation` re-audits each against patched code |

### ⑧ Team Report Packaging (`/generate-team-report`)

| Parameter | Required | Notes |
|---|---|---|
| Findings folders | yes | from `processed-results/` |
| Drive sharing config | yes | folder IDs, recipients (`progress-tracker/configs/`) |

### ⑨ Assign Findings Owners

| Parameter | Required | Notes |
|---|---|---|
| `owners.csv` | yes | from ① |
| Org repo structures YAML | yes | `org/config/structures/` |
| `OWNERS` files | fallback | OpenShift CI |
| LDAP server | yes | `HARNESS_LDAP_SERVER` — identity verification |
| Escalation contacts | yes | commenter grants, never owner slots |

---

## 2. Cross-cutting configuration (every ledger-writing stage)

- **`$TRAUST_CONFIG_HOME`** — deployment config is **mounted, never baked in**
  (Dockerfile). Must carry `locations.yaml` (workspace roots),
  `corpus-config.yaml`, and the product map, or path resolution breaks.
- **`track-findings` ledger writes** — with `LAAS_SIGNING_REQUIRED=true`,
  every write requires the `laas-signing-key` Secret. Unsigned writes fail
  closed. The signing identity is passed via `countersign --identity`.
- **`countersign`** — human decision gate for tiered FP dismissals; triage and
  live-validation verdicts need a countersigning identity.
- **Model routing** — every stage's model resolves from
  `config/model-registry.yaml` (`registry models resolve <role>`). A role with
  no approved model fails the stage. Model IDs may not be hardcoded anywhere
  else (alignment rule A12).

---

## 3. Environment secrets and tokens

| Secret | Stages | Notes |
|---|---|---|
| `MODEL_BASE_URL` + `LLMAPIKEY` | ② ③ ⑤ ⑦ | LLM endpoint (llm-access / tmm-llm-access Secret). `pi-setup` writes models.json from it at runtime — no LLM, no model-driven stage |
| `laas-signing-key` | all ledger writes | signing key; unsigned writes fail closed |
| GitHub token (`gh`) | ② ⑦ | advisory fetch (bootstrap), fork creation, PR assessment |
| Drive / Slack / Jira creds | ⑧ ⑨ | share, notify, file defects |
| LDAP creds | ⑨ | identity verification |
| Cluster kubeconfig / ROSA creds | ⑤ | authorized live target; disposable, always torn down |

---

## Relationship to the Tekton pipeline

The Tekton pipeline (`deploy/tekton/pipeline.yaml`) is the **①②③ slice only**:
`clone` → (`threat-model` bootstrap ∥ deterministic-scan) → `upload`. It needs
none of the per-stage human inputs above — everything it consumes is baked
into the toolchain image, taken from the target clone, or a one-time cluster
secret (`tmm-llm-access`, `minio-secret`, PVC `traust-scan-workspace`).

The full campaign (this page) runs **on top of** that slice, and it is where
every parameter above is passed by a human or a config file.
