#!/usr/bin/env bash

### Script variables injected by the pipeline
# username: username to configure on the VM
# url: Azure DevOps URL to connect
# token: Azure DevOps Personal Access Token (PAT) for given organization to authenticate Agent Pool
# pool: Azure DevOps agent pool to connect
# name: Name of the agent to configure in Azure DevOps
# kubeconfig: base64 encoded kubernetes configuration file

### Script variables
home_dir="/home/${username}"
agent_home="/home/${username}/agent"
agent_version="3.218.0"
terraform_version="1.3.7"

### Helper functions
log_heading() {
    echo "### $1"
}

log_install() {
    log_heading "Install: $1"
}

### Agent VM Setup
#
log_heading "Agent VM Setup"

# Setup Azure DevOps Agent
log_heading "Setup Azure DevOps Agent"
log_heading "Preparing Azure DevOps agent folder"
mkdir -p $agent_home
cd $agent_home
if [ ! -f ./svc.sh ]; then
    echo "Downloading Azure DevOps agent package"
    sudo wget -O agent.tar.gz https://vstsagentpackage.azureedge.net/agent/$agent_version/vsts-agent-linux-x64-$agent_version.tar.gz
    tar zxvf agent.tar.gz
    echo "Configure the agent"
    sudo -u ${username} ./config.sh --unattended --url ${url} --auth pat --token ${token} --pool ${pool} --agent ${name} --acceptTeeEula --work ./_work # --runAsService
    echo "Install agent service"
    ./svc.sh install ${username}
    echo "Starting agent service"
    ./svc.sh start
else
    echo "Agent already installed"
fi

log_heading "Create Azure DevOps agent scheduled cleanup script"
cat << EOF > ${agent_home}/cleanup-cron.sh
#!/usr/bin/env bash

clean_work() {
    sudo rm -rf ${agent_home}/_work
}

if apid=\$(pidof Agent.Listener); then
    # Agent is running
    tries=1
    while [ \$tries -lt "15" ]; do
        if ! pgrep -P \$apid > /dev/null; then
            # No build running
            cd ${agent_home}
            sudo ./svc.sh stop
            clean_work
            sudo ./svc.sh start
            break
        else
            tries=\$((tries+1))
            sleep 60
        fi
    done
fi

EOF

chown ${username}:${username} ${agent_home}/cleanup-cron.sh
chmod +x ${agent_home}/cleanup-cron.sh

log_heading "Create user crontab file"
cat << EOF > ${agent_home}/cron.txt
15 1,3,5 * * 6 ${agent_home}/cleanup-cron.sh > /dev/null

EOF

chown ${username}:${username} ${agent_home}/cron.txt
crontab -u ${username} ${agent_home}/cron.txt

# Prepare Kubernetes config file
cd $home_dir

log_heading "Prepare .kube/config"
mkdir ${home_dir}/.kube
echo "${kubeconfig}" | base64 -d > ${home_dir}/.kube/config
chown ${username}:${username} -R ${home_dir}/.kube
chmod 600 ${home_dir}/.kube/config

# Ubuntu packages
log_install "Ubuntu packages"
# Update the list of repositories
sudo apt update
sudo apt install apt-utils -qq
sudo apt install -qq --no-install-recommends \
    apt-transport-https \
    ca-certificates \
    curl \
    file \
    ftp \
    git \
    gnupg \
    iproute2 \
    iputils-ping \
    jq \
    locales \
    lsb-release \
    netcat \
    python-pip \
    software-properties-common \
    sudo \
    time \
    unzip \
    wget \
    zip \
    zsh \

# Azure CLI
log_install "Azure CLI"
curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash
az --version

# PowerShell
log_install "Powershell"
# Download the Microsoft repository GPG keys
wget -q "https://packages.microsoft.com/config/ubuntu/$(lsb_release -rs)/packages-microsoft-prod.deb"
# Register the Microsoft repository GPG keys
sudo dpkg -i packages-microsoft-prod.deb
# Delete the the Microsoft repository GPG keys file
rm packages-microsoft-prod.deb
# Update the list of packages after we added packages.microsoft.com
sudo apt update
# Install PowerShell
sudo apt install -y powershell
pwsh --version
# PowerShell Modules
sudo pwsh -Command Set-PSRepository -InstallationPolicy Trusted -Name "PSGallery"
sudo pwsh -Command Set-PSRepository -InstallationPolicy Untrusted -Name "PSGallery"
sudo pwsh -Command Install-Module -Name Az -AllowClobber -Scope AllUsers -Force

# Kubectl
log_install "Kubectl"
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
chmod +x kubectl
mv ./kubectl /usr/local/bin/kubectl
kubectl version --output yaml

# Helm
log_install "Helm"
curl -fsSL -o get_helm.sh https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3
chmod 700 get_helm.sh
./get_helm.sh
rm get_helm.sh

# Docker
log_install "Docker"
if !(dpkg -l docker-ce); then
    # Install Docker
    curl -fsSL https://get.docker.com -o get-docker.sh
    sudo sh get-docker.sh 
    sudo usermod -aG docker ${username}
    rm get-docker.sh
else
    # Update Docker
    sudp apt upgrade -y docker-ce
fi

# Terraform
log_install "Terraform"
wget -O- https://apt.releases.hashicorp.com/gpg | gpg --dearmor | sudo tee /usr/share/keyrings/hashicorp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/hashicorp-archive-keyring.gpg] https://apt.releases.hashicorp.com $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/hashicorp.list
sudo apt update && sudo apt install terraform=$terraform_version
terraform version

# Ansible
log_install "Ansible"
sudo add-apt-repository --yes --update ppa:ansible/ansible
sudo apt install -y ansible

log_heading "Done"

exit 0
