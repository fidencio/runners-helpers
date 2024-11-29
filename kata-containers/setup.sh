#!/usr/bin/env bash

# Copyright (c) 2024 Intel Corporation
#
# SPDX-License-Identifier: Apache-2.0
#

set -o errexit
set -o nounset
set -o pipefail
set -o errtrace

[ -n "${DEBUG:-}" ] && set -o xtrace

source /etc/os-release

readonly script_name=${0##*/}

script_called_time="$(date)"

CONTAINERD_VERSION="${CONTAINERD_VERSION:-latest}"
HTTPS_PROXY="${HTTPS_PROXY:-${https_proxy:-}}"
HTTP_PROXY="${HTTP_PROXY:-${http_proxy:-}}"
NO_PROXY="${NO_PROXY:-${no_proxy:-}}"

function _die() {
    local msg="$*"
	echo >&2 "ERROR: ${msg}"

    exit 1
}

function _warn()
{
    local msg="$*"
    echo "WARNING: ${msg}"
}

function _info()
{
    local msg="$*"
    echo "INFO: ${msg}"
}

function _usage()
{
	local ret=${1}
	cat << EOF
Usage ${script_name} install|uninstall

Description:
  This script is made to install / uninstall kuberntes for the Kata Containers CI
  and is totally tailored for that (and other general use cases are not supported).

When and how to use:
  If we happen to notice that a CI is failing due to nydus snapshotter issues, simply do:
  """
    ${script_name} uninstall
    sudo systemctl reboot
    ${script_name} install
  """
EOF

	return ${ret}
}

function _drop_in_proxy_snippet()
{
	local snippet_path="${1}"
	if [ -z "${HTTPS_PROXY}" ] && [ -z "${HTTP_PROXY}" ] && [ -z "${NO_PROXY}" ]; then
		_info "_drop_in_proxy_snippet | proxy is not required for the system, skip setting it up ..."
		return
	fi

	if [ -z "${snippet_path}" ]; then
		_warn "_drop_in_proxy_snippet | An error in the script itself was found, please consider reporting it back to \"https://github.com/fidencio/runners-helpers/issues\""
		_die "_drop_in_proxy_snippet | The snippet_path is required, but was not passed"
	fi

	sudo mkdir -p "${snippet_path}"
	_info "_drop_in_proxy_snippet: dropping the proxy.conf snippet to ${snippet_path}"
	local snippet_file="${1}/proxy.conf"
	sudo tee "${snippet_file}" << EOF
[Service]
Environment="no_proxy=${NO_PROXY}"
Environment="https_proxy=${HTTPS_PROXY}"
Environment="http_proxy=${HTTP_PROXY}"
Environment="NO_PROXY=${NO_PROXY}"
Environment="HTTPS_PROXY=${HTTPS_PROXY}"
Environment="HTTP_PROXY=${HTTP_PROXY}"
EOF

	sudo systemctl daemon-reload
}

function _remove_proxy_snippet()
{
	local snippet_path="${1}"

	if [ -z "${snippet_path}" ]; then
		_warn "_remove_proxy_snippet | An error in the script itself was found, please consider reporting it back to \"https://github.com/fidencio/runners-helpers/issues\""
		_die "_remove_proxy_snippet | The snippet_path is required, but was not passed"
	fi

	local snippet_file="${1}/proxy.conf"
	if [ -f "${snippet_file}" ]; then
		_info "_remove_proxy_snippet: removing the proxy.conf snippet from ${snippet_path}"
		rm -f "${snippet_file}"
	fi

	sudo systemctl daemon-reload
}

function _install_containerd()
{
	_info ""
	_info "_install_containerd | installing containerd: ${CONTAINERD_VERSION} ..."

	# from /etc/os-release
	case ${NAME} in
		Ubuntu)
			sudo apt update
			sudo apt -y install runc
			;;
		CentOS\ Stream)
			sudo dnf -y install runc
			;;
	esac

	local containerd_version="${CONTAINERD_VERSION}"
	if [ "${containerd_version}" = "latest" ]; then
		containerd_version=$(curl --silent https://api.github.com/repos/containerd/containerd/releases | jq -r .[].tag_name | grep -E "^v[0-9]+\.[0-9]+\.[0-9]+$" | sort -r | head -1)
	fi

	if ! echo "${containerd_version}" | grep -E "^v[0-9]+\.[0-9]+\.[0-9]+$"; then
		_warn "_install_containerd | Something went wrong when getting the containerd version"
		_warn "_install_containerd | You can manually check on your side by running the following command: "
		if [ "${CONTAINERD_VERSION}" == "latest" ]; then
			_warn "CONTAINERD_VERSION=\$(curl --silent https://api.github.com/repos/containerd/containerd/releases | jq -r .[].tag_name | grep -E "^v[0-9]+\.[0-9]+\.[0-9]+$" | sort -r | head -1)"
		fi
		_warn "echo \${CONTAINERD_VERSION} | grep -E \"^v[0-9]+\.[0-9]+\.[0-9]+$\""
		_die "_install_containerd | containerd_version does not follow the expected format (\"^v[0-9]+\.[0-9]+\.[0-9]+$\")"
	fi

	wget https://github.com/containerd/containerd/releases/download/${containerd_version}/containerd-${containerd_version#v}-linux-amd64.tar.gz
	sudo tar xvzpf containerd-${containerd_version#v}-linux-amd64.tar.gz -C /usr/local/
	rm -f containerd-${containerd_version#v}-linux-amd64.tar.gz 

	sudo mkdir -p /etc/containerd
	containerd config default | sudo tee /etc/containerd/config.toml
	pushd /etc/systemd/system
		sudo -E wget https://raw.githubusercontent.com/containerd/containerd/refs/heads/main/containerd.service
	popd
	_drop_in_proxy_snippet "/etc/systemd/system/containerd.service.d"

	sudo tee /etc/modules-load.d/containerd.conf <<EOF
overlay
br_netfilter
EOF
	sudo modprobe overlay
	sudo modprobe br_netfilter

	sudo systemctl enable --now containerd

	_info "_install_containerd | containerd installed"
	_info ""
}

function _uninstall_containerd()
{
	sudo rm -f /etc/modules-load.d/containerd.conf
	_remove_proxy_snippet "/etc/systemd/system/containerd.service.d"
	sudo rm -f /etc/systemd/system/containerd.service
	sudo rm -f /usr/local/bin/containerd
	sudo rm -f /usr/local/bin/containerd-shim-runc-v2
	sudo rm -f /usr/local/bin/containerd-stress
	sudo rm -f /usr/local/bin/ctr
	sudo rm -rf /var/lib/containerd*
	sudo rm -rf /opt/containerd
}

function _install_k8s()
{
	_info ""
	_info "_install_k8s | installing k8s from the distro ..."

	sudo tee /etc/sysctl.d/k8s.conf <<EOF
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables = 1
net.ipv4.ip_forward = 1
EOF
	sudo sysctl --system

	# from /etc/os-release
	case ${ID} in
		ubuntu)
			curl -fsSL https://pkgs.k8s.io/core:/stable:/$(curl -Ls https://dl.k8s.io/release/stable.txt | cut -d. -f-2)/deb/Release.key | sudo gpg -y --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
			echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/$(curl -Ls https://dl.k8s.io/release/stable.txt | cut -d. -f-2)/deb/ /" | sudo tee /etc/apt/sources.list.d/kubernetes.list
			sudo apt update
			sudo apt -y install kubeadm kubelet kubectl
			sudo apt-mark hold kubeadm kubelet kubectl
			;;
		centos)
			sudo systemctl disable --now firewalld
			sudo tee /etc/yum.repos.d/kubernetes.repo << EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.31/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.31/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
			sudo dnf makecache
			sudo dnf -y install kubelet kubeadm kubectl --disableexcludes=kubernetes
			;;
	esac

	_drop_in_proxy_snippet "/etc/systemd/system/kubelet.service.d"
	sudo systemctl restart kubelet

	_info "_install_k8s | k8s installed"
	_info ""
}

function _uninstall_k8s()
{
	_info ""
	_info "_uninstall_k8s | uninstalling k8s ..."

	_remove_proxy_snippet "/etc/systemd/system/kubelet.service.d"

	# from /etc/os-release
	case ${ID} in
		ubuntu)
			sudo apt --allow-change-held-packages -y remove kubeadm kubelet kubectl
			;;
		centos)
			sudo dnf -y erase kubelet
			;;
	esac

	sudo rm -f /etc/sysctl.d/k8s.conf
	sudo sysctl --system

	_info "_uninstall_k8s | k8s uninstalled"
	_info ""
}

function _setup_k8s()
{
	_info ""
	_info "_setup_k8s | setting up k8s ..."
	sudo systemctl enable --now kubelet
	sudo -E kubeadm config images pull
	sudo -E kubeadm init --pod-network-cidr=10.244.0.0/16
	mkdir -p ${HOME}/.kube
	sudo cp -i /etc/kubernetes/admin.conf ${HOME}/.kube/config
	sudo chown $(id -u):$(id -g) ${HOME}/.kube/config
	kubectl apply -f https://github.com/flannel-io/flannel/releases/latest/download/kube-flannel.yml
	kubectl taint nodes --all node-role.kubernetes.io/control-plane-

	_info "_setup_k8s | k8s set up"
	_info ""
}

function _reset_k8s()
{
	_info ""
	_info "_reset_k8s | resetting k8s ..."

   sudo kubeadm reset -f	
   rm -rf ${HOME}/.kube

   _info "_reset_k8s | k8s reset"
}

function _deploy_nydus()
{
	_info ""
	_info "_deploy_nydus | deploying nydus snapshotter ..."

	rm -rf /tmp/kata-containers
	git clone https://github.com/kata-containers/kata-containers /tmp/kata-containers
	pushd /tmp/kata-containers/tests/integration/kubernetes
		K8S="vanilla" KATA_RUNTIME="qemu" CONTAINER_RUNTIME="containerd" SNAPSHOTTER="nydus" PULL_TYPE="guest-pull" ./gha-run.sh deploy-snapshotter
	popd

	_info "_deploy_nydus | nydus snapshotter deployed"
}

function _undeploy_nydus()
{
	_info ""
	_info "_undeploy_nydus | undeploying nydus snapshotter ..."

	rm -rf /tmp/kata-containers
	git clone https://github.com/kata-containers/kata-containers /tmp/kata-containers
	pushd /tmp/kata-containers/tests/integration/kubernetes
		K8S="vanilla" KATA_RUNTIME="qemu" CONTAINER_RUNTIME="containerd" SNAPSHOTTER="nydus" PULL_TYPE="guest-pull" ./gha-run.sh delete-snapshotter
	popd

	_info "_undeploy_nydus | nydus undeplayed"
}

function _stop_all_services()
{
	for svc in nydus-snapshotter kubelet containerd; do
		sudo systemctl stop "${svc}" || true
		sudo systemctl disable "${svc}" || true
	done
}

function _ask_user_to_reboot()
{
	_info "Please, reboot your machine now"
}

function _main()
{
	# from /etc/os-release
	case ${ID} in
		ubuntu)
			;;
		centos)
			sudo setenforce 0
			sudo dnf -y install wget git fuse
			;;
		*)
			_die "${NAME} is not supported by this script"
			;;
	esac

	[ -z "${@}" ] && _usage 1

	case "${1}" in
		install) _install_containerd && _install_k8s && _setup_k8s && _deploy_nydus ;;
		uninstall) _stop_all_services && _undeploy_nydus && _reset_k8s && _uninstall_k8s && _uninstall_containerd && _ask_user_to_reboot ;;
		*)
			_warn "option \"${1}\" is not valid"
			_usage 1
			;;
	esac
}

_main "${@}"
