SUBSCRIPTION_ID=cb8d2bb0-ed2c-44e5-a01b-cde33c0320a4

PREFIX=afdperf
LOCATION=westeurope
KUBEVER=1.23.5

RGNAME=$PREFIX-rg
VNETNAME=$PREFIX-vnet
FDNAME=$PREFIX-fd

az account set -s $SUBSCRIPTION_ID

# create resource group
az group create --name $RGNAME --location $LOCATION

# create virtual network and different subnets
az network vnet create --name $VNETNAME -g $RGNAME -l $LOCATION --address-prefixes 10.10.0.0/16
az network vnet subnet create --address-prefixes 10.10.1.0/24 --name PrivateLink --vnet-name $VNETNAME -g $RGNAME
CLIENTSUBNET=$(az network vnet subnet create --address-prefixes 10.10.2.0/24 --name Clients --vnet-name $VNETNAME -g $RGNAME --query id -o tsv)

# create a static storage account backend
STORAGEID=$(az storage account create --name $PREFIX"static" --resource-group $RGNAME --location $LOCATION --query id -o tsv)

# add loganalytics workspace
az monitor log-analytics workspace create --resource-group $RGNAME --workspace-name $PREFIX-law --location $LOCATION

# create client vm
az vm create --name $PREFIX"client" --resource-group $RGNAME \
             --admin-username $PREFIX"user" --admin-password $PREFIX"pass!" --authentication-type "password" \
             --os-type "linux" --subnet $CLIENTSUBNET --public-ip-address "" --image Debian

# create front door
az afd profile create --profile-name $FDNAME --resource-group $RGNAME --sku Premium_AzureFrontDoor
az afd endpoint create --endpoint-name $FDNAME --profile-name $FDNAME --resource-group $RGNAME --enabled-state Enabled
az afd origin-group create --origin-group-name storage --probe-path "/" --probe-protocol Https \
                           --probe-request-type HEAD \
                           --profile-name $FDNAME \
                           --resource-group $RGNAME \
                           --sample-size 1 --successful-samples-required 1 \
                           --additional-latency-in-milliseconds 10

az afd origin create --enabled-state Enabled --host-name $PREFIX"static.blob.core.windows.net" \
                     --origin-group-name storage \
                     --origin-name storage \
                     --profile-name $FDNAME \
                     --resource-group $RGNAME \
                     --enable-private-link true \
                     --private-link-location $LOCATION \
                     --private-link-resource $STORAGEID \
                     --private-link-sub-resource-type blob \
                     --private-link-request-message "access"

az afd route create --endpoint-name $FDNAME --forwarding-protocol HttpsOnly --https-redirect Enabled --origin-group storage \
                    --link-to-default-domain Enabled \
                    --profile-name $FDNAME \
                    --resource-group $RGNAME \
                    --route-name $FDNAME \
                    --supported-protocols Https

# retrieve PE connection request for storage account#
PEREQUEST=$(az storage account show -n $PREFIX"static" --query "privateEndpointConnections[0].id" -o tsv)
az storage account private-endpoint-connection approve --id $PEREQUEST