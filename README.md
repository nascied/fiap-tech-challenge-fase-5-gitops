# 🚀 SolidaryTech — GitOps (Hackathon Fase 5)

> ⚠️ **PROJETO DIDÁTICO** — parte do Hackathon Fase 5 da Pós-Tech FIAP em Arquitetura Cloud e DevOps.

Charts Helm e Applications do ArgoCD dos 3 microsserviços da plataforma **SolidaryTech** (ONGs, doações, voluntários). Este repositório é a fonte da verdade de GitOps — o ArgoCD sincroniza o cluster EKS a partir daqui, sem `kubectl apply` manual.

Não fazem parte do escopo deste repositório:
- Código de aplicação ([`fiap-tech-challenge-fase-5-services`](https://github.com/nascied/fiap-tech-challenge-fase-5-services)).
- Provisionamento de infraestrutura AWS/Terraform ([`fiap-tech-challenge-fase-5-infra`](https://github.com/nascied/fiap-tech-challenge-fase-5-infra)).
- Stack de observabilidade ([`fiap-tech-challenge-fase-5-observability`](https://github.com/nascied/fiap-tech-challenge-fase-5-observability)).

## 📁 Estrutura

```text
.
├── .github/
│   └── workflows/
│       └── update-image.yaml # workflow_call — atualiza image.repository/tag via CI dos services
├── helm/
│   ├── ngo-service/          # Flask, RDS ngo_db, Secret via AWS Secrets Manager (CSI Driver)
│   ├── donation-service/     # Go, RDS donation_db + SQS, Secret via AWS Secrets Manager (CSI Driver)
│   └── volunteer-service/    # Flask, DynamoDB, Secret via AWS Secrets Manager (CSI Driver)
└── argocd/
    ├── root.yaml              # bootstrap único — único apply manual deste repositório
    ├── root/                  # root-infra (sync-wave -2) + root-applications (sync-wave -1)
    ├── infra/                 # ingress-nginx (Helm, via ArgoCD)
    └── applications/          # 1 Application por microsserviço + kustomization.yaml
```

## 🚦 Bootstrap (primeira vez, único passo manual)

```bash
kubectl apply -f argocd/root.yaml
```

Isso sobe o padrão *app-of-apps*: `root.yaml` → `argocd/root/root-infra.yaml` (sync-wave `-2`, hoje só `ingress-nginx`) → `argocd/root/root-applications.yaml` (sync-wave `-1`, as 3 Applications dos microsserviços) → cada chart em `helm/`. Daí em diante, tudo é `git push` — sem `kubectl apply` manual (`selfHeal: true` + `prune: true` em toda Application).

**Antes do primeiro apply**: confirmar que `repoURL: https://github.com/nascied/fiap-tech-challenge-fase-5-gitops` (em `argocd/root.yaml` e em todas as `argocd/applications/*.yaml`) é mesmo a URL final do repositório — está marcado com comentário em cada arquivo, mas nunca foi confirmado contra um cluster real.

## ⚙️ Os 3 charts

| | `ngo-service` | `donation-service` | `volunteer-service` |
|---|---|---|---|
| Porta / rota Ingress | `8081` / `/ngos` | `8082` / `/donations` | `8083` / `/volunteers` |
| Persistência | RDS `ngo_db` | RDS `donation_db` + SQS | DynamoDB |
| Secrets | AWS Secrets Manager via CSI Driver (só `DATABASE_URL`) | AWS Secrets Manager via CSI Driver | AWS Secrets Manager via CSI Driver |
| `db-init` (Job pré-install) | ✅ | ✅ | ❌ (DynamoDB, sem schema SQL) |
| Autoscaling | HPA nativo (CPU 70% / mem 80%, 1–3 réplicas) | idem | idem |

`/health` de propósito **não** entra no Ingress — só serve liveness/readiness probe; os 3 serviços colidiriam numa rota `/health` única. Nenhum serviço usa KEDA (removido deliberadamente — nenhum é consumidor de fila; só `donation-service` publica em `solidary-donations`). `requests`/`limits` de CPU/memória são hoje idênticos entre os 3 serviços (100m/128Mi → 200m/256Mi) — pendente de calibração com métrica real (Rightsizing, requisito de FinOps do hackathon).

### Secrets via AWS Secrets Manager (os 3 serviços)

Em vez de `Secret` literal no Helm, `DATABASE_URL`/`AWS_SQS_URL`/credenciais AWS vêm do Secrets Manager (`module.secrets`, repo infra) via **Secrets Store CSI Driver**:
- `templates/serviceaccount.yaml` — sem anotação IRSA (conta AWS Academy não permite criar IAM role própria); cai pra `LabRole` do node via IMDS.
- `templates/secretproviderclass.yaml` — lê o secret do Secrets Manager e sincroniza pra um `Secret` nativo via `secretObjects`.
- `values.yaml` → `awsSecrets.keys` — lista de env vars que viram `secretKeyRef` no Deployment.

`ngo-service` é o único que não acessa mais nenhum outro recurso AWS além disto (não usa SQS/DynamoDB/credenciais) — o secret dele só existe pra sincronizar o `DATABASE_URL` real do RDS automaticamente, em vez do placeholder literal fixo (`CHANGE_ME`) que existia antes, sem nenhum mecanismo de atualização pós-`terraform apply`.

**`db-init` (`ngo-service`/`donation-service`) e o CSI Driver**: o Secret nativo do Kubernetes só é sincronizado pelo CSI Driver quando algum pod monta o volume `aws-secrets` — por isso o próprio Job de `db-init` também monta esse volume e lê `DATABASE_URL` do arquivo (`/mnt/secrets-store/DATABASE_URL`), não de `secretKeyRef`/env var. Um `secretKeyRef` dependeria do Secret já existir antes do hook rodar, o que não é garantido (bug real encontrado nesta verificação: antes disso, o Job lia um valor de `values.yaml` que não existia mais desde que o serviço passou a usar `awsSecrets`, rodando `psql` com `DATABASE_URL` vazio).

## ⚙️ CI/CD — recebendo do repositório `services`

Este repositório não tem pipeline própria de deploy — quem dispara mudança aqui são as 3 pipelines de CI/CD do [`fiap-tech-challenge-fase-5-services`](https://github.com/nascied/fiap-tech-challenge-fase-5-services) (`ci-{ngo,donation,volunteer}-service.yaml`), depois de publicar a imagem no ECR em cada `push` pra `main`.

`.github/workflows/update-image.yaml` é um workflow **reutilizável** (`workflow_call`, não dispara sozinho): recebe `service`, `image_repository` e `image_tag`, faz checkout deste repositório, atualiza `.image.repository`/`.image.tag` no `values.yaml` do chart Helm correspondente com `yq`, e comita/dá push direto na `main` (com retry em caso de conflito de push concorrente) — o ArgoCD (`selfHeal: true`) sincroniza a partir daí, sem passo manual.

Precisa de um secret `GITOPS_PUSH_TOKEN` (token com permissão de push neste repositório) configurado **no repositório `services`**, não aqui — é de lá que o job efetivamente roda (contexto do repositório chamador de um `workflow_call` reutilizável).

## 🧩 ArgoCD

- `argocd/infra/` — só `ingress-nginx` hoje (Helm, via ArgoCD).
- `argocd/applications/` — uma `Application` por microsserviço, `namespace: fiap-tc-f5`, `selfHeal: true` + `prune: true`, `targetRevision: main`.
- Ingress sem prefixo/regex/`rewrite-target` — cada serviço expõe a rota real diretamente.

## ⚠️ Status Atual (honestidade)

| Componente | Situação |
|---|---|
| Charts Helm (3) | 🟡 Validados com `helm lint` + `helm template` — **nunca sincronizados contra um cluster EKS real** |
| Applications ArgoCD | 🟡 `repoURL` nunca confirmado contra um `git remote` real (ver bootstrap acima) |
| `repoURL` do ingress-nginx (`argocd/infra/application-ingress-nginx.yaml`) | ✅ aponta pro chart oficial `https://kubernetes.github.io/ingress-nginx` — correto, não é resíduo |
| `update-image.yaml` (recebe do repo `services`) | 🟡 implementado, sintaxe validada — **nunca chamado de uma run real** (depende das pipelines do repo `services` rodarem primeiro) |

Sem cluster real disponível nesta sessão pra validar o sync de ponta a ponta — ver `fiap-tech-challenge-fase-5-infra/docs/drp/DRP.md` e `scripts/README.md` (repo infra) pro caminho de subir o EKS antes do primeiro `kubectl apply -f argocd/root.yaml`.

## 👨‍💻 Autor

**Edson Leandro da Silva Nascimento** — Pós-Tech FIAP, Arquitetura Cloud e DevOps, Hackathon Fase 5.
