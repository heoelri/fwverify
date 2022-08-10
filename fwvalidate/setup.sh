SUBSCRIPTION_ID=cb8d2bb0-ed2c-44e5-a01b-cde33c0320a4

PREFIX=afd-pl-fw
LOCATION=westeurope
KUBEVER=1.23.5

RGNAME=$PREFIX-rg
FWNAME=$PREFIX-fw
VNETNAME=$PREFIX-vnet
AKSNAME=$PREFIX-aks

# create resource group
az group create --name $RGNAME --location $LOCATION

# create virtual network and different subnets
az network vnet create --name $VNETNAME -g $RGNAME -l $LOCATION --address-prefixes 10.10.0.0/16
az network vnet subnet create --address-prefixes 10.10.1.0/24 --name AzureFirewallSubnet --vnet-name $VNETNAME -g $RGNAME
KUBE_AGENT_SUBNET_ID=$(az network vnet subnet create --address-prefixes 10.10.2.0/24 --name kubernetes --vnet-name $VNETNAME -g $RGNAME --query id -o tsv)
INGRESS_SUBNET=$(az network vnet subnet create --address-prefixes 10.10.3.0/24 --name k8s-ingress --vnet-name $VNETNAME -g $RGNAME --query name -o tsv)

# add loganalytics workspace
az monitor log-analytics workspace create --resource-group $RGNAME --workspace-name $PREFIX-law --location $LOCATION

# create azure firewall
az extension add --name azure-firewall
az network public-ip create -g $RGNAME -n $PREFIX-fw-pip --sku Standard
az network firewall create --name $FWNAME --resource-group $RGNAME --location $LOCATION
az network firewall ip-config create --firewall-name $FWNAME --name ipconfig --public-ip-address $PREFIX-fw-pip --resource-group $RGNAME --vnet-name $VNETNAME
FW_PRIVATE_IP=$(az network firewall show -g $RGNAME -n $FWNAME --query "ipConfigurations[0].privateIpAddress" -o tsv)

# create a route table for the kubernetes subnet
az network route-table create -g $RGNAME --name $PREFIX-rt
az network route-table route create --resource-group $RGNAME --name default-fw --route-table-name $PREFIX-rt --address-prefix 0.0.0.0/0 --next-hop-type VirtualAppliance --next-hop-ip-address $FW_PRIVATE_IP --subscription $SUBSCRIPTION_ID
az network vnet subnet update --route-table $PREFIX-rt --ids $KUBE_AGENT_SUBNET_ID

# set firewall rules for aks
az network firewall network-rule create --firewall-name $FWNAME --collection-name "time" --destination-addresses "*" --destination-ports 123 --name "allow network" --protocols "UDP" --resource-group $RGNAME --source-addresses "*" --action "Allow" --description "aks node time sync rule" --priority 101
az network firewall network-rule create --firewall-name $FWNAME --collection-name "dns" --destination-addresses "*" --destination-ports 53 --name "allow network" --protocols "UDP" --resource-group $RGNAME --source-addresses "*" --action "Allow" --description "aks node dns rule" --priority 102
az network firewall network-rule create --firewall-name $FWNAME --collection-name "servicetags" --destination-addresses "AzureContainerRegistry" "MicrosoftContainerRegistry" "AzureActiveDirectory" "AzureMonitor" --destination-ports "*" --name "allow service tags" --protocols "Any" --resource-group $RGNAME --source-addresses "*" --action "Allow" --description "allow service tags" --priority 110

# rule for public cluster (needs to be refined - and not needed for private clusters)
az network firewall network-rule create --firewall-name $FWNAME --collection-name "port443" --destination-addresses "*" --destination-ports "443" --name "allow 443" --protocols "Any" --resource-group $RGNAME --source-addresses "*" --action "Allow" --description "allow 443" --priority 120
az network firewall network-rule create -g $RGNAME -f $FWNAME --collection-name 'aksfwnr' -n 'apiudp' --protocols 'UDP' --source-addresses '*' --destination-addresses "AzureCloud.$LOCATION" --destination-ports 1194 --action allow --priority 100
az network firewall network-rule create -g $RGNAME -f $FWNAME --collection-name 'aksfwnr' -n 'apitcp' --protocols 'TCP' --source-addresses '*' --destination-addresses "AzureCloud.$LOCATION" --destination-ports 9000

az network firewall application-rule create --firewall-name $FWNAME --resource-group $RGNAME --collection-name 'aksfwar' -n 'fqdn' --source-addresses '*' --protocols 'http=80' 'https=443' --fqdn-tags "AzureKubernetesService" --action allow --priority 101
az network firewall application-rule create --firewall-name $FWNAME --collection-name "osupdates" --name "allow network" --protocols http=80 https=443 --source-addresses "*" --resource-group $RGNAME --priority 102 --action "Allow"  --target-fqdns "download.opensuse.org" "security.ubuntu.com" "packages.microsoft.com" "azure.archive.ubuntu.com" "changelogs.ubuntu.com" "snapcraft.io" "api.snapcraft.io" "motd.ubuntu.com"
az network firewall application-rule create --firewall-name $FWNAME --collection-name "osupdates" --name "allow gcp sources" --protocols http=80 https=443 --source-addresses "*" --resource-group $RGNAME --priority 103 --action "Allow"  --target-fqdns "registry.k8s.io" "k8s.gcr.io" "storage.googleapis.com"
# create aks cluster
az identity create --name $AKSNAME --resource-group $RGNAME
MSI_RESOURCE_ID=$(az identity show -n $AKSNAME -g $RGNAME -o json | jq -r ".id")
MSI_CLIENT_ID=$(az identity show -n $AKSNAME -g $RGNAME -o json | jq -r ".clientId")
az role assignment create --role "Virtual Machine Contributor" --assignee $MSI_CLIENT_ID -g $RGNAME
az role assignment create --role "Network Contributor" --assignee $MSI_CLIENT_ID -g $RGNAME # this can be refined as well (granting access only to the subnet e.g.)
az aks create --resource-group $RGNAME --name $AKSNAME --load-balancer-sku standard --network-plugin azure --vnet-subnet-id $KUBE_AGENT_SUBNET_ID --enable-managed-identity --assign-identity $MSI_RESOURCE_ID --kubernetes-version $KUBEVER --outbound-type userDefinedRouting #--docker-bridge-address 172.17.0.1/16 --dns-service-ip 10.2.0.10 --service-cidr 10.2.0.0/24

az aks get-credentials -n $AKSNAME -g $RGNAME

NAMESPACE=ingress-nginx

helm repo add ingress-nginx https://kubernetes.github.io/ingress-nginx
helm repo update

helm upgrade --install ingress-nginx ingress-nginx/ingress-nginx \
  --create-namespace \
  --namespace $NAMESPACE \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-internal"="true" \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-pls-create"="true" \
  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-pls-ip-configuration-subnet"=$INGRESS_SUBNET