# Variables
resourceGroup="RG_DorianJohanLeo"
location="eastus"
adminWindowsUsername="AzureAdmin"
adminLinuxUsername="azureadmin"
adminWindowsPassword="Simplon2024@*"
adminLinuxPassword="Simplon2024@*"  # Mettez un mot de passe fort ici
sqlServerName="serversqldj"
sqlDatabaseName="databasedjl"
sqlAdminUser="sqladmin"
sqlAdminPassword="Simplon2024@*"
storageAccountName="storageaccountdjl" # Nom unique pour le compte de stockage
storageContainerName="scripts"
# Adresses des réseaux
monitoringNet="10.3.0.0/24"
dcNet="10.1.0.0/24"
bureauNet="10.5.0.0/24"


# Créer un compte de stockage
az storage account create --resource-group $resourceGroup --name $storageAccountName --location $location --sku Standard_LRS

# Permettre l'accès public au compte de stockage
az storage account update --name $storageAccountName --resource-group $resourceGroup --allow-blob-public-access true

# Obtenir la clé du compte de stockage
storageAccountKey=$(az storage account keys list --resource-group $resourceGroup --account-name $storageAccountName --query '[0].value' --output tsv)

# Créer un conteneur blob
az storage container create --account-name $storageAccountName --name $storageContainerName --account-key $storageAccountKey

# Configurer l'accès public pour le conteneur
az storage container set-permission --account-name $storageAccountName --name $storageContainerName --public-access blob --account-key $storageAccountKey

# Créer le script d'installation Docker et Docker Compose
cat <<EOF > install_docker.sh
#!/bin/bash
# install_docker.sh
# Mettre à jour le système
sudo apt-get update && sudo apt-get upgrade -y

# Installer les dépendances nécessaires
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg lsb-release

# Ajouter la clé GPG officielle de Docker
sudo mkdir -p /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg

# Ajouter le dépôt Docker
echo \
  "deb [arch=\$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian \
  \$(lsb_release -cs) stable" | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Installer Docker Engine, Docker Compose et autres paquets nécessaires
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

# Ajouter les droits au docker daemon socket
sudo chmod 666 /var/run/docker.sock

# Démarrer Docker et activer le démarrage automatique
sudo systemctl start docker
sudo systemctl enable docker

# Exécuter les containers spécifiques (exemples pour TrueNAS, GLPI, Uptime Kuma, HAProxy)
if [ "\$1" == "truenas_glpi" ]; then
  docker run -d --name truenas -p 80:80 truenas/truenas
  cat <<EOL > ~/docker-compose.yml
version: "3.3"
services:
  glpi:
    image: elestio/glpi:latest
    restart: always
    hostname: glpi
    ports:
      - "172.17.0.1:22571:80"
    volumes:
      - /etc/timezone:/etc/timezone
      - /etc/localtime:/etc/localtime
      - ./storage/var/www/html/glpi/:/var/www/html/glpi
    environment:
      - TIMEZONE=Europe/Brussels
EOL
  docker compose -f ~/docker-compose.yml up -d
elif [ "\$1" == "uptime_kuma" ]; then
  docker run -d --name uptime-kuma -p 3001:3001 louislam/uptime-kuma
elif [ "\$1" == "haproxy" ]; then
  mkdir -p /run/haproxy
  sudo chmod 660 /run/haproxy/admin.sock
  sudo usermod -a -G harpoxy azureadmin

  cat <<EOL > ~/docker-compose.yml
version: '3'
services:
  apache1:
    image: httpd:latest
    ports:
      - '8080:80'
  apache2:
    image: httpd:latest
    ports:
      - '8081:80'
  haproxy:
    image: haproxy:latest
    ports:
      - '80:80'
      - '443:443'
    volumes:
      - ./haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg
      - ~/haproxy/run:/run/haproxy
EOL
  cat <<EOL > ~/haproxy.cfg
global
  log /dev/log    local0
  log /dev/log    local1 notice
  chroot /var/lib/haproxy
  stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
  stats timeout 30s
  user haproxy
  group haproxy
  daemon
defaults
  log     global
  mode    http
  option  httplog
  option  dontlognull
  timeout connect 5000
  timeout client  50000
  timeout server  50000
frontend http_front
  bind *:80
  default_backend http_back
backend http_back
  balance roundrobin
  server apache1 127.0.0.1:8080 check
  server apache2 127.0.0.1:8081 check
EOL
  docker compose -f ~/docker-compose.yml up -d

  # Créer un deuxième conteneur HAProxy sans services Apache supplémentaires
  cat <<EOL > ~/docker-compose-2.yml
version: '3'
services:
  haproxy2:
    image: haproxy:latest
    ports:
      - '81:80'
      - '444:443'
    volumes:
      - ./haproxy-2.cfg:/usr/local/etc/haproxy/haproxy.cfg
      - ~/haproxy/run:/run/haproxy
EOL
  cat <<EOL > ~/haproxy-2.cfg
global
  log /dev/log    local0
  log /dev/log    local1 notice
  chroot /var/lib/haproxy
  stats socket /run/haproxy/admin.sock mode 660 level admin expose-fd listeners
  stats timeout 30s
  user haproxy
  group haproxy
  daemon
defaults
  log     global
  mode    http
  option  httplog
  option  dontlognull
  timeout connect 5000
  timeout client  50000
  timeout server  50000
frontend http_front
  bind *:81
  default_backend http_back
backend http_back
  balance roundrobin
  server apache1 127.0.0.1:8080 check
  server apache2 127.0.0.1:8081 check
EOL
  docker compose -f ~/docker-compose-2.yml up -d
fi
EOF

# Télécharger le script d'installation sur le blob de stockage
az storage blob upload --account-name $storageAccountName --container-name $storageContainerName --file install_docker.sh --name install_docker.sh --account-key $storageAccountKey

# Créer les réseaux virtuels, les sous-réseaux, et les NSG

# Réseau DC
az network vnet create \
    --resource-group $resourceGroup \
    --name DC \
    --address-prefix 10.1.0.0/16 \
    --subnet-name default \
    --subnet-prefix 10.1.0.0/24

az network nsg create \
    --resource-group $resourceGroup \
    --name DC-nsg \
    --location $location

az network nsg rule create \
    --resource-group $resourceGroup \
    --nsg-name DC-nsg \
    --name Allow-RDP \
    --protocol tcp \
    --priority 1000 \
    --destination-port-range 3389 \
    --access allow

az network vnet subnet update \
    --vnet-name DC \
    --name default \
    --resource-group $resourceGroup \
    --network-security-group DC-nsg

# Réseau NAS
az network vnet create \
    --resource-group $resourceGroup \
    --name NAS \
    --address-prefix 10.2.0.0/16 \
    --subnet-name default \
    --subnet-prefix 10.2.0.0/24

az network nsg create \
    --resource-group $resourceGroup \
    --name NAS-nsg \
    --location $location

az network nsg rule create \
    --resource-group $resourceGroup \
    --nsg-name NAS-nsg \
    --name Allow-SSH \
    --protocol tcp \
    --priority 1000 \
    --destination-port-range 22 \
    --access allow

az network vnet subnet update \
    --vnet-name NAS \
    --name default \
    --resource-group $resourceGroup \
    --network-security-group NAS-nsg

# Réseau MONITORING
az network vnet create \
    --resource-group $resourceGroup \
    --name MONITORING \
    --address-prefix 10.3.0.0/16 \
    --subnet-name default \
    --subnet-prefix 10.3.0.0/24

az network nsg create \
    --resource-group $resourceGroup \
    --name MONITORING-nsg \
    --location $location

az network nsg rule create \
    --resource-group $resourceGroup \
    --nsg-name MONITORING-nsg \
    --name Allow-SSH \
    --protocol tcp \
    --priority 1000 \
    --destination-port-range 22 \
    --access allow

az network nsg rule create \
    --resource-group $resourceGroup \
    --nsg-name MONITORING80-nsg \
    --name Allow-SSH \
    --protocol tcp \
    --priority 1000 \
    --destination-port-range 3001 \
    --access allow

az network vnet subnet update \
    --vnet-name MONITORING \
    --name default \
    --resource-group $resourceGroup \
    --network-security-group MONITORING-nsg

# Réseau DMZ
az network vnet create \
    --resource-group $resourceGroup \
    --name DMZ \
    --address-prefix 10.4.0.0/16 \
    --subnet-name default \
    --subnet-prefix 10.4.0.0/24

az network nsg create \
    --resource-group $resourceGroup \
    --name DMZ-nsg \
    --location $location

az network nsg rule create \
    --resource-group $resourceGroup \
    --nsg-name DMZ-nsg \
    --name Allow-SSH \
    --protocol tcp \
    --priority 1000 \
    --destination-port-range 22 \
    --access allow

az network vnet subnet update \
    --vnet-name DMZ \
    --name default \
    --resource-group $resourceGroup \
    --network-security-group DMZ-nsg

# Réseau BUREAU
az network vnet create \
    --resource-group $resourceGroup \
    --name BUREAU \
    --address-prefix 10.5.0.0/16 \
    --subnet-name default \
    --subnet-prefix 10.5.0.0/24

az network nsg create \
    --resource-group $resourceGroup \
    --name BUREAU-nsg \
    --location $location

az network vnet subnet update \
    --vnet-name BUREAU \
    --name default \
    --resource-group $resourceGroup \
    --network-security-group BUREAU-nsg

az network nsg rule create \
    --resource-group $resourceGroup \
    --nsg-name Bureau-nsg \
    --name Allow-RDP \
    --protocol tcp \
    --priority 1000 \
    --destination-port-range 3389 \
    --access allow



# NSG et leurs réseaux associés
declare -A nsgs
nsgs=(
  ["DC-nsg"]="DC"
  ["NAS-nsg"]="NAS"
  ["DMZ-nsg"]="DMZ"
  ["BUREAU-nsg"]="BUREAU"
)

# Boucle pour ajouter les règles d'interconnexion dans chaque NSG
for nsg in "${!nsgs[@]}"; do
  # Règle pour permettre les connexions du réseau MONITORING
  az network nsg rule create \
    --resource-group $resourceGroup \
    --nsg-name $nsg \
    --name Allow-Monitoring \
    --protocol tcp \
    --direction inbound \
    --priority 100 \
    --source-address-prefix $monitoringNet \
    --destination-port-ranges '*' \
    --description "Allow connections from MONITORING VNet"

  # Règle spécifique pour les NSG DC-nsg (vers BUREAU) et BUREAU-nsg (vers NAS)
  if [ "$nsg" == "BUREAU-nsg" ]; then
    # Règle pour permettre les connexions du réseau DC vers BUREAU
    az network nsg rule create \
      --resource-group $resourceGroup \
      --nsg-name $nsg \
      --name Allow-DC \
      --protocol tcp \
      --direction inbound \
      --priority 200 \
      --source-address-prefix $dcNet \
      --destination-port-ranges '*' \
      --description "Allow connections from DC VNet to BUREAU VNet"

    # Règle pour permettre les connexions du réseau BUREAU vers NAS
    az network nsg rule create \
      --resource-group $resourceGroup \
      --nsg-name NAS-nsg \
      --name Allow-BUREAU \
      --protocol tcp \
      --direction inbound \
      --priority 300 \
      --source-address-prefix $bureauNet \
      --destination-port-ranges '*' \
      --description "Allow connections from BUREAU VNet to NAS VNet"
  fi
done

# Créer une VM Windows Server 2022 dans DC pour Active Directory
az vm create \
    --resource-group $resourceGroup \
    --name ADServer \
    --image Win2022Datacenter \
    --admin-username $adminWindowsUsername \
    --admin-password $adminWindowsPassword \
    --vnet-name DC \
    --subnet default \
    --nsg DC-nsg \
    --size Standard_B1s

# Créer une VM Windows 11 Dans Bureau
az vm create \
    --resource-group $resourceGroup \
    --name Win11-User \
    --image MicrosoftWindowsDesktop:Windows-11:win11-21h2-pro:latest \
    --admin-username $adminWindowsUsername \
    --admin-password $adminWindowsPassword \
    --vnet-name Bureau \
    --subnet default \
    --nsg Bureau-nsg \
    --size Standard_B1s


# Créer les VMs Debian
cloudInitMountScriptNas=$(cat <<EOF
#cloud-config
runcmd:
  - apt-get update
  - apt-get install -y curl
  - mkdir /mnt/scripts
  - curl -o /mnt/scripts/install_docker.sh https://$storageAccountName.blob.core.windows.net/$storageContainerName/install_docker.sh
  - chmod +x /mnt/scripts/install_docker.sh
  - /mnt/scripts/install_docker.sh truenas_glpi
EOF
)

echo "$cloudInitMountScriptNas" > cloud-init-nas.txt

az vm create \
    --resource-group $resourceGroup \
    --name DebianNAS \
    --image Debian:debian-12:12:latest \
    --admin-username $adminLinuxUsername \
    --admin-password $adminLinuxPassword \
    --custom-data cloud-init-nas.txt \
    --vnet-name NAS \
    --subnet default \
    --nsg NAS-nsg \
    --size Standard_B1s

cloudInitMountScriptMonitoring=$(cat <<EOF
#cloud-config
runcmd:
  - apt-get update
  - apt-get install -y curl
  - mkdir /mnt/scripts
  - curl -o /mnt/scripts/install_docker.sh https://$storageAccountName.blob.core.windows.net/$storageContainerName/install_docker.sh
  - chmod +x /mnt/scripts/install_docker.sh
  - /mnt/scripts/install_docker.sh uptime_kuma
EOF
)

echo "$cloudInitMountScriptMonitoring" > cloud-init-monitoring.txt

az vm create \
    --resource-group $resourceGroup \
    --name DebianMonitoring \
    --image Debian:debian-12:12:latest \
    --admin-username $adminLinuxUsername \
    --admin-password $adminLinuxPassword \
    --custom-data cloud-init-monitoring.txt \
    --vnet-name MONITORING \
    --subnet default \
    --nsg MONITORING-nsg \
    --size Standard_B1s

cloudInitMountScriptDmz=$(cat <<EOF
#cloud-config
runcmd:
  - apt-get update
  - apt-get install -y curl
  - mkdir /mnt/scripts
  - curl -o /mnt/scripts/install_docker.sh https://$storageAccountName.blob.core.windows.net/$storageContainerName/install_docker.sh
  - chmod +x /mnt/scripts/install_docker.sh
  - /mnt/scripts/install_docker.sh haproxy
EOF
)

echo "$cloudInitMountScriptDmz" > cloud-init-dmz.txt

az vm create \
    --resource-group $resourceGroup \
    --name DebianDMZ \
    --image Debian:debian-12:12:latest \
    --admin-username $adminLinuxUsername \
    --admin-password $adminLinuxPassword \
    --custom-data cloud-init-dmz.txt \
    --vnet-name DMZ \
    --subnet default \
    --nsg DMZ-nsg \
    --size Standard_B1s

# Créer une base de données Azure SQL dans le réseau DMZ
az sql server create \
    --name $sqlServerName \
    --resource-group $resourceGroup \
    --location westus \
    --admin-user $sqlAdminUser \
    --admin-password $sqlAdminPassword

az sql db create \
    --resource-group $resourceGroup \
    --server $sqlServerName \
    --name $sqlDatabaseName \
    --service-objective S0

# Configurer le pare-feu pour permettre l'accès à la base de données Azure SQL depuis le réseau DMZ
dmzVnetId=$(az network vnet show --resource-group $resourceGroup --name DMZ --query id --output tsv)
az sql server vnet-rule create \
    --resource-group $resourceGroup \
    --server $sqlServerName \
    --name AllowDMZ \
    --vnet-name DMZ \
    --subnet default

# Créer un Load Balancer Azure
az network lb create \
  --resource-group $resourceGroup \
  --name LoadBalancerDMZ \
  --sku Basic \
  --frontend-ip-name myFrontEndPool \
  --backend-pool-name myBackEndPool \
  --vnet-name DMZ \
  --subnet default

dmzVmPrivateIp=$(az vm list-ip-addresses --resource-group $resourceGroup --name DebianDMZ --query "[].virtualMachine.network.privateIpAddresses[0]" --output tsv)


# Créer des probes de santé pour le Load Balancer
az network lb probe create \
  --resource-group $resourceGroup \
  --lb-name LoadBalancerDMZ \
  --name myHealthProbe \
  --protocol tcp \
  --port 80

az network lb probe create \
  --resource-group $resourceGroup \
  --lb-name LoadBalancerDMZ \
  --name myHealthProbe2 \
  --protocol tcp \
  --port 81

# Ajouter les instances HAProxy au pool backend du Load Balancer
az network lb backend-address-pool address add \
  --resource-group $resourceGroup \
  --lb-name LoadBalancerDMZ \
  --pool-name myBackEndPool \
  --vnet DMZ \
  --ip-addresses $dmzVmPrivateIp

# Ajouter des règles de Load Balancer pour diriger le trafic vers les instances HAProxy
az network lb rule create \
  --resource-group $resourceGroup \
  --lb-name LoadBalancerDMZ \
  --name LoadBalancerRuleWeb \
  --protocol tcp \
  --frontend-port 80 \
  --backend-port 80 \
  --frontend-ip-name myFrontEndPool \
  --backend-pool-name myBackEndPool \
  --probe-name myHealthProbe

az network lb rule create \
  --resource-group $resourceGroup \
  --lb-name LoadBalancerDMZ \
  --name LoadBalancerRuleWeb2 \
  --protocol tcp \
  --frontend-port 81 \
  --backend-port 81 \
  --frontend-ip-name myFrontEndPool \
  --backend-pool-name myBackEndPool \
  --probe-name myHealthProbe2
  
