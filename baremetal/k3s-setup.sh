#!/usr/bin/env bash
main_pid=$$
date=$(date "+%Y%m%d%H%M%S")
self_name=$(basename "$0")
self_path=$(cd -- "$(dirname "${BASH_SOURCE[0]:-$0}")" >/dev/null 2>&1 && pwd)

if [[ -n "$SUDO_USER" ]]; then
  unset _sudo
  usr="$SUDO_USER"
  grp="$SUDO_GID"
else
  _sudo="sudo"
  usr="$LOGNAME"
  grp="$(id -g)"
fi
echo "$usr / $grp"

echo "Installing K3s..."
curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION=v1.28.11+k3s2 K3S_KUBECONFIG_MODE=644 sh -s - server --disable traefik
if [[ -f ~/.kube/config ]] && [[ ! -L ~/.kube/config ]]; then
  mv ~/.kube/config ~/.kube/config.$date.bkp
fi
mkdir -p ~/.kube && ln -fs /etc/rancher/k3s/k3s.yaml ~/.kube/config

echo "Installing Helm..."
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

if [[ -f "$self_path/docker-registry.yaml" ]]; then
  if ! grep -qE '^[[:space:]]*127.0.0.1[[:space:]]*registry.localhost[[:space:]]*' /etc/hosts; then
    echo "127.0.0.1   registry.localhost # K3s private registry" | $_sudo tee -a /etc/hosts >/dev/null
  fi

  if ! kubectl get namespace docker-registry >/dev/null 2>&1; then
    kubectl create namespace docker-registry
  fi
  kubectl apply -f $self_path/docker-registry.yaml --namespace docker-registry

  registries="/etc/rancher/k3s/registries.yaml"
  if ! $_sudo test -f $registries; then
    $_sudo touch $registries && $_sudo chmod 600 $registries
  fi

  if ! $_sudo grep -q '^  registry.localhost:' $registries; then
    if ! $_sudo grep -q '^mirrors:' $registries; then
      echo "mirrors:" | $_sudo tee -a $registries >/dev/null
    fi
    echo "  registry.localhost:" | $_sudo tee -a $registries >/dev/null
    echo "    endpoint:" | $_sudo tee -a $registries >/dev/null
    echo "      - \"http://registry.localhost\"" | $_sudo tee -a $registries >/dev/null
  fi

  $_sudo systemctl restart k3s.service
  while ! systemctl is-active --quiet k3s.service; do
    printf "."
    sleep 0.2
  done

else
  echo "docker-registry.yaml not found, not deploying private registry"
fi

[[ -z "$K2_AGENT_REPO" ]] && K2_AGENT_REPO="https://raw.githubusercontent.com/k2view/blueprints/main/helm/k2view-agent"
[[ -z "$K2_AGENT_CHART" ]] && K2_AGENT_CHART="k2view-agent/k2view-agent"
[[ -z "$K2_MANAGER_URL" ]] && K2_MANAGER_URL="https://cloud.k2view.com/api/mailbox"
[[ -z "$K2_MAILBOX_ID" ]] && mailbox_placeholder="no default - this should be provided by K2view" || mailbox_placeholder="press Enter to use '$K2_MAILBOX_ID'"

if [[ -z "$no_prompt" ]] || [[ "$no_prompt" == "false" ]]; then
  echo "Configuring K2view Agent..."

  read -p "  - Enter K2view Agent Helm repository [press Enter to use '$K2_AGENT_REPO']: " input
  [[ -n "$input" ]] && K2_AGENT_REPO="$input"

  read -p "  - Enter Mailbox URL [press Enter to use '$K2_MANAGER_URL']: " input
  [[ -n "$input" ]] && K2_MANAGER_URL="$input"

  read -p "  - Enter Mailbox ID [$mailbox_placeholder]: " input
  [[ -n "$input" ]] && K2_MAILBOX_ID="$input"
fi

if [[ -n "$K2_MAILBOX_ID" ]]; then
  echo "Installing K2view Agent..."
  helm repo add k2view-agent "$K2_AGENT_REPO"
  helm upgrade --install k2view-agent --debug --wait --set secrets.K2_MANAGER_URL="$K2_MANAGER_URL" --set secrets.K2_MAILBOX_ID="$K2_MAILBOX_ID" "$K2_AGENT_CHART"
else
  echo "No Mailbox ID provided, skipping K2view Agent installation"
fi

[[ -z "$INGRESS_REPO" ]] && INGRESS_REPO="https://raw.githubusercontent.com/gm-k2v/blueprints-fork/dev/gm/k2v-ingress/helm/k2v-ingress"
[[ -z "$INGRESS_CHART" ]] && INGRESS_CHART="k2v-ingress/k2v-ingress"
[[ -z "$INGRESS_DOMAIN" ]] && domain_placeholder="no default - ie: k3scluster.example.com" || domain_placeholder="press Enter to use '$INGRESS_DOMAIN'"
[[ -z "$INGRESS_CERT" ]] && cert_placeholder="no default - ie: /path/to/file" || cert_placeholder="press Enter to use '$INGRESS_CERT'"
[[ -z "$INGRESS_KEY" ]] && key_placeholder="no default - ie: /path/to/file" || key_placeholder="press Enter to use '$INGRESS_KEY'"

if [[ -z "$no_prompt" ]] || [[ "$no_prompt" == "false" ]]; then
  echo "Configuring ingress controller..."

  read -p "  - Enter Ingress-NGINX Helm repository [press Enter to use '$INGRESS_REPO']: " input
  [[ -n "$input" ]] && INGRESS_REPO="$input"

  read -p "  - Enter cluster URL [$domain_placeholder]: " input
  [[ -n "$input" ]] && INGRESS_DOMAIN="$input"

  read -p "  - Enter SSL certificate to be used by the cluster [$cert_placeholder]: " input
  [[ -n "$input" ]] && INGRESS_CERT="$input"

  read -p "  - Enter SSL key to be used by the cluster [$key_placeholder]: " input
  [[ -n "$input" ]] && INGRESS_KEY="$input"
fi

unset set_domain set_sslcrt set_sslkey set_sslsecret
[[ -n "$INGRESS_DOMAIN" ]] && set_domain="--set domain=$INGRESS_DOMAIN"
[[ -n "$INGRESS_CERT" ]] && { INGRESS_CERT=${INGRESS_CERT/\~\//$HOME/}; [[ -f "$INGRESS_CERT" ]] && set_sslcrt="--set tlsSecret.cert=$(base64 -w 0 "$INGRESS_CERT")" || echo "SSL certificate '$INGRESS_CERT' not found, not configuring SSL"; }
[[ -n "$INGRESS_KEY" ]] && { INGRESS_KEY=${INGRESS_KEY/\~\//$HOME/}; [[ -f "$INGRESS_KEY" ]] && set_sslkey="--set tlsSecret.key=$(base64 -w 0 "$INGRESS_KEY")" || echo "SSL key '$INGRESS_KEY' not found, not configuring SSL"; }
[[ -n "$set_sslcrt" ]] && [[ -n "$set_sslkey" ]] && set_sslsecret='--set ingress-nginx.controller.extraArgs.default-ssl-certificate=$(POD_NAMESPACE)/wildcard-certificate'

helm repo add k2v-ingress "$INGRESS_REPO"
helm upgrade --install ingress-nginx --namespace ingress-nginx --create-namespace $set_domain $set_sslkey $set_sslcrt $set_sslsecret "$INGRESS_CHART"
