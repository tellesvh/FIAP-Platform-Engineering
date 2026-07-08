#!/usr/bin/env bash
# Provisiona o GitLab Runner do Trabalho Final, reaproveitando o codigo do
# Modulo 02 (terraform-gitlab-runner + playbook Ansible) e a rede do Lab 01.2.
# O objetivo e tirar a friccao: o provisionamento nao e o que se avalia no
# Trabalho Final, entao vem pronto — o aluno roda UM comando e foca no codigo.
#
# IDEMPOTENTE / RESUMIVEL: pode rodar quantas vezes quiser. Cada etapa checa o
# que ja esta pronto e pula; se algo faltou, continua de onde parou. Se tudo ja
# esta de pe, nao faz nada destrutivo.
#
# PRE-REQUISITO (feito na Parte 0 do README, na UI do GitLab):
#   1. criar o projeto e o runner (tags shell,terraform) -> copiar o token
#   2. guardar o token no SSM:
#        aws ssm put-parameter --name /fiap/gitlab-runner/token \
#          --type SecureString --value "SEU-TOKEN" --region us-east-1 --overwrite
#
# Uso:  bash provisionamento/subir-runner.sh [nome-do-runner]
#
# Convencao de saida: stdout = resultado util; stderr = progresso.
set -euo pipefail
log() { printf '>> %s\n' "$*" >&2; }

REPO="/workspaces/FIAP-Platform-Engineering"
RUNNER_TF="$REPO/02-Ansible/01-provisionando-gitlab-runner/terraform-gitlab-runner"
ANSIBLE_DIR="$REPO/02-Ansible/01-provisionando-gitlab-runner/ansible-gitlab-runner"
NET_VPC="$REPO/01-Terraform/demos/02-Modules/vpc-call"
NET_RT="$REPO/01-Terraform/demos/02-Modules/RT-call"
RUNNER_NAME="${1:-gitlab-runner-trabalho-final}"
TOKEN_SSM_PATH="/fiap/gitlab-runner/token"
REGION="us-east-1"

log "1/6 Validando credenciais AWS..."
aws sts get-caller-identity >/dev/null || { echo "ERRO: credenciais AWS invalidas/expiradas." >&2; exit 1; }

log "2/6 Confirmando o token do runner no SSM ($TOKEN_SSM_PATH)..."
aws ssm get-parameter --name "$TOKEN_SSM_PATH" --with-decryption --region "$REGION" >/dev/null 2>&1 || {
  echo "ERRO: token nao encontrado em $TOKEN_SSM_PATH." >&2
  echo "Grave com: aws ssm put-parameter --name $TOKEN_SSM_PATH --type SecureString --value 'SEU-TOKEN' --region $REGION --overwrite" >&2
  exit 1
}

log "3/6 Descobrindo o bucket de state (base-config-*)..."
BUCKET="$(aws s3 ls | awk '{print $3}' | grep '^base-config' | head -1)"
[ -n "$BUCKET" ] || { echo "ERRO: nenhum bucket 'base-config-*' encontrado. Crie o do setup (Modulo 01)." >&2; exit 1; }
log "    bucket = $BUCKET"

log "4/6 Garantindo a rede fiap-lab (Lab 01.2)..."
# O runner e a infra do trabalho descobrem a VPC 'fiap-lab' por tag. Se ela nao
# existe (conta nova/rotacionada, ou o Lab 01.2 nao foi feito), o 'terraform
# apply' quebraria com "no matching EC2 VPC found". Entao garantimos aqui:
# 0 VPCs -> aplica o Lab 01.2 (vpc-call + RT-call); 1 -> ok; >1 -> aborta (ambiguo).
VPC_COUNT="$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=fiap-lab" --region "$REGION" --query 'length(Vpcs)' --output text 2>/dev/null || echo 0)"
if [ "$VPC_COUNT" = "0" ]; then
  log "    rede ausente — criando (vpc-call + RT-call, state local)..."
  ( cd "$NET_VPC" && terraform init -input=false >/dev/null && terraform apply -auto-approve -input=false >/dev/null )
  ( cd "$NET_RT"  && terraform init -input=false >/dev/null && terraform apply -auto-approve -input=false >/dev/null )
  log "    rede fiap-lab criada."
elif [ "$VPC_COUNT" = "1" ]; then
  log "    rede fiap-lab ja existe — ok."
else
  echo "ERRO: existem $VPC_COUNT VPCs com tag Name=fiap-lab. Deixe apenas uma (o data source exige)." >&2
  exit 1
fi

log "5/6 Preparando o tooling do Ansible (venv, boto3, collections, session-manager-plugin)..."
if [ -x "$HOME/venv/bin/ansible-playbook" ] && command -v session-manager-plugin >/dev/null; then
  log "    tooling ja instalado — pulando."
  # shellcheck disable=SC1091
  source "$HOME/venv/bin/activate"
else
  sudo apt-get update -y >/dev/null 2>&1
  sudo apt-get install -y python3 python3-venv python3-pip jq curl >/dev/null 2>&1
  [ -d "$HOME/venv" ] || python3 -m venv "$HOME/venv"
  # shellcheck disable=SC1091
  source "$HOME/venv/bin/activate"
  pip install --quiet ansible boto3 botocore
  ansible-galaxy collection install --force community.aws amazon.aws >/dev/null
  if ! command -v session-manager-plugin >/dev/null; then
    curl -sSL "https://s3.amazonaws.com/session-manager-downloads/plugin/latest/ubuntu_64bit/session-manager-plugin.deb" -o /tmp/smp.deb
    sudo dpkg -i /tmp/smp.deb >/dev/null
  fi
fi

log "6/6 Provisionando a EC2 do runner com Terraform..."
# Bucket via -backend-config (nao editamos o state.tf versionado do Modulo 02).
# 'terraform apply' e idempotente: se a EC2 ja existe no state, nao recria.
cd "$RUNNER_TF"
terraform init -input=false -reconfigure -backend-config="bucket=$BUCKET" >/dev/null
terraform apply -auto-approve -input=false >/dev/null
INSTANCE_ID="$(terraform output -raw instance_id)"
log "    EC2 = $INSTANCE_ID"

# Registro idempotente: se o runner ja esta registrado e VALIDO nesta EC2, pula
# o Ansible; senao, roda o playbook (que instala/configura/registra).
log "    Verificando se o runner ja esta configurado..."
ALREADY="no"
CHK_CMD="$(aws ssm send-command --instance-ids "$INSTANCE_ID" --document-name AWS-RunShellScript \
  --parameters 'commands=["gitlab-runner verify 2>&1 | grep -q \"is valid\" && echo RUNNER_OK || echo RUNNER_NOK"]' \
  --region "$REGION" --query 'Command.CommandId' --output text 2>/dev/null || true)"
if [ -n "$CHK_CMD" ]; then
  sleep 6
  CHK_OUT="$(aws ssm get-command-invocation --command-id "$CHK_CMD" --instance-id "$INSTANCE_ID" --region "$REGION" --query 'StandardOutputContent' --output text 2>/dev/null || true)"
  case "$CHK_OUT" in *RUNNER_OK*) ALREADY="yes" ;; esac
fi

if [ "$ALREADY" = "yes" ]; then
  log "    Runner ja registrado e valido — nada a fazer."
else
  log "    Configurando a EC2 como GitLab Runner (Ansible via SSM)..."
  HOSTS_FILE="$(mktemp)"
  cat > "$HOSTS_FILE" <<EOF
[runner]
$INSTANCE_ID

[all:vars]
ansible_connection=community.aws.aws_ssm
ansible_aws_ssm_bucket_name=$BUCKET
ansible_aws_ssm_region=$REGION
ansible_become=true
EOF
  cd "$ANSIBLE_DIR"
  ansible-playbook -i "$HOSTS_FILE" --extra-vars "gitlab_runner_name=$RUNNER_NAME" play.yaml
  rm -f "$HOSTS_FILE"
fi

log "OK! Runner '$RUNNER_NAME' de pe. Confira em Settings > CI/CD > Runners (online)."
echo "$INSTANCE_ID"
